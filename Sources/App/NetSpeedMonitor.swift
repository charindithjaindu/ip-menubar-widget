import Foundation

/// Measures live download/upload throughput by diffing the OS interface byte
/// counters between samples. Menu-bar-app only — a widget can't sample live.
final class NetSpeedMonitor {

    /// Bytes per second since the previous sample.
    private(set) var downloadBytesPerSec: Double = 0
    private(set) var uploadBytesPerSec: Double = 0

    /// Raw bytes transferred during the most recent sample interval. The data
    /// usage tracker accumulates these into per-day totals.
    private(set) var lastIntervalDownloadBytes: UInt64 = 0
    private(set) var lastIntervalUploadBytes: UInt64 = 0

    private var lastReceived: UInt64 = 0
    private var lastSent: UInt64 = 0
    private var lastSampleTime: Date?

    /// Reads current counters and updates the per-second rates.
    func sample() {
        let counters = Self.interfaceBytes()
        let now = Date()

        defer {
            lastReceived = counters.received
            lastSent = counters.sent
            lastSampleTime = now
        }

        guard let last = lastSampleTime else { return } // first sample: no baseline yet
        let elapsed = now.timeIntervalSince(last)
        guard elapsed > 0 else { return }

        // Counters can wrap (they're 32-bit per interface); treat a decrease as 0.
        let down = counters.received >= lastReceived ? counters.received - lastReceived : 0
        let up = counters.sent >= lastSent ? counters.sent - lastSent : 0
        lastIntervalDownloadBytes = down
        lastIntervalUploadBytes = up
        downloadBytesPerSec = Double(down) / elapsed
        uploadBytesPerSec = Double(up) / elapsed
    }

    /// Sum of received/sent bytes across all non-loopback hardware interfaces.
    private static func interfaceBytes() -> (received: UInt64, sent: UInt64) {
        var received: UInt64 = 0
        var sent: UInt64 = 0

        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return (0, 0) }
        defer { freeifaddrs(addrs) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cursor = ptr {
            let ifa = cursor.pointee
            // Per-interface byte counts live on the AF_LINK (data-link) entry.
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
               let dataPtr = ifa.ifa_data {
                let name = String(cString: ifa.ifa_name)
                if !name.hasPrefix("lo") { // skip loopback
                    let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
                    received += UInt64(data.ifi_ibytes)
                    sent += UInt64(data.ifi_obytes)
                }
            }
            ptr = ifa.ifa_next
        }
        return (received, sent)
    }

    /// "1.2 MB/s", "840 KB/s", etc.
    static func format(_ bytesPerSec: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytesPerSec
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0
            ? String(format: "%.0f %@", value, units[unit])
            : String(format: "%.1f %@", value, units[unit])
    }

    /// Compact form for the cramped menu bar, e.g. "1.2M", "840K", "0".
    static func formatCompact(_ bytesPerSec: Double) -> String {
        let units = ["", "K", "M", "G"]
        var value = bytesPerSec
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0
            ? String(format: "%.0f%@", value, units[unit])
            : String(format: "%.1f%@", value, units[unit])
    }
}

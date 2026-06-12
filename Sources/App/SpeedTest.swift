import Foundation

/// On-demand bandwidth test against Cloudflare's speed-test endpoints
/// (`speed.cloudflare.com` — anycast, no API key needed). Measures latency,
/// then sustained download and upload throughput for a few seconds each.
enum SpeedTest {

    struct Result {
        let pingMillis: Double
        let downloadBitsPerSec: Double
        let uploadBitsPerSec: Double
    }

    enum Phase {
        case ping, download, upload

        var label: String {
            switch self {
            case .ping: return "Measuring ping…"
            case .download: return "Testing download…"
            case .upload: return "Testing upload…"
            }
        }
    }

    /// How long each throughput direction is exercised. Long enough to get
    /// past TCP slow start, short enough that the user will actually wait.
    private static let measureDuration: TimeInterval = 8

    static func run(onPhase: @escaping @MainActor (Phase) -> Void) async -> Result? {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15

        await onPhase(.ping)
        guard let ping = await measurePing(config: config) else { return nil }

        await onPhase(.download)
        guard let download = await measureDownload(config: config) else { return nil }

        await onPhase(.upload)
        guard let upload = await measureUpload(config: config) else { return nil }

        return Result(pingMillis: ping, downloadBitsPerSec: download, uploadBitsPerSec: upload)
    }

    /// "245.3 Mbps" — decimal megabits, the unit every speed test reports in.
    static func formatMbps(_ bitsPerSec: Double) -> String {
        String(format: "%.1f Mbps", bitsPerSec / 1_000_000)
    }

    // MARK: - Ping

    /// Best of several zero-byte round trips. The first one also pays the TLS
    /// handshake, which is why we take the minimum rather than the mean.
    private static func measurePing(config: URLSessionConfiguration) async -> Double? {
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=0") else { return nil }
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var best: Double?
        for _ in 0..<4 {
            let start = Date()
            guard let (_, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let ms = Date().timeIntervalSince(start) * 1000
            best = min(best ?? ms, ms)
        }
        return best
    }

    // MARK: - Download

    private static func measureDownload(config: URLSessionConfiguration) async -> Double? {
        // Ask for far more than any connection can move in the window; the
        // probe cancels the transfer once its time is up.
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=2000000000") else { return nil }
        let probe = DownloadProbe(duration: measureDuration)
        let session = URLSession(configuration: config, delegate: probe, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (bytes, elapsed) = await probe.run(in: session, request: URLRequest(url: url))
        guard bytes > 0, elapsed > 0.2 else { return nil }
        return Double(bytes) * 8 / elapsed
    }

    /// Counts received bytes and cancels the task once the measurement window
    /// (timed from the first byte, so connection setup isn't billed) closes.
    private final class DownloadProbe: NSObject, URLSessionDataDelegate {
        private let duration: TimeInterval
        private var bytes: Int64 = 0
        private var firstByte: Date?
        private var continuation: CheckedContinuation<(Int64, TimeInterval), Never>?

        init(duration: TimeInterval) { self.duration = duration }

        func run(in session: URLSession, request: URLRequest) async -> (Int64, TimeInterval) {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                session.dataTask(with: request).resume()
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            if firstByte == nil { firstByte = Date() }
            bytes += Int64(data.count)
            if let firstByte, Date().timeIntervalSince(firstByte) >= duration {
                dataTask.cancel() // expected; the cancel "error" still hits didComplete
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let elapsed = firstByte.map { Date().timeIntervalSince($0) } ?? 0
            continuation?.resume(returning: (bytes, elapsed))
            continuation = nil
        }
    }

    // MARK: - Upload

    private static func measureUpload(config: URLSessionConfiguration) async -> Double? {
        guard let url = URL(string: "https://speed.cloudflare.com/__up") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        // POST fixed-size chunks back-to-back over one session (so the
        // connection is reused and only the first chunk pays the handshake)
        // until the time budget is spent.
        let chunk = Data(count: 16 << 20) // 16 MB
        let probe = UploadProbe()
        let session = URLSession(configuration: config, delegate: probe, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var totalBytes: Int64 = 0
        var totalTime: TimeInterval = 0
        while totalTime < measureDuration {
            let (bytes, elapsed) = await probe.run(
                in: session, request: request, body: chunk,
                budget: measureDuration - totalTime
            )
            if bytes == 0 || elapsed <= 0 { break }
            totalBytes += bytes
            totalTime += elapsed
        }
        guard totalBytes > 0, totalTime > 0.2 else { return nil }
        return Double(totalBytes) * 8 / totalTime
    }

    /// Counts sent body bytes and cancels the task when its share of the time
    /// budget runs out (so one chunk can't stall a slow connection forever).
    /// Reused across the sequential chunk uploads of a single measurement.
    private final class UploadProbe: NSObject, URLSessionTaskDelegate {
        private var budget: TimeInterval = 0
        private var sent: Int64 = 0
        private var start: Date?
        private var continuation: CheckedContinuation<(Int64, TimeInterval), Never>?

        func run(in session: URLSession, request: URLRequest, body: Data, budget: TimeInterval) async -> (Int64, TimeInterval) {
            self.budget = budget
            sent = 0
            start = nil
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                session.uploadTask(with: request, from: body).resume()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                        totalBytesExpectedToSend: Int64) {
            if start == nil { start = Date() }
            sent = totalBytesSent
            if let start, Date().timeIntervalSince(start) >= budget {
                task.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let elapsed = start.map { Date().timeIntervalSince($0) } ?? 0
            continuation?.resume(returning: (sent, elapsed))
            continuation = nil
        }
    }
}

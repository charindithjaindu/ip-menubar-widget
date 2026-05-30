import AppKit

/// A small window that shows a day-by-day and month-by-month breakdown of data
/// usage, so the user can "check" history beyond the today / this-month summary
/// in the menu.
final class StatisticsWindowController: NSWindowController {

    private let tracker: DataUsageTracker
    private let textView = NSTextView()

    init(tracker: DataUsageTracker) {
        self.tracker = tracker

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Data Usage Statistics"
        window.isReleasedWhenClosed = false

        super.init(window: window)

        let contentView = window.contentView!
        let scroll = NSScrollView(frame: contentView.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        // An NSTextView placed manually inside a scroll view must have its
        // sizing wired up explicitly, or it renders zero-height (blank window).
        let contentSize = scroll.contentSize
        textView.frame = NSRect(origin: .zero, size: contentSize)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 14, height: 14)

        scroll.documentView = textView
        contentView.addSubview(scroll)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Refresh the report and bring the window to the front.
    func present() {
        renderReport()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func renderReport() {
        var lines: [String] = []

        let todayDown = tracker.todayDownload
        let todayUp = tracker.todayUpload
        let monthDown = tracker.monthDownload
        let monthUp = tracker.monthUpload

        lines.append("SUMMARY")
        lines.append(String(repeating: "─", count: 46))
        lines.append(summaryLine("Today", down: todayDown, up: todayUp))
        lines.append(summaryLine("This month", down: monthDown, up: monthUp))
        lines.append("")

        let months = tracker.monthlyTotals()
        if !months.isEmpty {
            lines.append("BY MONTH")
            lines.append(header())
            for m in months {
                lines.append(row(label: m.month, down: m.download, up: m.upload))
            }
            lines.append("")
        }

        let days = tracker.recentDays(60)
        if !days.isEmpty {
            lines.append("BY DAY (most recent)")
            lines.append(header())
            for d in days {
                lines.append(row(label: d.day, down: d.download, up: d.upload))
            }
        }

        if days.isEmpty && months.isEmpty {
            lines.append("No data recorded yet. Usage is counted while the app runs.")
        }

        lines.append("")
        lines.append("Counts machine-wide traffic while the app is running; not per-app.")

        textView.string = lines.joined(separator: "\n")
    }

    private func summaryLine(_ label: String, down: UInt64, up: UInt64) -> String {
        let l = label.padding(toLength: 12, withPad: " ", startingAt: 0)
        return "\(l)↓ \(DataUsageTracker.formatBytes(down))   ↑ \(DataUsageTracker.formatBytes(up))   Σ \(DataUsageTracker.formatBytes(down + up))"
    }

    private func header() -> String {
        let label = "".padding(toLength: 12, withPad: " ", startingAt: 0)
        let d = "Download".padding(toLength: 12, withPad: " ", startingAt: 0)
        let u = "Upload".padding(toLength: 12, withPad: " ", startingAt: 0)
        return "\(label)\(d)\(u)Total"
    }

    private func row(label: String, down: UInt64, up: UInt64) -> String {
        let l = label.padding(toLength: 12, withPad: " ", startingAt: 0)
        let d = DataUsageTracker.formatBytes(down).padding(toLength: 12, withPad: " ", startingAt: 0)
        let u = DataUsageTracker.formatBytes(up).padding(toLength: 12, withPad: " ", startingAt: 0)
        return "\(l)\(d)\(u)\(DataUsageTracker.formatBytes(down + up))"
    }
}

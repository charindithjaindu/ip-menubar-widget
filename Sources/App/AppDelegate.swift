import AppKit
import WidgetKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    /// How often the menu bar app refetches automatically.
    private let refreshInterval: TimeInterval = 120 // 2 minutes

    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var info = IPInfo.loading
    private var lastUpdated: Date?
    private var isRefreshing = false

    // Live network throughput.
    private let speedMonitor = NetSpeedMonitor()
    private var speedTimer: Timer?

    // Cumulative data-usage tracking (today / this month / history).
    private let usageTracker = DataUsageTracker()
    private var flushTimer: Timer?
    private var statisticsWindow: StatisticsWindowController?

    // Menu items we update in place while the menu is open.
    private var ipv4Item: NSMenuItem!
    private var ipv6Item: NSMenuItem!
    private var countryItem: NSMenuItem!
    private var ispItem: NSMenuItem!
    private var downItem: NSMenuItem!
    private var upItem: NSMenuItem!
    private var speedTestResultItem: NSMenuItem!
    private var runSpeedTestItem: NSMenuItem!
    private var isSpeedTesting = false
    private var usageTodayItem: NSMenuItem!
    private var usageMonthItem: NSMenuItem!
    private var statusLineItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🏳️"
        buildMenu()
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        // Sample throughput every 2s; the first sample just sets the baseline.
        speedMonitor.sample()
        speedTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.speedMonitor.sample()
            self.usageTracker.record(
                download: self.speedMonitor.lastIntervalDownloadBytes,
                upload: self.speedMonitor.lastIntervalUploadBytes
            )
            self.updateSpeedRows()
            self.updateUsageRows()
            self.updateStatusTitle()
        }

        // Persist accumulated usage to disk periodically (not every sample).
        flushTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.usageTracker.flush()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        usageTracker.flush()
    }

    // MARK: - Refresh

    /// Opening the menu means the user wants fresh data, so refetch every time.
    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        updateMenu()

        Task { @MainActor in
            let newInfo = await IPService.fetch()
            self.info = newInfo
            self.lastUpdated = Date()
            self.isRefreshing = false
            self.updateStatusTitle()
            self.updateMenu()
            // Nudge the widget to pick up fresh data too.
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: - Menu

    /// Built once; values are refreshed in place via `updateMenu()` so the menu
    /// can update live while it's open.
    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(sectionTitle("My Public IP"))
        ipv4Item = valueItem(label: "IPv4", value: info.ipv4)
        ipv6Item = valueItem(label: "IPv6", value: info.ipv6)
        countryItem = valueItem(label: "Country", value: "\(info.countryFlag) \(info.country)")
        ispItem = valueItem(label: "ISP", value: info.isp)
        menu.addItem(ipv4Item)
        menu.addItem(ipv6Item)
        menu.addItem(countryItem)
        menu.addItem(ispItem)
        menu.addItem(.separator())

        menu.addItem(sectionTitle("Network Speed"))
        downItem = valueItem(label: "↓ Download", value: "—")
        upItem = valueItem(label: "↑ Upload", value: "—")
        menu.addItem(downItem)
        menu.addItem(upItem)
        menu.addItem(.separator())

        menu.addItem(sectionTitle("Speed Test"))
        speedTestResultItem = valueItem(label: "Result", value: "Not run yet")
        menu.addItem(speedTestResultItem)
        runSpeedTestItem = NSMenuItem(title: "Run Speed Test", action: #selector(runSpeedTest), keyEquivalent: "")
        runSpeedTestItem.target = self
        menu.addItem(runSpeedTestItem)
        menu.addItem(.separator())

        menu.addItem(sectionTitle("Data Usage"))
        usageTodayItem = valueItem(label: "Today", value: "—")
        usageMonthItem = valueItem(label: "This Month", value: "—")
        menu.addItem(usageTodayItem)
        menu.addItem(usageMonthItem)
        let statsItem = NSMenuItem(title: "Statistics…", action: #selector(openStatistics), keyEquivalent: "")
        statsItem.target = self
        menu.addItem(statsItem)
        menu.addItem(.separator())

        statusLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        updateMenu()
    }

    private func updateMenu() {
        setValue(ipv4Item, label: "IPv4", value: info.ipv4)
        setValue(ipv6Item, label: "IPv6", value: info.ipv6)
        setValue(countryItem, label: "Country", value: "\(info.countryFlag) \(info.country)")
        setValue(ispItem, label: "ISP", value: info.isp)
        updateSpeedRows()
        updateUsageRows()
        statusLineItem.title = isRefreshing ? "Refreshing…" : "Updated \(updatedString)"
    }

    private func updateSpeedRows() {
        guard let downItem, let upItem else { return }
        setValue(downItem, label: "↓ Download", value: NetSpeedMonitor.format(speedMonitor.downloadBytesPerSec))
        setValue(upItem, label: "↑ Upload", value: NetSpeedMonitor.format(speedMonitor.uploadBytesPerSec))
    }

    private func updateUsageRows() {
        guard let usageTodayItem, let usageMonthItem else { return }
        let today = "↓ \(DataUsageTracker.formatBytes(usageTracker.todayDownload))  ↑ \(DataUsageTracker.formatBytes(usageTracker.todayUpload))"
        let month = "↓ \(DataUsageTracker.formatBytes(usageTracker.monthDownload))  ↑ \(DataUsageTracker.formatBytes(usageTracker.monthUpload))"
        setValue(usageTodayItem, label: "Today", value: today)
        setValue(usageMonthItem, label: "This Month", value: month)
    }

    /// Runs the on-demand bandwidth test. The phase/result rows update in place,
    /// so the user can watch progress with the menu open — and the test keeps
    /// running to completion even if they close it.
    @objc private func runSpeedTest() {
        guard !isSpeedTesting else { return }
        isSpeedTesting = true
        runSpeedTestItem.action = nil // greys the item out while the test runs

        Task { @MainActor in
            let result = await SpeedTest.run { [weak self] phase in
                self?.runSpeedTestItem.title = phase.label
            }
            if let result {
                let value = "↓ \(SpeedTest.formatMbps(result.downloadBitsPerSec))  ↑ \(SpeedTest.formatMbps(result.uploadBitsPerSec))  •  \(Int(result.pingMillis.rounded())) ms ping"
                self.setValue(self.speedTestResultItem, label: "Result", value: value)
            } else {
                self.setValue(self.speedTestResultItem, label: "Result", value: "Failed — try again")
            }
            self.runSpeedTestItem.title = "Run Speed Test"
            self.runSpeedTestItem.action = #selector(self.runSpeedTest)
            self.isSpeedTesting = false
        }
    }

    @objc private func openStatistics() {
        usageTracker.flush()
        if statisticsWindow == nil {
            statisticsWindow = StatisticsWindowController(tracker: usageTracker)
        }
        statisticsWindow?.present()
    }

    /// Menu bar title: flag + the dominant transfer direction only.
    private func updateStatusTitle() {
        let down = speedMonitor.downloadBytesPerSec
        let up = speedMonitor.uploadBytesPerSec
        let arrow: String
        let rate: Double
        if up > down {
            arrow = "↑"
            rate = up
        } else {
            arrow = "↓"
            rate = down
        }
        statusItem.button?.title = "\(info.countryFlag) \(arrow)\(NetSpeedMonitor.formatCompact(rate))"
    }

    private func sectionTitle(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// A clickable row that copies its value to the clipboard.
    private func valueItem(label: String, value: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(copyValue(_:)), keyEquivalent: "")
        item.target = self
        item.toolTip = "Click to copy"
        setValue(item, label: label, value: value)
        return item
    }

    private func setValue(_ item: NSMenuItem, label: String, value: String) {
        item.title = "\(label):  \(value)"
        item.representedObject = value
    }

    @objc private func copyValue(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private var updatedString: String {
        guard let lastUpdated else { return "never" }
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter.string(from: lastUpdated)
    }
}

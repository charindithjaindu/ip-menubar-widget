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

    // Menu items we update in place while the menu is open.
    private var ipv4Item: NSMenuItem!
    private var ipv6Item: NSMenuItem!
    private var countryItem: NSMenuItem!
    private var ispItem: NSMenuItem!
    private var downItem: NSMenuItem!
    private var upItem: NSMenuItem!
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
            self.updateSpeedRows()
            self.updateStatusTitle()
        }
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
        statusLineItem.title = isRefreshing ? "Refreshing…" : "Updated \(updatedString)"
    }

    private func updateSpeedRows() {
        guard let downItem, let upItem else { return }
        setValue(downItem, label: "↓ Download", value: NetSpeedMonitor.format(speedMonitor.downloadBytesPerSec))
        setValue(upItem, label: "↑ Upload", value: NetSpeedMonitor.format(speedMonitor.uploadBytesPerSec))
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

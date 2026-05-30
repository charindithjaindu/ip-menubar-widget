import WidgetKit
import SwiftUI

struct IPEntry: TimelineEntry {
    let date: Date
    let info: IPInfo
}

struct IPProvider: TimelineProvider {
    func placeholder(in context: Context) -> IPEntry {
        IPEntry(date: Date(), info: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (IPEntry) -> Void) {
        if context.isPreview {
            completion(IPEntry(date: Date(), info: .placeholder))
            return
        }
        Task {
            let info = await IPService.fetch()
            completion(IPEntry(date: Date(), info: info))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<IPEntry>) -> Void) {
        Task {
            let info = await IPService.fetch()
            let entry = IPEntry(date: Date(), info: info)
            // macOS throttles widget refreshes against a daily budget; ~15 min is realistic.
            let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

struct IPWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: IPEntry

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 10) {
            HStack {
                Text("My IP")
                    .font(.headline)
                Spacer()
                Button(intent: RefreshIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            row(label: "IPv4", value: entry.info.ipv4)
            row(label: "IPv6", value: entry.info.ipv6)
            row(label: entry.info.countryFlag, value: entry.info.country)
            if family != .systemSmall {
                row(label: "ISP", value: entry.info.isp)
            }

            Spacer(minLength: 0)

            Text("Updated \(entry.date, style: .time)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private func row(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
}

struct IPWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "IPWidget", provider: IPProvider()) { entry in
            IPWidgetView(entry: entry)
        }
        .configurationDisplayName("My IP")
        .description("Shows your public IPv4, IPv6 and country.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

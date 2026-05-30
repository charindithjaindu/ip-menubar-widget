import AppIntents
import WidgetKit

/// Powers the manual refresh button inside the widget (interactive widgets, macOS 14+).
struct RefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh IP"
    static var description = IntentDescription("Reload the public IP information.")

    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

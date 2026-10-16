import Foundation

/// A recipe's trigger in words for the list and the card ("Weekdays 09:00",
/// "Button: Release", "On new Gmail (work)"). `specJSON` is the
/// `trigger_spec` column: `{"schedule":…}`, `{"button":{"label":…}}`,
/// `{"event":{"type":…,"where":{…}}}` or `{"manual":true}`.
package enum AutomationTriggerText {
    private struct Spec: Decodable {
        struct Button: Decodable { let label: String? }
        struct Event: Decodable {
            let type: String?
            let `where`: [String: String]?
        }

        let schedule: String?
        let button: Button?
        let event: Event?
    }

    private static let eventWords: [String: String] = [
        "gmail.new_messages": "On new Gmail",
        "slack.new_messages": "On new Slack messages",
        "jira.issue_changed": "On Jira change",
        "calendar.event_changed": "On calendar change",
        "confluence.page_changed": "On Confluence change"
    ]

    package static func describe(kind: String, specJSON: String) -> String {
        let spec = try? JSONDecoder().decode(Spec.self, from: Data(specJSON.utf8))
        switch kind {
        case "schedule":
            guard let expr = spec?.schedule, !expr.isEmpty else { return "Schedule" }
            return CronText.describe(expr)
        case "button":
            guard let label = spec?.button?.label, !label.isEmpty else { return "Button" }
            return "Button: \(label)"
        case "event":
            let type = spec?.event?.type ?? ""
            let base = eventWords[type] ?? (type.isEmpty ? "On event" : "On \(type)")
            let filter = (spec?.event?.where ?? [:]).sorted { $0.key < $1.key }.map(\.value).joined(separator: ", ")
            return filter.isEmpty ? base : "\(base) (\(filter))"
        case "manual":
            return "Manual"
        default:
            return "—"
        }
    }
}

/// A five-field cron expression in words for the common shapes (a fixed
/// minute, one or more hours, any day of month and month, and every day,
/// weekdays or one weekday); anything else is shown as "Cron: <expr>".
package enum CronText {
    private static let dayNames = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays",
                                   "Saturdays", "Sundays"]

    package static func describe(_ expr: String) -> String {
        let fallback = "Cron: \(expr)"
        let fields = expr.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 5, fields[2] == "*", fields[3] == "*",
              let minute = Int(fields[0]), (0...59).contains(minute) else { return fallback }
        let hourParts = fields[1].split(separator: ",", omittingEmptySubsequences: false).map { Int($0) }
        guard !hourParts.isEmpty else { return fallback }
        var hours: [Int] = []
        for hour in hourParts {
            guard let hour, (0...23).contains(hour) else { return fallback }
            hours.append(hour)
        }
        let days: String
        switch fields[4] {
        case "*": days = "Daily"
        case "1-5": days = "Weekdays"
        default:
            guard let dow = Int(fields[4]), dayNames.indices.contains(dow) else { return fallback }
            days = dayNames[dow]
        }
        let times = hours.map { String(format: "%02d:%02d", $0, minute) }.joined(separator: ", ")
        return "\(days) \(times)"
    }
}

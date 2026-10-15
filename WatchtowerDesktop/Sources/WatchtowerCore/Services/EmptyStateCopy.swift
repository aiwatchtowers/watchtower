import Foundation

/// What a tab's empty state says: what lands here, whose readiness line
/// shows, and the one thing to do now.
package struct EmptyStateCopy: Equatable, Sendable {
    /// SF Symbol, the tab's sidebar icon.
    package let icon: String
    /// "No briefings yet"
    package let title: String
    /// One sentence; `{hour}` is already filled in by `EmptyStateCopyTable.copy`.
    package let landsHere: String
    /// Whose readiness line shows; nil = none.
    package let feature: ReadinessFeature?
    package let primaryAction: EmptyStateAction?

    package init(
        icon: String, title: String, landsHere: String, feature: ReadinessFeature?, primaryAction: EmptyStateAction?
    ) {
        self.icon = icon
        self.title = title
        self.landsHere = landsHere
        self.feature = feature
        self.primaryAction = primaryAction
    }
}

package enum EmptyStateAction: Equatable, Sendable {
    /// Shown only when readiness is `.off`.
    case turnOn(featureID: String)
    /// Shown only when readiness is `.needsSource`.
    case connect(ReadinessSource)
    /// A Settings tab, e.g. "features" for the briefing and day plan hours,
    /// under the button's own label.
    case openSettings(tab: String, label: String)
    /// The tab's own existing action (e.g. "Build a recap").
    case tabAction(label: String)
}

/// The per-tab copy (first-run spec §1.5). UI text is English only.
package enum EmptyStateCopyTable {
    /// Keyed by `SidebarDestination.rawValue` (SidebarDestination lives in the
    /// Desktop target; Workbench's persisted raw value is "projects").
    package static func copy(for destinationRawValue: String, briefingHour: Int, dayPlanHour: Int) -> EmptyStateCopy? {
        guard let row = rows[destinationRawValue] else { return nil }
        let hour: Int? = switch destinationRawValue {
        case "briefings": briefingHour
        case "dayPlan": dayPlanHour
        default: nil
        }
        guard let hour else { return row }
        return EmptyStateCopy(
            icon: row.icon,
            title: row.title,
            landsHere: row.landsHere.replacingOccurrences(of: "{hour}", with: String(format: "%02d:00", hour)),
            feature: row.feature,
            primaryAction: row.primaryAction
        )
    }

    /// Raw values with intentionally no shared empty state (search, usage,
    /// mcpServer, chat keep theirs).
    package static let exempt: Set<String> = ["search", "usage", "mcpServer", "chat"]

    private static func jira(_ icon: String, _ title: String, _ landsHere: String) -> EmptyStateCopy {
        EmptyStateCopy(icon: icon, title: title, landsHere: landsHere, feature: .jira, primaryAction: .connect(.jira))
    }

    private static let rows: [String: EmptyStateCopy] = [
        "catchUp": EmptyStateCopy(
            icon: "tray.and.arrow.down", title: "No recap yet",
            landsHere: "A recap of what you missed while away, built from Slack, mail, Jira and the calendar.",
            feature: .digests, primaryAction: .tabAction(label: "Build a recap")),
        "briefings": EmptyStateCopy(
            icon: "sun.max", title: "No briefings yet",
            landsHere: "A morning briefing: meetings, what needs you, what changed. Generated once a day at or after {hour}.",
            feature: .briefing, primaryAction: .openSettings(tab: "features", label: "Change the hour")),
        "dayPlan": EmptyStateCopy(
            icon: "calendar.day.timeline.left", title: "No day plan yet",
            landsHere: "Your day in time blocks, from the calendar, targets and the briefing. Once a day at or after {hour}.",
            feature: .dayPlan, primaryAction: .openSettings(tab: "features", label: "Change the hour")),
        "inbox": EmptyStateCopy(
            icon: "tray", title: "Nothing waiting for you",
            landsHere: "Proposals and due reminders that need you, plus reaction shortcuts.",
            feature: .inbox, primaryAction: nil),
        "ideas": EmptyStateCopy(
            icon: "lightbulb", title: "No ideas yet",
            landsHere: "Ideas and decisions picked up from conversations, every ~6 h.",
            feature: .ideas, primaryAction: nil),
        "calendar": EmptyStateCopy(
            icon: "calendar", title: "No meetings yet",
            landsHere: "Today's meetings with prep.",
            feature: .calendar, primaryAction: .connect(.calendar)),
        "targets": EmptyStateCopy(
            icon: "scope", title: "No targets yet",
            landsHere: "Your tasks — from you, from Slack reactions, from meetings.",
            feature: nil, primaryAction: .tabAction(label: "New target")),
        "tracks": EmptyStateCopy(
            icon: "binoculars", title: "No tracks yet",
            landsHere: "Ongoing topics Watchtower follows across channels.",
            feature: .tracks, primaryAction: nil),
        "projects": EmptyStateCopy(
            icon: "folder.badge.gearshape", title: "No workbenches yet",
            landsHere: "Boards bound to a folder, where Claude Code or Codex works.",
            feature: nil, primaryAction: .tabAction(label: "Add a folder")),
        "digests": EmptyStateCopy(
            icon: "doc.text.magnifyingglass", title: "No digests yet",
            landsHere: "Per-channel summaries after each sync.",
            feature: .digests, primaryAction: nil),
        "people": EmptyStateCopy(
            icon: "person.2", title: "No people cards yet",
            landsHere: "A card per colleague: role, what they work on, how to reach them. First cards after the first digests.",
            feature: .peopleCards, primaryAction: nil),
        "memory": EmptyStateCopy(
            icon: "archivebox", title: "Nothing remembered yet",
            landsHere: "What the assistant remembers about your work.",
            feature: .memory, primaryAction: .turnOn(featureID: "memory")),
        "workload": jira("gauge.with.dots.needle.33percent", "No workload yet", "Jira views: who carries how much work."),
        "blockers": jira("exclamationmark.triangle", "No blockers yet", "Jira views: what is blocked and by what."),
        "projectMap": jira("map", "No project map yet", "Jira views: how the projects and their epics fit together."),
        "releases": jira("shippingbox", "No releases yet", "Jira views: upcoming releases and what is in them."),
        "boards": jira("rectangle.on.rectangle.angled", "No boards yet", "Jira views: your Jira boards and their columns."),
        "statistics": EmptyStateCopy(
            icon: "chart.bar.xaxis", title: "No activity yet",
            landsHere: "Activity across channels.",
            feature: .slackSync, primaryAction: nil)
    ]
}

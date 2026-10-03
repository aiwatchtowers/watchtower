/// The sidebar's "+ Connect …" row and the "turn on related features?"
/// offer after a source is connected from Settings.
package enum SourceConnectPrompt {
    /// A source kind as the row names it; Google and IMAP/CalDAV are one
    /// ("Mail").
    package enum Kind: String, CaseIterable, Sendable {
        case slack, mail, jira

        package var title: String {
            switch self {
            case .slack: "Slack"
            case .mail: "Mail"
            case .jira: "Jira"
            }
        }
    }

    /// UserDefaults key: the row was closed with its ×.
    package static let dismissedKey = "sidebar_connect_row_dismissed"

    package static func missing(_ connected: ConnectedSources) -> [Kind] {
        Kind.allCases.filter { kind in
            switch kind {
            case .slack: !connected.slack
            case .mail: !(connected.mail || connected.calendar)
            case .jira: !connected.jira
            }
        }
    }

    /// "+ Connect Slack, Mail, Jira…" naming what is still missing; nil once
    /// all three are connected or the row was closed.
    package static func rowTitle(connected: ConnectedSources, dismissed: Bool) -> String? {
        let absent = missing(connected)
        guard !dismissed, !absent.isEmpty else { return nil }
        return "+ Connect " + absent.map(\.title).joined(separator: ", ") + "…"
    }

    /// The goals a newly connected source serves: Slack and mail are work
    /// communication, a calendar is meetings, Jira is tasks.
    package static func goals(newlyConnectedFrom before: ConnectedSources, to after: ConnectedSources) -> [OnboardingGoal] {
        var goals: [OnboardingGoal] = []
        if (after.slack && !before.slack) || (after.mail && !before.mail) { goals.append(.workCommunication) }
        if after.calendar && !before.calendar { goals.append(.meetings) }
        if after.jira && !before.jira { goals.append(.tasksAndJira) }
        return goals
    }

    /// The features those goals turn on (`OnboardingFeaturePlan`) that are
    /// off now, in `registryOrder`. The always-on features are not goal
    /// features, so one the owner turned off in Settings is not offered
    /// again. Nothing is enabled here: the owner confirms the list first.
    package static func suggestedFeatureIDs(
        for goals: [OnboardingGoal],
        disabled: Set<String>,
        registryOrder: [String]
    ) -> [String] {
        let wanted = goals.reduce(into: Set<String>()) { $0.formUnion(OnboardingFeaturePlan.featureIDs(for: $1)) }
        return registryOrder.filter { wanted.contains($0) && disabled.contains($0) }
    }
}

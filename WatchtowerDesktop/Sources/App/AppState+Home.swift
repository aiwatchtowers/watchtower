import Foundation
import WatchtowerCore

extension AppState {
    /// Today cards with no tab of their own to follow.
    static let homeAlwaysAllowed: Set<TodayCardKind> = [.myTargets, .agentsWaiting]

    /// The Today cards that follow a tab, shown only while that tab is.
    private static let homeCardTabs: [(TodayCardKind, SidebarDestination)] = [
        (.waitingOnYou, .inbox),
        (.nextMeeting, .calendar),
        (.briefing, .briefings),
        (.sinceYouWereAway, .catchUp)
    ]

    /// The first sync's line while it runs (Catch-Up's empty pane, Home); the
    /// history depth is read from the config only while that sync runs.
    var firstSyncLine: FirstSyncLine? {
        let daemon = daemonManager
        guard daemon.lastSyncTime == nil, daemon.syncProgress?.isSyncing() == true else { return nil }
        let text = OnboardingFinishPlan.firstSyncText(
            progress: daemon.syncProgress,
            lastSyncTime: daemon.lastSyncTime,
            historyDays: ConfigService().initialHistoryDays ?? Self.defaultInitialHistoryDays,
            connected: featureVisibility.connectedSources
        )
        return text.map { FirstSyncLine(title: $0.title, detail: $0.detail) }
    }

    /// The Today cards Home may show: a card that follows a tab (Waiting on
    /// you → Inbox, Next meeting → Calendar, Briefing → Briefings, Since you
    /// were away → Catch-Up) only while that tab is visible.
    var homeTodayCardsAllowed: Set<TodayCardKind> {
        let disabled = featureVisibility.disabledFeatureIDs
        let connected = featureVisibility.connectedSources
        let followed = Self.homeCardTabs
            .filter { $0.1.isVisible(disabledFeatures: disabled, connected: connected) }
            .map(\.0)
        return Self.homeAlwaysAllowed.union(followed)
    }
}

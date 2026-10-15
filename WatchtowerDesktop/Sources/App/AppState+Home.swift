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

    /// A Home click: a tab, or an item through the tab's own navigate helper.
    /// A tab hidden right now is left to `applyFeatureFallback` (Navigation),
    /// so a stale link lands on Home.
    func openHomeLink(_ link: HomeLink) {
        switch link {
        case .inbox: selectedDestination = .inbox
        case .calendarEvent(let id): navigateToCalendarEvent(id)
        case .briefing(let id): navigateToBriefing(id)
        case .targets: selectedDestination = .targets
        case .target(let id): navigateToTarget(id)
        case .workbench(let route): navigateToWorkbench(route)
        case .workbenches: selectedDestination = .workbench
        case .catchUp: selectedDestination = .catchUp
        case .feature(let feature): selectedDestination = Self.homeDestination(for: feature)
        case .connect(let source): performEmptyStateAction(.connect(source))
        }
    }

    /// The tab a Getting ready card's Open lands on.
    static func homeDestination(for feature: ReadinessFeature) -> SidebarDestination {
        switch feature {
        case .slackSync: .statistics
        case .digests, .streamDigests: .digests
        case .tracks: .tracks
        case .peopleCards: .people
        case .briefing: .briefings
        case .dayPlan: .dayPlan
        case .ideas: .ideas
        case .memory: .memory
        case .inbox: .inbox
        case .knowledgeIndex: .search
        case .calendar: .calendar
        case .jira: .boards
        }
    }
}

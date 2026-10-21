import AppKit
import Foundation
import WatchtowerCore

extension AppState {
    /// Feed sources with no tab or feature of their own to follow.
    static let homeFeedAlwaysAllowed: Set<FeedSource> = [.reminders, .proposals, .automations, .targets]

    /// Each Home link's tab: the link shows only while its tab does.
    private static let homeLinkTabs: [(HomeLinkKind, SidebarDestination)] = [
        (.briefing, .briefings),
        (.catchUp, .catchUp),
        (.dayPlan, .dayPlan),
        (.digests, .digests)
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

    /// The links Home's links zone may show: each only while its tab is visible.
    var homeLinksAllowed: Set<HomeLinkKind> {
        let disabled = featureVisibility.disabledFeatureIDs
        let connected = featureVisibility.connectedSources
        return Set(Self.homeLinkTabs
            .filter { $0.1.isVisible(disabledFeatures: disabled, connected: connected) }
            .map(\.0))
    }

    /// The feed sources Home may show: inbox rows only while attention
    /// detection is on, calendar rows only while the Calendar tab is visible;
    /// reminders, proposals, automation outputs and targets always.
    var homeFeedSourcesAllowed: Set<FeedSource> {
        let disabled = featureVisibility.disabledFeatureIDs
        var allowed = Self.homeFeedAlwaysAllowed
        // Attention detection (the inbox feeder) is ReadinessFeature.inbox's feature.
        if ReadinessFeature.inbox.featureID.map(disabled.contains) != true { allowed.insert(.inbox) }
        if SidebarDestination.calendar.isVisible(
            disabledFeatures: disabled, connected: featureVisibility.connectedSources) {
            allowed.insert(.calendar)
        }
        return allowed
    }

    /// Open the Automations tab on one of its sections (the Settings pointer).
    func navigateToAutomations(section: AutomationsSection) {
        UserDefaults.standard.set(section.rawValue, forKey: AutomationsSection.storageKey)
        selectedDestination = .automations
    }

    /// The Slack Digests Turn on for Home's Getting ready cards (#575); read inside a
    /// view's body, so the card follows it.
    var digestsTurnOnState: DigestsTurnOnState {
        let id = ReadinessFeature.digests.featureID ?? ""
        return DigestsTurnOnState(
            busy: isTurningOnFromEmptyState, isTurningOn: turningOnFeatureID == id,
            error: emptyStateTurnOnError(for: id))
    }

    /// A Home click: a tab, or an item through the tab's own navigate helper.
    /// A tab hidden right now is left to `applyFeatureFallback` (Navigation),
    /// so a stale link lands on Home.
    func openHomeLink(_ link: HomeLink) {
        switch link {
        case .inbox: selectedDestination = .inbox
        case .permalink(let url):
            if AllowedURLSchemes.permits(url) { NSWorkspace.shared.open(url) }
        case .calendarEvent(let id): navigateToCalendarEvent(id)
        case .briefing(let id): navigateToBriefing(id)
        case .targets: selectedDestination = .targets
        case .target(let id): navigateToTarget(id)
        case .workbench(let route): navigateToWorkbench(route)
        case .workbenches: selectedDestination = .workbench
        case .catchUp: selectedDestination = .catchUp
        case let .automationRun(automationID, runID): openAutomationRun(automationID: automationID, runID: runID)
        case let .inboxOutput(id, automationID, runID): openInboxOutput(id, automationID: automationID, runID: runID)
        case .feature(let feature): selectedDestination = Self.homeDestination(for: feature)
        case .connect(let source): performEmptyStateAction(.connect(source))
        case .turnOn(let featureID): performEmptyStateAction(.turnOn(featureID: featureID))
        }
    }

    /// An automation note's Inbox card, selected so its buttons show; the
    /// run in the Automations tab while the Inbox tab is hidden.
    private func openInboxOutput(_ id: Int64, automationID: Int64, runID: Int64) {
        let inboxVisible = SidebarDestination.inbox.isVisible(
            disabledFeatures: featureVisibility.disabledFeatureIDs, connected: featureVisibility.connectedSources)
        guard inboxVisible, let strip = actionStripViewModel else {
            openAutomationRun(automationID: automationID, runID: runID)
            return
        }
        selectedDestination = .inbox
        Task { await strip.select(.output(id)) }
    }

    /// Add / Dismiss from Home's suggestion row; the CLI's refusal (an
    /// over-limit Add) comes back as text for the row to show. A success
    /// re-reads Home at once: the CLI writes from another process, which the
    /// GRDB observation never sees. `decide` replaces the CLI call in tests.
    func decideInstructionSuggestion(
        id: Int64, add: Bool, decide: ((Int64, Bool) async throws -> Void)? = nil
    ) async -> String? {
        do {
            if let decide {
                try await decide(id, add)
            } else {
                guard let cli = workbenchesViewModel?.cli else { return "The command line is not available." }
                _ = try await cli.decideSuggestion(id: id, add: add)
            }
        } catch {
            return error.localizedDescription
        }
        await homeCenter.rereadNow()
        return nil
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
        case .linear: .blockers
        }
    }
}

/// Home's feed writes in the app: the pool is the open DB's at the moment
/// of the press (Home is built before the DB opens) and the CLI is looked up
/// per press, so a binary installed later is found. AppState is held weakly
/// (it owns the center that owns this).
@MainActor
final class AppHomeFeedPerformer: HomeFeedPerforming {
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func perform(_ action: FeedAction, on ref: FeedRef, now: Date, calendar: Calendar) async throws {
        guard let pool = appState?.databaseManager?.dbPool else { throw HomeFeedActionError.databaseUnavailable }
        try await LiveHomeFeedPerformer(runner: ProcessCLIRunner.makeDefault(), pool: pool)
            .perform(action, on: ref, now: now, calendar: calendar)
    }
}

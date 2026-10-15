import Foundation

// MARK: - Getting ready

/// How a Getting ready card reads its readiness.
package enum ReadinessTone: Equatable, Sendable {
    case ready, preparing, waiting, error
}

/// One tracked feature in the Getting ready zone.
package struct GettingReadyCard: Equatable, Sendable {
    package let feature: ReadinessFeature
    package let copy: FeatureCardCopy
    /// nil = no line (before evaluation, or the owner gate).
    package let readiness: Readiness?

    package init(feature: ReadinessFeature, copy: FeatureCardCopy, readiness: Readiness?) {
        self.feature = feature
        self.copy = copy
        self.readiness = readiness
    }

    package var tone: ReadinessTone {
        switch readiness {
        case .ready: .ready
        case .preparing: .preparing
        case .error: .error
        case .off, .needsSource, .waitingForSync, .scheduled, nil: .waiting
        }
    }

    /// Ready or error: nothing more will happen to this card on its own.
    package var isTerminal: Bool { tone == .ready || tone == .error }
}

/// A source the zone asks to connect, with the features waiting on it.
package struct GettingReadySourceRow: Equatable, Sendable {
    package let source: ReadinessSource
    /// Pipeline order.
    package let features: [ReadinessFeature]

    package init(source: ReadinessSource, features: [ReadinessFeature]) {
        self.source = source
        self.features = features
    }
}

package enum GettingReadyZone: Equatable, Sendable {
    case hidden
    /// "Everything's ready", this launch only.
    case allReady
    case shown(cards: [GettingReadyCard], sourceRows: [GettingReadySourceRow])
}

/// Persisted per install: the owner's ×, when the zone was first shown,
/// when it completed.
package struct GettingReadyMemory: Equatable, Sendable {
    package var hiddenByOwner: Bool
    package var firstShownAt: Date?
    package var completedAt: Date?

    package init(hiddenByOwner: Bool = false, firstShownAt: Date? = nil, completedAt: Date? = nil) {
        self.hiddenByOwner = hiddenByOwner
        self.firstShownAt = firstShownAt
        self.completedAt = completedAt
    }
}

/// One `GettingReadyPolicy.step` result.
package struct GettingReadyStep: Equatable, Sendable {
    package let zone: GettingReadyZone
    /// What to persist.
    package let memory: GettingReadyMemory
    /// Launch-scoped; fed back into the next step.
    package let sawUnready: Bool

    package init(zone: GettingReadyZone, memory: GettingReadyMemory, sawUnready: Bool) {
        self.zone = zone
        self.memory = memory
        self.sawUnready = sawUnready
    }
}

// MARK: - Today

/// A Today card, in its fixed order (owner ask #308).
package enum TodayCardKind: CaseIterable, Sendable {
    case sinceYouWereAway, nextMeeting, waitingOnYou, briefing, myTargets, agentsWaiting
}

/// Where a click goes. Core has no SidebarDestination; AppState.openHomeLink maps these.
package enum HomeLink: Equatable, Sendable {
    case inbox
    case calendarEvent(id: String)
    case briefing(id: Int)
    case targets
    case target(id: Int)
    case workbench(WorkbenchRoute)
    case workbenches
    case catchUp
    /// Getting ready's Open.
    case feature(ReadinessFeature)
    /// Getting ready's Connect row.
    case connect(ReadinessSource)
}

/// A target row's status dot.
package enum TodayItemTone: Equatable, Sendable {
    case overdue, dueToday, inProgress
}

/// One row inside a Today card.
package struct TodayItem: Equatable, Sendable {
    /// "Proposal", "Failed", "Reminder", "Review", "Check", "Question".
    package let chip: String?
    package let title: String
    /// A workbench name, "Due today", "Overdue · Oct 12", "In progress".
    package let detail: String?
    package let tone: TodayItemTone?
    package let link: HomeLink

    package init(chip: String?, title: String, detail: String?, tone: TodayItemTone?, link: HomeLink) {
        self.chip = chip
        self.title = title
        self.detail = detail
        self.tone = tone
        self.link = link
    }
}

package struct TodayCard: Equatable, Sendable {
    package let kind: TodayCardKind
    /// "WAITING ON YOU · 4", "NEXT MEETING · IN 25 MIN".
    package let eyebrow: String
    /// The meeting title.
    package let title: String?
    /// The meeting line, the briefing summary or the recap line.
    package let body: String?
    package let items: [TodayItem]
    /// The card's own target (header click).
    package let link: HomeLink

    package init(
        kind: TodayCardKind,
        eyebrow: String,
        title: String? = nil,
        body: String? = nil,
        items: [TodayItem] = [],
        link: HomeLink
    ) {
        self.kind = kind
        self.eyebrow = eyebrow
        self.title = title
        self.body = body
        self.items = items
        self.link = link
    }
}

/// Every Today source as one read (`HomeQueries.today`) left it.
package struct HomeTodayData: Equatable, Sendable {
    package var awaitingCount: Int
    /// `awaitingOwner(limit: 3)`.
    package var actions: [AgentAction]
    /// `fetchDue`.
    package var reminders: [Reminder]
    package var nextEvent: CalendarEvent?
    package var nextEventHasPrep: Bool
    /// Today's.
    package var briefing: Briefing?
    /// `homeSummary`.
    package var targets: [Target]
    package var asks: WorkbenchAskRows
    /// `newestUnacknowledgedReady`: the newest ready recap not yet acknowledged.
    package var pendingRecap: CatchUpRecap?
    /// A card whose read threw (logged).
    package var failed: Set<TodayCardKind>

    package init(
        awaitingCount: Int = 0,
        actions: [AgentAction] = [],
        reminders: [Reminder] = [],
        nextEvent: CalendarEvent? = nil,
        nextEventHasPrep: Bool = false,
        briefing: Briefing? = nil,
        targets: [Target] = [],
        asks: WorkbenchAskRows = WorkbenchAskRows(rows: [], unreadableIDs: []),
        pendingRecap: CatchUpRecap? = nil,
        failed: Set<TodayCardKind> = []
    ) {
        self.awaitingCount = awaitingCount
        self.actions = actions
        self.reminders = reminders
        self.nextEvent = nextEvent
        self.nextEventHasPrep = nextEventHasPrep
        self.briefing = briefing
        self.targets = targets
        self.asks = asks
        self.pendingRecap = pendingRecap
        self.failed = failed
    }
}

/// `OnboardingFinishPlan.firstSyncText`'s pair, named.
package struct FirstSyncLine: Equatable, Sendable {
    package let title: String
    package let detail: String

    package init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

package struct HomeSnapshot: Equatable, Sendable {
    package let gettingReady: GettingReadyZone
    /// Shown on top of a `.shown` zone.
    package let firstSync: FirstSyncLine?
    package let today: [TodayCard]
    /// Every allowed card's read failed.
    package let todayReadFailed: Bool
    /// The allowed cards whose read failed (`HomeTodayData.failed ∩ allowed`);
    /// any one of them rules out the all-clear (Review Focus 3).
    package let todayFailed: Set<TodayCardKind>

    package init(
        gettingReady: GettingReadyZone,
        firstSync: FirstSyncLine?,
        today: [TodayCard],
        todayReadFailed: Bool,
        todayFailed: Set<TodayCardKind> = []
    ) {
        self.gettingReady = gettingReady
        self.firstSync = firstSync
        self.today = today
        self.todayReadFailed = todayReadFailed
        self.todayFailed = todayFailed
    }

    /// No card to show, and at least one allowed card's read failed: Home
    /// shows the read error where the all-clear line would be.
    package var showsReadError: Bool {
        today.isEmpty && (todayReadFailed || !todayFailed.isEmpty)
    }

    /// "Nothing needs you right now.": no card, no failed read (not even
    /// one), and no Getting ready zone still asking for attention.
    package var nothingNeedsYou: Bool {
        guard today.isEmpty, !showsReadError else { return false }
        switch gettingReady {
        case .hidden, .allReady: return true
        case .shown: return false
        }
    }
}

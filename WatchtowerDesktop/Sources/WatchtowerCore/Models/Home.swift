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
        case .off, .needsSource, .needsDigests, .daemonStopped, .waitingForSync, .scheduled, nil: .waiting
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

// MARK: - Right column

/// The open instruction suggestion Home offers (`instruction_suggestions`).
package struct HomeInstructionSuggestion: Equatable, Sendable {
    package let id: Int64
    package let text: String

    package init(id: Int64, text: String) {
        self.id = id
        self.text = text
    }
}

/// Where a click goes. Core has no SidebarDestination; AppState.openHomeLink maps these.
package enum HomeLink: Equatable, Sendable {
    case inbox
    /// Slack / mail / Jira open the item's own permalink.
    case permalink(URL)
    case calendarEvent(id: String)
    case briefing(id: Int)
    case targets
    case target(id: Int)
    case workbench(WorkbenchRoute)
    case workbenches
    case catchUp
    /// Settings → System (the instruction suggestion's More…).
    case instructionSettings
    /// Getting ready's Open.
    case feature(ReadinessFeature)
    /// Getting ready's Connect row.
    case connect(ReadinessSource)
    /// A Getting ready card's Turn on (a feature waiting on Slack Digests).
    case turnOn(featureID: String)
}

/// The Workbench zone's read (`HomeQueries.workbench`): the open asks and the
/// instruction suggestion. The live sessions come from the app, not the DB.
package struct HomeWorkbenchData: Equatable, Sendable {
    package var asks: WorkbenchAskRows
    /// The newest open suggestion first seen within 7 days.
    package var suggestion: HomeInstructionSuggestion?
    /// A read threw (logged) or an open ask could not be read: the zone says
    /// so and never reads as empty.
    package var failed: Bool

    package init(
        asks: WorkbenchAskRows = WorkbenchAskRows(rows: [], unreadableIDs: []),
        suggestion: HomeInstructionSuggestion? = nil,
        failed: Bool = false
    ) {
        self.asks = asks
        self.suggestion = suggestion
        self.failed = failed
    }
}

extension HomeNumbers {
    /// Every field's name, as `failed` names them: a pool that could not be
    /// read at all fails them all.
    package static let fieldNames: Set<String> = [
        "messagesToMe", "messagesSent", "meetings", "meetingHours", "aiSpendUSD",
        "plan5h", "planWeek", "workbenchCreated", "workbenchDone", "meetingsRecorded"
    ]
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
    /// The left column: what waits, NOW and what follows. The all-clear is
    /// its own; the right column never says it.
    package let feed: HomeFeed
    /// The right column's Workbench zone: one block per workbench with a live
    /// session to look at or an open ask.
    package let workbench: [HomeWorkbenchBlock]
    /// The zone's last row, Add / Dismiss.
    package let suggestion: HomeInstructionSuggestion?
    /// The asks or suggestion read failed, or an ask could not be read.
    package let workbenchFailed: Bool
    /// The links zone, only the links whose tab is visible.
    package let links: [HomeLinkRow]
    /// A links read failed: the rows still show, their status may be stale.
    package let linksFailed: Bool
    /// Today in numbers; nil until its own first read lands.
    package let numbers: HomeNumbers?

    package init(
        gettingReady: GettingReadyZone,
        firstSync: FirstSyncLine?,
        feed: HomeFeed,
        workbench: [HomeWorkbenchBlock] = [],
        suggestion: HomeInstructionSuggestion? = nil,
        workbenchFailed: Bool = false,
        links: [HomeLinkRow] = [],
        linksFailed: Bool = false,
        numbers: HomeNumbers? = nil
    ) {
        self.gettingReady = gettingReady
        self.firstSync = firstSync
        self.feed = feed
        self.workbench = workbench
        self.suggestion = suggestion
        self.workbenchFailed = workbenchFailed
        self.links = links
        self.linksFailed = linksFailed
        self.numbers = numbers
    }

    /// The Workbench zone shows: a block, the suggestion or its read error.
    package var showsWorkbench: Bool {
        !workbench.isEmpty || suggestion != nil || workbenchFailed
    }
}

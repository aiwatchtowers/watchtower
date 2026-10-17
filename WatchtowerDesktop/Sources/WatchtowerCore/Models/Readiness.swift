import Foundation

/// A tracked feature: an AI or sync output a tab shows, with a readiness.
package enum ReadinessFeature: String, CaseIterable, Sendable {
    case slackSync, digests, streamDigests, tracks, peopleCards, briefing,
         dayPlan, ideas, memory, inbox, knowledgeIndex, calendar, jira

    /// The feature registry id (`internal/features`); nil when the feature
    /// has no switch of its own.
    package var featureID: String? {
        switch self {
        case .slackSync, .calendar, .jira: nil
        case .digests: "slack-digests"
        case .streamDigests: "stream-digests"
        case .tracks: "tracks"
        case .peopleCards: "people-cards"
        case .briefing: "briefing"
        case .dayPlan: "day-plan"
        case .ideas: "ideas"
        case .memory: "memory"
        case .inbox: "secretary-inbox"
        case .knowledgeIndex: "knowledge-search"
        }
    }

    /// `pipeline_runs.pipeline` as the daemon writes it; nil when the
    /// feature has no runs to read (calendar).
    package var pipelineName: String? {
        switch self {
        case .slackSync: "slack-sync"
        case .digests: "digests"
        case .streamDigests: "stream-digests"
        case .tracks: "tracks"
        case .peopleCards: "people"
        case .briefing: "briefing"
        case .dayPlan: "day_plan"
        case .ideas: "ideas"
        case .memory: "memory"
        case .inbox: "inbox"
        case .knowledgeIndex: "knowledge-index"
        case .calendar: nil
        case .jira: "jira-boards"
        }
    }

    package var source: ReadinessSource {
        switch self {
        case .slackSync, .digests, .tracks, .peopleCards, .ideas: .slack
        case .streamDigests: .jiraOrMail
        case .briefing, .dayPlan, .memory, .inbox: .anySource
        case .knowledgeIndex: .none
        case .calendar: .calendar
        case .jira: .jira
        }
    }

    /// Whether the daemon runs the feature only while Slack Digests is on too.
    /// Dual path with the compound gates in `internal/daemon/daemon.go`
    /// (`phaseTracksAndRollups`, `phaseCustomTrackScan`, `phasePeopleCards`:
    /// `Tracks.Enabled && Digest.Enabled`, `People.Enabled && Digest.Enabled`) —
    /// tracks and people cards mine what the digests produce (#575).
    package var runsOnlyWithDigests: Bool { self == .tracks || self == .peopleCards }

    /// Whether the feature has nothing to work on until the first Slack sync
    /// finishes (when Slack is connected). Slack sync is that sync itself.
    package var readsSyncedData: Bool { self != .slackSync }
}

/// The source a feature reads.
package enum ReadinessSource: Hashable, Sendable {
    case none, slack, anySource, calendar, jira, jiraOrMail
    /// A source that tells Watchtower who the owner is (the OWNER-01 ladder).
    /// No feature reads it; Home names it on an owner-gated card while the
    /// owner is unknown.
    case ownerIdentity
    /// The named connected source ("Jira", "Linear") will identify the owner
    /// once it reports who connected it; Home waits on it instead of asking
    /// to connect something.
    case ownerIdentityPending(String)
    /// Jira is connected but no board is selected: the daemon's Jira sync
    /// has nothing to fetch until the owner picks boards (#572).
    case jiraBoards

    /// What a "Connect …" line or button names.
    package var displayName: String {
        switch self {
        case .slack: "Slack"
        case .calendar: "a calendar"
        case .jira: "Jira"
        case .jiraBoards: "Jira boards"
        case .jiraOrMail: "Jira or mail"
        case .ownerIdentity: "Slack, Google, Jira, Linear or an email account"
        case .ownerIdentityPending(let name): "your \(name) identity"
        case .anySource, .none: "a source"
        }
    }

    /// The button title and the start of the "… to get" line: "Connect
    /// Slack", or "Choose Jira boards" when the source is there but its
    /// boards are not picked.
    package var actionTitle: String {
        switch self {
        case .jiraBoards: "Choose Jira boards"
        default: "Connect \(displayName)"
        }
    }

    /// The owner gate's sources: shown on the feature's card, never as a Connect row.
    package var isOwnerIdentity: Bool {
        switch self {
        case .ownerIdentity, .ownerIdentityPending: true
        default: false
        }
    }

    package func isConnected(in connected: ConnectedSources) -> Bool {
        switch self {
        case .none, .ownerIdentity, .ownerIdentityPending: true
        case .slack: connected.slack
        case .anySource: connected.slack || connected.mail || connected.calendar || connected.jira
        case .calendar: connected.calendar
        case .jira, .jiraBoards: connected.jira
        case .jiraOrMail: connected.jira || connected.mail
        }
    }
}

/// When a scheduled feature runs next. A vocabulary, not a duration: the
/// UI never shows a countdown or minutes beyond the poll interval.
package enum Eta: Equatable, Sendable {
    /// A sync is running; the pipeline runs in the same cycle.
    case afterCurrentSync
    /// The next daemon cycle, `sync.poll_interval` away.
    case nextCycle(minutes: Int)
    /// A daily pipeline's hour gate.
    case at(hour: Int, tomorrow: Bool)
    /// The people cards 24 h throttle.
    case inAboutADay
    /// The ideas/streams interval, rounded up to whole hours.
    case inHours(Int)
    /// Memory waits for a running history backfill (#578).
    case afterHistoryLoads
}

/// One feature's readiness, in evaluation precedence order.
package enum Readiness: Equatable, Sendable {
    case off
    case needsSource(ReadinessSource)
    case ready
    /// On, with no content yet, and the daemon skips it while Slack Digests
    /// is off (`ReadinessFeature.runsOnlyWithDigests`, #575).
    case needsDigests
    /// The daemon has been down for `FeatureReadiness.daemonDownGrace`:
    /// nothing scheduled will happen until it is started (from the app-wide
    /// banner; the state itself carries no button).
    case daemonStopped
    case preparing(detail: String?)
    case error(message: String)
    case waitingForSync(detail: String?)
    case scheduled(Eta)
}

/// The newest `pipeline_runs` row of one pipeline.
package struct RunSnapshot: Equatable, Sendable {
    /// "running" | "done" | "error"
    package let status: String
    package let startedAt: Date
    package let errorMessage: String

    package init(status: String, startedAt: Date, errorMessage: String = "") {
        self.status = status
        self.startedAt = startedAt
        self.errorMessage = errorMessage
    }
}

/// The daemon's throttle stamp files (`last_*.txt` in the workspace
/// directory); nil when missing or unreadable.
package struct ReadinessStamps: Equatable, Sendable {
    package var lastPeople: Date?
    package var lastBriefing: Date?
    package var lastIdeas: Date?
    package var lastStreams: Date?

    package init(lastPeople: Date? = nil, lastBriefing: Date? = nil, lastIdeas: Date? = nil, lastStreams: Date? = nil) {
        self.lastPeople = lastPeople
        self.lastBriefing = lastBriefing
        self.lastIdeas = lastIdeas
        self.lastStreams = lastStreams
    }
}

/// Everything `FeatureReadiness.evaluate` reads; no clock, no DB.
package struct ReadinessInputs: Equatable {
    package var now: Date
    package var disabledFeatureIDs: Set<String>
    package var connected: ConnectedSources
    package var daemonRunning: Bool
    /// Since when the daemon has been seen down (`DaemonManager.notRunningSince`);
    /// nil while it runs or before the first status read.
    package var daemonNotRunningSince: Date?
    package var syncProgress: SyncProgress?
    /// When the last Slack sync finished (`last_sync.json`, written only by
    /// the daemon's Slack sync phase); nil = the first Slack sync hasn't
    /// finished. Without Slack it stays nil forever, so it only gates
    /// `waitingForSync` while Slack is connected.
    package var lastSyncTime: Date?
    /// Keyed by pipeline name.
    package var latestRuns: [String: RunSnapshot]
    package var contentPresent: Set<ReadinessFeature>
    package var stamps: ReadinessStamps
    package var briefingHour: Int
    package var dayPlanHour: Int
    package var pollIntervalMinutes: Int
    /// `started_at` of every `history_backfill` row with status `running`
    /// (a held row included), for memory's backfill wait (#578).
    package var runningBackfillStarts: [Date]
    /// A `memory` pipeline run finished `done` at least once: memory's
    /// backfill wait is over for good (#578).
    package var memoryHasRun: Bool
    /// `sync.backfill_days <= 0` (the backfill kill switch).
    package var backfillOff: Bool
    /// At least one Jira board is selected on a connected site. Without one
    /// the daemon's Jira sync fetches nothing (`internal/jira/sync.go`), so a
    /// connected Jira with no content reads `.needsSource(.jiraBoards)`.
    package var jiraBoardsSelected: Bool

    package init(
        now: Date,
        disabledFeatureIDs: Set<String> = [],
        connected: ConnectedSources = .none,
        daemonRunning: Bool = false,
        daemonNotRunningSince: Date? = nil,
        syncProgress: SyncProgress? = nil,
        lastSyncTime: Date? = nil,
        latestRuns: [String: RunSnapshot] = [:],
        contentPresent: Set<ReadinessFeature> = [],
        stamps: ReadinessStamps = ReadinessStamps(),
        briefingHour: Int = 8,
        dayPlanHour: Int = 8,
        pollIntervalMinutes: Int = 15,
        runningBackfillStarts: [Date] = [],
        memoryHasRun: Bool = false,
        backfillOff: Bool = false,
        jiraBoardsSelected: Bool = true
    ) {
        self.now = now
        self.disabledFeatureIDs = disabledFeatureIDs
        self.connected = connected
        self.daemonRunning = daemonRunning
        self.daemonNotRunningSince = daemonNotRunningSince
        self.syncProgress = syncProgress
        self.lastSyncTime = lastSyncTime
        self.latestRuns = latestRuns
        self.contentPresent = contentPresent
        self.stamps = stamps
        self.briefingHour = briefingHour
        self.dayPlanHour = dayPlanHour
        self.pollIntervalMinutes = pollIntervalMinutes
        self.runningBackfillStarts = runningBackfillStarts
        self.memoryHasRun = memoryHasRun
        self.backfillOff = backfillOff
        self.jiraBoardsSelected = jiraBoardsSelected
    }
}

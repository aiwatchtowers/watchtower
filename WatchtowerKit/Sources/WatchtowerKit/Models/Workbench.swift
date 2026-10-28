import Foundation
import WatchtowerSync

/// The `workbench` slice (mobile POC spec §4.2), record name
/// `workbench-<projects.id>`: one workbench as the phone's Workbench list
/// shows it. The hub resolves and caps every field; the phone draws them as
/// given. The raw `folder_path` is never published.
///
/// `<field>_clipped` is true when the hub cut that text at its cap (absent
/// otherwise); `targets_more` counts the board targets past the window.
public struct Workbench: SliceMirror, Identifiable {
    public static let sliceKind = SliceKind.workbench

    public let id: Int64
    /// Cap 200.
    public let name: String
    public let nameClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// Cap 1000.
    public let description: String
    public let descriptionClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// The folder with the home prefix replaced by `~`. Cap 300.
    public let folderDisplay: String
    public let folderDisplayClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// The checked-out branch ("" when detached). Cap 120.
    public let branch: String
    public let branchClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    public let detached: Bool
    /// Changed entries in the working tree (staged, unstaged, untracked).
    public let changes: Int
    public let openAsks: Int
    public let openTargets: Int
    public let inProgressTargets: Int
    public let blockedTargets: Int
    /// Done targets that are not archived.
    public let doneTargets: Int
    public let sessionCounts: SessionCounts
    /// nil when the workbench has no session.
    public let lastSessionActivity: Date?
    public let archiveAfterDays: Int
    /// Board targets past the per-workbench window.
    public let targetsMore: Int?
    /// The agent a start from the phone runs: the Mac's default agent
    /// (Settings → Workbench → Default agent, board #399). One value for every
    /// workbench, carried on each record. nil from a hub older than Codex
    /// support, which starts Claude Code.
    public let defaultAgent: TerminalSessionState.Agent?
    /// The workbench's own automations the phone may run (ask #692), at most
    /// 50 (the hub's `WorkbenchSlice.maxAutomations`), in the Mac's quick-run order.
    /// Absent when it has none, and from a hub older than phone runs.
    public let automations: [WorkbenchAutomation]?

    /// Session counts over the workbench's published `terminal_session`
    /// records, by resolved state.
    public struct SessionCounts: Codable, Hashable, Sendable {
        public let working: Int
        public let waiting: Int
        public let needsApproval: Int
        public let finished: Int
        public let failed: Int
        public let stopped: Int
        public let notRunning: Int

        public init(
            working: Int, waiting: Int, needsApproval: Int, finished: Int, failed: Int, stopped: Int, notRunning: Int
        ) {
            self.working = working
            self.waiting = waiting
            self.needsApproval = needsApproval
            self.finished = finished
            self.failed = failed
            self.stopped = stopped
            self.notRunning = notRunning
        }
    }
}

/// One automation of a workbench as the phone lists it (ask #692): the
/// Mac's quick-run row (`QuickRunRow`), resolved on the Mac.
public struct WorkbenchAutomation: Codable, Hashable, Sendable, Identifiable {
    /// rawValues are wire format.
    public struct Kind: OpenWireValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// Runs only when the owner runs it.
        public static let manual = Self(rawValue: "manual")
        /// A button recipe.
        public static let button = Self(rawValue: "button")
        /// A schedule or event recipe, run now out of turn.
        public static let scheduled = Self(rawValue: "scheduled")
        public static let knownValues: [Self] = [.manual, .button, .scheduled]
    }

    /// rawValues are wire format. Only `runnable` runs; a value this build
    /// does not know is not runnable.
    public struct State: OpenWireValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let runnable = Self(rawValue: "runnable")
        /// A run is queued, running or waiting.
        public static let running = Self(rawValue: "running")
        /// Changed since the owner last confirmed it: confirmed on the Mac only.
        public static let needsConfirmation = Self(rawValue: "needs_confirmation")
        public static let disabled = Self(rawValue: "disabled")
        public static let parseError = Self(rawValue: "parse_error")
        public static let knownValues: [Self] = [.runnable, .running, .needsConfirmation, .disabled, .parseError]
    }

    public let id: Int64
    /// Cap 200.
    public let name: String
    public let nameClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    public let kind: Kind
    /// A button recipe with `confirm: true`: the phone asks before it sends the
    /// run, and the Mac runs it only with `AutomationRunParams.confirmed`.
    public let asksFirst: Bool
    public let state: State
    /// The newest finished run's `automation_runs.status` (`succeeded`,
    /// `failed`, …); absent before the first run.
    public let lastRunStatus: String?
    public let lastRunAt: Date?

    public init(
        id: Int64,
        name: String,
        nameClipped: Bool? = nil, // swiftlint:disable:this discouraged_optional_boolean
        kind: Kind,
        asksFirst: Bool,
        state: State,
        lastRunStatus: String? = nil,
        lastRunAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.nameClipped = nameClipped
        self.kind = kind
        self.asksFirst = asksFirst
        self.state = state
        self.lastRunStatus = lastRunStatus
        self.lastRunAt = lastRunAt
    }
}

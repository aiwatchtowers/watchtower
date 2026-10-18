import AppKit
import Foundation
import GRDB
import Observation
import WatchtowerCore

/// The Workbench tab (spec §6.1). Owned by `AppState` so a create or repair in
/// flight — and the selection — survive navigating away (house rule).
///
/// The daemon/CLI/MCP server write these tables from other processes, so
/// nothing here observes the DB: the view reloads on appear and the
/// notification center's 30 s poll reloads it (Task 18).
@MainActor
@Observable
final class WorkbenchesViewModel {
    /// The code viewer's file trees and open buffers (POC), here so unsaved
    /// edits survive switching panes and tabs.
    let codeFiles: CodeFilesCenter
    /// The owner asks: open lists, drafts and answers (spec 2026-10-03 Part 8).
    let asks: OwnerAsksViewModel
    /// Every line the app types into a session's prompt — an ask's answer,
    /// later the phone's input — one queue per session (PROJ-12). AppState
    /// passes its own; nil = one of the VM's own over `terminalCenter`.
    let lineDelivery: SessionLineDelivery

    private(set) var summaries: [WorkbenchSummary] = []
    /// The workbench switcher's rows (board #250), read when its popover opens.
    private(set) var switcherSummaries: [WorkbenchSwitcherSummary] = []
    /// Why the last switcher read failed; the next successful read clears it.
    private(set) var switcherError: String?
    // Go-to palette state. Written only by WorkbenchesViewModel+GoTo.swift,
    // which cannot reach a `private(set)` setter from its own file.

    /// The go-to palette's sessions of every workbench (board #252), read
    /// when it opens; its workbenches are `switcherSummaries`.
    var goToSessions: [TerminalSession] = []
    /// Why the last palette read of the sessions failed; the next success clears it.
    var goToError: String?
    var selectedWorkbenchID: Int64? {
        didSet {
            // One thing is on screen: a project, or a standalone terminal.
            // Selecting a project also drills the panel into it.
            if let selectedWorkbenchID {
                selectedStandaloneID = nil
                drilledWorkbenchID = selectedWorkbenchID
            } else {
                drilledWorkbenchID = nil
            }
            refreshStickySection()
        }
    }
    private(set) var isCreating = false
    private(set) var repairing: Set<Int64> = []
    private(set) var resyncing: Set<Int64> = []
    /// The last Re-run setup result per project, until the owner dismisses it.
    private(set) var resyncResults: [Int64: WorkbenchResynced] = [:]
    private(set) var resyncErrors: [Int64: String] = [:]
    var errorMessage: String?
    /// Why the last "Archive Closed Targets After" write failed, per
    /// workbench; the next successful write clears it.
    private(set) var archiveSettingErrors: [Int64: String] = [:]
    /// A failed save of the worktree setup command, per workbench.
    private(set) var worktreeSetupErrors: [Int64: String] = [:]
    /// Each workbench's methodology as `watchtower workbench methodology`
    /// last reported it (the Agent settings sheet, board #266).
    private(set) var methodology: [Int64: WorkbenchMethodologyState] = [:]
    /// The Agent settings sheet's last failure per workbench; nil once a call
    /// does everything it ran.
    private(set) var methodologyErrors: [Int64: String] = [:]
    /// Each workbench's latest methodology call: an older call's answer
    /// (a sheet's load still in flight when a picker changed) is dropped.
    @ObservationIgnored private var methodologyCallSeq: [Int64: Int] = [:]
    private(set) var installStatus: [Int64: WorkbenchInstallStatus] = [:]
    /// The default agent (Settings → Workbench → Default agent, D1) as last
    /// read: menus label themselves with it. A launch reads it afresh
    /// (`currentDefaultAgent`), since Settings saves from another window.
    private(set) var defaultAgent: AgentKind = .claude
    /// Reads `workbench.default_agent`; AppState wires the config file. A
    /// test VM launches Claude Code unless it sets this.
    @ObservationIgnored var readDefaultAgent: @MainActor () -> AgentKind = { .claude }
    /// The Codex home a relaunch looks for rollouts in: the login shell's
    /// CODEX_HOME (spec 2026-10-12 §7), resolved off the main thread; nil when
    /// the login shell did not answer (asked again on the next relaunch) —
    /// the relaunch then resets nothing.
    @ObservationIgnored var resolveCodexHome: () async -> URL? = {
        await Constants.resolvedLoginEnvironment().map { CodexRollout.home(environment: $0) }
    }
    /// Why installing or repairing a project's install failed. It explains
    /// the Repair button, so it stays until a status read finds nothing to
    /// repair — the page's own `.task` read races `createWorkbench`'s and must
    /// not wipe it.
    private var installNotes: [Int64: String] = [:]
    /// Why the last status read failed; the next successful read clears it.
    private var statusReadErrors: [Int64: String] = [:]
    /// The page's error line, per project — never the shared `errorMessage`,
    /// where one project's failure would outlive a switch to another.
    var installErrors: [Int64: String] {
        installNotes.merging(codexSetupErrors) { note, codex in "\(note) \(codex)" }
            .merging(statusReadErrors) { note, read in "\(note) \(read)" }
    }
    /// Why the last Codex setup (Setup, Set up Codex or Repair) failed: the
    /// one Codex state that warns while the part is not set up. Cleared by a
    /// successful run or a status that finds the part whole.
    private(set) var codexSetupErrors: [Int64: String] = [:]
    /// A project was created: Task 18 seeds its notification baseline.
    var onWorkbenchCreated: ((Workbench, _ installed: Bool) -> Void)?
    /// The embedded terminals. AppState passes its own; nil (most tests) =
    /// nothing launches.
    let terminalCenter: TerminalCenter?
    /// What the live sessions' agents are doing (board #312). AppState passes
    /// its own; nil = plain running dots.
    let agentStates: SessionAgentStateCenter?
    /// The sessions' report lines and the Session view's report (spec
    /// 2026-10-03-workbench-session-report Part 7). AppState wires its own;
    /// nil = rows without a report line, a Session view with nothing to show.
    @ObservationIgnored weak var sessionReports: SessionReportCenter?
    /// Session cleanup (board #535): the Delete dialog's plan and apply, the
    /// Clean Up… sheet. Held here, on the AppState-owned view model, so a
    /// run survives navigating away. AppState wires its own; nil = Delete
    /// Only.
    @ObservationIgnored var sessionCleanup: SessionCleanupCenter?
    /// The sessions' stored cleanup results (`cleanup_result`), for the
    /// report's Cleanup line; a session without one has no entry.
    var cleanupRecords: [Int64: SessionCleanupRecord] = [:]
    /// The sessions a cleanup runs on (board #535) — Delete and Clean Up,
    /// or a Clean Up… apply: the row is busy, it does not delete (✕, ⌘⌫,
    /// Delete, Delete and Clean Up) or start fresh, and shows "Cleaning
    /// up…".
    var cleaningUpSessions: Set<Int64> = []
    /// The subset whose terminal Delete and Clean Up closed: the row does
    /// not resume either, until it is deleted or kept. A Clean Up… apply
    /// leaves a live session's terminal reachable.
    var closedForCleanup: Set<Int64> = []
    /// The cleanup runs this view model owns (Delete and Clean Up, a Clean
    /// Up… apply), per session: a view going away never cancels one.
    @ObservationIgnored var cleanupRuns: [Int64: Task<Bool, Never>] = [:]
    /// The automatic cleanups of finished placed sessions whose agent
    /// exited (session worktrees spec §9), per session; gone when done.
    @ObservationIgnored var placedCleanupRuns: [Int64: Task<Void, Never>] = [:]
    /// The sessions whose Clean Up… sheet is on screen: an apply ending
    /// while it is not shows its failure on the page instead.
    @ObservationIgnored var openCleanupSheets: Set<Int64> = []
    /// Per deleted session, what its Delete and Clean Up kept of the items
    /// the dialog showed: told on the Undo bar while the row waits there,
    /// dropped once it leaves the batch (Undo or the commit).
    var cleanupKeptNotices: [Int64: String] = [:]
    /// The sweep applies this view model owns (Clean Up Old Worktrees…),
    /// per workbench: closing the sheet or leaving the page cancels none.
    @ObservationIgnored var sweepRuns: [Int64: Task<Bool, Never>] = [:]
    /// The workbenches whose sweep sheet is on screen.
    @ObservationIgnored var openSweepSheets: Set<Int64> = []
    /// Per workbench, the one-time "old worktrees use ~N GB" hint while it
    /// is up (open question 2 of the cleanup spec, owner approved).
    var cleanupHints: [Int64: String] = [:]
    /// The workbenches whose hint plan finished this launch, whatever it
    /// found (a failed one is not retried on every visit).
    @ObservationIgnored var cleanupHintChecked: Set<Int64> = []
    /// The workbench whose hint plan runs: one at a time, app-wide.
    @ObservationIgnored var cleanupHintRunning: Int64?
    /// How long a page stays on screen before its hint plan starts.
    @ObservationIgnored var cleanupHintDelay: Duration = .seconds(30)
    /// The hint's wait; throws once its page goes away. A seam for tests.
    @ObservationIgnored var cleanupHintSleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// The longest a hint plan may run before it is stopped and the slot
    /// freed.
    @ObservationIgnored var cleanupHintTimeLimit: Duration = .seconds(5 * 60)
    /// The hint's clock (the 7-day re-check). A seam for tests.
    @ObservationIgnored var cleanupHintNow: () -> Date = { Date() }
    /// Where each session's agent works (board #565): the rows' place line
    /// and the header's worktree crumb.
    let sessionPlaces: SessionPlaceCenter
    /// The code root last worked out per workbench and session, with what
    /// it was worked out from (`codeRoot(sessionID:project:)`): view bodies
    /// read it without touching the disk again.
    @ObservationIgnored var codeRootMemo: [CodeRootMemoKey: CodeRootMemo] = [:]
    /// The ask link clicked last per workbench, while it runs
    /// (`clickAskLink`): a newer click cancels it, and so does its view
    /// (`owner`) going away.
    @ObservationIgnored var askLinkTasks: [Int64: AskLinkInFlight] = [:]
    /// How long an ask link waits for a session brought onto the page to
    /// prove its place. Internal for tests.
    @ObservationIgnored var askPlaceTimeout: Duration = .seconds(3)
    /// A target the Board of that workbench opens once it is on screen
    /// (`showTargetOnBoard`); the Board takes it (`takeBoardFocus`).
    var boardFocus: [Int64: Int64] = [:]
    /// Bumped per workbench after a board write made here outside the Board's
    /// own view model (Work on It's status, board #499): the Board reloads at
    /// once instead of at its next poll.
    var boardReloads: [Int64: Int] = [:]
    /// Each workbench's GitHub repository from its `origin` remote, for the
    /// Session view's PR links; `.some(nil)` = read, not on GitHub.
    var gitHubRepositories: [Int64: URL?] = [:]
    @ObservationIgnored var gitHubRepositoryReads: Set<Int64> = []
    /// `git remote get-url origin` of a folder. A seam for tests.
    @ObservationIgnored var readOriginRemote: (URL) async -> String? = { await GitHubRemote.readOrigin(folder: $0) }
    /// Runs `watchtower terminal title`; nil without a CLI. A seam for tests.
    @ObservationIgnored var titleService: ((Int64) async throws -> TerminalTitleResult)?
    @ObservationIgnored var now: () -> Date = Date.init

    // Session state. Written only by WorkbenchesViewModel+Sessions.swift, which
    // cannot reach a `private(set)` setter from its own file.

    /// Each project's `terminal_sessions` rows, most recently active first.
    var terminalSessions: [Int64: [TerminalSession]] = [:]
    /// Standalone terminals (`project_id` NULL), most recently active first.
    var standaloneSessions: [TerminalSession] = []
    /// The left panel's level 2: the project drilled into (nil = level 1).
    /// Always nil or `selectedWorkbenchID`: selecting a project drills into
    /// it, Back sets it to nil.
    var drilledWorkbenchID: Int64?
    /// Whether the left panel is shown. Persisted under the key the view's
    /// `@AppStorage` used (the `projects.` prefix predates the rename, spec
    /// 2026-10-02 A1), so the owner's choice carries over.
    var panelVisible: Bool {
        didSet { defaults.set(panelVisible, forKey: Self.panelVisibleKey) }
    }
    static let panelVisibleKey = "projects.panelVisible"
    /// The standalone terminal on screen; mutually exclusive with
    /// `selectedWorkbenchID` (setting a project clears it).
    var selectedStandaloneID: Int64?
    /// Sessions whose `--resume` exited non-zero within
    /// `resumeFailureWindow` of launch: the pane offers "Start fresh".
    var resumeFailed: Set<Int64> = []
    /// Why the last session action failed, keyed by project (nil =
    /// standalone) — never the shared `errorMessage`, where one project's
    /// failure would follow a switch. The next action on it clears it.
    var sessionActionErrors: [Int64?: String] = [:]
    /// Why the last list load failed; the next successful load clears it
    /// (kept apart so a load after a failed action does not wipe that error).
    var sessionLoadErrors: [Int64?: String] = [:]
    /// Layouts touched this run; the rest are read from `defaults`.
    var layouts: [Int64: WorkspaceLayout] = [:]
    /// The panel's dragged session orders touched this run (key nil = the
    /// standalone terminals); the rest are read from `defaults`.
    var sessionOrders: [Int64?: [Int64]] = [:]
    /// The sessions panel's "▸ N finished" folds touched this run (board
    /// #480); the rest are read from `defaults`.
    var finishedGroupFolds: [Int64: Bool] = [:]
    /// The on-screen session's kept panel section (spec
    /// 2026-10-12-sessions-panel-design §3.3): a session finishing in front
    /// of the owner keeps its main-list slot until another one comes on
    /// screen (`refreshStickySection`).
    var stickySection: SessionPanelSections.Sticky?
    /// The sessions panel's keyboard highlight (spec
    /// 2026-10-12-sessions-panel-design §4.4): the row ↑ ↓ move over and ⌘⌫
    /// deletes, apart from the session on screen; moving it opens nothing.
    var panelCursor: Int64?
    /// Bumped to hand the keyboard to the sessions panel
    /// (`requestPanelKeyboard`): its key view takes first responder.
    var panelKeyboardSerial = 0
    /// Failed AI-title attempts per session id, this run only.
    @ObservationIgnored var titleAttempts: [Int64: Int] = [:]
    /// Consecutive "no owner message yet" title answers per session; at
    /// `maxNotYetTitledPolls` the poll leaves it until the owner switches back.
    @ObservationIgnored var notYetTitledStreak: [Int64: Int] = [:]
    /// When each running resume launched, until its process exits.
    @ObservationIgnored var resumeStarts: [Int64: Date] = [:]
    /// Projects an `openMostRecentSession` is running for, and targets a
    /// `workOn` is running for: a double click must not create two rows.
    @ObservationIgnored var openingSession: Set<Int64> = []
    @ObservationIgnored var workingOnTarget: Set<Int64> = []
    /// Per workbench, one line about where its last new session started
    /// when that was not the plain choice (spec 2026-10-14-session-worktrees
    /// §7: "Started in the folder: …", a `base_dirty` or worktree warning);
    /// nil once a start had nothing to say. Shown above the sessions panel.
    var startNotice: [Int64: String] = [:]
    /// Per workbench, the last start's placement turn (decide, make the
    /// worktree, insert the row): the next start awaits it before deciding,
    /// so two starts at one moment do not both see the folder free (§4).
    @ObservationIgnored var placementTurns: [Int64: Task<Void, Never>] = [:]
    /// Rows a start inserted whose launch has not returned yet, by id: they
    /// count as live for the next start's decision.
    @ObservationIgnored var startingRows: [Int64: TerminalSession] = [:]
    /// Per workbench, the ticket of the session switch the owner asked for
    /// last (`beginSwitch`); only that switch may still move the layout.
    @ObservationIgnored var latestSwitch: [Int64: Int] = [:]
    @ObservationIgnored var switchSerial = 0
    @ObservationIgnored var titleTask: Task<Void, Never>?
    /// Standalone list reads started; only the latest one is applied.
    @ObservationIgnored var standaloneLoads = 0
    /// Per project, session list reads started and the newest one applied.
    struct SessionLoads {
        var started = 0
        var applied = 0
    }
    @ObservationIgnored var workbenchLoads: [Int64: SessionLoads] = [:]
    /// Reads a project's sessions. A seam for tests (overlapping reads).
    @ObservationIgnored lazy var readWorkbenchSessions: (Int64) async throws -> [TerminalSession] = { [dbPool] projectID in
        try await dbPool.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: projectID) }
    }
    /// The title poll's wait. A seam for tests.
    @ObservationIgnored var titleSleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// The deleted sessions whose DELETE waits for the Undo window (board
    /// #480, PROJ-17): hidden from every read here, restored by Undo,
    /// committed when the window ends or the app quits. Here, on the
    /// AppState-owned view model, so the toast and its Undo survive
    /// navigating away. A change of the hidden ids is reported to
    /// `onPendingDeletesChanged` (the phone's session slice).
    var pendingDeletes = PendingSessionDeletes() {
        didSet {
            if oldValue.ids != pendingDeletes.ids {
                onPendingDeletesChanged?(pendingDeletes.ids)
                cleanupKeptNotices = cleanupKeptNotices.filter { pendingDeletes.ids.contains($0.key) }
            }
        }
    }
    /// The hidden ids changed (MobileHub: the `terminal_session` slice
    /// leaves them out until Undo or the commit).
    @ObservationIgnored var onPendingDeletesChanged: ((Set<Int64>) -> Void)?
    /// Waits out the Undo window, then commits the batch; re-armed by every
    /// delete, cancelled by Undo and the quit commit.
    @ObservationIgnored var deleteCommitTask: Task<Void, Never>?
    /// The deleted sessions whose process is still closing (up to
    /// `TerminalCenter.killGrace`): the batch never commits while one of
    /// its rows is here.
    @ObservationIgnored var closingDeletes: Set<Int64> = []
    /// The window ran out while a row of the batch was still closing: the
    /// last close to finish commits the batch.
    @ObservationIgnored var deleteCommitDue = false
    /// Every deferred DELETE write in flight (the timer's and the quit's):
    /// the quit waits on it, bounded by `quitDeleteWait`.
    @ObservationIgnored let deleteWrites = DispatchGroup()
    /// How long the quit commit of the Undo batch may hold the quit. A seam
    /// for tests.
    @ObservationIgnored var quitDeleteWait: TimeInterval = 2
    /// The Undo window's wait. A seam for tests.
    @ObservationIgnored var deleteSleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// Runs deferred DELETEs in one write — the only DELETE path of the
    /// deferred delete, the timer's and the quit's. Off the main actor, so
    /// the quit can wait for it while it holds the main thread. A seam for
    /// tests (a failing or a slow write).
    @ObservationIgnored lazy var commitSessionDeletes: @Sendable ([Int64]) async throws -> Void = { [dbPool] ids in
        try await dbPool.write { db in
            for id in ids { try TerminalSessionQueries.delete(db, id: id) }
        }
    }

    /// The owner changed something in a project (a comment, a status): the
    /// notification policy must not report it back (Task 18).
    var onOwnerWrite: ((Int64, WorkbenchSubject) -> Void)?
    /// Closes every embedded terminal of a project (SIGHUP → SIGKILL).
    /// AppState wires it to `TerminalCenter.closeAll(where:)` over the
    /// project's sessions in initWorkbenches; a project with none is a no-op,
    /// so calling it twice is harmless.
    var closeTerminal: ((Int64) async -> Void)?
    /// A workbench was deleted here, or left the list (deleted by the CLI):
    /// AppState lets the code questions forget it (their rows went with the
    /// delete). Calling it twice is harmless.
    var onWorkbenchRemoved: ((Int64) -> Void)?
    /// Whether the Workbench tab is what the owner is looking at (AppState:
    /// sidebar on Projects, main window visible). The git status refresh
    /// runs only then. Unwired = never on screen.
    var isTabOnScreen: () -> Bool = { false }
    /// The project a delete is running for; the page disables Delete meanwhile.
    private(set) var deletingWorkbenchID: Int64?
    /// Why the last delete failed; the page shows it in an alert.
    var deleteError: String?
    /// The worktrees the last delete kept because work was in them
    /// (`keptWorktreesNotice`): a neutral line under the list, not an error,
    /// until the owner dismisses it or the next delete replaces it.
    var deleteNotice: String?
    /// The last board drift check per workbench (PROJ-07, `workbench check`).
    /// Kept here, not on the board pane, so a result survives navigation.
    private(set) var drift: [Int64: WorkbenchDriftReport] = [:]
    /// Why the last drift check of a project failed; the next success clears it.
    private(set) var driftErrors: [Int64: String] = [:]
    private var driftCheckedAt: [Int64: Date] = [:]
    private var checkingDrift: Set<Int64> = []
    /// How often the open Board pane re-runs the check (git work in the folder).
    static let driftMinInterval: TimeInterval = 30

    // Git state (#233). Written only by WorkbenchesViewModel+Git.swift,
    // keyed by the root the branch menu works on (board #565: the main
    // folder, `[workbenchID]`, or a session's worktree, `[codeRoot]`); kept
    // here so a switch in flight, its pending confirmation and the last
    // status survive navigating away.

    /// The last `workbench git status` per root.
    var gitStatus: [GitRootKey: WorkbenchGitStatus] = [:]
    /// The popover's branch list: the last one read in full.
    var gitBranches: [GitRootKey: WorkbenchGitBranches] = [:]
    /// Where the latest read of that list stands; a failure beside a list
    /// in `gitBranches` means that list is stale. nil before the first read.
    var branchListStates: [GitRootKey: BranchListState] = [:]
    /// Board targets carrying a branch, by branch name — the `#id` badges.
    var branchTargets: [GitRootKey: [String: [WorkbenchBranchTarget]]] = [:]
    /// Why the last branch action (list, switch, create) failed or was
    /// refused; the popover shows it. The next action clears it.
    var gitErrors: [GitRootKey: String] = [:]
    /// Why the last status read failed; the next successful read clears it.
    var gitStatusErrors: [GitRootKey: String] = [:]
    /// A worktree root Go did not place in that worktree (board #565:
    /// `outside`/`missing`/unresolved — the envelope was the main folder's):
    /// why its branch menu is off. A neutral note, not a failed read; the
    /// next read that places the folder in its worktree clears it.
    var gitScopeNotes: [GitRootKey: String] = [:]
    /// What the last branch action left to note (git's warning).
    var gitNotices: [GitRootKey: String] = [:]
    /// The stash entry the latest stashing switch left, with its sha (Go
    /// keeps no record of it). In memory only: it survives popover reopens
    /// and status reads until the owner dismisses it, a newer stash replaces
    /// it or the app quits — after that `git stash list` finds the entry by
    /// its `watchtower: switching from …` message.
    var gitStashNotes: [GitRootKey: WorkbenchBranchPresentation.StashNote] = [:]
    /// The branch a switch or create is running for.
    var switchingBranch: [GitRootKey: String] = [:]
    /// A switch Go refused until the owner confirms (dirty tree, live agent).
    var pendingBranchConfirmation: [GitRootKey: BranchSwitchConfirmation] = [:]
    /// The popover's `git fetch origin` per repository (board #563), keyed
    /// by its common dir: one fetch at a time, shared by its worktrees.
    var gitFetchStates: [String: GitFetchState] = [:]
    /// The fetch in flight per repository: owned here, not by the popover,
    /// so closing it never cancels a fetch half way.
    @ObservationIgnored var gitFetchTasks: [String: Task<Void, Never>] = [:]
    /// A seam for tests: the fetch's clock.
    @ObservationIgnored var gitFetchNow: () -> Date = Date.init
    /// The header's label when Go asked: a status showing anything else
    /// means the branch moved since, and the question is dropped.
    @ObservationIgnored var pendingBranchBase: [GitRootKey: String] = [:]
    /// Status reads running, and those asked for again meanwhile: at most
    /// one read in flight per root plus one rerun.
    @ObservationIgnored var gitRefreshing: Set<GitRootKey> = []
    @ObservationIgnored var gitRefreshQueued: Set<GitRootKey> = []
    /// Workbench pages on screen that watch their refs.
    @ObservationIgnored var gitWatching: Set<Int64> = []
    /// The worktree root a watching page's branch menu works on, watched
    /// beside its main folder; none while the page shows the main folder.
    @ObservationIgnored var gitWatchedWorktree: [Int64: CodeRoot] = [:]
    @ObservationIgnored var gitWatchers: [GitRootKey: any GitRefsWatching] = [:]
    @ObservationIgnored var gitWatchedDirs: [GitRootKey: [String]] = [:]
    @ObservationIgnored var gitTimers: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored var gitActivationObserver: NSObjectProtocol?
    /// Seams for tests: the refs watcher, the dirty-dot poll's wait, the
    /// notification center, the clipboard.
    @ObservationIgnored var makeGitWatcher: (_ gitDir: String, _ commonDir: String, _ onChange: @escaping @MainActor (GitRefsChange) -> Void)
        -> any GitRefsWatching = { GitRefsWatcher(gitDir: $0, commonDir: $1, onChange: $2) }
    @ObservationIgnored var gitPollSleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    @ObservationIgnored var gitNotificationCenter: NotificationCenter = .default
    @ObservationIgnored var copyToPasteboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// One Changes pane model per session (board #328), so its round,
    /// drafts and selection survive the pane leaving the screen; dropped
    /// when the session is deleted (`forgetProcessState`). Created during a
    /// view's body, hence not observed.
    @ObservationIgnored var reviewModels: [Int64: ReviewChangesModel] = [:]

    let dbPool: DatabasePool
    /// Not private: WorkbenchesViewModel+Git.swift runs the `workbench git` calls.
    let cli: WorkbenchCLI?
    let defaults: UserDefaults

    init(
        dbPool: DatabasePool,
        cli: WorkbenchCLI?,
        defaults: UserDefaults = .standard,
        terminalCenter: TerminalCenter? = nil,
        agentStates: SessionAgentStateCenter? = nil,
        lineDelivery: SessionLineDelivery? = nil
    ) {
        self.dbPool = dbPool
        self.cli = cli
        self.defaults = defaults
        self.terminalCenter = terminalCenter
        self.agentStates = agentStates
        panelVisible = defaults.object(forKey: Self.panelVisibleKey) as? Bool ?? true
        codeFiles = CodeFilesCenter(defaults: defaults)
        sessionPlaces = Self.makeSessionPlaces(dbPool: dbPool, cli: cli, terminalCenter: terminalCenter)
        let lineDelivery = lineDelivery ?? SessionLineDelivery(terminalCenter: terminalCenter)
        self.lineDelivery = lineDelivery
        asks = OwnerAsksViewModel(dbPool: dbPool, terminalCenter: terminalCenter, lineDelivery: lineDelivery, defaults: defaults)
        if let cli {
            let service = TerminalTitleService(runner: cli.runner)
            titleService = { try await service.title(sessionID: $0) }
            terminalCenter?.codexLaunchArgs = { try await cli.launchArgs(agent: .codex, workbenchID: $0) }
        }
        terminalCenter?.onSessionExit = { [weak self] id, code, closedByApp in
            self?.sessionExited(id, code: code, closedByApp: closedByApp)
        }
        terminalCenter?.onPathLink = { [weak self] workbenchID, sessionID, location in
            Task { await self?.openTerminalLink(location, workbenchID: workbenchID, sessionID: sessionID) }
        }
        terminalCenter?.pathLinkRoot = { [weak self] workbenchID, sessionID in
            self?.terminalLinkFolder(workbenchID: workbenchID, sessionID: sessionID)
        }
        // A hover card that cannot be read shows nothing (logged); a click
        // still reports the failure (`openTerminalAskLink`).
        terminalCenter?.askLinkLookUp = { [weak self] workbenchID, askID in
            do {
                return try await self?.asks.linkedAsk(askID: askID, projectID: workbenchID)
            } catch {
                NSLog("OwnerAsks: ask #%lld link lookup failed: %@", askID, error.localizedDescription)
                return nil
            }
        }
        terminalCenter?.onAskLink = { [weak self] workbenchID, askID in
            Task { await self?.openTerminalAskLink(askID, workbenchID: workbenchID) }
        }
        asks.isTabOnScreen = { [weak self] in self?.isTabOnScreen() ?? false }
        asks.watchedProjectID = { [weak self] in self?.selectedWorkbenchID }
        asks.onLoaded = { [weak self] projectID in self?.openNewAsk(projectID: projectID) }
        asks.onDelivered = { [weak self] projectID, sessionID in
            self?.showAnsweredSession(sessionID, projectID: projectID)
        }
        // A closed session's ring follows its open asks without a poll.
        asks.onAnswered = { [weak agentStates] in await agentStates?.poll() }
        // A line (an answer's) is held while its session waits on a permission
        // prompt and goes once the states show it answered (PROJ-12); its
        // Return only into a session whose hooks reported this run (a
        // state, or the mark of a run not yet turned to — board #396).
        lineDelivery.follow(agentStates)
        // Keys typed into a permission dialog leave no draft in the prompt.
        terminalCenter?.inputAnswersDialog = { [weak agentStates] id in
            agentStates?.statuses[id]?.state.kind == .needsApproval
        }
        // The states' hooks are single slots: `follow` set them for the held
        // lines; these keep that call and add the panel's and the places'.
        agentStates?.onChange = { [weak self, weak lineDelivery, weak sessionPlaces = self.sessionPlaces] in
            lineDelivery?.statesRead()
            // The session on screen keeps its panel section (#480).
            self?.refreshStickySection()
            // A session started, stopped or began a run: whether its stored
            // cwd is trusted may have moved (board #565).
            sessionPlaces?.cwdsMayHaveChanged()
        }
        agentStates?.onRead = { [weak lineDelivery, weak sessionPlaces = self.sessionPlaces, weak agentStates] in
            lineDelivery?.statesRead()
            // A hook may have stored a new cwd: re-read only on a new stamp.
            sessionPlaces?.stateRowsRead(agentStates?.rows ?? [])
        }
    }

    /// The Workbench tab appeared: the list reloads, and the sessions'
    /// states are read even with none live.
    func tabAppeared() async {
        agentStates?.refresh()
        await reload()
    }

    var selectedWorkbench: Workbench? {
        summaries.first { $0.id == selectedWorkbenchID }?.project
    }

    /// Sidebar badge: open asks plus unread agent comments (spec 2026-10-03 Part 8).
    var badgeCount: Int {
        summaries.reduce(0) { $0 + badgeCount(for: $1) }
    }

    /// A workbench row's blue badge: open asks plus unread agent comments.
    func badgeCount(for summary: WorkbenchSummary) -> Int {
        summary.openAsks + summary.unreadAgentComments
    }

    /// The default agent, read now; the menus' copy follows it.
    func currentDefaultAgent() -> AgentKind {
        let agent = readDefaultAgent()
        if defaultAgent != agent { defaultAgent = agent }
        return agent
    }

    /// Whether `agent`'s CLI is there for this workbench, as its last install
    /// status read says. Unknown (not read yet, or the read failed) counts as
    /// there: the launch itself says when it is not.
    func agentAvailable(_ agent: AgentKind, projectID: Int64) -> Bool {
        installStatus[projectID]?.agentFound(agent) ?? true
    }

    /// false = the read failed and its error is in `errorMessage`.
    @discardableResult
    func reload() async -> Bool {
        _ = currentDefaultAgent()
        let previousIDs = summaries.map(\.id)
        do {
            summaries = try await dbPool.read { try WorkbenchQueries.summaries($0) }
        } catch {
            errorMessage = "Could not load workbenches: \(error.localizedDescription)"
            return false
        }
        for id in Self.vanished(previous: previousIDs, current: summaries.map(\.id)) {
            await closeTerminal?(id)
            discardPendingDeletes(workbenchID: id)
            terminalSessions[id] = nil
            sessionPlaces.forgetWorkbench(id)
            codeFiles.forgetRemovedBuffers(workbenchID: id)
            askLinkTasks.removeValue(forKey: id)?.task.cancel()
            onWorkbenchRemoved?(id)
            // Deleted elsewhere (CLI): never leave its id selected.
            if selectedWorkbenchID == id { selectedWorkbenchID = nil }
        }
        if let selectedWorkbenchID { await loadSessions(projectID: selectedWorkbenchID) }
        await loadSessions(projectID: nil)
        return true
    }

    /// The switcher popover's read. A failure keeps the rows of the last
    /// read beside the error.
    func loadSwitcherSummaries() async {
        do {
            switcherSummaries = try await dbPool.read { try WorkbenchQueries.switcherSummaries($0) }
            switcherError = nil
        } catch {
            switcherError = "Could not load workbenches: \(error.localizedDescription)"
        }
    }

    /// Deletes a project (spec §6.1, Review Focus #5). Order matters: the
    /// terminal — and with it the Claude Code session writing through
    /// `mcp --workbench` — closes first, then `watchtower workbench delete N`
    /// removes the rows and the folder install, then the list reloads. A CLI
    /// failure keeps the project listed and reports the CLI's error. A folder
    /// cleanup failure (`removal_ok == false`) still deletes the project and
    /// leaves a non-blocking warning in `errorMessage`; kept worktrees go to
    /// `deleteNotice`. A second call while one runs is refused.
    @discardableResult
    func deleteWorkbench(_ id: Int64) async -> Bool {
        guard deletingWorkbenchID == nil else { return false }
        guard let cli else {
            deleteError = "The watchtower CLI was not found."
            return false
        }
        deletingWorkbenchID = id
        deleteError = nil
        defer { deletingWorkbenchID = nil }
        await closeTerminal?(id)
        let result: WorkbenchDeleted
        do {
            result = try await cli.delete(projectID: id)
        } catch {
            deleteError = "Could not delete the workbench: \(error.localizedDescription)"
            return false
        }
        // The rows are gone: an answer still streaming stops now, not at the
        // reload (a failed delete above leaves the questions as they were).
        onWorkbenchRemoved?(id)
        // Its hidden sessions went with the cascade: nothing to commit or restore.
        discardPendingDeletes(workbenchID: id)
        if let warning = result.cleanupWarning { errorMessage = warning }
        deleteNotice = result.keptWorktreesNotice
        if selectedWorkbenchID == id { selectedWorkbenchID = nil }
        await reload()
        return true
    }

    /// The notification center's 30 s poll. The agent writes comments and
    /// asks from another process (DB only), so the list — and the badge — reloads.
    func refreshOnPoll() async {
        await reload()
    }

    nonisolated static func vanished(previous: [Int64], current: [Int64]) -> [Int64] {
        let now = Set(current)
        return previous.filter { !now.contains($0) }
    }

    /// A deep link puts its pane on screen the way a panel click does. An
    /// ask's notice (`route.askID`) opens that ask the way a stack row does
    /// (`showAsk`): its session on screen and the drawer on it; an ask gone
    /// meanwhile falls back to the notice's pane and session.
    func reveal(_ route: WorkbenchRoute) {
        selectedWorkbenchID = route.projectID
        if let askID = route.askID {
            Task {
                guard await !showAsk(askID, projectID: route.projectID) else { return }
                showPane(of: route)
            }
            return
        }
        showPane(of: route)
    }

    private func showPane(of route: WorkbenchRoute) {
        switch route.pane {
        case .board: layout.show(.board)
        case .terminal:
            let projectID = route.projectID
            let sessionID = route.subjectID
            Task { await revealTerminal(projectID: projectID, sessionID: sessionID) }
        }
    }

    /// An answer's line was typed or copied into `sessionID` (spec 2026-10-03
    /// Part 5): that terminal goes on its workbench's page and the keyboard
    /// into it, so the owner reads the line (or pastes it) and presses
    /// Return. Keyed by the ask's own workbench, never the selection. Takes
    /// a switch ticket: a slower session switch still pending must not land
    /// afterwards and move the keyboard off the line (board #187).
    func showAnsweredSession(_ sessionID: Int64, projectID: Int64) {
        beginSwitch(projectID: projectID)
        var updated = layout(projectID: projectID)
        updated.show(.session(sessionID))
        setLayout(updated, projectID: projectID)
        terminalCenter?.focus(sessionID)
        terminalCenter?.requestKeyboardFocus(sessionID)
    }

    /// `sessionID` (a session notice's click, board #312) puts that session
    /// of the workbench on screen: a live one the way a panel row click does,
    /// one that stopped since the banner without starting it — a stale
    /// banner never launches an agent; its pane offers Resume. Without one, or when
    /// it names no session of the workbench (deleted meanwhile), the live
    /// session, else the most recent one (its pane offers Resume) — read
    /// first, since a project just selected has no list yet. `ticket`: the
    /// switch a caller already took at its own entry, before its first await
    /// (`showAsk`); nil takes one here.
    func revealTerminal(projectID: Int64, sessionID: Int64? = nil, ticket: Int? = nil) async {
        let ticket = ticket ?? beginSwitch(projectID: projectID)
        // A session created since the last read is not in the list yet.
        let listed = terminalSessions[projectID]
        let unlisted = sessionID.map { id in !(listed ?? []).contains { $0.id == id } } ?? false
        if listed == nil || unlisted {
            guard await loadSessions(projectID: projectID) else { return }
        }
        let subject = sessionID.flatMap { id in terminalSessions[projectID]?.first { $0.id == id } }
        if let subject, terminalCenter?.liveIDs.contains(subject.id) == true {
            drill(into: projectID)
            await open(subject, placement: .show, ticket: ticket)
            return
        }
        if subject != nil { drill(into: projectID) }
        let id = subject?.id ?? activeSessionID(projectID: projectID) ?? terminalSessions[projectID]?.first?.id
        guard let id, isLatestSwitch(ticket, projectID: projectID) else { return }
        var updated = layout(projectID: projectID)
        updated.show(.session(id))
        setLayout(updated, projectID: projectID)
    }

    /// The create flow's note for a failed folder install. A symlink the CLI
    /// refuses to write through fails Repair the same way, so that note is the
    /// CLI's own message, which says how to fix the link. The two texts are
    /// Go's `devpack.ErrSymlinkOutsideFolder` and `devpack.ErrSymlinkInPlace`,
    /// pinned by `TestInstallErrorTextsTheDesktopMatches`.
    nonisolated static func createInstallNote(_ detail: String) -> String {
        let linkRefusals = ["outside the workbench folder", "is a symlink; not writing through it"]
        if linkRefusals.contains(where: detail.contains) {
            return "The workbench was created, but installing into the folder failed: " + detail
        }
        return "The workbench was created, but installing into the folder failed — use Repair. " + detail
    }

    /// What Open Folder… did with the picked folder (board #778).
    enum OpenFolderOutcome: Equatable {
        /// The workbench bound to the folder is open.
        case opened
        /// `workbench create` ran; its progress and errors are in the list.
        case created
        /// The folder lies under this TCC-sensitive `~/…` location: the
        /// owner confirms first, then `createFromOpenedFolder`.
        case confirmLocation(String)
        /// Nothing done: a create is in flight, or the reload failed (its
        /// error is in `errorMessage`, the list on screen).
        case stopped
    }

    /// Open Folder… (board #778), decided on a fresh list: a folder some
    /// workbench is already bound to opens that workbench, as the switcher's
    /// pick does, with no location warning (owner decision #778) —
    /// `workbench create` would refuse it. Any other folder becomes a new
    /// workbench, after the owner confirms a TCC-sensitive location.
    @discardableResult
    func openFolder(
        _ folder: URL,
        home: String = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
    ) async -> OpenFolderOutcome {
        guard !isCreating else { return .stopped }
        guard await reload() else {
            showAllWorkbenches()
            return .stopped
        }
        if let bound = workbenchID(boundTo: folder) {
            await switchTo(workbenchID: bound)
            return .opened
        }
        if let location = WorkbenchFolderPolicy.tccSensitiveLocation(path: folder.path, home: home) {
            return .confirmLocation(location)
        }
        await createFromOpenedFolder(folder)
        return .created
    }

    /// Open Folder…'s create: the list, which carries the create's progress
    /// and errors, comes on screen first (the switcher runs this at level 2,
    /// or with the panel hidden).
    func createFromOpenedFolder(_ folder: URL) async {
        showAllWorkbenches()
        await createWorkbench(folder: folder)
    }

    /// The listed workbench bound to `folder`, as `workbench create` compares
    /// folders: APFS is case-insensitive, so any spelling of it, with or
    /// without the `/private` of /tmp and /var (`comparableFolder`).
    func workbenchID(boundTo folder: URL) -> Int64? {
        let path = Self.comparableFolder(folder.path)
        return summaries.first {
            Self.comparableFolder($0.project.folderPath).caseInsensitiveCompare(path) == .orderedSame
        }?.id
    }

    /// Go's `EvalSymlinks` keeps the `/private` of /tmp and /var in a bound
    /// folder; Foundation's `resolvingSymlinksInPath` strips it from the
    /// picked one. Both sides drop it, and a trailing slash, before comparing.
    static func comparableFolder(_ path: String) -> String {
        var path = path
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// `workbench create`'s refusal of a folder already bound to a
    /// workbench (Go's `db.ErrWorkbenchFolderTaken`).
    static func isFolderTaken(_ error: Error) -> Bool {
        guard case let CLIRunnerError.nonZeroExit(_, stderr) = error else { return false }
        return stderr.contains("folder is already bound to a workbench")
    }

    /// Open Folder… → `workbench create`, then the folder install. A failed
    /// install keeps the project (it exists now), shows the install error,
    /// points at Repair and reports `installed: false` to `onWorkbenchCreated`.
    /// A folder bound since the list was read (another window, the CLI)
    /// opens its workbench instead of the refusal.
    func createWorkbench(folder: URL) async {
        guard !isCreating else { return }
        guard let cli else {
            errorMessage = "The watchtower CLI was not found."
            return
        }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        let created: WorkbenchCreated
        do {
            created = try await cli.create(folder: folder.path, name: nil)
        } catch {
            if Self.isFolderTaken(error), await reload(), let bound = workbenchID(boundTo: folder) {
                await switchTo(workbenchID: bound)
                return
            }
            errorMessage = "Could not create the workbench: \(error.localizedDescription)"
            return
        }
        var installed = true
        do {
            try await cli.install(projectID: created.id)
        } catch {
            installed = false
            installNotes[created.id] = Self.createInstallNote(error.localizedDescription)
        }
        await reload()
        selectedWorkbenchID = created.id
        await refreshInstallStatus(projectID: created.id)
        // D5: the Codex part only when codex is found (the status says so);
        // its failure never fails the Claude Code setup.
        if let status = installStatus[created.id], status.codexNeedsSetup || status.codexNeedsRepair {
            await installCodexPart(projectID: created.id, failure: "Setting up Codex failed — use Set up Codex.")
            await refreshInstallStatus(projectID: created.id)
        }
        guard let project = selectedWorkbench else { return }
        onWorkbenchCreated?(project, installed)
        // After a failed install the setup would run without the skill, hook
        // and MCP server it relies on, so no first-run session.
        if installed {
            await startNewSession(project: project, title: TerminalSessionNaming.setupTitle,
                                  prompt: TerminalLaunch.firstRunPrompt(vocabulary(projectID: project.id)),
                                  agent: setupAgent(projectID: project.id))
        }
    }

    /// The first-run session's agent: the default one, unless that is Codex
    /// and its part is not in the folder (codex missing, or its setup failed)
    /// — then Claude Code, whose install just succeeded.
    private func setupAgent(projectID: Int64) -> AgentKind {
        let agent = currentDefaultAgent()
        guard agent == .codex else { return agent }
        let codex = installStatus[projectID]?.codex
        return codex?.found == true && codex?.skill == true ? .codex : .claude
    }

    /// `integrate codex`: Setup's, Set up Codex's and Repair's Codex step.
    /// A failure is kept in `codexSetupErrors`, apart from the Claude Code
    /// part's notes.
    private func installCodexPart(projectID: Int64, failure: String) async {
        guard let cli else { return }
        do {
            try await cli.installCodex(projectID: projectID)
            codexSetupErrors[projectID] = nil
        } catch {
            codexSetupErrors[projectID] = "\(failure) \(error.localizedDescription)"
        }
    }

    /// The header's "Set up Codex" (a workbench whose Codex part was never
    /// set up — `codexNeedsSetup`): the same `integrate codex` as Repair.
    func setUpCodex(projectID: Int64) async {
        guard !isInstalling(projectID: projectID) else { return }
        repairing.insert(projectID)
        defer { repairing.remove(projectID) }
        await installCodexPart(projectID: projectID, failure: "Setting up Codex failed:")
        await refreshInstallStatus(projectID: projectID)
    }

    /// The skill and server names the workbench's folder answers to
    /// (`WorkbenchInstallStatus.vocabulary`); the current ones while its status
    /// is unknown — not read yet, or the read failed (spec 2026-10-02 §5.3).
    func vocabulary(projectID: Int64) -> WorkbenchVocabulary {
        installStatus[projectID]?.vocabulary ?? .current
    }

    /// Reads `integrate status` for one project. The page runs this in
    /// `.task(id: project.id)`, so switching projects while the CLI is still
    /// running (it takes seconds) cancels it: a cancelled read is not a
    /// failure — it keeps the last known status and reports nothing. A result
    /// is keyed by its own project id, so it never lands on another project.
    func refreshInstallStatus(projectID: Int64) async {
        guard let cli else { return }
        do {
            let status = try await cli.status(projectID: projectID)
            installStatus[projectID] = status
            statusReadErrors[projectID] = nil
            if let codex = status.codex, let trustError = codex.trustError {
                // Spec §4.5: an unknown trust offers no Repair, only this line.
                NSLog("WorkbenchesViewModel: codex hook trust check failed for workbench %lld: %@",
                      projectID, trustError)
            } else if let codex = status.codex, codex.found, codex.hooksTrusted == nil {
                NSLog("WorkbenchesViewModel: codex could not be asked about hook trust for workbench %lld", projectID)
            }
            if !status.needsRepair { installNotes[projectID] = nil }
            if status.codex?.state != .notSetUp, !status.codexNeedsRepair { codexSetupErrors[projectID] = nil }
        } catch {
            // The process runner terminates the child on cancel, which can
            // surface as a non-zero exit rather than CancellationError.
            if error is CancellationError || Task.isCancelled { return }
            // The last known status stays, so its Repair button stays too.
            statusReadErrors[projectID] = "Could not read the install status: \(error.localizedDescription)"
        }
    }

    /// Runs the offline drift check for a project. The open Board pane's poll
    /// asks for it on every tick and gets one at most every `driftMinInterval`
    /// (`force` = the owner's Refresh or the pane appearing); one check per
    /// project runs at a time, and a result is keyed by its own project id.
    func refreshDrift(projectID: Int64, force: Bool = false, now: Date = Date()) async {
        guard let cli, !checkingDrift.contains(projectID) else { return }
        if !force, let last = driftCheckedAt[projectID], now.timeIntervalSince(last) < Self.driftMinInterval { return }
        checkingDrift.insert(projectID)
        defer { checkingDrift.remove(projectID) }
        driftCheckedAt[projectID] = now
        do {
            drift[projectID] = try await cli.checkDrift(projectID: projectID)
            driftErrors[projectID] = nil
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            // The last known result stays on screen beside the error.
            driftErrors[projectID] = "Could not check the board against git: \(error.localizedDescription)"
        }
    }

    func repairInstall(projectID: Int64) async {
        // On a folder set up before the Workbench rename the install is the
        // migration (spec 2026-10-02 §5.4); its report — the permission
        // rules to re-allow, an edited old skill that was kept — only comes
        // back from the resync, so Repair runs that and shows its summary.
        if installStatus[projectID]?.legacy == true {
            await resync(projectID: projectID)
            return
        }
        guard let cli, !isInstalling(projectID: projectID) else { return }
        repairing.insert(projectID)
        defer { repairing.remove(projectID) }
        installNotes[projectID] = nil
        // Each agent's part only when it needs it; a status not read yet
        // repairs Claude Code, as before Codex.
        let status = installStatus[projectID]
        if status?.claudeNeedsRepair ?? true {
            do {
                try await cli.install(projectID: projectID)
            } catch {
                installNotes[projectID] = "Repair failed: \(error.localizedDescription)"
            }
        }
        // A Codex part never set up comes along (D5) — it is not why Repair
        // is on, but the owner asked to fix the folder.
        if status?.codexNeedsRepair == true || status?.codexNeedsSetup == true {
            await installCodexPart(projectID: projectID, failure: "Repairing Codex failed:")
        }
        await refreshInstallStatus(projectID: projectID)
    }

    /// Re-run setup (#91): `workbench resync` re-indexes the folder's
    /// documents for search and re-installs missing or outdated integration pieces, then
    /// the page reloads what it may have changed. Additive only — it never
    /// creates targets; the result's suggestions say what to ask the agent.
    func resync(projectID: Int64) async {
        guard !isInstalling(projectID: projectID) else { return }
        guard let cli else {
            // The button is always shown, so say why nothing happened.
            resyncErrors[projectID] = "The watchtower CLI was not found."
            return
        }
        resyncing.insert(projectID)
        defer { resyncing.remove(projectID) }
        resyncErrors[projectID] = nil
        resyncResults[projectID] = nil
        do {
            resyncResults[projectID] = try await cli.resync(projectID: projectID)
        } catch is DecodingError {
            resyncErrors[projectID] = "Re-run Setup ran, but its report could not be read (is the CLI out of date?)."
        } catch {
            resyncErrors[projectID] = "Re-run Setup failed: \(error.localizedDescription)"
        }
        // The CLI may have installed files even when it failed or its report
        // could not be read.
        await reload()
        await refreshInstallStatus(projectID: projectID)
    }

    /// Repair and Re-run Setup both run the folder install (`claude mcp`
    /// remove/add, the settings merge); never two at once for one project.
    func isInstalling(projectID: Int64) -> Bool {
        repairing.contains(projectID) || resyncing.contains(projectID)
    }

    /// The header menu's "Archive Closed Targets After" (board #301). The
    /// board picks the change up through its fingerprint; the reload refreshes
    /// the menu's checkmark.
    func setArchiveAfterDays(_ days: Int, projectID: Int64) async {
        do {
            try await dbPool.write { try WorkbenchQueries.setArchiveAfterDays($0, projectID: projectID, days: days) }
            archiveSettingErrors[projectID] = nil
        } catch {
            archiveSettingErrors[projectID] = "Could not change the archive setting: \(error.localizedDescription)"
            return
        }
        await reload()
    }

    /// The header menu's "Worktree Setup Command…" (board #229): the command
    /// a new session's worktree runs before the agent starts; empty = none.
    /// Returns whether it was saved, so the sheet stays open on a failure.
    @discardableResult
    func setWorktreeSetup(_ command: String, projectID: Int64) async -> Bool {
        do {
            try await dbPool.write { try WorkbenchQueries.setWorktreeSetup($0, projectID: projectID, command: command) }
            worktreeSetupErrors[projectID] = nil
        } catch {
            worktreeSetupErrors[projectID] = "Could not save the worktree setup command: \(error.localizedDescription)"
            return false
        }
        await reload()
        return true
    }

    /// The Agent settings sheet's read (spec 2026-10-15 §8).
    func loadMethodology(projectID: Int64) async {
        await runMethodology(projectID: projectID) { try await $0.methodology(projectID: projectID) }
    }

    /// One picker's change; `WorkbenchMethodologyKey.fromFile` drops the
    /// personal setting. Go updates the folder's skills after a preset change.
    func setMethodology(_ key: WorkbenchMethodologyKey, to choice: String, projectID: Int64) async {
        await runMethodology(projectID: projectID) {
            try await $0.setMethodology(projectID: projectID, key: key, choice: choice)
        }
    }

    /// "Create workflow.md": the commented template, never over a file.
    func createWorkflowFile(projectID: Int64) async {
        await runMethodology(projectID: projectID) { try await $0.createWorkflowFile(projectID: projectID) }
    }

    /// Runs one methodology call: its answer replaces the shown state and its
    /// failure (if any) is shown; a call that could not run keeps the last
    /// state and shows why. Only the workbench's latest call lands — a stale
    /// read never overwrites a newer change — and a cancelled call (the
    /// sheet closed) changes nothing.
    private func runMethodology(
        projectID: Int64,
        _ call: (WorkbenchCLI) async throws -> WorkbenchMethodologyState
    ) async {
        guard let cli else {
            methodologyErrors[projectID] = "The watchtower command-line tool is not available."
            return
        }
        let seq = (methodologyCallSeq[projectID] ?? 0) + 1
        methodologyCallSeq[projectID] = seq
        do {
            let state = try await call(cli)
            guard methodologyCallSeq[projectID] == seq else { return }
            methodology[projectID] = state
            methodologyErrors[projectID] = state.failure
        } catch is CancellationError {
            return
        } catch {
            guard methodologyCallSeq[projectID] == seq else { return }
            methodologyErrors[projectID] = "Could not run watchtower workbench methodology: \(error.localizedDescription)"
        }
    }

    /// The header menu's "Archive Closed Targets Now" (board #415): every
    /// target closed by now leaves the board. The board picks the stamp up
    /// through its fingerprint; the reload shows "Undo Archive Now".
    func archiveClosedTargetsNow(projectID: Int64) async {
        do {
            try await dbPool.write { try WorkbenchQueries.archiveClosedTargetsNow($0, projectID: projectID) }
            archiveSettingErrors[projectID] = nil
        } catch {
            archiveSettingErrors[projectID] = "Could not archive closed targets: \(error.localizedDescription)"
            return
        }
        await reload()
    }

    /// The header menu's "Undo Archive Now" (board #415): forgets the stamp,
    /// so only the age rule archives again.
    func undoArchiveNow(projectID: Int64) async {
        do {
            try await dbPool.write { try WorkbenchQueries.clearArchivedThrough($0, projectID: projectID) }
            archiveSettingErrors[projectID] = nil
        } catch {
            archiveSettingErrors[projectID] = "Could not undo Archive Now: \(error.localizedDescription)"
            return
        }
        await reload()
    }

    func dismissResync(projectID: Int64) {
        resyncResults[projectID] = nil
        resyncErrors[projectID] = nil
    }
}

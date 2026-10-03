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
        }
    }
    private(set) var isCreating = false
    private(set) var repairing: Set<Int64> = []
    private(set) var resyncing: Set<Int64> = []
    /// The last Re-run setup result per project, until the owner dismisses it.
    private(set) var resyncResults: [Int64: WorkbenchResynced] = [:]
    private(set) var resyncErrors: [Int64: String] = [:]
    var errorMessage: String?
    private(set) var installStatus: [Int64: WorkbenchInstallStatus] = [:]
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
        installNotes.merging(statusReadErrors) { note, read in "\(note) \(read)" }
    }
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
    /// A target the Board of that workbench opens once it is on screen
    /// (`showTargetOnBoard`); the Board takes it (`takeBoardFocus`).
    var boardFocus: [Int64: Int64] = [:]
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

    /// The owner changed something in a project (a comment, a status): the
    /// notification policy must not report it back (Task 18).
    var onOwnerWrite: ((Int64, WorkbenchSubject) -> Void)?
    /// Closes every embedded terminal of a project (SIGHUP → SIGKILL).
    /// AppState wires it to `TerminalCenter.closeAll(where:)` over the
    /// project's sessions in initWorkbenches; a project with none is a no-op,
    /// so calling it twice is harmless.
    var closeTerminal: ((Int64) async -> Void)?
    /// Whether the Workbench tab is what the owner is looking at (AppState:
    /// sidebar on Projects, main window visible). The git status refresh
    /// runs only then. Unwired = never on screen.
    var isTabOnScreen: () -> Bool = { false }
    /// The project a delete is running for; the page disables Delete meanwhile.
    private(set) var deletingWorkbenchID: Int64?
    /// Why the last delete failed; the page shows it in an alert.
    var deleteError: String?
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
    // keyed by workbench id; kept here so a switch in flight, its pending
    // confirmation and the last status survive navigating away.

    /// The last `workbench git status` per workbench.
    var gitStatus: [Int64: WorkbenchGitStatus] = [:]
    /// The popover's branch list: the last one read in full.
    var gitBranches: [Int64: WorkbenchGitBranches] = [:]
    /// Where the latest read of that list stands; a failure beside a list
    /// in `gitBranches` means that list is stale. nil before the first read.
    var branchListStates: [Int64: BranchListState] = [:]
    /// Board targets carrying a branch, by branch name — the `#id` badges.
    var branchTargets: [Int64: [String: [WorkbenchBranchTarget]]] = [:]
    /// Why the last branch action (list, switch, create) failed or was
    /// refused; the popover shows it. The next action clears it.
    var gitErrors: [Int64: String] = [:]
    /// Why the last status read failed; the next successful read clears it.
    var gitStatusErrors: [Int64: String] = [:]
    /// What the last branch action left to note (git's warning).
    var gitNotices: [Int64: String] = [:]
    /// The stash entry the latest stashing switch left, with its sha (Go
    /// keeps no record of it). In memory only: it survives popover reopens
    /// and status reads until the owner dismisses it, a newer stash replaces
    /// it or the app quits — after that `git stash list` finds the entry by
    /// its `watchtower: switching from …` message.
    var gitStashNotes: [Int64: WorkbenchBranchPresentation.StashNote] = [:]
    /// The branch a switch or create is running for.
    var switchingBranch: [Int64: String] = [:]
    /// A switch Go refused until the owner confirms (dirty tree, live agent).
    var pendingBranchConfirmation: [Int64: BranchSwitchConfirmation] = [:]
    /// The header's label when Go asked: a status showing anything else
    /// means the branch moved since, and the question is dropped.
    @ObservationIgnored var pendingBranchBase: [Int64: String] = [:]
    /// Status reads running, and those asked for again meanwhile: at most
    /// one read in flight per workbench plus one rerun.
    @ObservationIgnored var gitRefreshing: Set<Int64> = []
    @ObservationIgnored var gitRefreshQueued: Set<Int64> = []
    /// Workbench pages on screen that watch their refs.
    @ObservationIgnored var gitWatching: Set<Int64> = []
    @ObservationIgnored var gitWatchers: [Int64: any GitRefsWatching] = [:]
    @ObservationIgnored var gitWatchedDirs: [Int64: [String]] = [:]
    @ObservationIgnored var gitTimers: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored var gitActivationObserver: NSObjectProtocol?
    /// Seams for tests: the refs watcher, the dirty-dot poll's wait, the
    /// notification center, the clipboard.
    @ObservationIgnored var makeGitWatcher: (_ gitDir: String, _ commonDir: String, _ onChange: @escaping @MainActor () -> Void)
        -> any GitRefsWatching = { GitRefsWatcher(gitDir: $0, commonDir: $1, onChange: $2) }
    @ObservationIgnored var gitPollSleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    @ObservationIgnored var gitNotificationCenter: NotificationCenter = .default
    @ObservationIgnored var copyToPasteboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    let dbPool: DatabasePool
    /// Not private: WorkbenchesViewModel+Git.swift runs the `workbench git` calls.
    let cli: WorkbenchCLI?
    let defaults: UserDefaults

    init(
        dbPool: DatabasePool,
        cli: WorkbenchCLI?,
        defaults: UserDefaults = .standard,
        terminalCenter: TerminalCenter? = nil,
        agentStates: SessionAgentStateCenter? = nil
    ) {
        self.dbPool = dbPool
        self.cli = cli
        self.defaults = defaults
        self.terminalCenter = terminalCenter
        self.agentStates = agentStates
        panelVisible = defaults.object(forKey: Self.panelVisibleKey) as? Bool ?? true
        codeFiles = CodeFilesCenter(defaults: defaults)
        asks = OwnerAsksViewModel(dbPool: dbPool, terminalCenter: terminalCenter, defaults: defaults)
        if let cli {
            let service = TerminalTitleService(runner: cli.runner)
            titleService = { try await service.title(sessionID: $0) }
        }
        terminalCenter?.onSessionExit = { [weak self] id, code in self?.sessionExited(id, code: code) }
        terminalCenter?.onPathLink = { [weak self] workbenchID, location in
            Task { await self?.openTerminalLink(location, workbenchID: workbenchID) }
        }
        asks.isTabOnScreen = { [weak self] in self?.isTabOnScreen() ?? false }
        asks.watchedProjectID = { [weak self] in self?.selectedWorkbenchID }
        asks.onDelivered = { [weak self] projectID, sessionID in
            self?.showAnsweredSession(sessionID, projectID: projectID)
        }
        // A closed session's ring follows its open asks without a poll.
        asks.onAnswered = { [weak agentStates] in await agentStates?.poll() }
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

    func reload() async {
        let previousIDs = summaries.map(\.id)
        do {
            summaries = try await dbPool.read { try WorkbenchQueries.summaries($0) }
        } catch {
            errorMessage = "Could not load workbenches: \(error.localizedDescription)"
            return
        }
        for id in Self.vanished(previous: previousIDs, current: summaries.map(\.id)) {
            await closeTerminal?(id)
            terminalSessions[id] = nil
            // Deleted elsewhere (CLI): never leave its id selected.
            if selectedWorkbenchID == id { selectedWorkbenchID = nil }
        }
        if let selectedWorkbenchID { await loadSessions(projectID: selectedWorkbenchID) }
        await loadSessions(projectID: nil)
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
    /// leaves a non-blocking warning in `errorMessage`. A second call while one
    /// runs is refused.
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
        if let warning = result.cleanupWarning {
            errorMessage = warning
        }
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
    /// first, since a project just selected has no list yet.
    func revealTerminal(projectID: Int64, sessionID: Int64? = nil) async {
        let ticket = beginSwitch(projectID: projectID)
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

    /// New Workbench… → `workbench create`, then the folder install. A failed
    /// install keeps the project (it exists now), shows the install error,
    /// points at Repair and reports `installed: false` to `onWorkbenchCreated`.
    func createWorkbench(folder: URL, name: String?) async {
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
            created = try await cli.create(folder: folder.path, name: name)
        } catch {
            errorMessage = "Could not create the workbench: \(error.localizedDescription)"
            return
        }
        var installed = true
        do {
            try await cli.install(projectID: created.id)
        } catch {
            installed = false
            installNotes[created.id] = "The workbench was created, but installing into the folder failed — use Repair. "
                + error.localizedDescription
        }
        await reload()
        selectedWorkbenchID = created.id
        await refreshInstallStatus(projectID: created.id)
        guard let project = selectedWorkbench else { return }
        onWorkbenchCreated?(project, installed)
        // After a failed install the setup would run without the skill, hook
        // and MCP server it relies on, so no first-run session.
        if installed {
            await startNewSession(project: project, title: TerminalSessionNaming.setupTitle,
                                  prompt: TerminalLaunch.firstRunPrompt(vocabulary(projectID: project.id)))
        }
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
            if !status.needsRepair { installNotes[projectID] = nil }
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
        do {
            try await cli.install(projectID: projectID)
        } catch {
            installNotes[projectID] = "Repair failed: \(error.localizedDescription)"
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

    func dismissResync(projectID: Int64) {
        resyncResults[projectID] = nil
        resyncErrors[projectID] = nil
    }
}

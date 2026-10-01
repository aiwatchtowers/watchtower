import Foundation
import GRDB
import Observation
import WatchtowerCore

/// The Projects tab (spec §6.1). Owned by `AppState` so a create or repair in
/// flight — and the selection — survive navigating away (house rule).
///
/// The daemon/CLI/MCP server write these tables from other processes, so
/// nothing here observes the DB: the view reloads on appear and the
/// notification center's 30 s poll reloads it (Task 18).
@MainActor
@Observable
final class ProjectsViewModel {
    /// Document id (string) → the `updated_at` the owner last opened.
    static let viewedDocumentsKey = "projects.viewedDocuments"

    private(set) var summaries: [ProjectSummary] = []
    var selectedProjectID: Int64? {
        didSet {
            if selectedProjectID != oldValue {
                closeDocument()
                documents = []
                attachNotice = nil
                documentQuery = ""
            }
            // One thing is on screen: a project, or a standalone terminal.
            // Selecting a project also drills the panel into it.
            if let selectedProjectID {
                selectedStandaloneID = nil
                drilledProjectID = selectedProjectID
            } else {
                drilledProjectID = nil
            }
        }
    }
    /// The document the documents pane should open next (a deep link); the
    /// pane consumes and clears it.
    var pendingDocumentID: Int64?
    private(set) var isCreating = false
    private(set) var repairing: Set<Int64> = []
    private(set) var resyncing: Set<Int64> = []
    /// The last Re-run setup result per project, until the owner dismisses it.
    private(set) var resyncResults: [Int64: ProjectResynced] = [:]
    private(set) var resyncErrors: [Int64: String] = [:]
    var errorMessage: String?
    private(set) var installStatus: [Int64: ProjectInstallStatus] = [:]
    /// Why installing or repairing a project's install failed. It explains
    /// the Repair button, so it stays until a status read finds nothing to
    /// repair — the page's own `.task` read races `createProject`'s and must
    /// not wipe it.
    private var installNotes: [Int64: String] = [:]
    /// Why the last status read failed; the next successful read clears it.
    private var statusReadErrors: [Int64: String] = [:]
    /// What create's document import could not do (`ProjectCreated.importNote`),
    /// per project. A status read says nothing about it, so it stays for the
    /// session; a retry runs in the terminal, which the Desktop does not watch.
    private(set) var importNotes: [Int64: String] = [:]
    /// The page's error line, per project — never the shared `errorMessage`,
    /// where one project's failure would outlive a switch to another.
    var installErrors: [Int64: String] {
        installNotes.merging(statusReadErrors) { note, read in "\(note) \(read)" }
    }
    private(set) var documents: [ProjectDocumentListItem] = []
    /// The Documents list's title search (#81); cleared on a project switch.
    var documentQuery = ""
    /// Collapsed groups of the Documents list, per project; kept for the session.
    private(set) var collapsedDocumentGroups: [Int64: Set<ProjectDocumentGrouping.Group>] = [:]

    var documentSections: [ProjectDocumentGrouping.Section] {
        ProjectDocumentGrouping.sections(documents, query: documentQuery)
    }

    func isDocumentGroupCollapsed(_ group: ProjectDocumentGrouping.Group) -> Bool {
        selectedProjectID.map { collapsedDocumentGroups[$0, default: []].contains(group) } ?? false
    }

    func setDocumentGroup(_ group: ProjectDocumentGrouping.Group, collapsed: Bool) {
        guard let selectedProjectID else { return }
        if collapsed {
            collapsedDocumentGroups[selectedProjectID, default: []].insert(group)
        } else {
            collapsedDocumentGroups[selectedProjectID]?.remove(group)
        }
    }

    /// An opened document is always findable in the list: a search that
    /// hides it is cleared and its group unfolded (a deep link or an attach
    /// may open one the list currently hides).
    private func revealInList(_ document: ProjectDocument) {
        if !ProjectDocumentGrouping.matches(document, query: documentQuery) { documentQuery = "" }
        setDocumentGroup(ProjectDocumentGrouping.Group.of(document), collapsed: false)
    }
    /// An "Add document…" attach is running (#80); the sheet disables Attach.
    private(set) var isAttachingDocument = false
    /// Why the last attach failed (the CLI's refusal); the sheet shows it.
    private(set) var attachError: String?
    /// Set when the chosen file was already attached: it opened unchanged,
    /// so the kind and target picked in the sheet were not applied.
    private(set) var attachNotice: String?
    /// The open document. Kept here (not in the view) so it survives pane
    /// switches and tab changes with its watcher running.
    private(set) var documentViewModel: ProjectDocumentViewModel?
    /// Unsent document comments: kept here so they outlive the open document.
    let commentDrafts = ProjectCommentDrafts()

    /// A project was created: Task 18 seeds its notification baseline.
    var onProjectCreated: ((Project, _ installed: Bool) -> Void)?
    /// The embedded terminals. AppState passes its own; nil (most tests) =
    /// nothing launches.
    let terminalCenter: TerminalCenter?
    /// Runs `watchtower terminal title`; nil without a CLI. A seam for tests.
    @ObservationIgnored var titleService: ((Int64) async throws -> TerminalTitleResult)?
    @ObservationIgnored var now: () -> Date = Date.init

    // Session state. Written only by ProjectsViewModel+Sessions.swift, which
    // cannot reach a `private(set)` setter from its own file.

    /// Each project's `terminal_sessions` rows, most recently active first.
    var terminalSessions: [Int64: [TerminalSession]] = [:]
    /// Standalone terminals (`project_id` NULL), most recently active first.
    var standaloneSessions: [TerminalSession] = []
    /// The left panel's level 2: the project drilled into (nil = level 1).
    /// Always nil or `selectedProjectID`: selecting a project drills into
    /// it, Back sets it to nil.
    var drilledProjectID: Int64?
    /// The standalone terminal on screen; mutually exclusive with
    /// `selectedProjectID` (setting a project clears it).
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
    @ObservationIgnored var titleTask: Task<Void, Never>?
    /// Standalone list reads started; only the latest one is applied.
    @ObservationIgnored var standaloneLoads = 0
    /// Per project, session list reads started and the newest one applied.
    struct SessionLoads {
        var started = 0
        var applied = 0
    }
    @ObservationIgnored var projectLoads: [Int64: SessionLoads] = [:]
    /// Reads a project's sessions. A seam for tests (overlapping reads).
    @ObservationIgnored lazy var readProjectSessions: (Int64) async throws -> [TerminalSession] = { [dbPool] projectID in
        try await dbPool.read { try TerminalSessionQueries.fetchForProject($0, projectID: projectID) }
    }
    /// The title poll's wait. A seam for tests.
    @ObservationIgnored var titleSleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    /// The owner changed something in a project (a comment, a status): the
    /// notification policy must not report it back (Task 18).
    var onOwnerWrite: ((Int64, ProjectSubject) -> Void)?
    /// Closes every embedded terminal of a project (SIGHUP → SIGKILL).
    /// AppState wires it to `TerminalCenter.closeAll(where:)` over the
    /// project's sessions in initProjects; a project with none is a no-op,
    /// so calling it twice is harmless.
    var closeTerminal: ((Int64) async -> Void)?
    /// Whether the Projects tab is what the owner is looking at (AppState:
    /// sidebar on Projects, main window visible). The poll marks agent
    /// replies read only then — an open-but-hidden document is not "seen".
    /// Unwired = never on screen.
    var isTabOnScreen: () -> Bool = { false }
    /// The project a delete is running for; the page disables Delete meanwhile.
    private(set) var deletingProjectID: Int64?
    /// Why the last delete failed; the page shows it in an alert.
    var deleteError: String?
    /// The last board drift check per project (PROJ-07, `project check`).
    /// Kept here, not on the board pane, so a result survives navigation.
    private(set) var drift: [Int64: ProjectDriftReport] = [:]
    /// Why the last drift check of a project failed; the next success clears it.
    private(set) var driftErrors: [Int64: String] = [:]
    private var driftCheckedAt: [Int64: Date] = [:]
    private var checkingDrift: Set<Int64> = []
    /// How often the open Board pane re-runs the check (git work in the folder).
    static let driftMinInterval: TimeInterval = 30

    let dbPool: DatabasePool
    private let cli: ProjectCLI?
    let defaults: UserDefaults
    private var viewed: [String: String]

    init(
        dbPool: DatabasePool,
        cli: ProjectCLI?,
        defaults: UserDefaults = .standard,
        terminalCenter: TerminalCenter? = nil
    ) {
        self.dbPool = dbPool
        self.cli = cli
        self.defaults = defaults
        self.terminalCenter = terminalCenter
        viewed = defaults.dictionary(forKey: Self.viewedDocumentsKey) as? [String: String] ?? [:]
        if let cli {
            let service = TerminalTitleService(runner: cli.runner)
            titleService = { try await service.title(sessionID: $0) }
        }
        terminalCenter?.onSessionExit = { [weak self] id, code in self?.sessionExited(id, code: code) }
    }

    var selectedProject: Project? {
        summaries.first { $0.id == selectedProjectID }?.project
    }

    /// Sidebar badge: unread agent comments + documents revised since last viewed.
    var badgeCount: Int {
        summaries.reduce(0) { $0 + $1.unreadAgentComments + revisedDocumentCount(for: $1) }
    }

    func revisedDocumentCount(for summary: ProjectSummary) -> Int {
        summary.documentStamps.filter { id, stamp in viewed[String(id)] != stamp }.count
    }

    func isRevised(_ document: ProjectDocument) -> Bool {
        document.isAgentAttached && viewed[String(document.id)] != document.updatedAt
    }

    func markDocumentViewed(_ document: ProjectDocument) {
        viewed[String(document.id)] = document.updatedAt
        defaults.set(viewed, forKey: Self.viewedDocumentsKey)
    }

    func reload() async {
        let previousIDs = summaries.map(\.id)
        do {
            // A deleted project's documents fall out of `summaries`; their
            // stale `viewed` stamps are never read again, so none are pruned.
            summaries = try await dbPool.read { try ProjectQueries.summaries($0) }
        } catch {
            errorMessage = "Could not load projects: \(error.localizedDescription)"
            return
        }
        for id in Self.vanished(previous: previousIDs, current: summaries.map(\.id)) {
            await closeTerminal?(id)
            terminalSessions[id] = nil
            // Deleted elsewhere (CLI): never leave its id selected.
            if selectedProjectID == id { selectedProjectID = nil }
        }
        if let selectedProjectID { await loadSessions(projectID: selectedProjectID) }
        await loadSessions(projectID: nil)
    }

    /// Deletes a project (spec §6.1, Review Focus #5). Order matters: the
    /// terminal — and with it the Claude Code session writing through
    /// `mcp --project` — closes first, then `watchtower project delete N`
    /// removes the rows and the folder install, then the list reloads. A CLI
    /// failure keeps the project listed and reports the CLI's error. A folder
    /// cleanup failure (`removal_ok == false`) still deletes the project and
    /// leaves a non-blocking warning in `errorMessage`. A second call while one
    /// runs is refused.
    @discardableResult
    func deleteProject(_ id: Int64) async -> Bool {
        guard deletingProjectID == nil else { return false }
        guard let cli else {
            deleteError = "The watchtower CLI was not found."
            return false
        }
        deletingProjectID = id
        deleteError = nil
        defer { deletingProjectID = nil }
        await closeTerminal?(id)
        let result: ProjectDeleted
        do {
            result = try await cli.delete(projectID: id)
        } catch {
            deleteError = "Could not delete the project: \(error.localizedDescription)"
            return false
        }
        if let warning = result.cleanupWarning {
            errorMessage = warning
        }
        if selectedProjectID == id { selectedProjectID = nil }
        await reload()
        return true
    }

    /// The notification center's 30 s poll. The agent writes documents and
    /// comments from another process (DB only, no file change), so besides
    /// the list this also refreshes the documents pane and the open
    /// document's threads — neither re-renders the file, so an open composer
    /// keeps its selection. An agent reply that arrived on the document the
    /// owner has on screen is marked read, the way opening it does; the list
    /// reloads last so its unread badge already reflects that.
    func refreshOnPoll() async {
        if selectedProjectID != nil {
            await loadDocuments()
            await documentViewModel?.refreshThreads(markRead: layout.visiblePanes.contains(.documents) && isTabOnScreen())
        }
        await reload()
    }

    /// Opens `pendingDocumentID` (a deep link). The list is reloaded first
    /// whenever the id is not in it — a notification for a document the
    /// agent just attached must open even when others are already listed.
    func openPendingDocument() async {
        guard let id = pendingDocumentID else { return }
        if !documents.contains(where: { $0.id == id }) { await loadDocuments() }
        guard let item = documents.first(where: { $0.id == id }) else { return }
        pendingDocumentID = nil
        await openDocument(item.document)
    }

    nonisolated static func vanished(previous: [Int64], current: [Int64]) -> [Int64] {
        let now = Set(current)
        return previous.filter { !now.contains($0) }
    }

    /// A deep link puts its pane on screen the way a panel click does.
    func reveal(_ route: ProjectRoute) {
        selectedProjectID = route.projectID
        switch route.pane {
        case .board: layout.show(.board)
        case .documents: layout.show(.documents)
        case .terminal:
            let projectID = route.projectID
            Task { await revealTerminal(projectID: projectID) }
        }
        pendingDocumentID = route.pane == .documents ? route.subjectID : nil
    }

    /// The live session, else the most recent open one (its pane offers
    /// Resume) — read first, since a project just selected has no list yet.
    func revealTerminal(projectID: Int64) async {
        if terminalSessions[projectID] == nil {
            guard await loadSessions(projectID: projectID) else { return }
        }
        let id = activeSessionID(projectID: projectID) ?? terminalSessions[projectID]?.first { !$0.isClosed }?.id
        guard let id else { return }
        var updated = layout(projectID: projectID)
        updated.show(.session(id))
        setLayout(updated, projectID: projectID)
    }

    /// New project… → `project create`, then the folder install. A failed
    /// install keeps the project (it exists now), shows the install error,
    /// points at Repair and reports `installed: false` to `onProjectCreated`.
    func createProject(folder: URL, name: String?) async {
        guard !isCreating else { return }
        guard let cli else {
            errorMessage = "The watchtower CLI was not found."
            return
        }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        let created: ProjectCreated
        do {
            created = try await cli.create(folder: folder.path, name: name)
        } catch {
            errorMessage = "Could not create the project: \(error.localizedDescription)"
            return
        }
        importNotes[created.id] = created.importNote
        var installed = true
        do {
            try await cli.install(projectID: created.id)
        } catch {
            installed = false
            installNotes[created.id] = "The project was created, but installing into the folder failed — use Repair. "
                + error.localizedDescription
        }
        await reload()
        selectedProjectID = created.id
        await refreshInstallStatus(projectID: created.id)
        guard let project = selectedProject else { return }
        onProjectCreated?(project, installed)
        // After a failed install the setup would run without the skill, hook
        // and MCP server it relies on, so no first-run session.
        if installed {
            await startNewSession(project: project, title: TerminalSessionNaming.setupTitle,
                                  prompt: TerminalLaunch.firstRunPrompt)
        }
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

    /// Re-run setup (#91): `project resync` attaches the folder's new
    /// documents and re-installs missing or outdated integration pieces, then
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
        // The CLI may have attached documents or installed files even when
        // it failed or its report could not be read.
        await reload()
        if selectedProjectID == projectID { await loadDocuments() }
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

    func loadDocuments() async {
        guard let projectID = selectedProjectID else { return }
        do {
            documents = try await dbPool.read { try ProjectQueries.documentListItems($0, projectID: projectID) }
        } catch {
            errorMessage = "Could not load documents: \(error.localizedDescription)"
        }
    }

    /// "Add document…" (#80): `project attach-doc` writes the owner's row —
    /// the CLI checks the file is a .md/.txt inside the folder, symlinks
    /// resolved — and the pane opens it. The file itself is never written
    /// (PROJ-03). Returns whether it attached; on false `attachError` says why.
    func attachDocument(fileURL: URL, kind: String, targetID: Int64?) async -> Bool {
        guard let project = selectedProject, !isAttachingDocument else { return false }
        guard let cli else {
            attachError = "The watchtower CLI was not found."
            return false
        }
        isAttachingDocument = true
        clearAttachMessages()
        defer { isAttachingDocument = false }
        let attached: ProjectDocumentAttached
        do {
            attached = try await cli.attachDocument(projectID: project.id, path: fileURL.path, kind: kind, targetID: targetID)
        } catch {
            attachError = "Could not attach the document: \(error.localizedDescription)"
            return false
        }
        if attached.created { onOwnerWrite?(project.id, .document(attached.documentID)) }
        await loadDocuments()
        // Still on this project: open it (also for an already attached path).
        if let item = documents.first(where: { $0.id == attached.documentID }) {
            await openDocument(item.document)
            // Still the open document: a project switch during the open closed it.
            if !attached.created, documentViewModel?.document.id == attached.documentID {
                attachNotice = "\(attached.relPath) was already attached — it is open, with its kind and target unchanged."
            }
        }
        return true
    }

    func clearAttachMessages() {
        attachError = nil
        attachNotice = nil
    }

    /// The target picker's choices for "Add document…", in board order.
    func targetChoices() async throws -> [ProjectBoardRow] {
        guard let projectID = selectedProjectID else { return [] }
        let board = try await dbPool.read { try ProjectQueries.board($0, projectID: projectID) }
        return ProjectBoardOutline.rows(board, collapsed: [], showDone: true)
    }

    func openDocument(_ document: ProjectDocument) async {
        guard let project = selectedProject, project.id == document.projectID else { return }
        attachNotice = nil
        revealInList(document)
        if documentViewModel?.document.id != document.id {
            closeDocument()
            let docVM = ProjectDocumentViewModel(dbPool: dbPool, project: project, document: document, drafts: commentDrafts)
            docVM.onOwnerWrite = { [weak self] subject in self?.onOwnerWrite?(project.id, subject) }
            docVM.startWatching()
            documentViewModel = docVM
        }
        await documentViewModel?.load()
        if let loaded = documentViewModel?.document { markDocumentViewed(loaded) }
        await loadDocuments()
        await reload()
    }

    func closeDocument() {
        documentViewModel?.stopWatching()
        documentViewModel = nil
    }
}

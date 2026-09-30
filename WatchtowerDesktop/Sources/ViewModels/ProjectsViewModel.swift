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
    var pane: ProjectPane = .terminal
    /// The document the documents pane should open next (a deep link); the
    /// pane consumes and clears it.
    var pendingDocumentID: Int64?
    private(set) var isCreating = false
    private(set) var repairing: Set<Int64> = []
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
    /// Per project, the session last opened: its terminal pane keeps showing
    /// it (exit bar included) until it is closed.
    var shownSessionIDs: [Int64: Int64] = [:]
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
    /// Why the last board-language change of a project failed; the page shows it.
    var boardLanguageErrors: [Int64: String] = [:]
    /// Projects a board-language change is running for; the menu is disabled meanwhile.
    private(set) var settingBoardLanguage: Set<Int64> = []

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
            shownSessionIDs[id] = nil
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
        if !result.removalOK {
            errorMessage = "The project was deleted, but cleaning its folder failed: \(result.removalError)"
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
            await documentViewModel?.refreshThreads(markRead: pane == .documents && isTabOnScreen())
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

    func reveal(_ route: ProjectRoute) {
        selectedProjectID = route.projectID
        pane = route.pane
        pendingDocumentID = route.pane == .documents ? route.subjectID : nil
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
        pane = .terminal
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

    func repairInstall(projectID: Int64) async {
        guard let cli, !repairing.contains(projectID) else { return }
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

    /// Runs `watchtower project update N --board-language=…`, then reloads so
    /// the page shows the stored (normalized) value. A CLI failure — the
    /// CLI's own validation included — keeps the old value and says why.
    func setBoardLanguage(projectID: Int64, language: String) async {
        guard !settingBoardLanguage.contains(projectID) else { return }
        guard let cli else {
            boardLanguageErrors[projectID] = "The watchtower CLI was not found."
            return
        }
        settingBoardLanguage.insert(projectID)
        defer { settingBoardLanguage.remove(projectID) }
        boardLanguageErrors[projectID] = nil
        do {
            try await cli.setBoardLanguage(projectID: projectID, language: language)
        } catch {
            boardLanguageErrors[projectID] = "Could not change the board language: \(error.localizedDescription)"
            return
        }
        await reload()
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
        if documentViewModel?.document.id != document.id {
            closeDocument()
            let docVM = ProjectDocumentViewModel(dbPool: dbPool, project: project, document: document)
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

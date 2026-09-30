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
    /// The page's error line, per project — never the shared `errorMessage`,
    /// where one project's failure would outlive a switch to another.
    var installErrors: [Int64: String] {
        installNotes.merging(statusReadErrors) { note, read in "\(note) \(read)" }
    }
    private(set) var documents: [ProjectDocumentListItem] = []
    /// The open document. Kept here (not in the view) so it survives pane
    /// switches and tab changes with its watcher running.
    private(set) var documentViewModel: ProjectDocumentViewModel?

    /// A project was created: Task 18 seeds its notification baseline.
    var onProjectCreated: ((Project, _ installed: Bool) -> Void)?
    /// Starts (and focuses) a session's process. AppState wires it to
    /// `TerminalCenter.start`; unwired = nothing launches.
    var startSession: ((TerminalSession, _ fresh: Bool, _ prompt: String?) -> Void)?
    /// Each project's `terminal_sessions` rows, most recently active first.
    private(set) var terminalSessions: [Int64: [TerminalSession]] = [:]
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

    let dbPool: DatabasePool
    private let cli: ProjectCLI?
    private let defaults: UserDefaults
    private var viewed: [String: String]

    init(dbPool: DatabasePool, cli: ProjectCLI?, defaults: UserDefaults = .standard) {
        self.dbPool = dbPool
        self.cli = cli
        self.defaults = defaults
        viewed = defaults.dictionary(forKey: Self.viewedDocumentsKey) as? [String: String] ?? [:]
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
        viewed[String(document.id)] != document.updatedAt
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
        }
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

    func loadTerminalSessions(projectID: Int64) async {
        do {
            terminalSessions[projectID] = try await dbPool.read {
                try TerminalSessionQueries.fetchForProject($0, projectID: projectID)
            }
        } catch {
            errorMessage = "Could not load terminal sessions: \(error.localizedDescription)"
        }
    }

    /// Creates a `claude` session row with a new Claude session id and starts
    /// it fresh (`--session-id`).
    func startNewSession(project: Project, title: String, prompt: String? = nil) async {
        let new = TerminalSessionQueries.NewSession(
            projectID: project.id, kind: .claude, title: title,
            folderPath: project.folderPath, claudeSessionID: UUID().uuidString.lowercased()
        )
        let row: TerminalSession
        do {
            row = try await dbPool.write { try TerminalSessionQueries.create($0, new) }
        } catch {
            errorMessage = "Could not create a terminal session: \(error.localizedDescription)"
            return
        }
        await loadTerminalSessions(projectID: project.id)
        startSession?(row, true, prompt)
    }

    /// "Open terminal": resumes the project's most recently active open
    /// session, or starts a new one when it has none.
    func openMostRecentSession(project: Project) async {
        await loadTerminalSessions(projectID: project.id)
        if let row = terminalSessions[project.id]?.first(where: { !$0.isClosed }) {
            startSession?(row, false, nil)
        } else {
            await startNewSession(project: project, title: TerminalSessionNaming.provisional(now: Date()))
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

    func loadDocuments() async {
        guard let projectID = selectedProjectID else { return }
        do {
            documents = try await dbPool.read { try ProjectQueries.documentListItems($0, projectID: projectID) }
        } catch {
            errorMessage = "Could not load documents: \(error.localizedDescription)"
        }
    }

    func openDocument(_ document: ProjectDocument) async {
        guard let project = selectedProject, project.id == document.projectID else { return }
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

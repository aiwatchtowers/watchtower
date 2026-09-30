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
    private(set) var documents: [ProjectDocumentListItem] = []
    /// The open document. Kept here (not in the view) so it survives pane
    /// switches and tab changes with its watcher running.
    private(set) var documentViewModel: ProjectDocumentViewModel?

    /// A project was created: Task 18 seeds its notification baseline, and —
    /// only when `installed` — Task 17 opens its terminal with the first-run
    /// prompt (after a failed install the setup would run without the skill,
    /// hook and MCP server it relies on).
    var onProjectCreated: ((Project, _ installed: Bool) -> Void)?
    /// The owner changed something in a project (a comment, a status): the
    /// notification policy must not report it back (Task 18).
    var onOwnerWrite: ((Int64, ProjectSubject) -> Void)?
    /// Closes a project's embedded terminal (SIGHUP → SIGKILL). AppState wires
    /// it to ProjectTerminalCenter.close in initProjects; closing a project
    /// with no terminal is a no-op, so calling it twice is harmless.
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
            errorMessage = "The project was created, but installing into the folder failed — use Repair. "
                + error.localizedDescription
        }
        await reload()
        selectedProjectID = created.id
        pane = .terminal
        await refreshInstallStatus(projectID: created.id)
        if let project = selectedProject {
            onProjectCreated?(project, installed)
        }
    }

    func refreshInstallStatus(projectID: Int64) async {
        guard let cli else { return }
        do {
            installStatus[projectID] = try await cli.status(projectID: projectID)
        } catch {
            installStatus[projectID] = nil
            errorMessage = "Could not read the install status: \(error.localizedDescription)"
        }
    }

    func repairInstall(projectID: Int64) async {
        guard let cli, !repairing.contains(projectID) else { return }
        repairing.insert(projectID)
        defer { repairing.remove(projectID) }
        do {
            try await cli.install(projectID: projectID)
            errorMessage = nil
        } catch {
            errorMessage = "Repair failed: \(error.localizedDescription)"
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

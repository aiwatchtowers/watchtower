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
    var selectedProjectID: Int64?
    var pane: ProjectPane = .terminal
    /// The document the documents pane should open next (a deep link); the
    /// pane consumes and clears it.
    var pendingDocumentID: Int64?
    private(set) var isCreating = false
    private(set) var repairing: Set<Int64> = []
    var errorMessage: String?
    private(set) var installStatus: [Int64: ProjectInstallStatus] = [:]

    /// A project was created: Task 17 opens its terminal with the first-run
    /// prompt, Task 18 seeds its notification baseline.
    var onProjectCreated: ((Project) -> Void)?
    /// The owner changed something in a project (a comment, a status): the
    /// notification policy must not report it back (Task 18).
    var onOwnerWrite: ((Int64, ProjectSubject) -> Void)?

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
        do {
            // A deleted project's documents fall out of `summaries`; their
            // stale `viewed` stamps are never read again, so none are pruned.
            summaries = try await dbPool.read { try ProjectQueries.summaries($0) }
        } catch {
            errorMessage = "Could not load projects: \(error.localizedDescription)"
        }
    }

    func reveal(_ route: ProjectRoute) {
        selectedProjectID = route.projectID
        pane = route.pane
        pendingDocumentID = route.pane == .documents ? route.subjectID : nil
    }

    /// New project… → `project create`, then the folder install. A failed
    /// install keeps the project (it exists now) and points at Repair.
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
        do {
            try await cli.install(projectID: created.id)
        } catch {
            errorMessage = "The project was created, but installing into the folder failed — use Repair. "
                + error.localizedDescription
        }
        await reload()
        selectedProjectID = created.id
        pane = .terminal
        await refreshInstallStatus(projectID: created.id)
        if let project = selectedProject {
            onProjectCreated?(project)
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
}

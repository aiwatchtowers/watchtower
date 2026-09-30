import Foundation
import GRDB
import WatchtowerCore

/// The project page's Board pane: the target tree, one selected target's
/// detail and its comment threads. Owner edits are direct GRDB writes through
/// the same `TargetQueries` mutators the Targets tab uses (the targets
/// dual-path precedent). Agent writes arrive from another process
/// (`watchtower mcp --project N`), which ValueObservation cannot see, so the
/// pane polls a cheap fingerprint while it is on screen.
@MainActor
@Observable
final class ProjectBoardViewModel {
    let projectID: Int64
    private(set) var roots: [ProjectBoardNode] = []
    var collapsed: Set<Int> = []
    var showDone = false
    private(set) var selectedTargetID: Int?
    private(set) var selectedComments: [ProjectComment] = []
    private(set) var errorMessage: String?

    var rows: [ProjectBoardRow] {
        ProjectBoardOutline.rows(roots, collapsed: collapsed, showDone: showDone)
    }

    var selectedNode: ProjectBoardNode? {
        selectedTargetID.flatMap { ProjectBoardOutline.find($0, in: roots) }
    }

    var threads: [ProjectCommentThread] { ProjectCommentThread.group(selectedComments) }

    /// `ProjectsViewModel.onOwnerWrite`, set by the view: every successful owner
    /// write reports its target so the notification center never announces the
    /// owner's own change (e.g. a target the owner marked done).
    var onOwnerWrite: ((Int64, ProjectSubject) -> Void)?

    private let dbPool: DatabasePool
    private var fingerprint = ""
    private var pollTask: Task<Void, Never>?

    init(dbPool: DatabasePool, projectID: Int64) {
        self.dbPool = dbPool
        self.projectID = projectID
    }

    // MARK: - Loading

    func load() {
        do {
            let pid = projectID
            let selected = selectedTargetID
            let (board, comments, stamp) = try dbPool.read { db in
                (
                    try ProjectQueries.board(db, projectID: pid),
                    try selected.map { try ProjectQueries.comments(db, targetID: Int64($0)) } ?? [],
                    try Self.fingerprint(db, projectID: pid)
                )
            }
            roots = board
            selectedComments = comments
            fingerprint = stamp
            if let selected, ProjectBoardOutline.find(selected, in: board) == nil {
                selectedTargetID = nil
                selectedComments = []
            }
        } catch {
            errorMessage = "Could not load the board: \(error.localizedDescription)"
        }
    }

    /// Reloads when anything on this project's board changed since the last
    /// load, including writes from another process. Returns whether it reloaded.
    @discardableResult
    func refreshIfChanged() -> Bool {
        let pid = projectID
        guard let current = try? dbPool.read({ try Self.fingerprint($0, projectID: pid) }),
              current != fingerprint else { return false }
        load()
        return true
    }

    func startPolling(every interval: Duration = .seconds(5)) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.refreshIfChanged()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Counts plus the latest timestamps of everything the board renders. Any
    /// agent write (a new target, a status move, a comment, a resolve, a read
    /// mark) changes at least one of them.
    nonisolated private static func fingerprint(_ db: Database, projectID: Int64) throws -> String {
        let targets = try Row.fetchOne(
            db,
            sql: "SELECT COUNT(*), MAX(updated_at) FROM targets WHERE project_id = ?",
            arguments: [projectID]
        )
        let comments = try Row.fetchOne(
            db,
            sql: """
                SELECT COUNT(*), MAX(created_at), MAX(read_at),
                       SUM(CASE WHEN status = 'open' THEN 1 ELSE 0 END)
                FROM project_comments WHERE project_id = ?
                """,
            arguments: [projectID]
        )
        let docs = try Row.fetchOne(
            db,
            sql: "SELECT COUNT(*), MAX(updated_at) FROM project_documents WHERE project_id = ?",
            arguments: [projectID]
        )
        return [targets, comments, docs].map { $0?.description ?? "" }.joined(separator: "|")
    }

    // MARK: - Selection

    func select(_ targetID: Int?) {
        selectedTargetID = targetID
        errorMessage = nil
        load()
        guard let node = selectedNode, node.unreadForOwner > 0 else { return }
        do {
            let pid = projectID
            try dbPool.write { db in
                try ProjectQueries.markAgentCommentsRead(
                    db, projectID: pid, targetID: Int64(node.target.id), documentID: nil
                )
            }
            load()
        } catch {
            // The badge stays: roots were not reloaded, so unreadForOwner is unchanged.
            errorMessage = "Could not mark comments read: \(error.localizedDescription)"
        }
    }

    func toggle(_ targetID: Int) {
        if collapsed.contains(targetID) {
            collapsed.remove(targetID)
        } else {
            collapsed.insert(targetID)
        }
    }

    // MARK: - Edits

    func setStatus(_ status: String) {
        guard let id = selectedTargetID, ProjectBoardCard.editableStatuses.contains(status) else { return }
        // The rollup (PROJ-05) may move the target's parents in the same
        // write; they are the owner's doing too, so they never notify.
        var rolledUp: [Int64] = []
        write("change the status", alsoTouched: { rolledUp }) { db in
            let before = try ProjectQueries.ancestorStatuses(db, of: Int64(id))
            try TargetQueries.updateStatus(db, id: id, status: status)
            let after = try ProjectQueries.ancestorStatuses(db, of: Int64(id))
            rolledUp = after.filter { before[$0.key] != $0.value }.map(\.key).sorted()
        }
    }

    func setPriority(_ priority: String) {
        guard let id = selectedTargetID, ProjectBoardCard.editablePriorities.contains(priority) else { return }
        write("change the priority") { db in try TargetQueries.updatePriority(db, id: id, priority: priority) }
    }

    func rename(_ text: String) {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = selectedTargetID, !title.isEmpty else { return }
        write("rename the target") { db in try TargetQueries.updateText(db, id: id, text: title) }
    }

    /// - Returns: whether the comment was written, so the composer keeps the
    ///   owner's draft on a failure (`errorMessage` says why).
    @discardableResult
    func addComment(_ body: String) -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = selectedTargetID, !text.isEmpty else { return false }
        let pid = projectID
        return write("add the comment") { db in
            _ = try ProjectQueries.addOwnerComment(
                db, projectID: pid, targetID: Int64(id), documentID: nil, anchor: nil, body: text
            )
        }
    }

    /// - Returns: whether the reply was written, so the thread keeps the
    ///   owner's draft on a failure (`errorMessage` says why).
    @discardableResult
    func reply(to rootID: Int64, body: String) -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return write("reply") { db in _ = try ProjectQueries.reply(db, to: rootID, body: text) }
    }

    func setThreadStatus(rootID: Int64, status: String) {
        write("update the thread") { db in try ProjectQueries.setStatus(db, commentID: rootID, status: status) }
    }

    /// Every owner write goes through here: the write, then the hook, then a
    /// reload. The hook fires only after the write succeeded — for the
    /// selected target and for every target `alsoTouched` names.
    @discardableResult
    private func write(
        _ what: String,
        alsoTouched: () -> [Int64] = { [] },
        _ body: (Database) throws -> Void
    ) -> Bool {
        do {
            try dbPool.write { db in try body(db) }
            errorMessage = nil
            if let id = selectedTargetID {
                onOwnerWrite?(projectID, .target(Int64(id)))
            }
            for id in alsoTouched() {
                onOwnerWrite?(projectID, .target(id))
            }
            load()
            return true
        } catch {
            errorMessage = "Could not \(what): \(error.localizedDescription)"
            return false
        }
    }
}

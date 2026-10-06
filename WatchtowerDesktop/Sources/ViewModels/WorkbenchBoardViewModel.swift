import Foundation
import GRDB
import WatchtowerCore

/// The project page's Board pane: the target tree, one selected target's
/// detail and its comment threads. Owner edits are direct GRDB writes through
/// the same `TargetQueries` mutators the Targets tab uses (the targets
/// dual-path precedent). Agent writes arrive from another process
/// (`watchtower mcp --workbench N`), which ValueObservation cannot see, so the
/// pane polls a cheap fingerprint while it is on screen.
@MainActor
@Observable
final class WorkbenchBoardViewModel {
    let projectID: Int64
    private(set) var roots: [WorkbenchBoardNode] = []
    var collapsed: Set<Int> = []
    var showDone = false
    /// The toolbar's "Archive (K)" (board #301): archived targets back on
    /// the board, dimmed. Session-only like `showDone`.
    var showArchived = false
    /// The board's search field (board #207; `WorkbenchBoardSearch`): view
    /// state, not remembered.
    var searchText = ""
    /// The side panel's navigation stack (spec 2026-10-06 Part 3): target
    /// ids, the open one last. A board click resets it (`select`), the parent
    /// link and a sub-task click push, "‹" pops (`back`).
    private(set) var panelPath: [Int] = []
    var selectedTargetID: Int? { panelPath.last }
    var canGoBack: Bool { panelPath.count > 1 }
    private(set) var selectedComments: [WorkbenchComment] = []
    /// The selected target's images (board target #117), read-only here.
    private(set) var selectedImages: [WorkbenchTargetImage] = []
    /// The selected target's owner asks, newest first (spec 2026-10-03 Part 8).
    private(set) var selectedAsks: [OwnerAskListItem] = []
    /// The selected target's status changes, newest first; read with the
    /// comments on selection and on reload.
    private(set) var selectedHistory: [TargetStatusChange] = []
    private(set) var errorMessage: String?

    /// List or Kanban, remembered per project.
    var mode: WorkbenchBoardMode {
        didSet { preferences.mode = mode }
    }

    /// The kanban parent filter (a top-level target id; nil = All),
    /// remembered per project. A stale id shows as All.
    var kanbanFilterRootID: Int? {
        didSet { preferences.kanbanFilterRootID = kanbanFilterRootID }
    }

    /// Kanban's "Lanes: By group | None", remembered per project.
    var lanesMode: WorkbenchBoardLanesMode {
        didSet { preferences.lanesMode = lanesMode }
    }

    /// What Kanban lays out: lanes under a totals row, or the flat columns.
    enum KanbanLayout: Equatable {
        case lanes
        case columns
    }

    var kanbanLayout: KanbanLayout { lanesMode == .none ? .columns : .lanes }

    /// Folded lanes as remembered (`Lane.id`, No group = 0), stale ids
    /// included: a target that is a lane again folds again. Read through
    /// `foldedLaneIDs(in:)`.
    private var storedFoldedLanes: Set<Int>

    /// Lanes whose folded Done the owner opened ("✓ N done — show"): this
    /// session only, never remembered (spec 2026-10-06 Part 2).
    private(set) var unfoldedDoneLanes: Set<Int> = []

    var kanban: WorkbenchBoardKanban {
        WorkbenchBoardKanban(
            roots, filterRootID: kanbanFilterRootID, showDone: showDone, showArchived: showArchived, query: searchText
        )
    }

    var rows: [WorkbenchBoardRow] {
        WorkbenchBoardOutline.rows(
            roots, collapsed: collapsed, showDone: showDone, showArchived: showArchived, query: searchText
        )
    }

    /// The K of "Archive (K)": what the toggle adds in the current mode —
    /// every archived target in the list, the archived leaf cards under the
    /// parent filter in Kanban.
    var archivedCount: Int {
        mode == .kanban ? kanban.archivedCardCount : WorkbenchBoardOutline.archivedCount(roots)
    }

    var selectedNode: WorkbenchBoardNode? {
        selectedTargetID.flatMap { WorkbenchBoardOutline.find($0, in: roots) }
    }

    /// The open target's nearest parent: the panel's parent link. Nil at
    /// the top level.
    var selectedParent: WorkbenchBoardNode? {
        selectedNode?.target.parentId.flatMap { WorkbenchBoardOutline.find($0, in: roots) }
    }

    var threads: [WorkbenchCommentThread] { WorkbenchCommentThread.group(selectedComments) }

    /// `WorkbenchesViewModel.onOwnerWrite`, set by the view: every successful owner
    /// write reports its target so the notification center never announces the
    /// owner's own change (e.g. a target the owner marked done).
    var onOwnerWrite: ((Int64, WorkbenchSubject) -> Void)?

    /// Called on every poll tick while the pane is on screen: the view asks
    /// for a drift check (`WorkbenchesViewModel.refreshDrift`, throttled there),
    /// so a git change — a merge, a fetch — that never touches the board
    /// shows too.
    var onPollTick: (() -> Void)?

    private let dbPool: DatabasePool
    private let preferences: WorkbenchBoardPreferences
    private var fingerprint = ""
    private var pollTask: Task<Void, Never>?

    init(dbPool: DatabasePool, projectID: Int64, defaults: UserDefaults = .standard) {
        self.dbPool = dbPool
        self.projectID = projectID
        let preferences = WorkbenchBoardPreferences(workbenchID: projectID, defaults: defaults)
        self.preferences = preferences
        mode = preferences.mode
        kanbanFilterRootID = preferences.kanbanFilterRootID
        lanesMode = preferences.lanesMode
        storedFoldedLanes = preferences.foldedLanes
    }

    // MARK: - Loading

    func load() {
        do {
            let pid = projectID
            let requestedPath = panelPath
            let (board, path, comments, images, asks, history, stamp) = try dbPool.read { db in
                let board = try WorkbenchQueries.board(db, projectID: pid)
                // A target gone from the board leaves the path: the panel
                // falls back to the nearest surviving entry, or closes.
                let path = requestedPath.filter { WorkbenchBoardOutline.find($0, in: board) != nil }
                let selected = path.last.map(Int64.init)
                return (
                    board,
                    path,
                    try selected.map { try WorkbenchQueries.comments(db, targetID: $0) } ?? [],
                    try selected.map { try WorkbenchQueries.images(db, targetID: $0) } ?? [],
                    try selected.map { try OwnerAskQueries.targetAsks(db, projectID: pid, targetID: $0) } ?? [],
                    try selected.map { Array(try TargetQueries.statusHistory(db, targetID: $0).reversed()) } ?? [],
                    try Self.fingerprint(db, projectID: pid)
                )
            }
            roots = board
            panelPath = path
            selectedComments = comments
            selectedImages = images
            selectedAsks = asks
            selectedHistory = history
            fingerprint = stamp
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
                self.onPollTick?()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Counts plus the latest timestamps of everything the board renders. Any
    /// agent write (a new target, a status move, a comment, a resolve, a read
    /// mark) changes at least one of them. The archive setting is in it too, so
    /// a change applies at once; a target that merely ages into the archive
    /// leaves at the next reload (spec 2026-10-04 decision 10, v1 limit).
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
        // Rows are only inserted and deleted, never updated: count + max id
        // changes with every attach and detach.
        let images = try Row.fetchOne(
            db,
            sql: "SELECT COUNT(*), MAX(id) FROM project_target_images WHERE project_id = ?",
            arguments: [projectID]
        )
        // An ask changes status (answered, delivered, withdrawn) in place:
        // the open count and the latest stamps move with it.
        let asks = try Row.fetchOne(
            db,
            sql: """
                SELECT COUNT(*), MAX(id), SUM(CASE WHEN status = 'open' THEN 1 ELSE 0 END),
                       MAX(answered_at), MAX(delivered_at)
                FROM owner_asks WHERE project_id = ?
                """,
            arguments: [projectID]
        )
        let archive = try Row.fetchOne(
            db, sql: "SELECT archive_after_days FROM projects WHERE id = ?", arguments: [projectID]
        )
        return [targets, comments, images, asks, archive].map { $0?.description ?? "" }.joined(separator: "|")
    }

    // MARK: - Selection

    /// A board click (or the Session view's `boardFocus` handoff): the
    /// panel opens `targetID` on a fresh path; nil closes it.
    func select(_ targetID: Int?) {
        open(targetID.map { [$0] } ?? [])
    }

    /// The panel's parent link or a sub-task click: `targetID` opens on top
    /// of the path, so "‹" returns. The open target itself adds no entry,
    /// and a target already on the path cuts the path back to it (task →
    /// parent → the same task again leaves `[task]`), so a path never holds
    /// an id twice and "‹" never walks a loop.
    func push(_ targetID: Int) {
        guard panelPath.last != targetID else { return }
        if let index = panelPath.firstIndex(of: targetID) {
            open(Array(panelPath.prefix(through: index)))
        } else {
            open(panelPath + [targetID])
        }
    }

    /// "‹": back to the previous entry. A no-op on a path of one.
    func back() {
        guard canGoBack else { return }
        open(Array(panelPath.dropLast()))
    }

    /// Every panel navigation: the new path, a fresh read, and the open
    /// target's agent comments marked read.
    private func open(_ path: [Int]) {
        panelPath = path
        errorMessage = nil
        load()
        guard let node = selectedNode, node.unreadForOwner > 0 else { return }
        do {
            let pid = projectID
            try dbPool.write { db in
                try WorkbenchQueries.markAgentCommentsRead(db, projectID: pid, targetID: Int64(node.target.id))
            }
            load()
        } catch {
            // The badge stays: roots were not reloaded, so unreadForOwner is unchanged.
            errorMessage = "Could not mark comments read: \(error.localizedDescription)"
        }
    }

    /// Closes the side panel. Unlike `select(nil)` it keeps `errorMessage`:
    /// a failed write from the panel (rename, status, comment) moves to the
    /// board's banner instead of vanishing with the panel.
    func closeDetail() {
        panelPath = []
        selectedComments = []
        selectedImages = []
        selectedAsks = []
        selectedHistory = []
        load()
    }

    /// The board's error banner is dismissed by the owner: a poll reload
    /// does not clear it, so a failed drop's message stays until read.
    func dismissError() {
        errorMessage = nil
    }

    func toggle(_ targetID: Int) {
        if collapsed.contains(targetID) {
            collapsed.remove(targetID)
        } else {
            collapsed.insert(targetID)
        }
    }

    // MARK: - Lanes

    /// The folded ones among `lanes` (the board on screen); a remembered id
    /// that is no longer a lane is ignored, never dropped from storage.
    func foldedLaneIDs(in lanes: [WorkbenchBoardKanban.Lane]) -> Set<Int> {
        storedFoldedLanes.intersection(lanes.map(\.id))
    }

    /// The lane header's chevron: folds or opens the lane, remembered per
    /// project. Stale ids already stored stay stored.
    func toggleLane(_ laneID: Int) {
        if storedFoldedLanes.remove(laneID) == nil { storedFoldedLanes.insert(laneID) }
        preferences.foldedLanes = storedFoldedLanes
    }

    /// "✓ N done — show" and its "Hide done": this lane's Done only.
    func toggleLaneDone(_ laneID: Int) {
        if unfoldedDoneLanes.remove(laneID) == nil { unfoldedDoneLanes.insert(laneID) }
    }

    // MARK: - Edits

    /// The detail pane's status menu: the selected target.
    func setStatus(_ status: String) {
        guard let id = selectedTargetID else { return }
        setStatus(status, for: id)
    }

    /// The one status writer — the detail menu and a kanban drop alike. A
    /// status equal to the current one (a drop into the card's own column),
    /// a status the board does not offer, and a target not on this board
    /// write nothing.
    /// - Returns: whether a status was written (a failed write sets `errorMessage`).
    @discardableResult
    func setStatus(_ status: String, for id: Int) -> Bool {
        guard WorkbenchBoardCard.editableStatuses.contains(status),
              let current = WorkbenchBoardOutline.find(id, in: roots),
              current.target.status != status else { return false }
        // The rollup (PROJ-05) may move the target's parents in the same
        // write; they are the owner's doing too, so they never notify.
        var rolledUp: [Int64] = []
        let body: (Database) throws -> Void = { db in
            let before = try WorkbenchQueries.ancestorStatuses(db, of: Int64(id))
            try TargetQueries.updateStatus(db, id: id, status: status)
            let after = try WorkbenchQueries.ancestorStatuses(db, of: Int64(id))
            rolledUp = after.filter { before[$0.key] != $0.value }.map(\.key).sorted()
        }
        return write("change the status", target: id, alsoTouched: { rolledUp }, body)
    }

    /// Nests a target under another one, or moves it to the top level when
    /// `parentID` is nil (board #186) — the list's drag and drop and the
    /// "Move to…" menu. A move the board does not allow (`canMove`) writes
    /// nothing. The new parent is expanded so the moved target stays in view.
    /// - Returns: whether the target moved (a failed write sets `errorMessage`).
    @discardableResult
    func move(_ id: Int, under parentID: Int?) -> Bool {
        guard WorkbenchBoardOutline.canMove(id, under: parentID, in: roots) else {
            // A drop onto its own sub-target is a refusal worth saying; a drop
            // onto itself or its current parent is a quiet no-op.
            if let parentID, parentID != id, let node = WorkbenchBoardOutline.find(id, in: roots),
               WorkbenchBoardOutline.find(parentID, in: [node]) != nil {
                errorMessage = TargetParentCycleError(id: Int64(id), parentID: Int64(parentID)).errorDescription
            }
            return false
        }
        let pid = projectID
        // Both the old and the new parent chain may roll up (PROJ-05); those
        // are the owner's doing too, so they never notify.
        var rolledUp: [Int64] = []
        let body: (Database) throws -> Void = { db in
            let before = try WorkbenchQueries.statuses(db, projectID: pid)
            try WorkbenchQueries.moveTarget(db, projectID: pid, targetID: Int64(id), parentID: parentID.map(Int64.init))
            let after = try WorkbenchQueries.statuses(db, projectID: pid)
            rolledUp = after.filter { before[$0.key] != $0.value }.map(\.key).sorted()
        }
        let moved = write("move the target", target: id, alsoTouched: { rolledUp }, body)
        if moved, let parentID { collapsed.remove(parentID) }
        return moved
    }

    func setPriority(_ priority: String) {
        guard let id = selectedTargetID, WorkbenchBoardCard.editablePriorities.contains(priority) else { return }
        write("change the priority") { db in try TargetQueries.updatePriority(db, id: id, priority: priority) }
    }

    func rename(_ text: String) {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = selectedTargetID, !title.isEmpty else { return }
        write("rename the target") { db in try TargetQueries.updateText(db, id: id, text: title) }
    }

    /// The panel's description editor (⌘↩ or focus loss) on `id`, the
    /// target the editor was opened on (nil = the open one): a focus loss
    /// that lands after the panel moved on still saves to its own target.
    /// The text is trimmed like a rename; a description unchanged once
    /// trimmed writes nothing.
    /// - Returns: whether the description is saved, so the editor keeps the
    ///   owner's draft on a failure (`errorMessage` says why).
    @discardableResult
    func saveIntent(_ text: String, for id: Int? = nil) -> Bool {
        let intent = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = id ?? selectedTargetID, let node = WorkbenchBoardOutline.find(id, in: roots) else { return false }
        guard node.target.intent != intent else { return true }
        return write("save the description", target: id) { db in
            try TargetQueries.updateIntent(db, id: id, intent: intent)
        }
    }

    /// An Asks row in the panel: `show` is `WorkbenchesViewModel.showAsk`,
    /// the "Waiting for you" stack row's path, so a click never starts an
    /// agent. An ask that is gone says so in the panel's error row.
    func openAsk(_ askID: Int64, show: (Int64, Int64) async -> Bool) async {
        if await !show(askID, projectID) {
            errorMessage = "This ask is gone."
        }
    }

    /// - Returns: whether the comment was written, so the composer keeps the
    ///   owner's draft on a failure (`errorMessage` says why).
    @discardableResult
    func addComment(_ body: String) -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = selectedTargetID, !text.isEmpty else { return false }
        let pid = projectID
        return write("add the comment") { db in
            _ = try WorkbenchQueries.addOwnerComment(db, projectID: pid, targetID: Int64(id), body: text)
        }
    }

    /// - Returns: whether the reply was written, so the thread keeps the
    ///   owner's draft on a failure (`errorMessage` says why).
    @discardableResult
    func reply(to rootID: Int64, body: String) -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return write("reply") { db in _ = try WorkbenchQueries.reply(db, to: rootID, body: text) }
    }

    func setThreadStatus(rootID: Int64, status: String) {
        write("update the thread") { db in try WorkbenchQueries.setStatus(db, commentID: rootID, status: status) }
    }

    /// Every owner write goes through here: the write, then the hook, then a
    /// reload. The hook fires only after the write succeeded — for the target
    /// the write touched (`target`, the selected one unless the caller names
    /// another, e.g. a kanban drop) and for every target `alsoTouched` names.
    @discardableResult
    private func write(
        _ what: String,
        target: Int? = nil,
        alsoTouched: () -> [Int64] = { [] },
        _ body: (Database) throws -> Void
    ) -> Bool {
        let touched = target ?? selectedTargetID
        do {
            try dbPool.write { db in try body(db) }
            errorMessage = nil
            if let id = touched {
                onOwnerWrite?(projectID, .target(Int64(id)))
            }
            for id in alsoTouched() {
                onOwnerWrite?(projectID, .target(id))
            }
            load()
            return true
        } catch {
            errorMessage = "Could not \(what): \(error.localizedDescription)"
            // Drop a card deleted elsewhere now rather than on the next poll
            // (this `load()` keeps `errorMessage`); from this board a
            // `wrongWorkbench` means a row that is gone.
            if error is TargetNotFoundError || (error as? WorkbenchQueryError) == .wrongWorkbench { load() }
            return false
        }
    }
}

import Foundation
import GRDB
import WatchtowerCore

@MainActor
@Observable
final class TargetsViewModel {
    var todayTargets: [Target] = []
    var allTargets: [Target] = []
    var activeCount: Int = 0
    var overdueCount: Int = 0
    var isLoading = false
    var errorMessage: String?

    // Filters
    var levelFilter: String?
    var statusFilter: String?
    var priorityFilter: String?
    var ownershipFilter: String?
    var tagFilter: String?
    var showDone: Bool = false
    var searchText: String = ""

    /// Distinct tags across all targets, refreshed on every load — feeds the
    /// Label filter menu.
    var availableTags: [String] = []

    private let dbManager: DatabaseManager
    private(set) var observationTask: Task<Void, Never>?
    /// Optional injected runner for tests; production uses ProcessCLIRunner.makeDefault().
    private let cliRunner: CLIRunnerProtocol?

    init(
        dbManager: DatabaseManager,
        cliRunner: CLIRunnerProtocol? = nil
    ) {
        self.dbManager = dbManager
        self.cliRunner = cliRunner
    }

    func startObserving() {
        guard observationTask == nil else { return }
        load()
        let dbPool = dbManager.dbPool
        observationTask = Task { [weak self] in
            // Track (row count, latest update), not just the count: same-row
            // updates — e.g. a brief run's ad-hoc VM applying
            // update_title/priority/due — must refresh this shared VM too,
            // not only inserts/deletes.
            let observation = ValueObservation.tracking { db -> String in
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM targets") ?? 0
                let latest = try String.fetchOne(db, sql: "SELECT MAX(updated_at) FROM targets") ?? ""
                return "\(count)|\(latest)"
            }
            do {
                for try await _ in observation.values(in: dbPool).dropFirst() {
                    // A released VM ends the loop, so its observer leaves the pool
                    // at the next change even if no view called stopObserving().
                    guard !Task.isCancelled, let self else { break }
                    self.load()
                }
            } catch {}
        }
    }

    /// Cancels the GRDB observation; the view calls it from onDisappear.
    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    func load() {
        isLoading = true
        do {
            let result = try dbManager.dbPool.read { db in
                let counts = try TargetQueries.fetchCounts(db)
                var filter = TargetFilter()
                filter.level = self.levelFilter
                filter.status = self.statusFilter
                filter.priority = self.priorityFilter
                filter.ownership = self.ownershipFilter
                filter.tag = self.tagFilter
                filter.includeDone = self.showDone
                if !self.searchText.isEmpty {
                    filter.search = self.searchText
                }
                let all = try TargetQueries.fetchAll(db, filter: filter)
                let tags = try TargetQueries.fetchDistinctTags(db)
                return (all, counts, tags)
            }

            let targets = result.0
            activeCount = result.1.active
            overdueCount = result.1.overdue
            availableTags = result.2

            // Today: overdue + due today + high priority active
            todayTargets = targets.filter { target in
                target.isActive && (target.isOverdue || target.isDueToday || target.priority == "high")
            }

            // All: everything else
            let todayIDs = Set(todayTargets.map(\.id))
            allTargets = targets.filter { !todayIDs.contains($0.id) }

            errorMessage = nil
        } catch {
            todayTargets = []
            allTargets = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// A write to a target deleted elsewhere (the agent over MCP, the CLI)
    /// reloads first: this VM's `ValueObservation` never sees another
    /// process's delete, so without it the vanished row would stay on screen
    /// and fail the same way on every retry. The message is set after the
    /// reload, which clears `errorMessage` on success.
    private func reportWriteFailure(_ what: String, _ error: Error) {
        if error is TargetNotFoundError || error is TargetSubItemsChangedError || error is TargetNotesChangedError {
            load()
        }
        errorMessage = "Failed to \(what): \(error.localizedDescription)"
    }

    // MARK: - Writes (board #670)
    //
    // Every write awaits the writer in this view model's one chain
    // (`SerialWrites`), so two edits land in the order they were made and a
    // busy database never freezes the UI. The list reloads only once a write
    // landed; a failed one leaves everything as it was and says why in
    // `errorMessage`. Each mutator returns whether it wrote (nil on failure
    // for those that return a value), which the action executor and the
    // composers use. The duplicate-press guard is the view's
    // (`pendingWrites`, keyed by `subItemsKey`/`notesKey`/…): the executor's
    // writes never wait behind it.

    @ObservationIgnored private let writes = SerialWrites()
    /// The views' one-pending-write-per-control guard.
    let pendingWrites = PendingWrites()

    /// The `pendingWrites` key of a target's checklist (add, edit, check,
    /// remove, move, due date).
    static func subItemsKey(_ id: Int) -> String { "subItems:\(id)" }
    /// The key of a target's notes (add, remove).
    static func notesKey(_ id: Int) -> String { "notes:\(id)" }
    /// The key of a target's labels (add, remove).
    static func tagsKey(_ id: Int) -> String { "tags:\(id)" }
    /// The key of a target's delete.
    static func deleteKey(_ id: Int) -> String { "delete:\(id)" }

    /// One write in the chain: reloads on success, reports on failure.
    /// - Returns: the body's value, nil when the write failed.
    @discardableResult
    private func perform<T: Sendable>(
        _ what: String,
        _ body: @escaping @Sendable (Database) throws -> T
    ) async -> T? {
        do {
            let pool = dbManager.dbPool
            let value = try await writes.runThrowing { try await pool.write(body) }
            load()
            return value
        } catch {
            reportWriteFailure(what, error)
            return nil
        }
    }

    @discardableResult
    func markDone(_ target: Target) async -> Bool {
        await updateStatus(target, to: "done")
    }

    @discardableResult
    func dismiss(_ target: Target) async -> Bool {
        await updateStatus(target, to: "dismissed")
    }

    @discardableResult
    func snooze(_ target: Target, until: Date) async -> Bool {
        let id = target.id
        return await perform("snooze") { db in try TargetQueries.snooze(db, id: id, until: until) } != nil
    }

    /// Checks or unchecks the sub-item at `index` as the owner saw it: it
    /// becomes the opposite of its shown state.
    @discardableResult
    func toggleSubItem(_ target: Target, index: Int) async -> Bool {
        let shown = target.decodedSubItems
        guard index >= 0, index < shown.count else { return false }
        let done = !shown[index].done
        return await mutateSubItems(target, shown: shown[index], at: index) { items in items[index].done = done }
    }

    @discardableResult
    func updateText(_ target: Target, to text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let id = target.id
        return await perform("update text") { db in try TargetQueries.updateText(db, id: id, text: trimmed) } != nil
    }

    @discardableResult
    func updateIntent(_ target: Target, to intent: String) async -> Bool {
        let id = target.id
        let trimmed = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        return await perform("update intent") { db in
            try TargetQueries.updateIntent(db, id: id, intent: trimmed)
        } != nil
    }

    @discardableResult
    func updateDueDate(_ target: Target, to dueDate: String) async -> Bool {
        let id = target.id
        return await perform("update due date") { db in
            try TargetQueries.updateDueDate(db, id: id, dueDate: dueDate)
        } != nil
    }

    @discardableResult
    func updateOwnership(_ target: Target, to ownership: String) async -> Bool {
        let id = target.id
        return await perform("update ownership") { db in
            try TargetQueries.updateOwnership(db, id: id, ownership: ownership)
        } != nil
    }

    @discardableResult
    func updateBlocking(_ target: Target, to blocking: String) async -> Bool {
        let id = target.id
        let trimmed = blocking.trimmingCharacters(in: .whitespacesAndNewlines)
        return await perform("update blocking") { db in
            try TargetQueries.updateBlocking(db, id: id, blocking: trimmed)
        } != nil
    }

    @discardableResult
    func updateBallOn(_ target: Target, to ballOn: String) async -> Bool {
        let id = target.id
        let trimmed = ballOn.trimmingCharacters(in: .whitespacesAndNewlines)
        return await perform("update ball on") { db in
            try TargetQueries.updateBallOn(db, id: id, ballOn: trimmed)
        } != nil
    }

    /// - Returns: whether the sub-item was written, so the composer keeps
    ///   the owner's draft on a failure (`errorMessage` says why).
    @discardableResult
    func addSubItem(_ target: Target, text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await mutateSubItems(target) { items in items.append(TargetSubItem(text: trimmed, done: false)) }
    }

    @discardableResult
    func removeSubItem(_ target: Target, index: Int) async -> Bool {
        let shown = target.decodedSubItems
        guard index >= 0, index < shown.count else { return false }
        return await mutateSubItems(target, shown: shown[index], at: index) { items in items.remove(at: index) }
    }

    @discardableResult
    func editSubItem(_ target: Target, index: Int, newText: String) async -> Bool {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let shown = target.decodedSubItems
        guard index >= 0, index < shown.count else { return false }
        return await mutateSubItems(target, shown: shown[index], at: index) { items in items[index].text = trimmed }
    }

    @discardableResult
    func moveSubItem(_ target: Target, from source: IndexSet, to destination: Int) async -> Bool {
        let shown = target.decodedSubItems
        // `move(fromOffsets:toOffset:)` traps out of range, and a drag can outlive
        // the list it started in (a CLI write, another window, a Remove).
        guard let lowest = source.min(), let highest = source.max(),
              lowest >= 0, highest < shown.count,
              destination >= 0, destination <= shown.count else { return false }
        let texts = shown.map(\.text)
        let id = target.id
        return await perform("update sub-items") { db -> Void in
            var items = try Self.freshSubItems(db, id: id)
            // A reorder is of the list as shown: one changed since (another
            // window, the agent) is refused rather than shuffled.
            guard items.map(\.text) == texts else { throw TargetSubItemsChangedError() }
            items.move(fromOffsets: source, toOffset: destination)
            try TargetQueries.updateSubItems(db, id: id, subItems: items)
        } != nil
    }

    @discardableResult
    func replaceSubItems(_ target: Target, items: [TargetSubItem]) async -> Bool {
        let id = target.id
        return await perform("update sub-items") { db -> Void in
            try TargetQueries.updateSubItems(db, id: id, subItems: items)
        } != nil
    }

    @discardableResult
    func updateSubItemDueDate(_ target: Target, index: Int, dueDate: String?) async -> Bool {
        let shown = target.decodedSubItems
        guard index >= 0, index < shown.count else { return false }
        return await mutateSubItems(target, shown: shown[index], at: index) { items in items[index].dueDate = dueDate }
    }

    /// A read-modify-write of the checklist: the list is read back inside
    /// the write's transaction, so a change made meanwhile (an earlier write
    /// in the chain, the agent, another window) is kept. An edit of one item
    /// (`shown`, at `index` when the owner acted) is refused when that slot
    /// now holds another item, so it never lands on the wrong one.
    private func mutateSubItems(
        _ target: Target,
        shown: TargetSubItem? = nil,
        at index: Int = 0,
        _ change: @escaping @Sendable (inout [TargetSubItem]) -> Void
    ) async -> Bool {
        let id = target.id
        let shownText = shown?.text
        return await perform("update sub-items") { db -> Void in
            var items = try Self.freshSubItems(db, id: id)
            if let shownText {
                guard index < items.count, items[index].text == shownText else { throw TargetSubItemsChangedError() }
            }
            change(&items)
            try TargetQueries.updateSubItems(db, id: id, subItems: items)
        } != nil
    }

    nonisolated private static func freshSubItems(_ db: Database, id: Int) throws -> [TargetSubItem] {
        guard let fresh = try TargetQueries.fetchByID(db, id: id) else { throw TargetNotFoundError(id: id) }
        return fresh.decodedSubItems
    }

    // MARK: - Notes

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    /// - Returns: whether the note was written, so the composer keeps the
    ///   owner's draft on a failure (`errorMessage` says why).
    @discardableResult
    func addNote(_ target: Target, text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let note = TargetNote(text: trimmed, createdAt: Self.iso8601Formatter.string(from: Date()))
        return await mutateNotes(target) { notes in notes.append(note) }
    }

    @discardableResult
    func removeNote(_ target: Target, index: Int) async -> Bool {
        let shown = target.decodedNotes
        guard index >= 0, index < shown.count else { return false }
        let (text, createdAt) = (shown[index].text, shown[index].createdAt)
        return await mutateNotes(target) { notes in
            // Refused when the slot now holds another note (see mutateSubItems).
            guard index < notes.count, notes[index].text == text, notes[index].createdAt == createdAt else {
                throw TargetNotesChangedError()
            }
            notes.remove(at: index)
        }
    }

    /// The notes are read back inside the write's transaction, like the
    /// checklist (`mutateSubItems`).
    private func mutateNotes(
        _ target: Target,
        _ change: @escaping @Sendable (inout [TargetNote]) throws -> Void
    ) async -> Bool {
        let id = target.id
        return await perform("update notes") { db -> Void in
            guard let fresh = try TargetQueries.fetchByID(db, id: id) else { throw TargetNotFoundError(id: id) }
            var notes = fresh.decodedNotes
            try change(&notes)
            try TargetQueries.updateNotes(db, id: id, notes: notes)
        } != nil
    }

    @discardableResult
    func updatePriority(_ target: Target, to priority: String) async -> Bool {
        let id = target.id
        return await perform("update priority") { db in
            try TargetQueries.updatePriority(db, id: id, priority: priority)
        } != nil
    }

    /// Returns whether the label set actually changed (false on the
    /// idempotent no-op cases), nil when the write failed (`errorMessage`
    /// says why; the action executor reports it).
    @discardableResult
    func addTag(_ target: Target, tag: String) async -> Bool? {
        let id = target.id
        return await perform("add label") { db in try TargetQueries.addTag(db, id: id, tag: tag) }
    }

    @discardableResult
    func removeTag(_ target: Target, tag: String) async -> Bool? {
        let id = target.id
        return await perform("remove label") { db in try TargetQueries.removeTag(db, id: id, tag: tag) }
    }

    @discardableResult
    func updateLevel(_ target: Target, to level: String) async -> Bool {
        // Expand the period to the new level's natural window, anchored on the
        // target's existing period_start so its "when" is preserved (nil for
        // custom/unknown levels → period left untouched).
        let window = Target.periodWindow(for: level, anchoredOn: target.periodStart)
        let id = target.id
        return await perform("update level") { db in
            try TargetQueries.updateLevel(
                db,
                id: id,
                level: level,
                periodStart: window?.start,
                periodEnd: window?.end
            )
        } != nil
    }

    @discardableResult
    func updateStatus(_ target: Target, to status: String) async -> Bool {
        let id = target.id
        return await perform("update status") { db in
            try TargetQueries.updateStatus(db, id: id, status: status)
        } != nil
    }

    @discardableResult
    func updateProgress(_ target: Target, to progress: Double) async -> Bool {
        let id = target.id
        return await perform("update progress") { db in
            try TargetQueries.updateProgress(db, id: id, progress: progress)
        } != nil
    }

    /// Create a child target under `parent`, inheriting its planning period and
    /// level. Used by the task AI agent. Returns the new id, or nil on failure.
    @discardableResult
    func createChild(_ parent: Target, text: String, intent: String, priority: String) async -> Int? {
        let (level, start, end, parentID) = (parent.level, parent.periodStart, parent.periodEnd, parent.id)
        return await perform("create child target") { db in
            try TargetQueries.create(
                db,
                text: text,
                intent: intent,
                level: level,
                periodStart: start,
                periodEnd: end,
                parentId: parentID,
                priority: priority,
                sourceType: "chat",
                sourceID: "target:\(parentID)"
            )
        }
    }

    /// Create a typed link (contributes_to/blocks/related/duplicates) from one
    /// existing target to another. Used by the task AI agent.
    @discardableResult
    func createLink(from sourceID: Int, to targetID: Int, relation: String) async -> Bool {
        await perform("link target") { db in
            try TargetQueries.createLink(db, sourceID: sourceID, targetID: targetID, relation: relation)
        } != nil
    }

    @discardableResult
    func deleteTarget(_ target: Target) async -> Bool {
        let id = target.id
        return await perform("delete") { db in try TargetQueries.delete(db, id: id) } != nil
    }

    func fetchJiraIssue(key: String) -> JiraIssue? {
        guard !key.isEmpty else { return nil }
        return try? dbManager.dbPool.read { db in
            try JiraQueries.fetchIssueByKey(db, key: key)
        }
    }

    func itemByID(_ id: Int) -> Target? {
        do {
            return try dbManager.dbPool.read { db in
                try TargetQueries.fetchByID(db, id: id)
            }
        } catch {
            return nil
        }
    }

    /// Throwing variant of `itemByID` for callers that must tell "no such
    /// row" apart from a failed read (the executor's link validation).
    func fetchByID(_ id: Int) throws -> Target? {
        try dbManager.dbPool.read { db in
            try TargetQueries.fetchByID(db, id: id)
        }
    }

    func fetchLinks(for targetID: Int) -> [TargetLink] {
        do {
            return try dbManager.dbPool.read { db in
                try TargetQueries.fetchLinks(db, targetID: targetID, direction: .both)
            }
        } catch {
            return []
        }
    }

    func submitFeedback(targetID: Int, rating: Int) async {
        let pool = dbManager.dbPool
        do {
            try await writes.runThrowing {
                try await pool.write { db in
                    try FeedbackQueries.addFeedback(
                        db,
                        entityType: "target",
                        entityID: "\(targetID)",
                        rating: rating,
                        comment: ""
                    )
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Promote sub-item to child target

    /// Resolves a CLIRunner via the injected `cliRunner` or, in production, by
    /// locating the bundled `watchtower` binary via `ProcessCLIRunner.makeDefault()`.
    private func resolveCLIRunner() throws -> CLIRunnerProtocol {
        if let runner = cliRunner {
            return runner
        }
        if let runner = ProcessCLIRunner.makeDefault() {
            return runner
        }
        throw PromoteSubItemError.cliNotFound
    }

    /// Converts the sub-item at `index` of `target` into a standalone child
    /// target with `parent_id = target.id`. Returns the new child's ID.
    ///
    /// On failure: throws to the caller — the caller decides how to surface
    /// the error (sheet typically displays it inline). `errorMessage` is *not*
    /// also set here, to avoid double-channel signaling that would surface the
    /// same error twice (banner + sheet alert).
    @discardableResult
    func promoteSubItem(
        _ target: Target,
        index: Int,
        overrides: PromoteSubItemOverrides = PromoteSubItemOverrides()
    ) async throws -> Int {
        let runner = try resolveCLIRunner()
        let svc = TargetPromoteSubItemService(runner: runner)
        let result = try await svc.promote(
            parentID: target.id,
            index: index,
            overrides: overrides
        )
        // CLI subprocess writes through its own SQLite connection, so GRDB's
        // in-process ValueObservation never sees the change. Refresh manually
        // so the parent's stripped sub_items and the new child show up.
        load()
        return result.id
    }

    /// Batch-promote sub-items of a freshly created parent. Iterates in
    /// descending `index` order so removals from `sub_items` on the Go side
    /// do not invalidate the indices that still need to be promoted.
    func promoteSubItemsAfterCreate(
        parentID: Int,
        items: [(index: Int, overrides: PromoteSubItemOverrides)]
    ) async throws {
        guard !items.isEmpty else { return }
        let runner = try resolveCLIRunner()
        let svc = TargetPromoteSubItemService(runner: runner)
        let sorted = items.sorted { $0.index > $1.index }
        for item in sorted {
            _ = try await svc.promote(
                parentID: parentID,
                index: item.index,
                overrides: item.overrides
            )
        }
        // Same rationale as promoteSubItem: cross-process CLI writes bypass our
        // in-process ValueObservation, so refresh after the batch finishes.
        load()
    }
}

/// A checklist edit whose item moved or changed since the owner saw it, or a
/// reorder of a list that changed: nothing is written and the list reloads.
struct TargetSubItemsChangedError: LocalizedError {
    var errorDescription: String? { "the checklist changed meanwhile — try again" }
}

/// As `TargetSubItemsChangedError`, for a note's removal.
struct TargetNotesChangedError: LocalizedError {
    var errorDescription: String? { "the notes changed meanwhile — try again" }
}

/// Errors emitted by promote-related ViewModel methods.
enum PromoteSubItemError: LocalizedError {
    case cliNotFound

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "watchtower CLI not found"
        }
    }
}

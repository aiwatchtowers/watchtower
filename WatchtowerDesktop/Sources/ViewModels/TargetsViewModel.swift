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
    private var observationTask: Task<Void, Never>?
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
                    guard !Task.isCancelled else { break }
                    self?.load()
                }
            } catch {}
        }
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
        if error is TargetNotFoundError { load() }
        errorMessage = "Failed to \(what): \(error.localizedDescription)"
    }

    func markDone(_ target: Target) {
        updateStatus(target, to: "done")
    }

    func dismiss(_ target: Target) {
        updateStatus(target, to: "dismissed")
    }

    func snooze(_ target: Target, until: Date) {
        do {
            try dbManager.dbPool.write { db in
                try TargetQueries.snooze(db, id: target.id, until: until)
            }
            load()
        } catch {
            reportWriteFailure("snooze", error)
        }
    }

    func toggleSubItem(_ target: Target, index: Int) {
        var items = target.decodedSubItems
        guard index >= 0, index < items.count else { return }
        items[index].done.toggle()
        do {
            try dbManager.dbPool.write { db in
                try TargetQueries.updateSubItems(db, id: target.id, subItems: items)
            }
            load()
        } catch {
            reportWriteFailure("update sub-items", error)
        }
    }

    func updateText(_ target: Target, to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try dbManager.dbPool.write { db in
                try TargetQueries.updateText(db, id: target.id, text: trimmed)
            }
            load()
        } catch {
            reportWriteFailure("update text", error)
        }
    }

    func updateIntent(_ target: Target, to intent: String) {
        do {
            try dbManager.dbPool.write { db in
                try TargetQueries.updateIntent(
                    db, id: target.id,
                    intent: intent.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            load()
        } catch {
            reportWriteFailure("update intent", error)
        }
    }

    func updateDueDate(_ target: Target, to dueDate: String) {
        do {
            try dbManager.dbPool.write { db in
                try TargetQueries.updateDueDate(db, id: target.id, dueDate: dueDate)
            }
            load()
        } catch {
            reportWriteFailure("update due date", error)
        }
    }

    func updateOwnership(_ target: Target, to ownership: String) {
        do {
            try dbManager.dbPool.write { db in
                try TargetQueries.updateOwnership(db, id: target.id, ownership: ownership)
            }
            load()
        } catch {
            reportWriteFailure("update ownership", error)
        }
    }

    func updateBlocking(_ target: Target, to blocking: String) {
        do {
            try dbManager.dbPool.write { db in
                try TargetQueries.updateBlocking(
                    db, id: target.id, blocking: blocking.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            load()
        } catch {
            reportWriteFailure("update blocking", error)
        }
    }

    func updateBallOn(_ target: Target, to ballOn: String) {
        do {
            try dbManager.dbPool.write { db in
                try TargetQueries.updateBallOn(
                    db, id: target.id, ballOn: ballOn.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            load()
        } catch {
            reportWriteFailure("update ball on", error)
        }
    }

    /// - Returns: whether the sub-item was written, so the composer keeps
    ///   the owner's draft on a failure (`errorMessage` says why).
    @discardableResult
    func addSubItem(_ target: Target, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var items = target.decodedSubItems
        items.append(TargetSubItem(text: trimmed, done: false))
        return saveSubItems(target, items: items)
    }

    func removeSubItem(_ target: Target, index: Int) {
        var items = target.decodedSubItems
        guard index >= 0, index < items.count else { return }
        items.remove(at: index)
        saveSubItems(target, items: items)
    }

    func editSubItem(_ target: Target, index: Int, newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var items = target.decodedSubItems
        guard index >= 0, index < items.count else { return }
        items[index].text = trimmed
        saveSubItems(target, items: items)
    }

    func moveSubItem(_ target: Target, from source: IndexSet, to destination: Int) {
        var items = target.decodedSubItems
        // `move(fromOffsets:toOffset:)` traps out of range, and a drag can outlive
        // the list it started in (a CLI write, another window, a Remove).
        guard let lowest = source.min(), let highest = source.max(),
              lowest >= 0, highest < items.count,
              destination >= 0, destination <= items.count else { return }
        items.move(fromOffsets: source, toOffset: destination)
        saveSubItems(target, items: items)
    }

    @discardableResult
    private func saveSubItems(_ target: Target, items: [TargetSubItem]) -> Bool {
        do {
            try dbManager.dbPool.write { db in
                try TargetQueries.updateSubItems(db, id: target.id, subItems: items)
            }
            load()
            return true
        } catch {
            reportWriteFailure("update sub-items", error)
            return false
        }
    }

    func replaceSubItems(_ target: Target, items: [TargetSubItem]) {
        saveSubItems(target, items: items)
    }

    func updateSubItemDueDate(_ target: Target, index: Int, dueDate: String?) {
        var items = target.decodedSubItems
        guard index >= 0, index < items.count else { return }
        items[index].dueDate = dueDate
        saveSubItems(target, items: items)
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
    func addNote(_ target: Target, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var notes = target.decodedNotes
        let now = Self.iso8601Formatter.string(from: Date())
        notes.append(TargetNote(text: trimmed, createdAt: now))
        return saveNotes(target, notes: notes)
    }

    func removeNote(_ target: Target, index: Int) {
        var notes = target.decodedNotes
        guard index >= 0, index < notes.count else { return }
        notes.remove(at: index)
        saveNotes(target, notes: notes)
    }

    @discardableResult
    private func saveNotes(_ target: Target, notes: [TargetNote]) -> Bool {
        do {
            try dbManager.dbPool.write { db in
                try TargetQueries.updateNotes(db, id: target.id, notes: notes)
            }
            load()
            return true
        } catch {
            reportWriteFailure("update notes", error)
            return false
        }
    }

    func updatePriority(_ target: Target, to priority: String) {
        do {
            try dbManager.dbPool.write { db in
                try TargetQueries.updatePriority(db, id: target.id, priority: priority)
            }
            load()
        } catch {
            reportWriteFailure("update priority", error)
        }
    }

    /// Returns whether the label set actually changed (false on the idempotent
    /// no-op cases and on error — errors land in `errorMessage` per the house
    /// idiom, which the action executor consumes via checkWrite).
    @discardableResult
    func addTag(_ target: Target, tag: String) -> Bool {
        do {
            let changed = try dbManager.dbPool.write { db in
                try TargetQueries.addTag(db, id: target.id, tag: tag)
            }
            load()
            return changed
        } catch {
            reportWriteFailure("add label", error)
            return false
        }
    }

    @discardableResult
    func removeTag(_ target: Target, tag: String) -> Bool {
        do {
            let changed = try dbManager.dbPool.write { db in
                try TargetQueries.removeTag(db, id: target.id, tag: tag)
            }
            load()
            return changed
        } catch {
            reportWriteFailure("remove label", error)
            return false
        }
    }

    func updateLevel(_ target: Target, to level: String) {
        // Expand the period to the new level's natural window, anchored on the
        // target's existing period_start so its "when" is preserved (nil for
        // custom/unknown levels → period left untouched).
        let window = Target.periodWindow(for: level, anchoredOn: target.periodStart)
        do {
            try dbManager.dbPool.write { db in
                try TargetQueries.updateLevel(
                    db,
                    id: target.id,
                    level: level,
                    periodStart: window?.start,
                    periodEnd: window?.end
                )
            }
            load()
        } catch {
            reportWriteFailure("update level", error)
        }
    }

    func updateStatus(_ target: Target, to status: String) {
        do {
            try dbManager.dbPool.write { db in
                try TargetQueries.updateStatus(db, id: target.id, status: status)
            }
            load()
        } catch {
            reportWriteFailure("update status", error)
        }
    }

    func updateProgress(_ target: Target, to progress: Double) {
        do {
            try dbManager.dbPool.write { db in
                try TargetQueries.updateProgress(db, id: target.id, progress: progress)
            }
            load()
        } catch {
            reportWriteFailure("update progress", error)
        }
    }

    /// Create a child target under `parent`, inheriting its planning period and
    /// level. Used by the task AI agent. Returns the new id, or nil on failure.
    @discardableResult
    func createChild(_ parent: Target, text: String, intent: String, priority: String) -> Int? {
        do {
            let newID = try dbManager.dbPool.write { db in
                try TargetQueries.create(
                    db,
                    text: text,
                    intent: intent,
                    level: parent.level,
                    periodStart: parent.periodStart,
                    periodEnd: parent.periodEnd,
                    parentId: parent.id,
                    priority: priority,
                    sourceType: "chat",
                    sourceID: "target:\(parent.id)"
                )
            }
            load()
            return newID
        } catch {
            reportWriteFailure("create child target", error)
            return nil
        }
    }

    /// Create a typed link (contributes_to/blocks/related/duplicates) from one
    /// existing target to another. Used by the task AI agent.
    func createLink(from sourceID: Int, to targetID: Int, relation: String) {
        do {
            try dbManager.dbPool.write { db in
                try TargetQueries.createLink(db, sourceID: sourceID, targetID: targetID, relation: relation)
            }
            load()
        } catch {
            reportWriteFailure("link target", error)
        }
    }

    @discardableResult
    func deleteTarget(_ target: Target) -> Bool {
        do {
            try dbManager.dbPool.write { db in
                try TargetQueries.delete(db, id: target.id)
            }
            load()
            return true
        } catch {
            reportWriteFailure("delete", error)
            return false
        }
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

    func submitFeedback(targetID: Int, rating: Int) {
        do {
            try dbManager.dbPool.write { db in
                try FeedbackQueries.addFeedback(
                    db,
                    entityType: "target",
                    entityID: "\(targetID)",
                    rating: rating,
                    comment: ""
                )
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

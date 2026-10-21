import Foundation
import GRDB
import Observation
import WatchtowerCore

// MARK: - DayPlanViewModel

@MainActor
@Observable
final class DayPlanViewModel {

    // MARK: - Published State

    var plan: DayPlan?
    var items: [DayPlanItem] = []
    var calendarEventsByID: [String: CalendarEvent] = [:]
    var isGenerating: Bool = false
    var generationError: String?
    var feedbackDraft: String = ""

    // MARK: - Dependencies

    private let dbPool: any DatabaseWriter
    private let cli: any CLIRunnerProtocol
    private var currentDate: String = ""

    // MARK: - Init

    init(databasePool: any DatabaseWriter, cliRunner: any CLIRunnerProtocol) {
        self.dbPool = databasePool
        self.cli = cliRunner
    }

    // MARK: - Load

    /// The date whose plan (or its absence) `plan`/`items` show; nil before
    /// the first load. One view model serves whichever day is on screen, so a
    /// view checks this before it shows the plan as its date's.
    private(set) var loadedDate: String?

    func loadFor(date: String) async {
        currentDate = date
        await reload()
    }

    /// Reads the plan, its items and their calendar events in one read and
    /// shows them together. A load of another date that started meanwhile
    /// wins: this one's result (or error) is dropped, so one date's items
    /// never show under another date's plan.
    private func reload() async {
        let date = currentDate
        do {
            let snapshot = try await dbPool.read { db -> (DayPlan?, [DayPlanItem], [String: CalendarEvent]) in
                guard let fetched = try DayPlanQueries.fetchByDate(db, date: date) else { return (nil, [], [:]) }
                let items = try DayPlanQueries.fetchItems(db, planId: fetched.id)
                return (fetched, items, try Self.calendarEvents(db, for: items))
            }
            guard date == currentDate else { return }
            (plan, items, calendarEventsByID) = snapshot
            loadedDate = date
        } catch {
            guard date == currentDate else { return }
            generationError = error.localizedDescription
        }
    }

    nonisolated private static func calendarEvents(_ db: Database, for items: [DayPlanItem]) throws -> [String: CalendarEvent] {
        var map: [String: CalendarEvent] = [:]
        for item in items where item.sourceType == .calendar {
            guard let sid = item.sourceId, !sid.isEmpty else { continue }
            if let event = try CalendarQueries.fetchEvent(db, id: sid) {
                map[sid] = event
            }
        }
        return map
    }

    // MARK: - Computed Views

    /// Timed timeblocks (excluding all-day calendar events) sorted by start time.
    var timeblocks: [DayPlanItem] {
        items.filter { $0.kind == .timeblock && !isAllDayCalendar($0) }
             .sorted { ($0.startTime ?? .distantFuture) < ($1.startTime ?? .distantFuture) }
    }

    /// All-day calendar timeblocks, shown in a collapsible chip above the timeline.
    var allDayItems: [DayPlanItem] {
        items.filter { $0.kind == .timeblock && isAllDayCalendar($0) }
             .sorted { ($0.startTime ?? .distantFuture) < ($1.startTime ?? .distantFuture) }
    }

    /// Backlog items sorted by order_index.
    var backlogItems: [DayPlanItem] {
        items.filter { $0.kind == .backlog }
             .sorted { $0.orderIndex < $1.orderIndex }
    }

    private func isAllDayCalendar(_ item: DayPlanItem) -> Bool {
        guard item.sourceType == .calendar, let sid = item.sourceId else { return false }
        return calendarEventsByID[sid]?.isAllDay ?? false
    }

    /// (done count, total count) across all items.
    var progress: (done: Int, total: Int) {
        (items.filter { $0.status == .done }.count, items.count)
    }

    var hasConflicts: Bool { plan?.hasConflicts ?? false }

    // MARK: - Item Actions

    func markDone(_ item: DayPlanItem) async {
        await setItemStatus(item, done: true)
    }

    func markPending(_ item: DayPlanItem) async {
        await setItemStatus(item, done: false)
    }

    /// Marks the item and cascades to its task. A task deleted elsewhere
    /// fails the cascade (and rolls the whole write back); the item itself is
    /// then marked alone, so it never gets stuck for the rest of the day, and
    /// the message says the task is gone. An item a regenerated plan replaced
    /// reloads the plan before its message shows.
    private func setItemStatus(_ item: DayPlanItem, done: Bool) async {
        let mark = done ? DayPlanQueries.markItemDone : DayPlanQueries.markItemPending
        let id = item.id
        do {
            do {
                let cascade = item.sourceType == .task
                try await dbPool.write { db in try mark(db, id, cascade) }
                await reload()
            } catch let gone as TargetNotFoundError {
                try await dbPool.write { db in try mark(db, id, false) }
                await reload()
                generationError = "Updated the plan item only: \(gone.localizedDescription)"
            }
        } catch {
            if error is RowNotFoundError { await reload() }
            generationError = error.localizedDescription
        }
    }

    func delete(_ item: DayPlanItem) async {
        guard !item.isReadOnly else { return }
        do {
            try await dbPool.write { db in
                try DayPlanQueries.deleteItem(db, itemId: item.id)
            }
            await reload()
        } catch {
            generationError = error.localizedDescription
        }
    }

    func reorderBacklog(_ orderedIds: [Int64]) async {
        guard let planId = plan?.id else { return }
        do {
            try await dbPool.write { db in
                try DayPlanQueries.reorderBacklog(db, planId: planId, orderedIds: orderedIds)
            }
            await reload()
        } catch {
            generationError = error.localizedDescription
        }
    }

    func addManual(kind: DayPlanItemKind, title: String, startTime: Date?, endTime: Date?) async {
        guard let planId = plan?.id else { return }
        do {
            _ = try await dbPool.write { db in
                try DayPlanQueries.addManualItem(
                    db,
                    planId: planId,
                    kind: kind,
                    title: title,
                    startTime: startTime,
                    endTime: endTime
                )
            }
            await reload()
        } catch {
            generationError = error.localizedDescription
        }
    }

    // MARK: - CLI Actions

    /// Calls `watchtower day-plan generate [--feedback <text>] --date <date>`.
    /// Updates `isGenerating` and reloads from DB on success.
    func regenerate(feedback: String?) async {
        isGenerating = true
        generationError = nil
        defer { isGenerating = false }

        var args = ["day-plan", "generate"]
        if let fb = feedback, !fb.isEmpty {
            args += ["--feedback", fb]
        }
        args += ["--date", currentDate]

        do {
            _ = try await cli.run(args: args)
            await reload()
        } catch {
            generationError = error.localizedDescription
        }
    }

    /// Calls `watchtower day-plan reset <date>` and reloads.
    func reset() async {
        isGenerating = true
        generationError = nil
        defer { isGenerating = false }

        do {
            _ = try await cli.run(args: ["day-plan", "reset", currentDate])
            await reload()
        } catch {
            generationError = error.localizedDescription
        }
    }

    /// Calls `watchtower day-plan check-conflicts <date>` and reloads.
    func checkConflicts() async {
        isGenerating = true
        generationError = nil
        defer { isGenerating = false }

        do {
            _ = try await cli.run(args: ["day-plan", "check-conflicts", currentDate])
            await reload()
        } catch {
            generationError = error.localizedDescription
        }
    }
}

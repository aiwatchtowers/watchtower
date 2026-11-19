import Foundation
import GRDB
import Observation
import WatchtowerCore
import WatchtowerInterface

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

    /// The presses through the tower and each item row's state.
    let presses: TowerPresses

    init(databasePool: any DatabaseWriter, cliRunner: any CLIRunnerProtocol, tower: (any TowerSending)? = nil) {
        self.dbPool = databasePool
        self.cli = cliRunner
        presses = TowerPresses(tower: tower)
        presses.reread = { [weak self] in await self?.reload() }
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

    /// The row key of plan item `id`'s presses.
    static func row(_ id: Int64) -> String { "plan:\(id)" }
    /// The row key of the plan's own presses (reorder, add).
    static let planRow = "plan"

    /// Marks the item and cascades to its task (`dayplan.done` /
    /// `dayplan.pending`, #1170 Task 12). A task deleted elsewhere leaves the
    /// item marked alone in the same write — Go answers why in `note`, so it
    /// never gets stuck for the rest of the day. An item a regenerated plan
    /// replaced is Go's `not_found`: the plan re-reads under its sentence.
    private func setItemStatus(_ item: DayPlanItem, done: Bool) async {
        let id = item.id
        let cascade = item.sourceType == .task
        let result: ActResult? = await press(done ? .dayplanDone : .dayplanPending, row: Self.row(id),
                                             label: TowerPressText.updating) {
            PlanItemStatusRequest(requestID: $0, itemID: id, cascade: cascade)
        }
        if let note = result?.note, !note.isEmpty { generationError = note }
    }

    func delete(_ item: DayPlanItem) async {
        guard !item.isReadOnly else { return }
        let id = item.id
        let _: ActResult? = await press(.dayplanDelete, row: Self.row(id), label: TowerPressText.deleting) {
            PlanItemRequest(requestID: $0, itemID: id)
        }
    }

    func reorderBacklog(_ orderedIds: [Int64]) async {
        guard let planId = plan?.id else { return }
        let variant = orderedIds.map(String.init).joined(separator: ",")
        let _: ActResult? = await press(.dayplanReorder, row: Self.planRow, label: TowerPressText.moving,
                                        variant: variant) {
            PlanReorderRequest(requestID: $0, planID: planId, orderedIDs: orderedIds)
        }
    }

    func addManual(kind: DayPlanItemKind, title: String, startTime: Date?, endTime: Date?) async {
        guard let planId = plan?.id else { return }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let start = startTime.map { fmt.string(from: $0) }
        let end = endTime.map { fmt.string(from: $0) }
        let variant = "\(kind.rawValue)|\(title)|\(start ?? "")|\(end ?? "")"
        let _: CreatedResult? = await press(.dayplanAdd, row: Self.planRow, label: TowerPressText.saving,
                                            variant: variant) {
            PlanAddRequest(requestID: $0, planID: planId, kind: kind.rawValue, title: title,
                           startTime: start, endTime: end)
        }
    }

    /// One press through the tower: an item's row keeps its state
    /// (`presses`); a press on the plan itself (reorder, add) says why it
    /// failed in `generationError`. The plan re-reads after every answer.
    private func press<Resp: Decodable & Sendable, Params: Encodable & Sendable>(
        _ command: TowerCommand,
        row: String,
        label: String,
        variant: String = "",
        _ params: @escaping (String) -> Params
    ) async -> Resp? {
        let result: Resp? = await presses.send(command, row: row, label: label, variant: variant, params: params)
        if result == nil, row == Self.planRow, case .refused(let sentence) = presses.state(row) {
            generationError = sentence
        }
        return result
    }

    // MARK: - CLI Actions

    /// Calls `watchtower day-plan generate [--feedback <text>] --date <date>`.
    /// Updates `isGenerating` and reloads from DB on success. `date` nil =
    /// the loaded date; another date (a run that outlived a day switch) is
    /// generated without reloading the shown one.
    func regenerate(feedback: String?, date: String? = nil) async {
        isGenerating = true
        generationError = nil
        defer { isGenerating = false }

        var args = ["day-plan", "generate"]
        if let fb = feedback, !fb.isEmpty {
            args += ["--feedback", fb]
        }
        let target = date ?? currentDate
        args += ["--date", target]

        do {
            _ = try await cli.runModel(args: args, origin: .owner)
            if target == currentDate { await reload() }
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

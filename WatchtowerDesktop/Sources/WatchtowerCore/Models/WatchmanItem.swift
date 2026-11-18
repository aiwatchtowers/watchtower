import Foundation
import GRDB

/// One wait point Watchman handled for the owner (`watchman_items`, 00198;
/// Go `db.WatchmanItem`). The journal reads it; only the feedback columns
/// are ever written from the Desktop (`WatchmanFeedbackQueries`). Times are RFC 3339
/// UTC, as Go writes them (`wmTime`).
package struct WatchmanItem: Identifiable, Equatable, Sendable, FetchableRecord {
    package var id: Int64
    package var workbenchID: Int64
    /// The workbench's name (`projects.name`); empty when the row is gone.
    package var workbenchName: String
    /// 0 = none.
    package var sessionID: Int64
    package var targetID: Int64
    /// `ask`, `review_doc`, `check`, `handover`, `permission`, `review_code`, `guard`.
    package var kind: String
    /// `queued`, `deciding`, `done`.
    package var state: String
    /// `''`, `answered`, `handed`, `parked`, `owner_first`, `approved`, `changes`.
    package var outcome: String
    package var question: String
    package var choice: String
    package var rationale: String
    package var precedentIDs: [Int64]
    package var confidence: String
    package var category: String
    package var unsure: Bool
    package var parkReason: String
    /// How the answer reached the session; `no_session` = it had ended.
    package var delivery: String
    package var costUSD: Double
    package var createdAt: Date
    package var decidedAt: Date?
    /// `''`, `ok`, `corrected`.
    package var feedback: String
    /// The owner's correction (`feedback = 'corrected'`).
    package var feedbackText: String
    package var checkDoneAt: Date?
    /// The owner marked a waiting (parked, handed) item done.
    package var ownerDoneAt: Date?
    /// The owner's correction reached a session (typed, or a new session).
    package var correctionSentAt: Date?

    package init(
        id: Int64,
        workbenchID: Int64 = 1,
        workbenchName: String = "",
        sessionID: Int64 = 0,
        targetID: Int64 = 0,
        kind: String = "ask",
        state: String = "done",
        outcome: String = "answered",
        question: String = "",
        choice: String = "",
        rationale: String = "",
        precedentIDs: [Int64] = [],
        confidence: String = "",
        category: String = "",
        unsure: Bool = true,
        parkReason: String = "",
        delivery: String = "",
        costUSD: Double = 0,
        createdAt: Date,
        decidedAt: Date? = nil,
        feedback: String = "",
        feedbackText: String = "",
        checkDoneAt: Date? = nil,
        ownerDoneAt: Date? = nil,
        correctionSentAt: Date? = nil
    ) {
        self.id = id
        self.workbenchID = workbenchID
        self.workbenchName = workbenchName
        self.sessionID = sessionID
        self.targetID = targetID
        self.kind = kind
        self.state = state
        self.outcome = outcome
        self.question = question
        self.choice = choice
        self.rationale = rationale
        self.precedentIDs = precedentIDs
        self.confidence = confidence
        self.category = category
        self.unsure = unsure
        self.parkReason = parkReason
        self.delivery = delivery
        self.costUSD = costUSD
        self.createdAt = createdAt
        self.decidedAt = decidedAt
        self.feedback = feedback
        self.feedbackText = feedbackText
        self.checkDoneAt = checkDoneAt
        self.ownerDoneAt = ownerDoneAt
        self.correctionSentAt = correctionSentAt
    }

    package init(row: Row) throws {
        id = row["id"]
        workbenchID = row["workbench_id"]
        workbenchName = row["workbench_name"] ?? ""
        sessionID = row["session_id"] ?? 0
        targetID = row["target_id"] ?? 0
        kind = row["kind"]
        state = row["state"]
        outcome = row["outcome"]
        question = row["question"]
        choice = row["choice"]
        rationale = row["rationale"]
        let precedents: String = row["precedent_ids"] ?? "[]"
        precedentIDs = Self.decodePrecedents(precedents)
        confidence = row["confidence"]
        category = row["category"]
        unsure = (row["unsure"] as Int64? ?? 1) != 0
        parkReason = row["park_reason"]
        delivery = row["delivery"]
        costUSD = row["cost_usd"]
        let created: String = row["created_at"]
        guard let createdAt = AutomationDates.parse(created) else {
            throw WatchmanItemError.badTime(column: "created_at", value: created)
        }
        self.createdAt = createdAt
        decidedAt = AutomationDates.parse(row["decided_at"])
        feedback = row["feedback"]
        feedbackText = row["feedback_text"] ?? ""
        checkDoneAt = AutomationDates.parse(row["check_done_at"])
        ownerDoneAt = AutomationDates.parse(row["owner_done_at"])
        correctionSentAt = AutomationDates.parse(row["correction_sent_at"])
    }

    /// Malformed `precedent_ids` JSON is logged once per launch (never its
    /// text) and reads as no precedents.
    nonisolated(unsafe) private static var loggedBadPrecedents = false
    private static let logLock = NSLock()

    private static func decodePrecedents(_ text: String) -> [Int64] {
        if text.isEmpty { return [] }
        if let ids = try? JSONDecoder().decode([Int64].self, from: Data(text.utf8)) { return ids }
        logLock.lock()
        defer { logLock.unlock() }
        if !loggedBadPrecedents {
            loggedBadPrecedents = true
            NSLog("WatchmanItem: a precedent_ids column is not a JSON id list; its precedents are not shown")
        }
        return []
    }

    /// Parked or handed back: the owner has to act.
    package var waitsForOwner: Bool {
        isWaitingKind && feedback.isEmpty && ownerDoneAt == nil
    }

    /// Parked or handed back, whether or not the owner has dealt with it.
    package var isWaitingKind: Bool {
        state == "done" && (outcome == "parked" || outcome == "handed")
    }

    /// The owner corrected it and the correction never reached a session.
    package var correctionUnsent: Bool {
        feedback == "corrected" && correctionSentAt == nil
    }

    /// A check Watchman passed on that nobody has run since.
    package var isCheckNobodyRan: Bool {
        kind == "check" && state == "done" && checkDoneAt == nil
    }
}

package enum WatchmanItemError: Error, Equatable {
    /// A time column Go always writes as RFC 3339 did not parse.
    case badTime(column: String, value: String)
}

/// One night of the journal: 12:00 local to 12:00 the next day (spec §10),
/// its items grouped by what the owner needs from them.
package struct WatchmanNight: Identifiable, Equatable, Sendable {
    /// The night's start, 12:00 local.
    package var date: Date
    /// Parked and handed items the owner has not acknowledged.
    package var waiting: [WatchmanItem]
    /// Checks Watchman passed on that nobody has run.
    package var checks: [WatchmanItem]
    /// Items the owner answered before the twin (`owner_first`): not decisions.
    package var ownerFirst: [WatchmanItem]
    /// The other finished items: the twin's decisions.
    package var decided: [WatchmanItem]
    /// Items still queued or being decided.
    package var pending: [WatchmanItem]
    /// The spans the Mac slept through during the night.
    package var gaps: [ClosedRange<Date>]
    /// What the night's decisions cost.
    package var costUSD: Double

    package var id: Date { date }

    package init(
        date: Date,
        waiting: [WatchmanItem] = [],
        checks: [WatchmanItem] = [],
        ownerFirst: [WatchmanItem] = [],
        decided: [WatchmanItem] = [],
        pending: [WatchmanItem] = [],
        gaps: [ClosedRange<Date>] = [],
        costUSD: Double = 0
    ) {
        self.date = date
        self.waiting = waiting
        self.checks = checks
        self.ownerFirst = ownerFirst
        self.decided = decided
        self.pending = pending
        self.gaps = gaps
        self.costUSD = costUSD
    }

    /// Every item of the night, in creation order.
    package var items: [WatchmanItem] {
        (waiting + checks + ownerFirst + decided + pending).sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// The night with only `workbench`'s items (nil = all); the gaps and
    /// the cost follow the items kept.
    package func scoped(to workbench: Int64?) -> Self {
        guard let workbench else { return self }
        func keep(_ items: [WatchmanItem]) -> [WatchmanItem] { items.filter { $0.workbenchID == workbench } }
        var night = self
        night.waiting = keep(waiting)
        night.checks = keep(checks)
        night.ownerFirst = keep(ownerFirst)
        night.decided = keep(decided)
        night.pending = keep(pending)
        night.costUSD = night.items.reduce(0) { $0 + $1.costUSD }
        return night
    }

    /// The start of the night `date` falls in: 12:00 of its day, or of the
    /// day before when it is earlier than noon.
    /// Built from calendar components, so a day with a DST change still
    /// starts and ends its night at 12:00 local.
    package static func start(of date: Date, calendar: Calendar) -> Date {
        let noon = noon(of: date, calendar: calendar)
        guard date < noon else { return noon }
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: date) ?? date
        return Self.noon(of: dayBefore, calendar: calendar)
    }

    /// The end of the night that starts at `start`: the next night's start.
    package static func end(of start: Date, calendar: Calendar) -> Date {
        let nextDay = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return noon(of: nextDay, calendar: calendar)
    }

    private static func noon(of date: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
    }
}

/// The counts the Home row and the Inbox entry show for one night.
package struct WatchmanNightCounts: Equatable, Sendable {
    package var start: Date
    package var decided: Int
    package var unsure: Int
    package var waiting: Int

    package init(start: Date, decided: Int, unsure: Int, waiting: Int) {
        self.start = start
        self.decided = decided
        self.unsure = unsure
        self.waiting = waiting
    }

    package init(_ night: WatchmanNight) {
        self.init(start: night.date, decided: night.decided.count, unsure: night.decided.filter(\.unsure).count,
                  waiting: night.waiting.count)
    }
}

/// What the Inbox's Watchman entry needs (`InboxFeedQueries.read`).
package struct WatchmanInboxSummary: Equatable, Sendable {
    /// The newest night with an item; nil before the first.
    package var latest: WatchmanNightCounts?
    /// Parked and handed items not acknowledged, every night.
    package var waiting: Int
    /// The newest item's time, else when Watchman was first turned on.
    package var updatedAt: Date

    package init(latest: WatchmanNightCounts?, waiting: Int, updatedAt: Date) {
        self.latest = latest
        self.waiting = waiting
        self.updatedAt = updatedAt
    }
}

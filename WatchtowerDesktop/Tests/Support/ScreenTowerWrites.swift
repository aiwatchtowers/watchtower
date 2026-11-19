import Foundation
import GRDB
import WatchtowerCore
import WatchtowerInterface

/// Go's screen writers (`internal/inboxfeed/screens.go` over
/// `internal/db/screen_writes.go`, `inbox_writes.go`,
/// `target_owner_writes.go` and inbox.act's own paths) as a test database
/// sees them: a `FakeScreenTower.applying(db)` answers every screen command
/// as Go would — its guards (`already`), its refusals (code and sentence)
/// and its rows — after making Go's write on `db`. A command it does not
/// model is refused loudly ("FakeScreenTower does not model …") and listed
/// in `unmodelled`, never answered ok. `ScreenTowerWritesFixtureTests`
/// replays the Go golden `internal/inboxfeed/testdata/screen_writes.json`
/// through it, so a drift from Go fails there.
extension FakeScreenTower {
    /// `now` is the tower's clock (Go's `c.Now()`), which stamps the
    /// automation tables; every other stamp is SQLite's `now`, as in Go.
    package static func applying(_ db: any DatabaseWriter, now: @escaping @Sendable () -> Date = { Date() }) -> FakeScreenTower {
        let tower = FakeScreenTower()
        tower.apply = { [weak tower] command, data in
            do {
                return try await ScreenTowerWrites(db: db, now: now()).apply(command, data)
            } catch let error as ScreenTowerWrites.Unmodelled {
                tower?.noteUnmodelled(error.command)
                throw Refused("FakeScreenTower does not model \(error.command.rawValue).", code: .unsupported)
            }
        }
        return tower
    }
}

/// One command's params, by Go's JSON names.
private struct Params: @unchecked Sendable {
    let raw: [String: Any]

    func int(_ key: String) -> Int64? { (raw[key] as? NSNumber)?.int64Value }
    func id(_ key: String = "id") -> Int64 { int(key) ?? 0 }
    func string(_ key: String) -> String? { raw[key] as? String }
    func text(_ key: String) -> String { string(key) ?? "" }
    func bool(_ key: String) -> Bool { (raw[key] as? NSNumber)?.boolValue ?? false }
    func ints(_ key: String) -> [Int64] { (raw[key] as? [NSNumber])?.map(\.int64Value) ?? [] }
}

struct ScreenTowerWrites {
    /// A command the fake does not answer.
    struct Unmodelled: Error {
        let command: TowerCommand
    }

    let db: any DatabaseWriter
    let now: Date

    private static let now = "strftime('%Y-%m-%dT%H:%M:%SZ','now')"
    private static let clearReview = "needs_review = 0, review_reason = ''"
    /// IdeaQueries.knowledgeVisibleSQL: a chat-born item not kept is no knowledge.
    private static let knowledgeVisible = "NOT (chat_born = 1 AND status IN ('proposed','not_now','rejected','dropped'))"

    /// Go's screen phrases (`screenPhrases`).
    private static let phrases: [TowerCommand: String] = [
        .outputsRead: "mark it read", .outputsDone: "mark it done", .outputsDismiss: "dismiss it",
        .remindersDone: "mark it done", .remindersSnooze: "snooze", .inboxItemsRead: "mark it read",
        .tracksDone: "mark it done", .tracksRestore: "restore it", .briefingRead: "mark it read",
        .tracksRead: "mark it read", .tracksStop: "stop watching", .tracksPriority: "change the priority",
        .tracksOwnership: "change the ownership", .tracksSubItems: "update the sub-item",
        .tracksEnabled: "update the watch", .tracksInstruction: "save the instruction", .tracksDelete: "delete it",
        .tracksEventStatus: "update the event", .tracksEventsRead: "mark it read",
        .ideasStatus: "update the idea", .ideasSnooze: "put it off", .ideasMerge: "merge it",
        .ideasSupersede: "supersede it", .ideasRating: "rate it", .ideasCreate: "save the idea",
        .ideasDelete: "delete it", .ideasConverted: "convert it", .ideasDecisionSeen: "mark it seen",
        .ideasDecisionsSeenAll: "mark them seen", .ideasCreateFromChat: "save it to knowledge",
        .ideasUndoChat: "undo it", .dayplanDone: "check it off", .dayplanPending: "uncheck it",
        .dayplanDelete: "delete it", .dayplanReorder: "reorder the plan", .dayplanAdd: "add it to the plan",
        .targetsSetStatus: "change the status", .targetsSetColumn: "move it", .targetsSnooze: "snooze it",
        .targetsWorkOn: "start it", .catchupAcknowledge: "mark it caught up", .digestsRead: "mark it read",
        .digestsStreamRead: "mark it read", .digestsDecisionRead: "mark it read",
        .digestsDecisionsReadAll: "mark them read"
    ]

    /// Go's `ErrRowNotFound` and the other refusals, worded as `screenFault`.
    private struct Refusal: Error {
        let code: RefusalCode
        let reason: String
        static let gone = Self(code: .notFound, reason: "it's no longer on the Mac.")
        static let changed = Self(code: .changed, reason: "this card changed — look again.")
        static let closed = Self(code: .changed, reason: "the item was already closed on the Mac.")
        static let unsupported = Self(code: .unsupported, reason: "this card doesn't offer that here.")
        static let notReady = Self(code: .changed, reason: "this recap isn't ready.")
        static let columnMismatch = Self(code: .unsupported, reason: "board column does not match the target.")
    }

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f
    }()

    private static let localDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func apply(_ command: TowerCommand, _ data: Data) async throws -> Data? {
        let p = Params(raw: (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
        do {
            return try await db.write { db in try JSONSerialization.data(withJSONObject: run(command, p, db)) }
        } catch let refusal as Refusal {
            let phrase = Self.phrases[command] ?? "do that"
            throw FakeScreenTower.Refused("Couldn't \(phrase): \(refusal.reason)", code: refusal.code)
        } catch let error as DatabaseError where (error.message ?? "").contains("board column does not match the target") {
            throw FakeScreenTower.Refused("Couldn't move it: \(Refusal.columnMismatch.reason)", code: .unsupported)
        }
    }

    private static let already: [String: Any] = ["already": true]

    /// `done(already, err)`.
    private static func act(_ already: Bool) -> [String: Any] {
        already ? Self.already : [:]
    }

    // One switch over the screens' commands, as `RegisterScreens`.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func run(_ command: TowerCommand, _ p: Params, _ db: Database) throws -> [String: Any] {
        switch command {
        case .outputsRead: return try stampOutput(db, p, column: "read_at", extra: " AND read_at IS NULL", verb: command)
        case .outputsDone: return try stampOutput(db, p, column: "done_at", extra: "", verb: command)
        case .outputsDismiss: return try stampOutput(db, p, column: "dismissed_at", extra: "", verb: command)
        case .remindersDone, .remindersSnooze: return try reminder(db, p, snooze: command == .remindersSnooze)
        case .briefingRead:
            let ids = p.ints("ids")
            guard !ids.isEmpty else { return Self.already }
            let unread = try Int64.fetchAll(db, sql: """
                SELECT id FROM briefings WHERE id IN (\(marks(ids.count))) AND read_at IS NULL ORDER BY id
                """, arguments: StatementArguments(ids))
            guard !unread.isEmpty else { return Self.already }
            try db.execute(sql: """
                UPDATE briefings SET read_at = \(Self.now) WHERE id IN (\(marks(unread.count))) AND read_at IS NULL
                """, arguments: StatementArguments(unread))
            return [:]
        case .inboxItemsRead:
            guard let row = try Row.fetchOne(db, sql: "SELECT read_at FROM inbox_items WHERE id = ?", arguments: [p.id()])
            else { throw Refusal.gone }
            if let readAt: String = row["read_at"], !readAt.isEmpty { return Self.already }
            try db.execute(sql: """
                UPDATE inbox_items SET read_at = \(Self.now) WHERE id = ? AND (read_at IS NULL OR read_at = '')
                """, arguments: [p.id()])
            return [:]
        // Tracks.
        case .tracksRead:
            for id in p.ints("ids") { try markTrackRead(db, id) }
            return [:]
        case .tracksDone, .tracksRestore:
            return try trackVerb(db, p.id(), verb: command)
        case .tracksStop:
            var all = true
            for id in p.ints("ids") {
                all = try trackVerb(db, id, verb: .tracksStop)["already"] as? Bool == true && all
            }
            return Self.act(all)
        case .tracksPriority:
            let priority = p.text("priority")
            try update(db, "UPDATE tracks SET priority = ? WHERE id = ?", [priority, p.id()])
            try db.execute(sql: "INSERT INTO feedback (entity_type, entity_id, rating, comment) VALUES ('track', ?, -1, ?)",
                           arguments: [String(p.id()), "priority corrected to \(priority)"])
            return [:]
        case .tracksOwnership:
            try update(db, "UPDATE tracks SET ownership = ? WHERE id = ?", [p.text("ownership"), p.id()])
            return [:]
        case .tracksSubItems: return try trackSubItem(db, p)
        case .tracksEnabled:
            try update(db, "UPDATE tracks SET enabled = ?, updated_at = \(Self.now) WHERE id = ?", [p.bool("enabled"), p.id()])
            return [:]
        case .tracksInstruction:
            try update(db, "UPDATE tracks SET instruction = ?, updated_at = \(Self.now) WHERE id = ? AND origin = 'custom'",
                       [p.text("instruction"), p.id()])
            return [:]
        case .tracksDelete:
            try db.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [p.id()])
            return Self.act(db.changesCount == 0)
        case .tracksEventStatus:
            guard let cur = try String.fetchOne(db, sql: "SELECT action_status FROM track_events WHERE id = ?",
                                                arguments: [p.id("event_id")]) else { throw Refusal.gone }
            if cur == p.text("status") { return Self.already }
            try db.execute(sql: "UPDATE track_events SET action_status = ? WHERE id = ?",
                           arguments: [p.text("status"), p.id("event_id")])
            return [:]
        case .tracksEventsRead:
            if let event = p.int("event_id"), event > 0 {
                try db.execute(sql: "UPDATE track_events SET read_at = \(Self.now) WHERE id = ? AND track_id = ?",
                               arguments: [event, p.id("track_id")])
            } else {
                try db.execute(sql: """
                    UPDATE track_events SET read_at = \(Self.now) WHERE track_id = ? AND (read_at IS NULL OR read_at = '')
                    """, arguments: [p.id("track_id")])
            }
            return [:]
        // Ideas and Decisions.
        case .ideasStatus, .ideasSnooze, .ideasMerge, .ideasSupersede, .ideasRating, .ideasCreate, .ideasDelete,
             .ideasConverted, .ideasDecisionSeen, .ideasDecisionsSeenAll, .ideasCreateFromChat, .ideasUndoChat:
            return try idea(command, p, db)
        // Day plan.
        case .dayplanDone, .dayplanPending, .dayplanDelete, .dayplanReorder, .dayplanAdd:
            return try plan(command, p, db)
        // Targets.
        case .targetsSetStatus:
            let rolled = try rolledUp(db, p.id()) {
                try requireTarget(db, p.id())
                try setTargetStatus(db, p.id(), p.text("status"), column: nil)
            }
            return ["rolled_up": rolled]
        case .targetsSetColumn:
            let rolled = try rolledUp(db, p.id()) {
                try requireTarget(db, p.id())
                let current = try String.fetchOne(db, sql: "SELECT status FROM targets WHERE id = ?", arguments: [p.id()])
                let column = p.int("column_id").map(DatabaseValue.init) ?? .null
                if current != p.text("status") {
                    try setTargetStatus(db, p.id(), p.text("status"), column: column)
                } else {
                    try db.execute(sql: "UPDATE targets SET board_column_id = ?, updated_at = \(Self.now) WHERE id = ?",
                                   arguments: [column, p.id()])
                }
            }
            return ["rolled_up": rolled]
        case .targetsSnooze:
            let rolled = try rolledUp(db, p.id()) {
                try update(db, """
                    UPDATE targets SET status = 'snoozed', snooze_until = ?, status_actor = 'owner', updated_at = \(Self.now)
                    WHERE id = ?
                    """, [p.text("until"), p.id()])
                try db.execute(sql: """
                    UPDATE targets SET progress = 0 WHERE id = ? AND
                    NOT EXISTS (SELECT 1 FROM targets c WHERE c.parent_id = targets.id AND c.status != 'dismissed')
                    """, arguments: [p.id()])
                if let parent = try Int64.fetchOne(db, sql: "SELECT parent_id FROM targets WHERE id = ?", arguments: [p.id()]) {
                    try recomputeParentProgress(db, parent)
                }
            }
            return ["rolled_up": rolled]
        case .targetsWorkOn:
            guard let row = try Row.fetchOne(db, sql: "SELECT status, project_id FROM targets WHERE id = ?", arguments: [p.id()]),
                  let project: Int64 = row["project_id"], row["status"] as String == "todo",
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM targets WHERE parent_id = ? AND project_id = ?)",
                                    arguments: [p.id(), project]) == false
            else { return ["moved": false, "rolled_up": [Int64]()] }
            let rolled = try rolledUp(db, p.id()) { try setTargetStatus(db, p.id(), "in_progress", column: nil) }
            return ["moved": true, "rolled_up": rolled]
        // Catch-Up and Digests.
        case .catchupAcknowledge:
            try acknowledge(db, p.id())
            return [:]
        case .digestsRead:
            for id in p.ints("ids") { try markDigestRead(db, id) }
            return [:]
        case .digestsStreamRead:
            guard let row = try Row.fetchOne(db, sql: "SELECT read_at FROM stream_digests WHERE id = ?", arguments: [p.id()])
            else { throw Refusal.gone }
            if (row["read_at"] as String?) != nil { return Self.already }
            try db.execute(sql: "UPDATE stream_digests SET read_at = \(Self.now) WHERE id = ? AND read_at IS NULL",
                           arguments: [p.id()])
            return [:]
        case .digestsDecisionRead:
            try db.execute(sql: "INSERT INTO decision_reads (digest_id, decision_idx) VALUES (?, ?) ON CONFLICT DO NOTHING",
                           arguments: [p.id("digest_id"), p.int("idx") ?? 0])
            return [:]
        case .digestsDecisionsReadAll:
            try markDecisionsRead(db, p.id("digest_id"))
            return [:]
        default:
            throw Unmodelled(command: command)
        }
    }

    // MARK: - inbox.act's paths

    private func stampOutput(_ db: Database, _ p: Params, column: String, extra: String, verb: TowerCommand) throws -> [String: Any] {
        let hash = p.text("content_hash")
        try db.execute(sql: """
            UPDATE automation_outputs SET \(column) = ?
            WHERE id = ? AND content_hash = ? AND done_at IS NULL AND dismissed_at IS NULL\(extra)
            """, arguments: [Self.iso.string(from: now), p.id(), hash])
        if db.changesCount > 0 { return [:] }
        guard let row = try Row.fetchOne(db, sql: """
            SELECT kind, content_hash, done_at IS NOT NULL AS done, dismissed_at IS NOT NULL AS dismissed
            FROM automation_outputs WHERE id = ?
            """, arguments: [p.id()]), row["kind"] as String == "inbox" else { throw Refusal.gone }
        guard row["content_hash"] as String == hash else { throw Refusal.changed }
        switch verb {
        case .outputsRead: return Self.already
        case .outputsDone where row["done"] as Bool: return Self.already
        case .outputsDismiss where row["dismissed"] as Bool: return Self.already
        default: throw Refusal.closed
        }
    }

    /// `refReminder`: Done once; Snooze to a time it is not at already.
    /// (The approval hook it fires runs in Go; no test database has one.)
    private func reminder(_ db: Database, _ p: Params, snooze: Bool) throws -> [String: Any] {
        let until = p.text("until")
        if snooze, until.isEmpty { throw Refusal.unsupported }
        guard let row = try Row.fetchOne(db, sql: "SELECT status, remind_at FROM reminders WHERE id = ?", arguments: [p.id()])
        else { throw Refusal.gone }
        if snooze {
            if row["status"] as String == "pending", row["remind_at"] as String == until { return Self.already }
            try update(db, "UPDATE reminders SET remind_at = ?, status = 'pending' WHERE id = ?", [until, p.id()])
            return [:]
        }
        try db.execute(sql: "UPDATE reminders SET status = 'done', done_at = \(Self.now) WHERE id = ? AND status != 'done'",
                       arguments: [p.id()])
        return Self.act(db.changesCount == 0)
    }

    /// `trackVerbTx`: Done, Stop or Restore, with a custom track's collection.
    private func trackVerb(_ db: Database, _ id: Int64, verb: TowerCommand) throws -> [String: Any] {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT dismissed_at, origin, COALESCE(read_at, '') != '' AS read, has_updates != 0 AS has_updates,
                EXISTS(SELECT 1 FROM track_events e WHERE e.track_id = tracks.id AND (e.read_at IS NULL OR e.read_at = ''))
                    AS unread_events,
                enabled != 0 AS enabled, automation_id
            FROM tracks WHERE id = ?
            """, arguments: [id]) else { throw Refusal.gone }
        let dismissed = !(row["dismissed_at"] as String).isEmpty
        let custom = row["origin"] as String == "custom"
        let enabled: Bool = row["enabled"]
        let automation: Int64? = row["automation_id"]
        switch verb {
        case .tracksDone:
            if row["read"] as Bool, !(row["has_updates"] as Bool), !(row["unread_events"] as Bool) { return Self.already }
            try markTrackRead(db, id)
            try db.execute(sql: """
                UPDATE track_events SET read_at = \(Self.now) WHERE track_id = ? AND (read_at IS NULL OR read_at = '')
                """, arguments: [id])
            return [:]
        case .tracksStop:
            if dismissed, !custom || !enabled { return Self.already }
            if custom { try setCollecting(db, id, automation, on: false) }
            if dismissed { return [:] }
            try update(db, "UPDATE tracks SET dismissed_at = \(Self.now) WHERE id = ?", [id])
            return [:]
        default:
            if !dismissed, !custom || enabled { return Self.already }
            if dismissed { try update(db, "UPDATE tracks SET dismissed_at = '' WHERE id = ?", [id]) }
            if custom { try setCollecting(db, id, automation, on: true) }
            return [:]
        }
    }

    private func setCollecting(_ db: Database, _ id: Int64, _ automation: Int64?, on: Bool) throws {
        guard let automation else {
            try update(db, "UPDATE tracks SET enabled = ?, updated_at = \(Self.now) WHERE id = ?", [on, id])
            return
        }
        let stamp = Self.iso.string(from: now)
        try update(db, """
            UPDATE automations SET
                last_scheduled_for = CASE WHEN ? AND enabled = 0 THEN ? ELSE last_scheduled_for END,
                enabled = ?, disabled_reason = '', disabled_at = NULL, updated_at = ?
            WHERE id = ?
            """, [on, stamp, on, stamp, automation])
    }

    // MARK: - tracks

    /// `MarkTrackReadTx` (TRACKS-04): the track read with its related digests.
    private func markTrackRead(_ db: Database, _ id: Int64) throws {
        try db.execute(sql: "UPDATE tracks SET read_at = \(Self.now), has_updates = 0 WHERE id = ?", arguments: [id])
        guard let related = try String.fetchOne(db, sql: "SELECT related_digest_ids FROM tracks WHERE id = ?", arguments: [id])
        else { return }
        for digest in (try? JSONDecoder().decode([Int64].self, from: Data(related.utf8))) ?? [] where digest > 0 {
            try markDigestRead(db, digest)
        }
    }

    private struct SubItem: Codable {
        var text: String
        var status: String
    }

    private func trackSubItem(_ db: Database, _ p: Params) throws -> [String: Any] {
        guard let raw = try String.fetchOne(db, sql: "SELECT sub_items FROM tracks WHERE id = ?", arguments: [p.id()])
        else { throw Refusal.gone }
        var items = (try? JSONDecoder().decode([SubItem].self, from: Data(raw.utf8))) ?? []
        let index = Int(p.int("index") ?? -1)
        let status = p.bool("done") ? "done" : "open"
        guard items.indices.contains(index), items[index].status != status else { return Self.already }
        items[index].status = status
        let encoded = String(bytes: try JSONEncoder().encode(items), encoding: .utf8) ?? "[]"
        try db.execute(sql: "UPDATE tracks SET sub_items = ? WHERE id = ?", arguments: [encoded, p.id()])
        return [:]
    }

    // MARK: - ideas

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func idea(_ command: TowerCommand, _ p: Params, _ db: Database) throws -> [String: Any] {
        let id = p.id()
        let state = { () throws -> Row in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT status, snooze_until, needs_review != 0 AS review, merged_into_id, superseded_by_id,
                    converted_target_id, title, essence
                FROM ideas WHERE id = ?
                """, arguments: [id]) else { throw Refusal.gone }
            return row
        }
        switch command {
        case .ideasStatus:
            let row = try state()
            if row["status"] as String == p.text("status"), !(row["review"] as Bool) { return Self.already }
            try update(db, "UPDATE ideas SET status = ?, \(Self.clearReview), updated_at = \(Self.now) WHERE id = ?",
                       [p.text("status"), id])
            return [:]
        case .ideasSnooze:
            let row = try state()
            let until = p.text("until")
            if row["status"] as String == "not_now", row["snooze_until"] as String == until, !(row["review"] as Bool) {
                return Self.already
            }
            try update(db, """
                UPDATE ideas SET status = 'not_now', snooze_until = ?, \(Self.clearReview), updated_at = \(Self.now) WHERE id = ?
                """, [until, id])
            return [:]
        case .ideasMerge:
            let row = try state()
            let into = p.id("into")
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM ideas WHERE id = ?)", arguments: [into]) == true
            else { throw Refusal.gone }
            if row["status"] as String == "merged", row["merged_into_id"] as Int64? == into, !(row["review"] as Bool) {
                return Self.already
            }
            try db.execute(sql: """
                UPDATE ideas SET status = 'merged', merged_into_id = ?, \(Self.clearReview), updated_at = \(Self.now) WHERE id = ?
                """, arguments: [into, id])
            try db.execute(sql: "UPDATE idea_mentions SET idea_id = ? WHERE idea_id = ?", arguments: [into, id])
            try db.execute(sql: "UPDATE ideas SET merged_into_id = ? WHERE merged_into_id = ?", arguments: [into, id])
            return [:]
        case .ideasSupersede:
            let row = try state()
            let by = p.int("by")
            if row["status"] as String == "superseded", row["superseded_by_id"] as Int64? == by, !(row["review"] as Bool) {
                return Self.already
            }
            try db.execute(sql: """
                UPDATE ideas SET status = 'superseded', superseded_by_id = ?, \(Self.clearReview), updated_at = \(Self.now)
                WHERE id = ?
                """, arguments: [by, id])
            return [:]
        case .ideasRating:
            try update(db, "UPDATE ideas SET owner_rating = ?, rating_comment = ?, updated_at = \(Self.now) WHERE id = ?",
                       [p.int("rating") ?? 0, p.text("comment"), id])
            return [:]
        case .ideasCreate:
            let at = Self.iso.string(from: now)
            try db.execute(sql: """
                INSERT INTO ideas (kind, title, essence, status, source, last_mention_at) VALUES (?, ?, ?, 'active', 'owner', ?)
                """, arguments: [p.text("kind"), p.text("title"), p.text("essence"), at])
            let created = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO idea_mentions (idea_id, source, quote, said_at) VALUES (?, 'owner', ?, ?)",
                           arguments: [created, p.text("essence"), at])
            return ["id": created]
        case .ideasDelete:
            return Self.act(try deleteIdea(db, id))
        case .ideasConverted:
            guard (try? Date(p.text("today"), strategy: .iso8601.year().month().day())) != nil else { throw Refusal.unsupported }
            let row = try state()
            if row["status"] as String == "converted", let target: Int64 = row["converted_target_id"],
               try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM targets WHERE id = ?)", arguments: [target]) == true {
                return ["target_id": target, "already": true]
            }
            try db.execute(sql: """
                INSERT INTO targets (text, intent, level, custom_label, period_start, period_end,
                    parent_id, status, priority, ownership, ball_on, due_date, snooze_until,
                    blocking, tags, sub_items, notes, progress, source_type, source_id, ai_level_confidence)
                VALUES (?, ?, 'day', '', ?, ?, NULL, 'todo', 'medium', 'mine', '', '', '', '', '[]', '[]', '[]', 0, 'idea', ?, NULL)
                """, arguments: [row["title"] as String, row["essence"] as String, p.text("today"), p.text("today"), String(id)])
            let target = db.lastInsertedRowID
            try db.execute(sql: """
                UPDATE ideas SET status = 'converted', converted_target_id = ?, \(Self.clearReview), updated_at = \(Self.now)
                WHERE id = ?
                """, arguments: [target, id])
            return ["target_id": target]
        case .ideasDecisionSeen:
            try db.execute(sql: "UPDATE ideas SET seen_at = \(Self.now), \(Self.clearReview) WHERE id = ?", arguments: [id])
            return [:]
        case .ideasDecisionsSeenAll:
            try db.execute(sql: """
                UPDATE ideas SET seen_at = \(Self.now), \(Self.clearReview)
                WHERE kind = 'decision' AND (seen_at IS NULL OR needs_review = 1) AND \(Self.knowledgeVisible)
                """)
            return [:]
        case .ideasCreateFromChat:
            let at = try String.fetchOne(db, sql: "SELECT \(Self.now)") ?? ""
            let body = p.text("body")
            let title = String(body.prefix { !$0.isNewline }.prefix(120))
            try db.execute(sql: """
                INSERT INTO ideas (kind, title, essence, status, source, last_mention_at, chat_born)
                VALUES (?, ?, ?, 'active', 'owner', ?, 1)
                """, arguments: [p.text("kind"), title, body, at])
            let created = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO idea_mentions (idea_id, source, ref, quote, said_at) VALUES (?, 'chat', ?, ?, ?)",
                           arguments: [created, "chat:\(p.id("conversation_id")):\(p.id("message_id"))", body, at])
            let stamp = try String.fetchOne(db, sql: "SELECT updated_at FROM ideas WHERE id = ?", arguments: [created])
            return ["id": created, "updated_at": stamp ?? ""]
        case .ideasUndoChat:
            let untouched = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM ideas
                    WHERE id = ? AND chat_born = 1 AND status = 'active' AND merged_into_id IS NULL AND updated_at = ?
                      AND NOT EXISTS (SELECT 1 FROM ideas c WHERE c.merged_into_id = ideas.id))
                """, arguments: [id, p.text("created_updated_at")]) ?? false
            if untouched { _ = try deleteIdea(db, id) }
            return ["undone": untouched]
        default:
            throw Unmodelled(command: command)
        }
    }

    /// `DeleteIdeaTx`: the idea and everything merged into it, their
    /// mentions and Discuss chats; links into them cleared. True: not there.
    private func deleteIdea(_ db: Database, _ id: Int64) throws -> Bool {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM ideas WHERE id = ?)", arguments: [id]) == true
        else { return true }
        let doomed = try Int64.fetchAll(db, sql: """
            WITH RECURSIVE doomed(id) AS (
                SELECT ? UNION SELECT ideas.id FROM ideas JOIN doomed ON ideas.merged_into_id = doomed.id)
            SELECT id FROM doomed
            """, arguments: [id])
        for one in doomed {
            if let chat = try Int64.fetchOne(db, sql: """
                SELECT id FROM chat_conversations WHERE context_type = 'idea' AND context_id = ? ORDER BY updated_at DESC LIMIT 1
                """, arguments: [String(one)]) {
                try db.execute(sql: "DELETE FROM chat_messages WHERE conversation_id = ?", arguments: [chat])
                try db.execute(sql: "DELETE FROM chat_conversations WHERE id = ?", arguments: [chat])
            }
            try db.execute(sql: "DELETE FROM idea_mentions WHERE idea_id = ?", arguments: [one])
            try db.execute(sql: "DELETE FROM ideas WHERE id = ?", arguments: [one])
        }
        for column in ["similar_to_id", "superseded_by_id"] {
            try db.execute(sql: "UPDATE ideas SET \(column) = NULL WHERE \(column) IN (\(marks(doomed.count)))",
                           arguments: StatementArguments(doomed))
        }
        return false
    }

    // MARK: - day plan

    private func plan(_ command: TowerCommand, _ p: Params, _ db: Database) throws -> [String: Any] {
        switch command {
        case .dayplanDone, .dayplanPending:
            let item = p.id("item_id")
            let status = command == .dayplanDone ? "done" : "pending"
            guard let cur = try String.fetchOne(db, sql: "SELECT status FROM day_plan_items WHERE id = ?", arguments: [item])
            else { throw Refusal.gone }
            if cur == status { return Self.already }
            let task = try planItemTask(db, item)
            var cascade = p.bool("cascade")
            var result: [String: Any] = [:]
            if cascade, let task, try !targetExists(db, task) {
                cascade = false
                result["note"] = "Updated the plan item only: target #\(task) no longer exists (it may have been deleted elsewhere)"
            }
            try update(db, "UPDATE day_plan_items SET status = ?, updated_at = \(Self.now) WHERE id = ?", [status, item])
            if cascade, let task {
                try setTargetStatus(db, task, status == "done" ? "done" : "todo", column: nil)
            }
            return result
        case .dayplanDelete:
            try db.execute(sql: "DELETE FROM day_plan_items WHERE id = ? AND source_type != 'calendar'", arguments: [p.id("item_id")])
            return Self.act(db.changesCount == 0)
        case .dayplanReorder:
            for (index, id) in p.ints("ordered_ids").enumerated() {
                try db.execute(sql: """
                    UPDATE day_plan_items SET order_index = ?, updated_at = \(Self.now) WHERE id = ? AND day_plan_id = ?
                    """, arguments: [index, id, p.id("plan_id")])
            }
            return [:]
        case .dayplanAdd:
            let plan = p.id("plan_id")
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM day_plans WHERE id = ?)", arguments: [plan]) == true
            else { throw Refusal.gone }
            let next = try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(order_index) + 1, 0) FROM day_plan_items WHERE day_plan_id = ?
                """, arguments: [plan]) ?? 0
            let start = p.text("start_time"), end = p.text("end_time")
            try db.execute(sql: """
                INSERT INTO day_plan_items (day_plan_id, kind, source_type, title, start_time, end_time, status, order_index, tags)
                VALUES (?, ?, 'manual', ?, ?, ?, 'pending', ?, '[]')
                """, arguments: [plan, p.text("kind"), p.text("title"), start.isEmpty ? nil : start, end.isEmpty ? nil : end, next])
            return ["id": db.lastInsertedRowID]
        default:
            throw Unmodelled(command: command)
        }
    }

    /// The task a plan item came from (`planItemTaskTx`).
    private func planItemTask(_ db: Database, _ item: Int64) throws -> Int64? {
        guard let row = try Row.fetchOne(db, sql: "SELECT source_type, source_id FROM day_plan_items WHERE id = ?",
                                         arguments: [item]),
              row["source_type"] as String == "task", let source: String = row["source_id"] else { return nil }
        return Int64(source)
    }

    private func targetExists(_ db: Database, _ id: Int64) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM targets WHERE id = ?)", arguments: [id]) ?? false
    }

    // MARK: - targets

    private func requireTarget(_ db: Database, _ id: Int64) throws {
        guard try targetExists(db, id) else { throw Refusal.gone }
    }

    /// `setTargetStatusOn` as the owner: the status (and the column), the
    /// leaf's progress, INBOX-02's target_due cascade, the parents' progress.
    private func setTargetStatus(_ db: Database, _ id: Int64, _ status: String, column: DatabaseValue?) throws {
        let parent = try Int64.fetchOne(db, sql: "SELECT parent_id FROM targets WHERE id = ?", arguments: [id])
        if let column {
            try db.execute(sql: """
                UPDATE targets SET status = ?, board_column_id = ?, status_actor = 'owner', updated_at = \(Self.now) WHERE id = ?
                """, arguments: [status, column, id])
        } else {
            try db.execute(sql: "UPDATE targets SET status = ?, status_actor = 'owner', updated_at = \(Self.now) WHERE id = ?",
                           arguments: [status, id])
        }
        try db.execute(sql: """
            UPDATE targets SET progress = ? WHERE id = ? AND
            NOT EXISTS (SELECT 1 FROM targets c WHERE c.parent_id = targets.id AND c.status != 'dismissed')
            """, arguments: [Self.progress(status), id])
        if status == "done" || status == "dismissed" {
            try db.execute(sql: """
                UPDATE inbox_items SET status = 'resolved', resolved_reason = 'target_closed', updated_at = \(Self.now)
                WHERE target_id = ? AND trigger_type = 'target_due' AND status = 'pending'
                """, arguments: [id])
        }
        if let parent { try recomputeParentProgress(db, parent) }
    }

    private static func progress(_ status: String) -> Double {
        ["done": 1.0, "in_progress": 0.5, "in_review": 0.8, "blocked": 0.2][status] ?? 0
    }

    /// `recomputeParentProgressOn`: each ancestor's progress from its children.
    private func recomputeParentProgress(_ db: Database, _ start: Int64) throws {
        var visited: Set<Int64> = []
        var current: Int64? = start
        while let id = current, visited.insert(id).inserted, visited.count <= 256 {
            let average = try Double.fetchOne(db, sql: "SELECT AVG(progress) FROM targets WHERE parent_id = ? AND status != 'dismissed'",
                                              arguments: [id])
            let own = try String.fetchOne(db, sql: "SELECT status FROM targets WHERE id = ?", arguments: [id]) ?? ""
            let value = average ?? Self.progress(own)
            try db.execute(sql: "UPDATE targets SET progress = ?, updated_at = \(Self.now) WHERE id = ? AND progress != ?",
                           arguments: [value, id, value])
            current = try Int64.fetchOne(db, sql: "SELECT parent_id FROM targets WHERE id = ?", arguments: [id])
        }
    }

    /// The ancestors the PROJ-05 triggers moved during `write`, sorted (Go's
    /// `rolled_up`).
    private func rolledUp(_ db: Database, _ id: Int64, _ write: () throws -> Void) throws -> [Int64] {
        let before = try WorkbenchQueries.ancestorStatuses(db, of: id)
        try write()
        let after = try WorkbenchQueries.ancestorStatuses(db, of: id)
        return after.filter { before[$0.key] != $0.value }.map(\.key).sorted()
    }

    // MARK: - catch-up and digests

    /// `AcknowledgeCatchupTx` (CATCHUP-01): the window read on all five
    /// surfaces and the recap stamped, first stamp wins.
    private func acknowledge(_ db: Database, _ id: Int64) throws {
        guard let recap = try Row.fetchOne(db, sql: "SELECT status, period_from, period_to FROM catchup_recaps WHERE id = ?",
                                           arguments: [id]) else { throw Refusal.gone }
        guard recap["status"] as String == "ready" else { throw Refusal.notReady }
        let from = (recap["period_from"] as Double).rounded(.towardZero), to = (recap["period_to"] as Double).rounded(.towardZero)
        let fromISO = Self.iso.string(from: Date(timeIntervalSince1970: from))
        let toISO = Self.iso.string(from: Date(timeIntervalSince1970: to))
        let fromDate = Self.localDay.string(from: Date(timeIntervalSince1970: from))
        let toDate = Self.localDay.string(from: Date(timeIntervalSince1970: to - 1))
        let now = Self.now
        let statements: [(String, StatementArguments)] = [
            ("UPDATE digests SET read_at=\(now) WHERE read_at IS NULL AND type='channel' AND period_to > ? AND period_from < ?",
             [recap["period_from"] as Double, recap["period_to"] as Double]),
            ("UPDATE stream_digests SET read_at=\(now) WHERE read_at IS NULL AND period_to > ? AND period_from < ?", [fromISO, toISO]),
            ("""
             UPDATE tracks SET read_at=\(now), has_updates=0 WHERE dismissed_at='' AND updated_at > ? AND updated_at <= ?
             AND (read_at IS NULL OR has_updates=1)
             """, [fromISO, toISO]),
            ("""
             UPDATE inbox_items SET read_at=\(now) WHERE read_at IS NULL
             AND MAX(created_at, mentioned_at) > ? AND MAX(created_at, mentioned_at) <= ?
             """, [fromISO, toISO]),
            ("UPDATE briefings SET read_at=\(now) WHERE read_at IS NULL AND date >= ? AND date <= ?", [fromDate, toDate]),
            ("UPDATE catchup_recaps SET acknowledged_at=\(now), updated_at=\(now) WHERE id=? AND acknowledged_at IS NULL", [id])
        ]
        for (sql, arguments) in statements { try db.execute(sql: sql, arguments: arguments) }
    }

    /// `markDigestReadTx`: the digest read with all its decisions.
    private func markDigestRead(_ db: Database, _ id: Int64) throws {
        try db.execute(sql: "UPDATE digests SET read_at = \(Self.now) WHERE id = ? AND read_at IS NULL", arguments: [id])
        try markDecisionsRead(db, id)
    }

    private func markDecisionsRead(_ db: Database, _ digest: Int64) throws {
        guard let decisions = try String.fetchOne(db, sql: "SELECT decisions FROM digests WHERE id = ?", arguments: [digest])
        else { return }
        let count = ((try? JSONSerialization.jsonObject(with: Data(decisions.utf8))) as? [Any])?.count ?? 0
        for index in 0..<count {
            try db.execute(sql: "INSERT INTO decision_reads (digest_id, decision_idx) VALUES (?, ?) ON CONFLICT DO NOTHING",
                           arguments: [digest, index])
        }
    }

    // MARK: - helpers

    /// One statement on a row that must exist: Go's `ErrRowNotFound` otherwise.
    private func update(_ db: Database, _ sql: String, _ arguments: StatementArguments) throws {
        try db.execute(sql: sql, arguments: arguments)
        guard db.changesCount > 0 else { throw Refusal.gone }
    }

    private func marks(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }
}

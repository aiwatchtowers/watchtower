import Foundation
import GRDB
import WatchtowerCore
import WatchtowerInterface

/// Go's screen writers (`internal/db/screen_writes.go`, `inbox_writes.go`,
/// `target_owner_writes.go`) as a test database sees them, for the view
/// models' tests: a `FakeScreenTower.applying(db)` answers each command the
/// screens send as Go would, after making Go's write on `db`. Only the
/// columns the screens read back are modelled; the writers themselves are
/// pinned in Go (the `screen_writes` fixture, the moved guards).
extension FakeScreenTower {
    package static func applying(_ db: any DatabaseWriter) -> FakeScreenTower {
        let tower = FakeScreenTower()
        tower.apply = { command, data in try await ScreenTowerWrites(db: db).apply(command, data) }
        return tower
    }
}

private struct ScreenTowerWrites {
    let db: any DatabaseWriter

    private static let now = "strftime('%Y-%m-%dT%H:%M:%SZ','now')"
    private static let clearReview = "needs_review = 0, review_reason = ''"

    private func request<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    private func encode(_ value: some Encodable) throws -> Data {
        try JSONEncoder().encode(value)
    }

    /// One statement on a row that must exist: Go's `not_found` otherwise.
    private func update(_ db: Database, _ sql: String, _ arguments: StatementArguments, phrase: String) throws {
        try db.execute(sql: sql, arguments: arguments)
        guard db.changesCount > 0 else { throw FakeScreenTower.Refused("Couldn't \(phrase): it's no longer on the Mac.") }
    }

    /// The ancestors the PROJ-05 triggers moved during `write`, sorted (Go's
    /// `rolled_up`).
    private func rolledUp(_ db: Database, _ id: Int64, _ write: () throws -> Void) throws -> [Int64] {
        let before = try WorkbenchQueries.ancestorStatuses(db, of: id)
        try write()
        let after = try WorkbenchQueries.ancestorStatuses(db, of: id)
        return after.filter { before[$0.key] != $0.value }.map(\.key).sorted()
    }

    // One switch over the commands the screens send.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func apply(_ command: TowerCommand, _ data: Data) async throws -> Data? {
        let done = try encode(ActResult())
        switch command {
        case .ideasStatus:
            let q = try request(IdeaStatusRequest.self, data)
            try await db.write { db in
                try update(db, "UPDATE ideas SET status = ?, \(Self.clearReview), updated_at = \(Self.now) WHERE id = ?",
                           [q.status, q.id], phrase: "update the idea")
            }
            return done
        case .ideasSnooze:
            let q = try request(IdeaSnoozeRequest.self, data)
            try await db.write { db in
                try update(db, """
                    UPDATE ideas SET status = 'not_now', snooze_until = ?, \(Self.clearReview), updated_at = \(Self.now)
                    WHERE id = ?
                    """, [q.until ?? "", q.id], phrase: "put it off")
            }
            return done
        case .ideasMerge:
            let q = try request(IdeaMergeRequest.self, data)
            try await db.write { db in
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM ideas WHERE id = ?)", arguments: [q.into]) == true
                else { throw FakeScreenTower.Refused("Couldn't merge it: it's no longer on the Mac.") }
                try update(db, """
                    UPDATE ideas SET status = 'merged', merged_into_id = ?, \(Self.clearReview), updated_at = \(Self.now)
                    WHERE id = ?
                    """, [q.into, q.id], phrase: "merge it")
                try db.execute(sql: "UPDATE idea_mentions SET idea_id = ? WHERE idea_id = ?", arguments: [q.into, q.id])
                try db.execute(sql: "UPDATE ideas SET merged_into_id = ? WHERE merged_into_id = ?", arguments: [q.into, q.id])
            }
            return done
        case .ideasSupersede:
            let q = try request(IdeaSupersedeRequest.self, data)
            try await db.write { db in
                try update(db, """
                    UPDATE ideas SET status = 'superseded', superseded_by_id = ?, \(Self.clearReview), updated_at = \(Self.now)
                    WHERE id = ?
                    """, [q.by, q.id], phrase: "supersede it")
            }
            return done
        case .ideasRating:
            let q = try request(IdeaRatingRequest.self, data)
            try await db.write { db in
                try update(db, "UPDATE ideas SET owner_rating = ?, rating_comment = ? WHERE id = ?",
                           [q.rating, q.comment, q.id], phrase: "rate it")
            }
            return done
        case .ideasCreate:
            let q = try request(IdeaCreateRequest.self, data)
            let id = try await db.write { db -> Int64 in
                try db.execute(sql: """
                    INSERT INTO ideas (kind, title, essence, status, source, last_mention_at)
                    VALUES (?, ?, ?, 'active', 'owner', \(Self.now))
                    """, arguments: [q.kind, q.title, q.essence])
                let id = db.lastInsertedRowID
                try db.execute(sql: """
                    INSERT INTO idea_mentions (idea_id, source, quote, said_at) VALUES (?, 'owner', ?, \(Self.now))
                    """, arguments: [id, q.essence])
                return id
            }
            return try encode(CreatedResult(id: id))
        case .ideasDelete:
            let q = try request(ScreenIDRequest.self, data)
            let gone = try await db.write { db -> Bool in
                let doomed = try Int64.fetchAll(db, sql: """
                    WITH RECURSIVE tree(id) AS (
                        SELECT id FROM ideas WHERE id = ?
                        UNION SELECT i.id FROM ideas i JOIN tree t ON i.merged_into_id = t.id)
                    SELECT id FROM tree
                    """, arguments: [q.id])
                guard !doomed.isEmpty else { return true }
                let marks = doomed.map { _ in "?" }.joined(separator: ",")
                let ids = StatementArguments(doomed)
                try db.execute(sql: "UPDATE ideas SET similar_to_id = NULL WHERE similar_to_id IN (\(marks))", arguments: ids)
                try db.execute(sql: "UPDATE ideas SET superseded_by_id = NULL WHERE superseded_by_id IN (\(marks))", arguments: ids)
                try db.execute(sql: "DELETE FROM ideas WHERE id IN (\(marks))", arguments: ids)
                return false
            }
            return try encode(ActResult(already: gone ? true : nil))
        case .ideasConverted:
            let q = try request(IdeaConvertedRequest.self, data)
            let target = try await db.write { db -> Int64 in
                guard let row = try Row.fetchOne(db, sql: "SELECT title, essence FROM ideas WHERE id = ?", arguments: [q.id])
                else { throw FakeScreenTower.Refused("Couldn't convert it: it's no longer on the Mac.") }
                try db.execute(sql: """
                    INSERT INTO targets (text, intent, level, period_start, period_end, source_type, source_id)
                    VALUES (?, ?, 'day', ?, ?, 'idea', ?)
                    """, arguments: [row["title"] as String, row["essence"] as String, q.today, q.today, String(q.id)])
                let target = db.lastInsertedRowID
                try db.execute(sql: """
                    UPDATE ideas SET status = 'converted', converted_target_id = ?, \(Self.clearReview), updated_at = \(Self.now)
                    WHERE id = ?
                    """, arguments: [target, q.id])
                return target
            }
            return try encode(IdeaConvertResult(targetID: target))
        case .ideasDecisionSeen:
            let q = try request(ScreenIDRequest.self, data)
            try await db.write { db in
                try db.execute(sql: "UPDATE ideas SET seen_at = \(Self.now), \(Self.clearReview) WHERE id = ?", arguments: [q.id])
            }
            return done
        case .ideasDecisionsSeenAll:
            try await db.write { db in
                try db.execute(sql: """
                    UPDATE ideas SET seen_at = \(Self.now), \(Self.clearReview)
                    WHERE kind = 'decision' AND (seen_at IS NULL OR needs_review = 1)
                    """)
            }
            return done
        case .tracksRead:
            let q = try request(ScreenIDsRequest.self, data)
            try await db.write { db in
                for id in q.iDs {
                    try db.execute(sql: "UPDATE tracks SET read_at = \(Self.now), has_updates = 0 WHERE id = ?", arguments: [id])
                }
            }
            return done
        case .tracksPriority:
            let q = try request(TrackPriorityRequest.self, data)
            try await db.write { db in
                try update(db, "UPDATE tracks SET priority = ? WHERE id = ?", [q.priority, q.id], phrase: "change the priority")
            }
            return done
        case .tracksOwnership:
            let q = try request(TrackOwnershipRequest.self, data)
            try await db.write { db in
                try update(db, "UPDATE tracks SET ownership = ? WHERE id = ?", [q.ownership, q.id], phrase: "change the ownership")
            }
            return done
        case .tracksStop:
            let q = try request(ScreenIDsRequest.self, data)
            try await db.write { db in
                for id in q.iDs {
                    try db.execute(sql: "UPDATE tracks SET dismissed_at = \(Self.now) WHERE id = ?", arguments: [id])
                }
            }
            return done
        case .tracksRestore:
            let q = try request(ScreenIDRequest.self, data)
            try await db.write { db in
                try update(db, "UPDATE tracks SET dismissed_at = '' WHERE id = ?", [q.id], phrase: "restore it")
            }
            return done
        case .tracksEventStatus:
            let q = try request(TrackEventStatusRequest.self, data)
            try await db.write { db in
                try update(db, "UPDATE track_events SET action_status = ? WHERE id = ?", [q.status, q.eventID],
                           phrase: "update the event")
            }
            return done
        case .dayplanDone, .dayplanPending:
            let q = try request(PlanItemStatusRequest.self, data)
            let status = command == .dayplanDone ? "done" : "pending"
            let note = try await db.write { db -> String? in
                try update(db, "UPDATE day_plan_items SET status = ? WHERE id = ?", [status, q.itemID], phrase: "check it off")
                guard q.cascade, let task = try String.fetchOne(db, sql: """
                    SELECT source_id FROM day_plan_items WHERE id = ? AND source_type = 'task'
                    """, arguments: [q.itemID]) else { return nil }
                try db.execute(sql: "UPDATE targets SET status = ? WHERE id = ?",
                               arguments: [command == .dayplanDone ? "done" : "todo", task])
                guard db.changesCount > 0 else {
                    return "Updated the plan item only: target #\(task) no longer exists (it may have been deleted elsewhere)"
                }
                return nil
            }
            return try encode(ActResult(note: note))
        case .dayplanDelete:
            let q = try request(PlanItemRequest.self, data)
            try await db.write { db in
                try db.execute(sql: "DELETE FROM day_plan_items WHERE id = ? AND source_type != 'calendar'", arguments: [q.itemID])
            }
            return done
        case .dayplanReorder:
            let q = try request(PlanReorderRequest.self, data)
            try await db.write { db in
                for (index, id) in q.orderedIDs.enumerated() {
                    try db.execute(sql: "UPDATE day_plan_items SET order_index = ? WHERE id = ? AND day_plan_id = ?",
                                   arguments: [index, id, q.planID])
                }
            }
            return done
        case .dayplanAdd:
            let q = try request(PlanAddRequest.self, data)
            let id = try await db.write { db -> Int64 in
                let next = try Int.fetchOne(db, sql: """
                    SELECT COALESCE(MAX(order_index) + 1, 0) FROM day_plan_items WHERE day_plan_id = ?
                    """, arguments: [q.planID]) ?? 0
                try db.execute(sql: """
                    INSERT INTO day_plan_items (day_plan_id, kind, source_type, title, start_time, end_time, status, order_index, tags)
                    VALUES (?, ?, 'manual', ?, ?, ?, 'pending', ?, '[]')
                    """, arguments: [q.planID, q.kind, q.title, q.startTime, q.endTime, next])
                return db.lastInsertedRowID
            }
            return try encode(CreatedResult(id: id))
        case .targetsSetStatus:
            let q = try request(TargetStatusRequest.self, data)
            let rolled = try await db.write { db in
                try rolledUp(db, q.id) {
                    try update(db, "UPDATE targets SET status = ?, status_actor = 'owner', updated_at = \(Self.now) WHERE id = ?",
                               [q.status, q.id], phrase: "change the status")
                }
            }
            return try encode(TargetStatusResult(rolledUp: rolled))
        case .targetsSetColumn:
            let q = try request(TargetColumnRequest.self, data)
            let rolled = try await db.write { db in
                try rolledUp(db, q.id) {
                    try update(db, """
                        UPDATE targets SET status = ?, board_column_id = ?, status_actor = 'owner', updated_at = \(Self.now)
                        WHERE id = ?
                        """, [q.status, q.columnID, q.id], phrase: "move it")
                }
            }
            return try encode(TargetStatusResult(rolledUp: rolled))
        case .targetsWorkOn:
            // Go's `MarkInProgressOnWorkOnTx`: only a `todo` task of a
            // workbench with no sub-targets moves, as the owner's write.
            let q = try request(ScreenIDRequest.self, data)
            let (moved, rolled) = try await db.write { db -> (Bool, [Int64]) in
                guard let row = try Row.fetchOne(db, sql: "SELECT status, project_id FROM targets WHERE id = ?",
                                                 arguments: [q.id]),
                      let project: Int64 = row["project_id"], row["status"] as String == "todo",
                      try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM targets WHERE parent_id = ? AND project_id = ?)",
                                        arguments: [q.id, project]) == false
                else { return (false, []) }
                let rolled = try rolledUp(db, q.id) {
                    try update(db, """
                        UPDATE targets SET status = 'in_progress', status_actor = 'owner', updated_at = \(Self.now) WHERE id = ?
                        """, [q.id], phrase: "start it")
                }
                return (true, rolled)
            }
            return try encode(WorkOnResult(moved: moved, rolledUp: rolled))
        case .catchupAcknowledge:
            // The window's channel digests read and the recap stamped (the
            // five surfaces are Go's `AcknowledgeCatchupTx`, CATCHUP-01).
            let q = try request(ScreenIDRequest.self, data)
            try await db.write { db in
                guard let recap = try Row.fetchOne(db, sql: """
                    SELECT status, period_from, period_to FROM catchup_recaps WHERE id = ?
                    """, arguments: [q.id]) else { throw FakeScreenTower.Refused("Couldn't mark it caught up: it's no longer on the Mac.") }
                guard recap["status"] as String == "ready" else {
                    throw FakeScreenTower.Refused("Couldn't mark it caught up: this recap isn't ready.")
                }
                try db.execute(sql: """
                    UPDATE digests SET read_at = \(Self.now)
                    WHERE read_at IS NULL AND type = 'channel' AND period_to > ? AND period_from < ?
                    """, arguments: [recap["period_from"] as Double, recap["period_to"] as Double])
                try db.execute(sql: "UPDATE catchup_recaps SET acknowledged_at = \(Self.now) WHERE id = ? AND acknowledged_at IS NULL",
                               arguments: [q.id])
            }
            return done
        case .targetsSnooze:
            let q = try request(TargetSnoozeRequest.self, data)
            try await db.write { db in
                try update(db, """
                    UPDATE targets SET status = 'snoozed', snooze_until = ?, status_actor = 'owner', updated_at = \(Self.now)
                    WHERE id = ?
                    """, [q.until, q.id], phrase: "snooze it")
            }
            return try encode(TargetStatusResult(rolledUp: []))
        case .digestsRead:
            let q = try request(ScreenIDsRequest.self, data)
            try await db.write { db in
                for id in q.iDs {
                    try db.execute(sql: "UPDATE digests SET read_at = \(Self.now) WHERE id = ? AND read_at IS NULL", arguments: [id])
                }
            }
            return done
        case .digestsStreamRead:
            let q = try request(ScreenIDRequest.self, data)
            try await db.write { db in
                try db.execute(sql: "UPDATE stream_digests SET read_at = \(Self.now) WHERE id = ? AND read_at IS NULL",
                               arguments: [q.id])
            }
            return done
        default:
            return nil
        }
    }
}

import Foundation
import GRDB

// MARK: - Supporting Types

package struct TargetFilter {
    package var level: String? = nil
    package var status: String? = nil
    package var priority: String? = nil
    package var ownership: String? = nil
    package var periodStart: String? = nil     // filter targets whose period overlaps this date range start
    package var periodEnd: String? = nil       // filter targets whose period overlaps this date range end
    package var search: String? = nil
    package var tag: String?
    package var includeDone: Bool = false
    package var parentID: Int? = nil
    package var limit: Int = 200

    package init(
        level: String? = nil,
        status: String? = nil,
        priority: String? = nil,
        ownership: String? = nil,
        periodStart: String? = nil,
        periodEnd: String? = nil,
        search: String? = nil,
        tag: String? = nil,
        includeDone: Bool = false,
        parentID: Int? = nil,
        limit: Int = 200
    ) {
        self.level = level
        self.status = status
        self.priority = priority
        self.ownership = ownership
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.search = search
        self.tag = tag
        self.includeDone = includeDone
        self.parentID = parentID
        self.limit = limit
    }
}

package struct TargetCounts {
    package let active: Int
    package let overdue: Int
    package let dueToday: Int
    package let highPriority: Int
}

package enum LinkDirection {
    case inbound    // target_target_id = targetID
    case outbound   // source_target_id = targetID
    case both
}

// MARK: - TargetQueries

package enum TargetQueries {

    // MARK: - Fetch

    package static func fetchAll(
        _ db: Database,
        filter: TargetFilter = TargetFilter()
    ) throws -> [Target] {
        var conditions: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let level = filter.level {
            conditions.append("level = ?")
            args.append(level)
        }

        if let status = filter.status {
            conditions.append("status = ?")
            args.append(status)
        } else if !filter.includeDone {
            conditions.append("status NOT IN ('done', 'dismissed')")
        }

        if let priority = filter.priority {
            conditions.append("priority = ?")
            args.append(priority)
        }

        if let ownership = filter.ownership {
            conditions.append("ownership = ?")
            args.append(ownership)
        }

        if let parentID = filter.parentID {
            conditions.append("parent_id = ?")
            args.append(parentID)
        }

        // Period overlap: period_start <= periodEnd AND period_end >= periodStart
        if let ps = filter.periodStart {
            conditions.append("period_end >= ?")
            args.append(ps)
        }
        if let pe = filter.periodEnd {
            conditions.append("period_start <= ?")
            args.append(pe)
        }

        if let search = filter.search, !search.isEmpty {
            conditions.append("(text LIKE ? OR intent LIKE ?)")
            let pattern = "%\(search)%"
            args.append(pattern)
            args.append(pattern)
        }

        // SQL predicate, not an in-memory pass: filtering after the LIMIT
        // would make rarely-used tags appear empty once the table outgrows it.
        // json_valid guards the whole query: json_each over one malformed row
        // would otherwise abort it and blank the entire list.
        if let tag = filter.tag, !tag.isEmpty {
            conditions.append("(json_valid(targets.tags) AND EXISTS (SELECT 1 FROM json_each(targets.tags) WHERE value = ?))")
            args.append(tag)
        }

        var sql = "SELECT * FROM targets"
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += """
             ORDER BY \
            CASE level WHEN 'quarter' THEN 0 WHEN 'month' THEN 1 WHEN 'week' THEN 2 WHEN 'day' THEN 3 ELSE 4 END, \
            period_start ASC, \
            CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 WHEN 'low' THEN 2 ELSE 1 END, \
            created_at DESC
            """
        sql += " LIMIT ?"
        args.append(filter.limit)

        return try Target.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    package static func fetchByID(_ db: Database, id: Int) throws -> Target? {
        try Target.fetchOne(db, sql: "SELECT * FROM targets WHERE id = ?", arguments: [id])
    }

    package static func fetchBySourceRef(
        _ db: Database,
        sourceType: String,
        sourceID: String
    ) throws -> [Target] {
        try Target.fetchAll(
            db,
            sql: "SELECT * FROM targets WHERE source_type = ? AND source_id = ? ORDER BY created_at DESC",
            arguments: [sourceType, sourceID]
        )
    }

    // MARK: - Counts

    package static func fetchCounts(_ db: Database) throws -> TargetCounts {
        let active = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM targets WHERE status IN ('todo', 'in_progress', 'blocked')"
        ) ?? 0
        let now = nowDatetimeString()
        let overdue = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM targets
                WHERE status IN ('todo', 'in_progress', 'blocked')
                AND due_date != '' AND due_date < ?
                """,
            arguments: [now]
        ) ?? 0
        let today = todayDateString()
        let dueToday = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM targets
                WHERE status IN ('todo', 'in_progress', 'blocked')
                AND due_date != '' AND due_date >= ? AND due_date < ?
                """,
            arguments: [today, today + "T24:00"]
        ) ?? 0
        let highPriority = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM targets
                WHERE status IN ('todo', 'in_progress', 'blocked')
                AND priority = 'high'
                """
        ) ?? 0
        return TargetCounts(active: active, overdue: overdue, dueToday: dueToday, highPriority: highPriority)
    }

    // MARK: - Create

    @discardableResult
    package static func create(
        _ db: Database,
        text: String,
        intent: String = "",
        level: String = "day",
        customLabel: String = "",
        periodStart: String,
        periodEnd: String,
        parentId: Int? = nil,
        status: String = "todo",
        priority: String = "medium",
        ownership: String = "mine",
        ballOn: String = "",
        dueDate: String = "",
        snoozeUntil: String = "",
        blocking: String = "",
        tags: String = "[]",
        subItems: String = "[]",
        notes: String = "[]",
        progress: Double = 0.0,
        sourceType: String = "manual",
        sourceID: String = "",
        aiLevelConfidence: Double? = nil,
        secondaryLinks: [TargetPrefillLink] = []
    ) throws -> Int {
        try db.execute(sql: """
            INSERT INTO targets (text, intent, level, custom_label, period_start, period_end,
                parent_id, status, priority, ownership, ball_on, due_date, snooze_until,
                blocking, tags, sub_items, notes, progress, source_type, source_id, ai_level_confidence)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [text, intent, level, customLabel, periodStart, periodEnd,
                             parentId, status, priority, ownership, ballOn, dueDate, snoozeUntil,
                             blocking, tags, subItems, notes, progress, sourceType, sourceID, aiLevelConfidence])
        let newID = Int(db.lastInsertedRowID)

        for link in secondaryLinks {
            let ref = link.externalRef
            // Mirrors the Go-side allow-list `IsValidExternalRef`
            // (internal/targets/extractor.go:146): only "jira:" and "slack:" pass.
            guard ref.hasPrefix("jira:") || ref.hasPrefix("slack:") else { continue }
            try db.execute(
                sql: """
                    INSERT INTO target_links (source_target_id, target_target_id, external_ref, relation, created_by)
                    VALUES (?, NULL, ?, ?, 'user')
                    """,
                arguments: [newID, ref, link.relation]
            )
        }

        return newID
    }

    // MARK: - Update

    package static func updateStatus(_ db: Database, id: Int, status: String) throws {
        try db.execute(
            sql: """
                UPDATE targets SET status = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [status, id]
        )

        // BEHAVIOR INBOX-02 — closing a target resolves its pending `target_due`
        // inbox items so the user never has to close the same thing twice.
        // Mirrors the Go-side cascade in `UpdateTargetStatus`
        // (internal/db/targets.go); Desktop "Done" bypasses Go, so the two
        // paths must stay in sync (same dual-path convention as
        // `CatchUpQueries.acknowledge`).
        if status == "done" || status == "dismissed" {
            try db.execute(
                sql: """
                    UPDATE inbox_items
                    SET status = 'resolved',
                        resolved_reason = 'target_closed',
                        updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                    WHERE target_id = ? AND trigger_type = 'target_due' AND status = 'pending'
                    """,
                arguments: [id]
            )
        }
    }

    package static func updatePriority(_ db: Database, id: Int, priority: String) throws {
        try db.execute(
            sql: """
                UPDATE targets SET priority = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [priority, id]
        )
    }

    package static func updateText(_ db: Database, id: Int, text: String) throws {
        try db.execute(
            sql: """
                UPDATE targets SET text = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [text, id]
        )
    }

    package static func updateIntent(_ db: Database, id: Int, intent: String) throws {
        try db.execute(
            sql: """
                UPDATE targets SET intent = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [intent, id]
        )
    }

    package static func updateDueDate(_ db: Database, id: Int, dueDate: String) throws {
        try db.execute(
            sql: """
                UPDATE targets SET due_date = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [dueDate, id]
        )
    }

    /// Updates a target's horizon level. Switching to any standard level
    /// (quarter/month/week/day) clears `custom_label`, which is only meaningful
    /// for the "custom" level. When `periodStart`/`periodEnd` are supplied (the
    /// natural window for the new level, see `Target.periodWindow`), the period is
    /// updated too so it reflects the new granularity; pass nil to leave it as-is.
    package static func updateLevel(
        _ db: Database,
        id: Int,
        level: String,
        periodStart: String? = nil,
        periodEnd: String? = nil
    ) throws {
        if let periodStart, let periodEnd {
            try db.execute(
                sql: """
                    UPDATE targets
                    SET level = ?,
                        custom_label = CASE WHEN ? THEN '' ELSE custom_label END,
                        period_start = ?,
                        period_end = ?,
                        updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                    WHERE id = ?
                    """,
                arguments: [level, level != "custom", periodStart, periodEnd, id]
            )
        } else {
            try db.execute(
                sql: """
                    UPDATE targets
                    SET level = ?,
                        custom_label = CASE WHEN ? THEN '' ELSE custom_label END,
                        updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                    WHERE id = ?
                    """,
                arguments: [level, level != "custom", id]
            )
        }
    }

    package static func updateProgress(_ db: Database, id: Int, progress: Double) throws {
        let clamped = min(max(progress, 0.0), 1.0)
        try db.execute(
            sql: """
                UPDATE targets SET progress = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [clamped, id]
        )
    }

    package static func updateSubItems(_ db: Database, id: Int, subItems: [TargetSubItem]) throws {
        let json = try jsonString(JSONEncoder().encode(subItems))
        try db.execute(
            sql: """
                UPDATE targets SET sub_items = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [json, id]
        )
    }

    /// Tag edits are semantic add/remove against a fresh in-transaction read,
    /// never a wholesale rewrite from the caller's snapshot — a label written
    /// concurrently (daemon, CLI, second window) must survive the edit
    /// (review-rules: reload the row immediately before writing).
    /// Returns whether anything changed, so callers can report an honest
    /// summary for the idempotent no-op cases (duplicate add, absent remove,
    /// vanished row).
    @discardableResult
    package static func addTag(_ db: Database, id: Int, tag: String) throws -> Bool {
        guard var tags = try currentTags(db, id: id) else { return false }
        guard !tags.contains(tag) else { return false }
        tags.append(tag)
        try writeTags(db, id: id, tags: tags)
        return true
    }

    @discardableResult
    package static func removeTag(_ db: Database, id: Int, tag: String) throws -> Bool {
        guard let tags = try currentTags(db, id: id), tags.contains(tag) else { return false }
        try writeTags(db, id: id, tags: tags.filter { $0 != tag })
        return true
    }

    /// nil = row vanished (edit becomes a no-op, the sibling mutators' contract).
    /// An undecodable column throws — deliberately NOT `Target.decodedTags`'
    /// tolerant `try? → []`, which here would silently replace whatever the
    /// column held with the freshly built array.
    private static func currentTags(_ db: Database, id: Int) throws -> [String]? {
        guard let raw = try String.fetchOne(db, sql: "SELECT tags FROM targets WHERE id = ?", arguments: [id]) else {
            return nil
        }
        return try JSONDecoder().decode([String].self, from: Data(raw.utf8))
    }

    /// JSONEncoder output is always valid UTF-8, so the nil branch is
    /// unreachable — but if it ever fired, a `?? "[]"` fallback would silently
    /// erase the column; throwing is the only honest handling.
    private static func jsonString(_ data: Data) throws -> String {
        guard let json = String(bytes: data, encoding: .utf8) else {
            throw DatabaseError(message: "JSON encoding produced non-UTF-8 data")
        }
        return json
    }

    private static func writeTags(_ db: Database, id: Int, tags: [String]) throws {
        let json = try jsonString(JSONEncoder().encode(tags))
        try db.execute(
            sql: """
                UPDATE targets SET tags = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [json, id]
        )
    }

    /// Blank tags are excluded: pre-fix `targets update --tags ""` wrote `[""]`,
    /// which must not surface as an invisible filter-menu entry.
    package static func fetchDistinctTags(_ db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
                SELECT DISTINCT value FROM targets, json_each(targets.tags)
                WHERE json_valid(targets.tags) AND value <> ''
                ORDER BY value COLLATE NOCASE
                """
        )
    }

    package static func snooze(_ db: Database, id: Int, until: Date) throws {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let dateStr = fmt.string(from: until)
        try db.execute(
            sql: """
                UPDATE targets SET status = 'snoozed', snooze_until = ?,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [dateStr, id]
        )
    }

    // MARK: - Delete

    package static func delete(_ db: Database, id: Int) throws {
        try db.execute(sql: "DELETE FROM targets WHERE id = ?", arguments: [id])
    }

    // MARK: - Links

    /// Create a typed link between two existing targets. INSERT OR IGNORE respects
    /// the UNIQUE(source, target, external_ref, relation) constraint, so re-proposing
    /// an existing link is a no-op rather than an error.
    package static func createLink(
        _ db: Database,
        sourceID: Int,
        targetID: Int,
        relation: String,
        createdBy: String = "user"
    ) throws {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO target_links
                  (source_target_id, target_target_id, external_ref, relation, created_by)
                VALUES (?, ?, '', ?, ?)
                """,
            arguments: [sourceID, targetID, relation, createdBy]
        )
    }

    package static func fetchLinks(
        _ db: Database,
        targetID: Int,
        direction: LinkDirection = .both
    ) throws -> [TargetLink] {
        switch direction {
        case .inbound:
            return try TargetLink.fetchAll(
                db,
                sql: "SELECT * FROM target_links WHERE target_target_id = ? ORDER BY created_at DESC",
                arguments: [targetID]
            )
        case .outbound:
            return try TargetLink.fetchAll(
                db,
                sql: "SELECT * FROM target_links WHERE source_target_id = ? ORDER BY created_at DESC",
                arguments: [targetID]
            )
        case .both:
            return try TargetLink.fetchAll(
                db,
                sql: """
                    SELECT * FROM target_links
                    WHERE source_target_id = ? OR target_target_id = ?
                    ORDER BY created_at DESC
                    """,
                arguments: [targetID, targetID]
            )
        }
    }

    // MARK: - Helpers

    package static func todayDateString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: Date())
    }

    package static func nowDatetimeString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: Date())
    }
}

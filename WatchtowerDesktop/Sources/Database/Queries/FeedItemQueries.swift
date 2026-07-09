import Foundation
import GRDB

/// Reads and per-item state writes for the dashboard feed (`feed_items` index).
/// Content is joined live from the source tables; an entry whose source row is
/// missing is silently dropped (never an error placeholder in the wall).
enum FeedItemQueries {
    /// Threshold for the "Important only" filter — meetings (70) and
    /// high-priority situations (90) pass; routine items (60) don't.
    static let importantThreshold = 70

    struct Filter: Equatable {
        var types: Set<FeedItem.ItemType> = Set(FeedItem.ItemType.allCases)
        var importantOnly: Bool = false
        var showHidden: Bool = false
    }

    /// A keyset cursor into the feed's `(event_ts DESC, id DESC)` ordering —
    /// the (event_ts, id) of the last RAW `feed_items` row the previous page's
    /// SQL query returned (not the last surviving `FeedEntry`, whose source
    /// row may have been dropped — see `FeedPage.nextCursor`).
    struct FeedCursor: Equatable {
        let eventTs: String
        let id: Int64
    }

    struct FeedPage {
        let entries: [FeedEntry]
        let nextCursor: FeedCursor?
    }

    /// Fetches one page of the feed using keyset pagination instead of
    /// OFFSET. OFFSET/LIMIT breaks here because rows whose source content has
    /// been deleted (e.g. a cancelled calendar event) are dropped AFTER the
    /// SQL LIMIT — so `offset = entries.count` on the client undercounts the
    /// raw rows actually consumed, and the next page re-fetches (and
    /// duplicates) rows already seen. The keyset cursor tracks position by
    /// the last RAW row's `(event_ts, id)`, independent of how many entries
    /// survived the content join.
    static func fetchFeed(_ db: Database, filter: Filter = Filter(), limit: Int, before cursor: FeedCursor? = nil) throws -> FeedPage {
        if filter.types.isEmpty { return FeedPage(entries: [], nextCursor: nil) }
        var conditions: [String] = []
        var args: [DatabaseValueConvertible] = []
        if !filter.showHidden {
            conditions.append("hidden_at IS NULL")
        }
        if filter.importantOnly {
            conditions.append("importance >= ?")
            args.append(importantThreshold)
        }
        if filter.types.count < FeedItem.ItemType.allCases.count {
            let placeholders = Array(repeating: "?", count: filter.types.count).joined(separator: ",")
            conditions.append("item_type IN (\(placeholders))")
            args.append(contentsOf: filter.types.map(\.rawValue).sorted())
        }
        if let cursor {
            conditions.append("(event_ts < ? OR (event_ts = ? AND id < ?))")
            args.append(cursor.eventTs)
            args.append(cursor.eventTs)
            args.append(cursor.id)
        }
        var sql = "SELECT * FROM feed_items"
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY event_ts DESC, id DESC LIMIT ?"
        args.append(limit)

        let items = try FeedItem.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        let nextCursor: FeedCursor? = items.count < limit ? nil : items.last.map { FeedCursor(eventTs: $0.eventTs, id: $0.id) }
        var entries: [FeedEntry] = []
        entries.reserveCapacity(items.count)
        for item in items {
            guard let content = try loadContent(db, item: item) else { continue }
            entries.append(FeedEntry(item: item, content: content))
        }
        return FeedPage(entries: entries, nextCursor: nextCursor)
    }

    static func hide(_ db: Database, id: Int64) throws {
        try db.execute(
            sql: """
            UPDATE feed_items
            SET hidden_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
                updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            WHERE id = ?
            """, arguments: [id])
    }

    static func unhide(_ db: Database, id: Int64) throws {
        try db.execute(
            sql: "UPDATE feed_items SET hidden_at = NULL, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?",
            arguments: [id])
    }

    /// First-write-wins: re-selecting an already-seen item keeps the original mark.
    static func markSeen(_ db: Database, id: Int64) throws {
        try db.execute(
            sql: "UPDATE feed_items SET seen_at = COALESCE(seen_at, strftime('%Y-%m-%dT%H:%M:%SZ','now')) WHERE id = ?",
            arguments: [id])
    }

    // MARK: - Content joins

    private static func loadContent(_ db: Database, item: FeedItem) throws -> FeedContent? {
        switch item.itemType {
        case .situation:
            guard let id = Int(item.sourceID),
                  let s = try SituationQueries.fetchByID(db, id: id) else { return nil }
            return .situation(s)
        case .meeting:
            guard let event = try fetchEvent(db, id: item.sourceID) else { return nil }
            return .meeting(event, prep: try fetchPrep(db, eventID: item.sourceID))
        case .briefing:
            guard let id = Int(item.sourceID),
                  let b = try BriefingQueries.fetchByID(db, id: id) else { return nil }
            return .briefing(b)
        case .meetingRecap:
            guard let recap = try MeetingRecapQueries.fetch(db, eventID: item.sourceID) else { return nil }
            return .meetingRecap(recap, event: try fetchEvent(db, id: item.sourceID))
        case .dayPlan:
            guard let id = Int64(item.sourceID),
                  let plan = try DayPlan.fetchOne(db, sql: "SELECT * FROM day_plans WHERE id = ?", arguments: [id]) else { return nil }
            return .dayPlan(plan)
        }
    }

    private static func fetchEvent(_ db: Database, id: String) throws -> CalendarEvent? {
        try CalendarEvent.fetchOne(db, sql: "SELECT * FROM calendar_events WHERE id = ?", arguments: [id])
    }

    private static func fetchPrep(_ db: Database, eventID: String) throws -> MeetingPrepResult? {
        guard let json = try String.fetchOne(
                  db, sql: "SELECT result_json FROM meeting_prep_cache WHERE event_id = ?", arguments: [eventID]),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MeetingPrepResult.self, from: data)
    }
}

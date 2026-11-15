import Foundation
import GRDB
import Observation
import os
import WatchtowerKit
import WatchtowerSync

/// One chat as the phone holds it offline: the last feed it decoded and every page under it.
struct ChatHeldCopy: Equatable, Sendable {
    let feed: ChatFeed?
    /// By the message each page comes before.
    let pages: [Int64: ChatPage]
}

/// The phone's own copy of the chat pages it decoded (iPhone chat spec §6.4, D10): its own GRDB file per hub,
/// beside the transport store in the hub's local folder, so it goes with the hub link (`HubPaths.removeHubFiles`);
/// file protection `completeUntilFirstUserAuthentication`. A display copy only: the conversation screen reads it,
/// nothing else does. Kept within `budget` bytes, evicted by chat in order of last opened (a chat only prefetched,
/// never opened, goes first, oldest save first). Also the prefetch's ledger (`prefetched_at`), so the hour per chat
/// holds across relaunches.
final class ChatOfflineCopy: @unchecked Sendable {
    /// 200 MB per hub (D10).
    static let defaultBudget: Int64 = 200 * 1_024 * 1_024
    static let fileName = "chat-copy.sqlite"

    private let queue: DatabaseQueue
    private let budget: Int64
    private let now: @Sendable () -> Date
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "ChatOfflineCopy")

    /// Opens (or creates) the copy at `path`; nil keeps it in memory (the demo, tests).
    init(path: String?, budget: Int64 = defaultBudget, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.budget = budget
        self.now = now
        if let path {
            queue = try DatabaseQueue(path: path)
            try FileProtection.protect(URL(fileURLWithPath: path), as: .completeUntilFirstUserAuthentication)
        } else {
            queue = try DatabaseQueue()
        }
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS chat_copy (
                    conversation_id INTEGER PRIMARY KEY,
                    feed BLOB,
                    feed_bytes INTEGER NOT NULL DEFAULT 0,
                    saved_at REAL NOT NULL,
                    last_opened REAL,
                    prefetched_at REAL
                );
                CREATE TABLE IF NOT EXISTS chat_copy_pages (
                    conversation_id INTEGER NOT NULL,
                    before_id INTEGER NOT NULL,
                    payload BLOB NOT NULL,
                    bytes INTEGER NOT NULL,
                    PRIMARY KEY (conversation_id, before_id)
                );
                """)
        }
    }

    /// An in-memory copy; it cannot fail to open short of memory, which no screen can work without either.
    static func inMemory() -> ChatOfflineCopy {
        do {
            return try ChatOfflineCopy(path: nil)
        } catch {
            preconditionFailure("an in-memory chat copy did not open: \(error)")
        }
    }

    func saveFeed(conversationID: Int64, payload: Data) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO chat_copy (conversation_id, feed, feed_bytes, saved_at) VALUES (?, ?, ?, ?)
                    ON CONFLICT(conversation_id) DO UPDATE SET feed = excluded.feed, feed_bytes = excluded.feed_bytes,
                        saved_at = excluded.saved_at
                    """,
                arguments: [conversationID, payload, payload.count, now().timeIntervalSince1970]
            )
        }
    }

    func savePage(conversationID: Int64, beforeMessageID: Int64, payload: Data) throws {
        try queue.write { db in
            try Self.ensureRow(db, conversationID, at: now())
            try db.execute(
                sql: "INSERT OR REPLACE INTO chat_copy_pages (conversation_id, before_id, payload, bytes) VALUES (?, ?, ?, ?)",
                arguments: [conversationID, beforeMessageID, payload, payload.count]
            )
        }
    }

    /// What the copy holds of a chat; nil when it was never loaded here.
    func held(conversationID: Int64) throws -> ChatHeldCopy? {
        try queue.read { db in
            let feedData = try Data.fetchOne(db, sql: "SELECT feed FROM chat_copy WHERE conversation_id = ?", arguments: [conversationID])
            let rows = try Row.fetchAll(
                db, sql: "SELECT before_id, payload FROM chat_copy_pages WHERE conversation_id = ?", arguments: [conversationID]
            )
            var pages: [Int64: ChatPage] = [:]
            for row in rows {
                if let page = try? ChatPage.decode(payload: row["payload"]) { pages[row["before_id"]] = page }
            }
            let feed = feedData.flatMap { try? ChatFeed.decode(payload: $0) }
            guard feed != nil || !pages.isEmpty else { return nil }
            return ChatHeldCopy(feed: feed, pages: pages)
        }
    }

    func markOpened(conversationID: Int64) throws {
        try queue.write { db in
            try Self.ensureRow(db, conversationID, at: now())
            try db.execute(
                sql: "UPDATE chat_copy SET last_opened = ? WHERE conversation_id = ?", arguments: [now().timeIntervalSince1970, conversationID]
            )
        }
    }

    func markPrefetched(conversationID: Int64, at date: Date) throws {
        try queue.write { db in
            try Self.ensureRow(db, conversationID, at: date)
            try db.execute(
                sql: "UPDATE chat_copy SET prefetched_at = ? WHERE conversation_id = ?", arguments: [date.timeIntervalSince1970, conversationID]
            )
        }
    }

    /// When each chat was last prefetched.
    func prefetchedAt() throws -> [Int64: Date] {
        try queue.read { db in
            var out: [Int64: Date] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT conversation_id, prefetched_at FROM chat_copy WHERE prefetched_at IS NOT NULL") {
                out[row["conversation_id"]] = Date(timeIntervalSince1970: row["prefetched_at"])
            }
            return out
        }
    }

    /// The bytes of every feed and page held.
    func totalBytes() throws -> Int64 {
        try queue.read { db in try Self.total(db) }
    }

    /// Drops whole chats, the longest unopened first, until the copy fits its budget.
    func evict() throws {
        try queue.write { db in
            while try Self.total(db) > budget {
                guard let victim = try Int64.fetchOne(db, sql: """
                    SELECT conversation_id FROM chat_copy
                    WHERE feed IS NOT NULL OR conversation_id IN (SELECT conversation_id FROM chat_copy_pages)
                    ORDER BY last_opened IS NOT NULL, COALESCE(last_opened, saved_at) LIMIT 1
                    """) else { return }
                try db.execute(sql: "DELETE FROM chat_copy_pages WHERE conversation_id = ?", arguments: [victim])
                // The row stays for its prefetch time: an evicted chat is not prefetched again within the hour.
                try db.execute(sql: "UPDATE chat_copy SET feed = NULL, feed_bytes = 0 WHERE conversation_id = ?", arguments: [victim])
                Self.logger.notice("chat copy over budget: dropped one chat")
            }
        }
    }

    private static func total(_ db: Database) throws -> Int64 {
        let feeds = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(feed_bytes), 0) FROM chat_copy") ?? 0
        let pages = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(bytes), 0) FROM chat_copy_pages") ?? 0
        return feeds + pages
    }

    private static func ensureRow(_ db: Database, _ conversationID: Int64, at date: Date) throws {
        try db.execute(
            sql: "INSERT OR IGNORE INTO chat_copy (conversation_id, saved_at) VALUES (?, ?)",
            arguments: [conversationID, date.timeIntervalSince1970]
        )
    }
}

/// The background prefetch of the 20 most recent chats' latest feeds (spec §6.4): while the hub answers and the app
/// is in the foreground, one `chat_feed_request purpose: prefetch` at a time, at most once per chat per hour. A
/// prefetch never counts as the phone looking (the hub's push rule).
@MainActor
@Observable
final class ChatPrefetcher {
    static let recentCount = 20
    static let interval: TimeInterval = 3_600
    /// A request whose feed never came stops holding the line after this long (the hub keeps a prefetch 2 min).
    static let patience: TimeInterval = 120

    /// The chat being prefetched and when its request went.
    private(set) var inFlight: (id: Int64, at: Date)?
    private(set) var foreground = true
    @ObservationIgnored private let sender: ChatSender
    @ObservationIgnored private let copy: ChatOfflineCopy
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var sentAt: [Int64: Date]?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "ChatPrefetcher")

    init(sender: ChatSender, copy: ChatOfflineCopy, now: @escaping @MainActor () -> Date) {
        self.sender = sender
        self.copy = copy
        self.now = now
    }

    /// The next chat to prefetch: the most recent of the 20 newest not prefetched within the hour.
    nonisolated static func next(list: ChatList?, prefetchedAt: [Int64: Date], now: Date) -> Int64? {
        guard let list else { return nil }
        let recent = list.conversations.sorted { $0.updatedAt > $1.updatedAt }.prefix(recentCount)
        return recent.first { conversation in
            guard let last = prefetchedAt[conversation.id] else { return true }
            return now.timeIntervalSince(last) >= interval
        }?.id
    }

    func setForeground(_ foreground: Bool) {
        self.foreground = foreground
    }

    /// The feeds the replica holds now: the one in flight has come.
    func feedsArrived(_ ids: Set<Int64>) {
        if let inFlight, ids.contains(inFlight.id) { self.inFlight = nil }
    }

    /// Sends the next prefetch when nothing is in flight, the hub answers and the app is in the foreground.
    func step(list: ChatList?, online: Bool) {
        guard online, foreground else { return }
        let time = now()
        if let inFlight, time.timeIntervalSince(inFlight.at) < Self.patience { return }
        if sentAt == nil { sentAt = (try? copy.prefetchedAt()) ?? [:] }
        guard let id = Self.next(list: list, prefetchedAt: sentAt ?? [:], now: time) else { return }
        inFlight = (id, time)
        sentAt?[id] = time
        do {
            try copy.markPrefetched(conversationID: id, at: time)
        } catch {
            Self.logger.warning("prefetch time not kept: \(String(describing: type(of: error)), privacy: .public)")
        }
        let sender = sender
        Task {
            do {
                try await sender(ChatFeedRequestParams(conversationID: id, purpose: .prefetch))
            } catch {
                Self.logger.warning("chat prefetch not queued: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }
}

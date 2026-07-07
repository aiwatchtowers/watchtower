import Foundation
import GRDB

// MARK: - Chat (sessions + assembled messages)

extension ReplicaStore {
    /// All chat threads, most recently active first (stable tie-break on id).
    public func chatSessions() throws -> [ChatSession] {
        try writer.read { db in try chatSessions(from: db) }
    }

    /// `chatSessions()` against an ALREADY-OPEN database — for the app's
    /// ValueObservation tracking closures, where a nested `writer.read`
    /// would trap on DatabasePool reentrancy (same rule as
    /// `fetchAll(_:kind:from:)`).
    public func chatSessions(from db: Database) throws -> [ChatSession] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM chat_sessions ORDER BY updated_at DESC, session_id"
        )
        return rows.map(ChatSession.init(row:))
    }

    /// One thread's turns, oldest first. Both rows of a send share their
    /// created_at, so the user turn sorts before the assistant reply it
    /// prompted via the role tie-break.
    public func chatMessages(inSession sessionID: String) throws -> [ChatMessage] {
        try writer.read { db in try chatMessages(inSession: sessionID, from: db) }
    }

    /// `chatMessages(inSession:)` against an ALREADY-OPEN database — for
    /// ValueObservation tracking closures (see `chatSessions(from:)`).
    public func chatMessages(inSession sessionID: String, from db: Database) throws -> [ChatMessage] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM chat_messages WHERE session_id = ?
                ORDER BY created_at, CASE role WHEN 'user' THEN 0 ELSE 1 END, message_id
                """,
            arguments: [sessionID]
        )
        return rows.map(ChatMessage.init(row:))
    }

    /// Flips one session's per-conversation direct-API opt-in (Plan 5
    /// Decision 7). Written ONLY on an explicit user choice — the confirm
    /// dialog's "Answer directly" or the toolbar's "Back to Mac relay" —
    /// never programmatically: the backend switch must never be silent.
    /// An unknown sessionID is a no-op (UPDATE matches zero rows); the flag
    /// write must never mint a session.
    public func setDirectMode(sessionID: String, enabled: Bool) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE chat_sessions SET direct_mode = ? WHERE session_id = ?",
                arguments: [enabled, sessionID]
            )
        }
    }

    /// ChatAssembler.send's local persistence (internal: the app sends
    /// through the assembler). One transaction: session upsert (the FIRST
    /// turn sets the title, later turns only bump updated_at), the user turn
    /// (born complete), and the empty assistant placeholder that chunks
    /// keyed by `assistantMessageID` will fill.
    func insertChatTurn(
        sessionID: String,
        title: String,
        userMessageID: String,
        assistantMessageID: String,
        text: String,
        createdAt: Date
    ) throws {
        try writer.write { db in
            let timestamp = createdAt.timeIntervalSince1970
            try db.execute(
                sql: """
                    INSERT INTO chat_sessions (session_id, title, created_at, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(session_id) DO UPDATE SET updated_at = excluded.updated_at
                    """,
                arguments: [sessionID, title, timestamp, timestamp]
            )
            try db.execute(
                sql: """
                    INSERT INTO chat_messages (message_id, session_id, role, text, is_complete, created_at)
                    VALUES (?, ?, 'user', ?, 1, ?), (?, ?, 'assistant', '', 0, ?)
                    """,
                arguments: [
                    userMessageID, sessionID, text, timestamp,
                    assistantMessageID, sessionID, timestamp
                ]
            )
        }
    }

    /// Outcome of `applyChatChunk` — drives ChatAssembler's gap buffer.
    enum ChatChunkOutcome {
        /// Text appended (the next-in-order seq); more chunks expected.
        case applied
        /// This chunk completed the message (`is_complete` flipped).
        case completed
        /// Duplicate/lower-seq chunk, or the message is already complete.
        case ignored
        /// `seq` skips past `last_seq + 1` — nothing written.
        case gap
        /// No local row for `messageID` — nothing written.
        case unknownMessage
    }

    /// Applies one chunk to its assistant row in a single transaction,
    /// enforcing the frozen assembly contract (Plan 3 notes): per message
    /// ordered by seq, append only the next unseen seq, cut at the FIRST
    /// `done` — everything for that message is ignored afterward, including
    /// stale higher-seq leftovers of a redelivered shorter answer. A done
    /// chunk whose seq was already applied (its text arrived under the old
    /// record version) completes the message WITHOUT appending. `is_error`
    /// is meaningful only on the done chunk. Every branch is idempotent:
    /// RelayFeed replays whole batches after a mid-batch throw.
    func applyChatChunk(
        messageID: String,
        seq: Int,
        text: String,
        done: Bool,
        isError: Bool,
        receivedAt: Date
    ) throws -> ChatChunkOutcome {
        try writer.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT session_id, is_complete, last_seq FROM chat_messages WHERE message_id = ?",
                arguments: [messageID]
            ) else { return .unknownMessage }
            if row["is_complete"] as Bool { return .ignored }
            let lastSeq: Int = row["last_seq"]
            if seq <= lastSeq, !done { return .ignored }
            if seq > lastSeq + 1 { return .gap }
            try db.execute(
                sql: """
                    UPDATE chat_messages
                    SET text = text || ?, last_seq = max(last_seq, ?), is_complete = ?, is_error = ?
                    WHERE message_id = ?
                    """,
                arguments: [seq == lastSeq + 1 ? text : "", seq, done, done && isError, messageID]
            )
            try db.execute(
                sql: "UPDATE chat_sessions SET updated_at = ? WHERE session_id = ?",
                arguments: [receivedAt.timeIntervalSince1970, row["session_id"] as String]
            )
            return done ? .completed : .applied
        }
    }

    /// True while the assistant row exists, is incomplete, and no chunk has
    /// been applied yet — `ChatAssembler.firstChunkPending`'s read. A
    /// missing row reads false: an unknown message is not "waiting".
    func chatMessageAwaitingFirstChunk(_ messageID: String) throws -> Bool {
        try writer.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT is_complete = 0 AND last_seq < 0 FROM chat_messages WHERE message_id = ?",
                arguments: [messageID]
            ) ?? false
        }
    }
}

/// One chat thread header (the local chat replica, written by ChatAssembler).
public struct ChatSession: Equatable, Identifiable {
    /// The wire sessionID.
    public let id: String
    /// First words of the opening message; never rewritten afterward.
    public let title: String
    public let createdAt: Date
    /// Bumped by every turn and applied chunk — the sessions list sorts on it.
    public let updatedAt: Date
    /// Per-conversation direct-API opt-in (Plan 5 Decision 7): true routes
    /// this thread's sends through the on-device agent instead of the Mac
    /// relay. Defaults to false — relay — and flips ONLY via
    /// `setDirectMode(sessionID:enabled:)` on an explicit user choice.
    public let directMode: Bool

    init(row: Row) {
        id = row["session_id"]
        title = row["title"]
        createdAt = Date(timeIntervalSince1970: row["created_at"])
        updatedAt = Date(timeIntervalSince1970: row["updated_at"])
        directMode = row["direct_mode"]
    }
}

/// One turn of a chat thread. Assistant rows stream in via ChatAssembler —
/// text grows chunk by chunk until `isComplete`.
public struct ChatMessage: Equatable, Identifiable {
    public enum Role: String {
        case user
        case assistant
    }

    /// Assistant rows: the wire messageID chunks are keyed by. User rows use
    /// a disjoint "user-"-prefixed id (see ChatAssembler.send).
    public let id: String
    public let sessionID: String
    public let role: Role
    /// True only after an error-path final chunk (stream failure, watchdog
    /// timeout on the desktop).
    public let isError: Bool
    /// User turns are born complete; assistant rows flip at the first done
    /// chunk (the assembly cut).
    public let isComplete: Bool
    public let text: String
    public let createdAt: Date
    /// Highest applied chunk seq; -1 before the first chunk. Assembly
    /// plumbing, deliberately not public.
    let lastSeq: Int

    init(row: Row) {
        id = row["message_id"]
        sessionID = row["session_id"]
        // role is CHECK-constrained to the two rawValues; the fallback is
        // unreachable.
        role = Role(rawValue: row["role"]) ?? .assistant
        isError = row["is_error"]
        isComplete = row["is_complete"]
        text = row["text"]
        createdAt = Date(timeIntervalSince1970: row["created_at"])
        lastSeq = row["last_seq"]
    }
}

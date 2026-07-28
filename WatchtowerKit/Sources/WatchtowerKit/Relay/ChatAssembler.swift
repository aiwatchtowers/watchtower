import Foundation
import os

/// Where `ChatAssembler.send` ships the user turn after persisting it.
public enum SendRoute: Sendable {
    /// Save a `ChatMessagePayload` into the relay zone for the desktop to
    /// answer (the default — today's path).
    case relay
    /// No transport write at all: the turn exists only in the local replica.
    /// The Plan 5 direct BYOK agent answers it on-device by synthesizing
    /// chunks into `ingest`, so an offline phone must be able to send.
    case localOnly
}

/// Pre-flight failures of `ChatAssembler.send`, thrown before any side
/// effect on either route.
public enum ChatSendError: Error, Equatable {
    /// The text was empty after trimming whitespace and newlines. The UI's
    /// `canSend` disables the button for this input; the Kit guard is the
    /// authoritative check (Plan 5 Design Decision 2).
    case emptyText
}

extension ChatSendError: LocalizedError {
    /// Every error a chat backend can surface renders readable copy
    /// (Plan 5 Task 5 obligation).
    public var errorDescription: String? {
        switch self {
        case .emptyText: "Message text is empty"
        }
    }
}

/// The phone's chat endpoint: sends user turns into the relay zone (or, on
/// `SendRoute.localOnly`, persists them for the on-device agent to answer)
/// and assembles the answerer's streamed chunks into `chat_messages` rows
/// (Plan 4 Task 5). Conforms to `ChatChunkAssembling`, so RelayFeed — the
/// phone's single relay consumer — hands every decodable chunk here, in
/// batch order, BEFORE the relay token is persisted.
///
/// Assembly contract (Plan 3 notes, frozen): per messageID ordered by seq,
/// append only the next unseen seq, cut at the FIRST `done: true`, ignore
/// everything for that messageID afterward — including stale higher-seq
/// leftovers from a redelivered shorter answer. `ingest` is idempotent per
/// chunk because a mid-batch throw makes RelayFeed replay the whole batch.
///
/// Gap policy: a chunk that skips past `last_seq + 1` is BUFFERED in memory
/// (per messageID) and applied once the missing seq lands, then the buffer
/// drains in seq order. Gaps are unreachable from the shipped desktop (it
/// advances seq only after a successful save, and batches deliver in
/// first-seen save order), so the buffer is defense in depth: it preserves
/// text integrity without ever wedging the feed (throwing to force a replay
/// could wedge it forever if the missing record never appears). A gap that
/// never fills leaves the message incomplete — surfaced to the user by the
/// `firstChunkPending`/`unreachableAfter` waiting UI, never as mangled text.
/// The buffer is lost on relaunch; the batch it came from was consumed, so
/// such chunks are gone — same incomplete-message outcome.
///
/// PII note: chat text and session titles must never reach os.Logger — log
/// lines here carry ids and seq numbers only.
public actor ChatAssembler: ChatChunkAssembling {
    /// "No first chunk yet — is the desktop reachable?" threshold for the
    /// chat UI. The spec's 20 s is too tight for the shipped desktop cadence
    /// (30 s idle relay poll + stream start + CK propagation); Plan 3 notes
    /// fix it at ≥ 45 s until push entitlements land.
    public static let unreachableAfter: Duration = .seconds(45)

    /// Session titles show this many leading words of the opening message.
    private static let titleWordCount = 6

    private let transport: any CloudSyncTransport
    private let store: ReplicaStore
    private let now: @Sendable () -> Date
    /// Out-of-order chunks per messageID, waiting for their gap to fill.
    /// Cleared on completion; entries for messages that never complete stay
    /// until relaunch (bounded by what the desktop actually streamed).
    private var buffered: [String: [Int: ChatChunkPayload]] = [:]
    private let logger = Logger(subsystem: "WatchtowerKit", category: "ChatAssembler")

    public init(
        transport: any CloudSyncTransport,
        store: ReplicaStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.store = store
        self.now = now
    }

    // MARK: - Outgoing turns

    /// Ships one user turn and prepares the thread for the streamed reply:
    /// session row on the first message (title = first words), the user
    /// message (complete), a `ChatMessagePayload` into the relay zone
    /// (`.relay` route only), and the assistant placeholder row the chunks
    /// will fill. Returns the ids the UI tracks — `messageID` is the
    /// assistant reply's id (the answerer streams chunks keyed by the wire
    /// message id; the user turn's local row uses a disjoint "user-" prefix).
    ///
    /// Trimmed-empty text throws `ChatSendError.emptyText` before ANY side
    /// effect, on both routes.
    ///
    /// `.relay` ordering: transport save FIRST, local rows second
    /// (ActionOutbox's reasoning). A transport throw persists nothing — no
    /// phantom thread awaiting an answer that can never come — and the typed
    /// text is not lost: send() threw, so the compose field must keep its
    /// draft (Task 7 clears it only on success). The reverse failure (record
    /// saved, local write throws) means the desktop answers a thread this
    /// device never wrote down; those chunks hit no local row and are
    /// dropped by `ingest` — the user re-sends, at worst reading a duplicate
    /// answer's cost on the desktop, never corrupted local state.
    ///
    /// `.localOnly` has no wire leg, so none of that ordering applies: the
    /// single `insertChatTurn` call is the only failure point, and it
    /// throws atomically (all three rows or none).
    public func send(
        text: String,
        sessionID: String?,
        route: SendRoute = .relay
    ) async throws -> (sessionID: String, messageID: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatSendError.emptyText
        }
        let createdAt = now()
        let session = sessionID ?? UUID().uuidString
        let payload = ChatMessagePayload(
            id: UUID().uuidString,
            sessionID: session,
            text: text,
            createdAt: createdAt
        )
        if route == .relay {
            try await transport.save([try CloudRecordFactory.record(for: payload, modifiedAt: createdAt)])
        }
        try store.insertChatTurn(
            sessionID: session,
            title: Self.title(from: text),
            userMessageID: "user-\(payload.id)",
            assistantMessageID: payload.id,
            text: text,
            createdAt: createdAt
        )
        return (sessionID: session, messageID: payload.id)
    }

    // MARK: - Incoming chunks (ChatChunkAssembling)

    /// Applies one chunk per the frozen contract (see the type doc). Called
    /// by RelayFeed for every decodable chunk; a throw (store write failure)
    /// aborts the relay cycle with the token untouched, so the batch replays
    /// — every path below is idempotent against that replay.
    public func ingest(_ chunk: ChatChunkPayload) async throws {
        switch try apply(chunk) {
        case .applied:
            try drainBuffered(for: chunk.messageID)
        case .completed:
            // The cut: anything still buffered above the first done is the
            // redelivery contract's "stale higher-seq leftovers" — discard.
            buffered[chunk.messageID] = nil
        case .gap:
            buffered[chunk.messageID, default: [:]][chunk.seq] = chunk
        case .ignored:
            break
        case .unknownMessage:
            // Fresh install, or send()'s local write failed after the wire
            // save: there is no thread to attach this answer to. Dropped —
            // ids only, never chunk text (PII).
            logger.warning(
                "chat chunk for unknown message dropped: \(chunk.messageID, privacy: .public) seq \(chunk.seq)"
            )
        }
    }

    /// Waiting-state read for the chat UI: true while the reply row exists
    /// with no chunk applied yet. Pair with `unreachableAfter` for the
    /// "still nothing — is your Mac on?" hint. A read error flattens to
    /// false (cannot prove we are waiting), matching isDesktopReachable's
    /// conservative flattening.
    public func firstChunkPending(messageID: String) -> Bool {
        (try? store.chatMessageAwaitingFirstChunk(messageID)) ?? false
    }

    // MARK: - Internals

    private func apply(_ chunk: ChatChunkPayload) throws -> ReplicaStore.ChatChunkOutcome {
        try store.applyChatChunk(
            messageID: chunk.messageID,
            seq: chunk.seq,
            text: chunk.text,
            done: chunk.done,
            // Pre-flag desktop versions omit the field: nil → not an error.
            isError: chunk.isError ?? false,
            receivedAt: now()
        )
    }

    /// Replays buffered chunks in seq order until the buffer empties, a gap
    /// remains, or a done chunk completes the message (dropping the rest).
    private func drainBuffered(for messageID: String) throws {
        while let seq = buffered[messageID]?.keys.min(),
              let next = buffered[messageID]?[seq] {
            switch try apply(next) {
            case .completed:
                buffered[messageID] = nil
                return
            case .gap:
                return
            // .unknownMessage is unreachable here today: the message row
            // existed when the chunk was buffered and rows are never deleted.
            // If a deletion feature ever lands, buffered chunks would be
            // silently discarded on this arm — log it then.
            case .applied, .ignored, .unknownMessage:
                buffered[messageID]?[seq] = nil
                if buffered[messageID]?.isEmpty == true {
                    buffered[messageID] = nil
                }
            }
        }
    }

    /// First `titleWordCount` words of the opening message, with an ellipsis
    /// when truncated.
    private static func title(from text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        let title = words.prefix(titleWordCount).joined(separator: " ")
        return words.count > titleWordCount ? title + "…" : title
    }
}

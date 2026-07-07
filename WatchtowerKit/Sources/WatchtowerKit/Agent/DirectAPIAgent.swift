import Foundation
import os

/// Failures of `DirectAPIAgent`.
public enum DirectAPIAgentError: Error, Equatable {
    /// `apiKey()` returned nil or empty — thrown by `sendTurn` BEFORE any
    /// rows are created (the UI should prevent this; the Kit guards).
    case missingKey
    /// The SSE stream ended without a `.finished` event. A cut-off answer is
    /// an ERROR turn, never a silently-completed one.
    case streamEndedPrematurely
}

extension DirectAPIAgentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingKey: "No API key set — add one in Settings"
        case .streamEndedPrematurely: "The answer stream ended unexpectedly — try again"
        }
    }
}

/// The BYOK answer loop (Plan 5): when the Mac is unreachable and the user
/// opted in, the phone answers its own chat turns against `api.anthropic.com`
/// using the user's key.
///
/// `sendTurn` persists the turn via `ChatAssembler.send(route: .localOnly)`
/// (no wire leg — an offline phone must be able to send), then spawns an
/// answer task that streams the model's response and synthesizes
/// `ChatChunkPayload`s through the public `assembler.ingest` — EXACTLY the
/// desktop producer's shape (seq from 0, monotonic, final chunk `done: true`,
/// `isError` on failure), so the frozen assembly contract, persistence, and
/// the observing UI work unchanged (Design Decision 3). This agent never
/// writes chat tables itself.
///
/// Answer tasks are SERIALIZED per session (RelayFeed's inFlight discipline,
/// keyed by session): actors are reentrant, so a second `sendTurn` while an
/// answer is streaming would otherwise open a second API stream whose history
/// misses the first answer. Each turn's task awaits its predecessor.
///
/// Failure contract: EVERY failure path ends with a `done: true,
/// isError: true` chunk carrying a readable, key-free message — the
/// placeholder row must never stay incomplete forever.
///
/// PII: chat text and the API key never reach os.Logger — log lines carry
/// ids, seq counts, and error case labels only.
public actor DirectAPIAgent: MobileAgentBackend {
    /// Decision 8 cap: history carries the last 20 completed non-error turns.
    private static let historyCap = 20
    /// Tool rounds before the loop forces one final NO-tools call.
    private static let maxToolIterations = 8
    /// Minimum spacing between non-final chunk flushes — the desktop
    /// RelayProcessor's chunkInterval idea, tightened because there is no
    /// CloudKit hop to amortize.
    private static let flushInterval: TimeInterval = 0.25

    private let assembler: ChatAssembler
    private let store: ReplicaStore
    private let toolbox: ReplicaToolbox
    private let apiKey: @Sendable () -> String?
    private let model: @Sendable () -> AgentModel
    private let clientFactory: @Sendable (String) -> any AnthropicStreaming
    /// Injected clock for the flush cadence — tests script it; production
    /// reads the wall clock.
    private let now: @Sendable () -> Date
    /// Per-session answer chains (see the type doc). Entries are removed when
    /// their task finishes; a task superseded by a newer chain entry is
    /// cleaned up by the identity check in `clearChain`.
    private var chains: [String: Task<Void, Never>] = [:]
    private let logger = Logger(subsystem: "WatchtowerKit", category: "DirectAPIAgent")

    public init(
        assembler: ChatAssembler,
        store: ReplicaStore,
        toolbox: ReplicaToolbox,
        apiKey: @escaping @Sendable () -> String?,
        model: @escaping @Sendable () -> AgentModel,
        clientFactory: @escaping @Sendable (String) -> any AnthropicStreaming = { AnthropicClient(apiKey: $0) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.assembler = assembler
        self.store = store
        self.toolbox = toolbox
        self.apiKey = apiKey
        self.model = model
        self.clientFactory = clientFactory
        self.now = now
    }

    // MARK: - MobileAgentBackend

    /// Persists the turn locally and schedules the answer. Throws
    /// `DirectAPIAgentError.missingKey` BEFORE any side effect when no key is
    /// configured; the key is captured here, so removing it in Settings never
    /// strands an in-flight answer.
    public func sendTurn(text: String, sessionID: String?) async throws -> (sessionID: String, messageID: String) {
        guard let key = apiKey(), !key.isEmpty else {
            throw DirectAPIAgentError.missingKey
        }
        let ids = try await assembler.send(text: text, sessionID: sessionID, route: .localOnly)
        scheduleAnswer(sessionID: ids.sessionID, messageID: ids.messageID, key: key)
        return ids
    }

    // MARK: - Answer scheduling

    private func scheduleAnswer(sessionID: String, messageID: String, key: String) {
        let prior = chains[sessionID]
        let task = Task { [weak self] in
            // Serialize per session: this turn's history must include the
            // previous turn's completed answer, and two streams for one
            // session must never interleave.
            await prior?.value
            await self?.answer(sessionID: sessionID, messageID: messageID, key: key)
        }
        chains[sessionID] = task
        Task { [weak self] in
            await task.value
            await self?.clearChain(sessionID: sessionID, task: task)
        }
    }

    private func clearChain(sessionID: String, task: Task<Void, Never>) {
        if chains[sessionID] == task {
            chains[sessionID] = nil
        }
    }

    /// Test seam: awaits every answer task currently chained for the session
    /// (including ones scheduled while draining).
    func drainAnswers(inSession sessionID: String) async {
        while let task = chains[sessionID] {
            await task.value
            // Cleanup may not have run yet; if no NEWER task replaced this
            // one, everything scheduled so far has finished.
            if chains[sessionID] == task { break }
        }
    }

    // MARK: - Answer loop

    /// Chunk-flush state for one answer: `seq` is monotonic from 0 across the
    /// whole turn (tool rounds included), `buffer` holds unflushed text.
    private struct ChunkCursor {
        var seq = 0
        var buffer = ""
        var lastFlush: Date
    }

    private enum TurnOutcome {
        case completed
        /// `stop_reason == "tool_use"` with at least one collected call.
        case toolUse([ToolCall])
    }

    private struct ToolCall {
        let id: String
        let name: String
        /// The assembled `input_json_delta` bytes, handed to the toolbox.
        let inputData: Data
        /// The same input re-parsed, for the assistant `tool_use` block.
        let input: WireJSON

        var block: APIContentBlock { .toolUse(id: id, name: name, input: input) }
    }

    private func answer(sessionID: String, messageID: String, key: String) async {
        let client = clientFactory(key)
        var cursor = ChunkCursor(lastFlush: now())
        do {
            var convo = try history(inSession: sessionID, excludingPlaceholder: messageID)
            let system = MobileSystemPrompt.build()
            var iteration = 0
            while true {
                let request = AnthropicRequest(
                    model: model(),
                    system: system,
                    messages: convo,
                    // After the cap, one final call WITHOUT tools forces the
                    // model to answer with what it has.
                    tools: iteration < Self.maxToolIterations ? toolbox.tools : []
                )
                let outcome = try await streamOnce(
                    client: client, request: request, cursor: &cursor,
                    sessionID: sessionID, messageID: messageID
                )
                switch outcome {
                case .completed:
                    try await completeTurn(cursor, sessionID: sessionID, messageID: messageID)
                    return
                case let .toolUse(calls) where iteration < Self.maxToolIterations:
                    convo.append(APIMessage(role: .assistant, content: calls.map(\.block)))
                    convo.append(APIMessage(role: .user, content: await execute(calls, messageID: messageID)))
                    iteration += 1
                case .toolUse:
                    // Unreachable: the final iteration ships no tools, so the
                    // model cannot request one. Belt: end the turn cleanly.
                    try await completeTurn(cursor, sessionID: sessionID, messageID: messageID)
                    return
                }
            }
        } catch {
            await ingestFailure(error, cursor: cursor, sessionID: sessionID, messageID: messageID)
        }
    }

    /// One `streamMessage` call: text deltas buffered and flushed on the
    /// cadence, tool input JSON accumulated between started/finished markers.
    /// A stream that ends without `.finished` throws — that turn is an ERROR.
    private func streamOnce(
        client: any AnthropicStreaming,
        request: AnthropicRequest,
        cursor: inout ChunkCursor,
        sessionID: String,
        messageID: String
    ) async throws -> TurnOutcome {
        var calls: [ToolCall] = []
        var openTool: (id: String, name: String, json: String)?
        for try await event in client.streamMessage(request: request) {
            switch event {
            case let .textDelta(delta):
                cursor.buffer += delta
                try await flushIfDue(&cursor, sessionID: sessionID, messageID: messageID)
            case let .toolUseStarted(id, name):
                openTool = (id: id, name: name, json: "")
            case let .toolInputDelta(partial):
                openTool?.json += partial
            case .toolUseFinished:
                if let tool = openTool {
                    calls.append(try Self.toolCall(from: tool))
                    openTool = nil
                }
            case let .finished(stopReason):
                if stopReason == "tool_use", !calls.isEmpty {
                    return .toolUse(calls)
                }
                // end_turn, max_tokens, stop_sequence, or a tool_use claim
                // with nothing collected: the answer is what streamed.
                return .completed
            }
        }
        throw DirectAPIAgentError.streamEndedPrematurely
    }

    private func flushIfDue(_ cursor: inout ChunkCursor, sessionID: String, messageID: String) async throws {
        let stamp = now()
        guard !cursor.buffer.isEmpty, stamp.timeIntervalSince(cursor.lastFlush) >= Self.flushInterval else { return }
        try await assembler.ingest(ChatChunkPayload(
            sessionID: sessionID, messageID: messageID,
            seq: cursor.seq, text: cursor.buffer, done: false
        ))
        cursor.seq += 1
        cursor.buffer = ""
        cursor.lastFlush = stamp
    }

    /// Flushes whatever text remains as the final `done: true` chunk — the
    /// assembly cut that completes the placeholder row.
    private func completeTurn(_ cursor: ChunkCursor, sessionID: String, messageID: String) async throws {
        try await assembler.ingest(ChatChunkPayload(
            sessionID: sessionID, messageID: messageID,
            seq: cursor.seq, text: cursor.buffer, done: true
        ))
        logger.info("direct answer completed: \(messageID, privacy: .public) chunks \(cursor.seq + 1)")
    }

    /// Executes collected tool calls sequentially (Design Decision 4) and
    /// returns the blocks of the ONE user message that answers them all.
    private func execute(_ calls: [ToolCall], messageID: String) async -> [APIContentBlock] {
        var results: [APIContentBlock] = []
        for call in calls {
            logger.info("tool round: \(call.name, privacy: .public) for \(messageID, privacy: .public)")
            let output = await toolbox.execute(name: call.name, inputJSON: call.inputData)
            results.append(.toolResult(toolUseID: call.id, content: output))
        }
        return results
    }

    /// Decision 8: completed non-error turns of the session, oldest first,
    /// capped at the last 20 messages. Incomplete rows (including the
    /// just-created placeholder, excluded by id as belt) and error rows are
    /// skipped; so are empty completed rows — the API rejects empty text
    /// blocks.
    private func history(inSession sessionID: String, excludingPlaceholder placeholderID: String) throws -> [APIMessage] {
        let turns = try store.chatMessages(inSession: sessionID)
            .filter { $0.isComplete && !$0.isError && $0.id != placeholderID && !$0.text.isEmpty }
            .suffix(Self.historyCap)
        return turns.map {
            APIMessage(role: $0.role == .user ? .user : .assistant, content: [.text($0.text)])
        }
    }

    // MARK: - Failure path

    /// EVERY failure ends here: the placeholder is completed with a
    /// `done: true, isError: true` chunk whose text is unflushed partial
    /// answer (if any) plus a readable message. The copy comes from the
    /// errors' `LocalizedError` conformances — `.http` renders the server
    /// body, and no case can carry the API key.
    private func ingestFailure(_ error: Error, cursor: ChunkCursor, sessionID: String, messageID: String) async {
        logger.error(
            "direct answer failed: \(messageID, privacy: .public) \(Self.logLabel(for: error), privacy: .public)"
        )
        let separator = cursor.buffer.isEmpty && cursor.seq == 0 ? "" : "\n\n"
        let chunk = ChatChunkPayload(
            sessionID: sessionID, messageID: messageID,
            seq: cursor.seq, text: cursor.buffer + separator + error.localizedDescription,
            done: true, isError: true
        )
        do {
            try await assembler.ingest(chunk)
        } catch {
            // The one gap in the never-incomplete guarantee: the store write
            // itself failed. Nothing left to write with — ids only (PII).
            logger.error("error chunk ingest failed: \(messageID, privacy: .public)")
        }
    }

    /// Key-free, text-free label for os.Logger.
    private static func logLabel(for error: Error) -> String {
        switch error {
        case AnthropicClientError.invalidKey: "invalidKey"
        case AnthropicClientError.overloaded: "overloaded"
        case AnthropicClientError.rateLimited: "rateLimited"
        case let AnthropicClientError.http(status, _): "http(\(status))"
        case AnthropicClientError.cancelled: "cancelled"
        case DirectAPIAgentError.streamEndedPrematurely: "streamEndedPrematurely"
        default: String(describing: type(of: error))
        }
    }

    private static func toolCall(from tool: (id: String, name: String, json: String)) throws -> ToolCall {
        // Empty accumulation is a no-argument call — {} on the wire.
        let data = Data((tool.json.isEmpty ? "{}" : tool.json).utf8)
        // The API guarantees complete JSON by content_block_stop; a parse
        // failure here is a malformed stream and fails the turn.
        let input = try JSONDecoder().decode(WireJSON.self, from: data)
        return ToolCall(id: tool.id, name: tool.name, inputData: data, input: input)
    }
}

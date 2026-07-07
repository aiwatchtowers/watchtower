import os
import XCTest
@testable import WatchtowerKit

/// DirectAPIAgent — the BYOK answer loop (Plan 5 Task 5). Pinned here:
/// - `sendTurn` throws `missingKey` BEFORE any rows exist (nil AND empty key);
/// - synthesized chunks flow through `ChatAssembler.ingest` with monotonic
///   seq from 0, flushed on the ≥250 ms cadence, final chunk `done: true`;
/// - the tool loop assembles split `input_json` deltas, executes via
///   ReplicaToolbox, and call N+1 carries the assistant `tool_use` blocks
///   exactly as received plus ONE user message with all `tool_result`s;
/// - EVERY failure path (API error, premature stream end) completes the
///   placeholder with a `done: true, isError: true` chunk whose text is
///   readable and never contains the API key;
/// - history per Decision 8: completed non-error turns, oldest first, capped
///   at 20, incomplete/error rows skipped, own placeholder excluded — then
///   NORMALIZED for the Messages API alternation rules (owner-approved
///   Decision 8 deviation): consecutive same-role entries coalesce, a
///   leading assistant entry is dropped;
/// - history is snapshotted at send: a queued turn's user row never leaks
///   into an earlier turn's request;
/// - answers for one session are serialized (no interleaved chunk streams).
final class DirectAPIAgentTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_720_000_000)
    private static let testKey = "sk-ant-test-key-123"

    // MARK: - Test doubles

    /// Mutable test clock for the assembler (row timestamps must be distinct
    /// across turns so chat ordering is deterministic).
    private final class Clock: @unchecked Sendable {
        private let state: OSAllocatedUnfairLock<Date>
        init(_ start: Date) { state = OSAllocatedUnfairLock(initialState: start) }
        func now() -> Date { state.withLock { $0 } }
        func advance(by seconds: TimeInterval) {
            state.withLock { $0 = $0.addingTimeInterval(seconds) }
        }
    }

    /// Auto-advancing clock for the agent's flush cadence: every `now()` read
    /// steps forward, so `step` ≥ the flush interval flushes on every text
    /// delta and `step` 0 never flushes mid-stream.
    private final class SteppingClock: @unchecked Sendable {
        private let state: OSAllocatedUnfairLock<Date>
        private let step: TimeInterval
        init(start: Date, step: TimeInterval) {
            state = OSAllocatedUnfairLock(initialState: start)
            self.step = step
        }
        func now() -> Date {
            state.withLock { current in
                current = current.addingTimeInterval(step)
                return current
            }
        }
    }

    /// Reusable one-shot gate: `wait()` suspends until `open()`.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            let resumable: [CheckedContinuation<Void, Never>] = lock.withLock {
                isOpen = true
                defer { waiters = [] }
                return waiters
            }
            for waiter in resumable { waiter.resume() }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let alreadyOpen: Bool = lock.withLock {
                    if !isOpen { waiters.append(continuation) }
                    return isOpen
                }
                if alreadyOpen { continuation.resume() }
            }
        }
    }

    private enum ScriptStep {
        case yield(AnthropicEvent)
        case failure(Error)
        case wait(Gate)
    }

    /// Scripted `AnthropicStreaming` fake: records every request, replays one
    /// event script per `streamMessage` call. No network anywhere.
    private final class ScriptedClient: AnthropicStreaming, @unchecked Sendable {
        private let lock = NSLock()
        private var scripts: [[ScriptStep]]
        private var recorded: [AnthropicRequest] = []

        init(scripts: [[ScriptStep]]) { self.scripts = scripts }

        var requests: [AnthropicRequest] { lock.withLock { recorded } }

        func streamMessage(request: AnthropicRequest) -> AsyncThrowingStream<AnthropicEvent, Error> {
            let script: [ScriptStep] = lock.withLock {
                recorded.append(request)
                return scripts.isEmpty ? [] : scripts.removeFirst()
            }
            return AsyncThrowingStream { continuation in
                Task {
                    for step in script {
                        switch step {
                        case let .yield(event):
                            continuation.yield(event)
                        case let .failure(error):
                            continuation.finish(throwing: error)
                            return
                        case let .wait(gate):
                            await gate.wait()
                        }
                    }
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Fixtures

    private struct Fixtures {
        let transport: InMemoryCloudTransport
        let store: ReplicaStore
        let assembler: ChatAssembler
        let assemblerClock: Clock
        let client: ScriptedClient
        let factoryKeys: OSAllocatedUnfairLock<[String]>
        let agent: DirectAPIAgent
    }

    private func makeFixtures(
        key: String? = DirectAPIAgentTests.testKey,
        model: AgentModel = .sonnet5,
        step: TimeInterval = 0.3,
        scripts: [[ScriptStep]]
    ) throws -> Fixtures {
        let transport = InMemoryCloudTransport()
        let store = try ReplicaStore.inMemory()
        let assemblerClock = Clock(base)
        let assembler = ChatAssembler(transport: transport, store: store) { assemblerClock.now() }
        let outbox = ActionOutbox(transport: transport, store: store) { self.base }
        let toolbox = ReplicaToolbox(store: store, outbox: outbox) { self.base }
        let client = ScriptedClient(scripts: scripts)
        let agentClock = SteppingClock(start: base, step: step)
        let factoryKeys = OSAllocatedUnfairLock(initialState: [String]())
        let agent = DirectAPIAgent(
            assembler: assembler,
            store: store,
            toolbox: toolbox,
            apiKey: { key },
            model: { model },
            clientFactory: { factoryKey in
                factoryKeys.withLock { $0.append(factoryKey) }
                return client
            },
            now: { agentClock.now() }
        )
        return Fixtures(
            transport: transport,
            store: store,
            assembler: assembler,
            assemblerClock: assemblerClock,
            client: client,
            factoryKeys: factoryKeys,
            agent: agent
        )
    }

    private func message(_ store: ReplicaStore, sessionID: String, id: String) throws -> ChatMessage {
        try XCTUnwrap(store.chatMessages(inSession: sessionID).first { $0.id == id })
    }

    // MARK: - missingKey precondition

    func testMissingKeyThrowsBeforeAnyRows() async throws {
        for key in [String?.none, ""] {
            let f = try makeFixtures(key: key, scripts: [])
            do {
                _ = try await f.agent.sendTurn(text: "hello", sessionID: nil)
                XCTFail("expected missingKey for key \(String(describing: key))")
            } catch DirectAPIAgentError.missingKey {}
            // Thrown BEFORE any side effect: no session, no rows, no client.
            XCTAssertTrue(try f.store.chatSessions().isEmpty)
            XCTAssertTrue(f.factoryKeys.withLock { $0 }.isEmpty)
        }
    }

    // MARK: - Happy path

    func testHappyPathStreamsChunksIntoThread() async throws {
        let f = try makeFixtures(model: .haiku45, scripts: [[
            .yield(.textDelta("Hello ")),
            .yield(.textDelta("world")),
            .yield(.finished(stopReason: "end_turn"))
        ]])

        let (sessionID, messageID) = try await f.agent.sendTurn(text: "greet me", sessionID: nil)
        await f.agent.drainAnswers(inSession: sessionID)

        let reply = try message(f.store, sessionID: sessionID, id: messageID)
        XCTAssertEqual(reply.text, "Hello world")
        XCTAssertTrue(reply.isComplete)
        XCTAssertFalse(reply.isError)
        // 0.3 s stepping clock ≥ the 250 ms cadence: two timed flushes
        // (seq 0, 1) plus the final done chunk (seq 2).
        XCTAssertEqual(reply.lastSeq, 2)

        // Request shape: chosen model, static system prompt, the 12 replica
        // tools, and the single user turn as history.
        let request = try XCTUnwrap(f.client.requests.first)
        XCTAssertEqual(request.model, AgentModel.haiku45.rawValue)
        XCTAssertEqual(request.system, MobileSystemPrompt.build())
        XCTAssertEqual(request.tools.count, 12)
        XCTAssertEqual(request.messages, [APIMessage(role: .user, content: [.text("greet me")])])
        XCTAssertEqual(f.factoryKeys.withLock { $0 }, [Self.testKey])
    }

    func testFrozenClockBuffersAllTextIntoDoneChunk() async throws {
        // step 0: the cadence never fires, so all text rides the done chunk.
        let f = try makeFixtures(step: 0, scripts: [[
            .yield(.textDelta("all ")),
            .yield(.textDelta("at once")),
            .yield(.finished(stopReason: "end_turn"))
        ]])

        let (sessionID, messageID) = try await f.agent.sendTurn(text: "buffer me", sessionID: nil)
        await f.agent.drainAnswers(inSession: sessionID)

        let reply = try message(f.store, sessionID: sessionID, id: messageID)
        XCTAssertEqual(reply.text, "all at once")
        XCTAssertTrue(reply.isComplete)
        XCTAssertEqual(reply.lastSeq, 0)
    }

    // MARK: - Tool loop

    func testToolLoopExecutesAndContinues() async throws {
        let f = try makeFixtures(scripts: [
            [
                .yield(.toolUseStarted(id: "tu-1", name: "get_target")),
                .yield(.toolInputDelta("{\"id\"")),
                .yield(.toolInputDelta(": 7}")),
                .yield(.toolUseFinished),
                .yield(.finished(stopReason: "tool_use"))
            ],
            [
                .yield(.textDelta("No target 7 on the phone.")),
                .yield(.finished(stopReason: "end_turn"))
            ]
        ])

        let (sessionID, messageID) = try await f.agent.sendTurn(text: "look at target 7", sessionID: nil)
        await f.agent.drainAnswers(inSession: sessionID)

        let reply = try message(f.store, sessionID: sessionID, id: messageID)
        XCTAssertEqual(reply.text, "No target 7 on the phone.")
        XCTAssertTrue(reply.isComplete)
        XCTAssertFalse(reply.isError)

        // Call 2 carries the assistant tool_use blocks EXACTLY as received
        // (split input deltas assembled into one JSON object), then ONE user
        // message with the tool_result. Empty replica → get_target is null
        // (the MCP mirror rule), proving the toolbox really ran.
        let requests = f.client.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].messages, [
            APIMessage(role: .user, content: [.text("look at target 7")]),
            APIMessage(role: .assistant, content: [
                .toolUse(id: "tu-1", name: "get_target", input: .object(["id": .int(7)]))
            ]),
            APIMessage(role: .user, content: [.toolResult(toolUseID: "tu-1", content: "null")])
        ])
        // The tool round still ships the tool set (only the post-cap final
        // call goes tool-less).
        XCTAssertEqual(requests[1].tools.count, 12)
    }

    func testWriteToolLandsPendingAction() async throws {
        let f = try makeFixtures(scripts: [
            [
                .yield(.toolUseStarted(id: "tu-w", name: "create_task")),
                .yield(.toolInputDelta(#"{"text": "Buy milk"}"#)),
                .yield(.toolUseFinished),
                .yield(.finished(stopReason: "tool_use"))
            ],
            [
                .yield(.textDelta("Queued the task.")),
                .yield(.finished(stopReason: "end_turn"))
            ]
        ])

        let (sessionID, _) = try await f.agent.sendTurn(text: "task: buy milk", sessionID: nil)
        await f.agent.drainAnswers(inSession: sessionID)

        // The write tool queued through ActionOutbox: pending overlay row.
        let pending = try XCTUnwrap(f.store.pendingActions().first)
        XCTAssertEqual(pending.action.kind, .taskCreate)
        XCTAssertEqual(pending.state, .pending)

        // And the model was told the truth: queued, not applied.
        let secondCall = try XCTUnwrap(f.client.requests.last)
        guard case let .toolResult(toolUseID, content)? = secondCall.messages.last?.content.first else {
            return XCTFail("expected a tool_result block in call 2")
        }
        XCTAssertEqual(toolUseID, "tu-w")
        XCTAssertEqual(content, #"{"note":"will apply when your Mac processes the queue","status":"queued"}"#)
    }

    // MARK: - Failure paths (must always complete the placeholder)

    func testAPIErrorProducesErrorDoneChunk() async throws {
        let f = try makeFixtures(step: 0, scripts: [[
            .yield(.textDelta("partial ")),
            .failure(AnthropicClientError.invalidKey)
        ]])

        let (sessionID, messageID) = try await f.agent.sendTurn(text: "fail me", sessionID: nil)
        await f.agent.drainAnswers(inSession: sessionID)

        let reply = try message(f.store, sessionID: sessionID, id: messageID)
        XCTAssertTrue(reply.isComplete, "the placeholder must never stay incomplete")
        XCTAssertTrue(reply.isError)
        XCTAssertEqual(reply.text, "partial \n\nAPI key rejected — check Settings")
        XCTAssertFalse(reply.text.contains(Self.testKey), "error copy must never leak the API key")
    }

    func testPrematureStreamEndProducesErrorDoneChunk() async throws {
        // The stream ends with NO .finished event — an ERROR turn, never a
        // silently-completed one.
        let f = try makeFixtures(step: 0, scripts: [[.yield(.textDelta("half"))]])

        let (sessionID, messageID) = try await f.agent.sendTurn(text: "cut me off", sessionID: nil)
        await f.agent.drainAnswers(inSession: sessionID)

        let reply = try message(f.store, sessionID: sessionID, id: messageID)
        XCTAssertTrue(reply.isComplete)
        XCTAssertTrue(reply.isError)
        XCTAssertEqual(reply.text, "half\n\nThe answer stream ended unexpectedly — try again")
    }

    func testRateLimitErrorCopy() async throws {
        let f = try makeFixtures(scripts: [[.failure(AnthropicClientError.rateLimited(retryAfter: 30))]])

        let (sessionID, messageID) = try await f.agent.sendTurn(text: "busy", sessionID: nil)
        await f.agent.drainAnswers(inSession: sessionID)

        let reply = try message(f.store, sessionID: sessionID, id: messageID)
        XCTAssertTrue(reply.isError)
        XCTAssertEqual(reply.text, "Anthropic API is busy — try again")
    }

    func testHTTPErrorRendersBodyNotGenericDescription() async throws {
        let f = try makeFixtures(scripts: [[
            .failure(AnthropicClientError.http(status: 400, body: "invalid_request_error: max_tokens too large"))
        ]])

        let (sessionID, messageID) = try await f.agent.sendTurn(text: "bad request", sessionID: nil)
        await f.agent.drainAnswers(inSession: sessionID)

        let reply = try message(f.store, sessionID: sessionID, id: messageID)
        XCTAssertTrue(reply.isError)
        XCTAssertEqual(reply.text, "Anthropic API error (HTTP 400): invalid_request_error: max_tokens too large")
    }

    // MARK: - History (Decision 8, normalized)

    /// Seeds a session exercising every history edge at once: 10 completed
    /// turn pairs (20 messages — the 20-cap then cuts mid-pair, at an
    /// assistant row), one turn whose reply FAILED (error rows are skipped,
    /// orphaning its user turn), and one still-streaming turn (incomplete
    /// rows are skipped, orphaning its user turn too). The RAW eligible list
    /// after the next `sendTurn` would start with an assistant message and
    /// end with three consecutive user turns — both live-API 400 shapes.
    private func seedHistoryEdgeCases(_ f: Fixtures) async throws -> String {
        var sessionID: String?
        for index in 1...10 {
            f.assemblerClock.advance(by: 60)
            let (session, replyID) = try await f.assembler.send(
                text: "question \(index)", sessionID: sessionID, route: .localOnly
            )
            sessionID = session
            try await f.assembler.ingest(ChatChunkPayload(
                sessionID: session, messageID: replyID, seq: 0, text: "answer \(index)", done: true
            ))
        }
        let session = try XCTUnwrap(sessionID)
        f.assemblerClock.advance(by: 60)
        let (_, errorID) = try await f.assembler.send(text: "failed question", sessionID: session, route: .localOnly)
        try await f.assembler.ingest(ChatChunkPayload(
            sessionID: session, messageID: errorID, seq: 0, text: "boom", done: true, isError: true
        ))
        f.assemblerClock.advance(by: 60)
        _ = try await f.assembler.send(text: "pending question", sessionID: session, route: .localOnly)
        f.assemblerClock.advance(by: 60)
        return session
    }

    func testHistoryCapAndSkipsIncompleteAndErrorRows() async throws {
        let f = try makeFixtures(scripts: [[
            .yield(.textDelta("ok")),
            .yield(.finished(stopReason: "end_turn"))
        ]])
        let session = try await seedHistoryEdgeCases(f)

        _ = try await f.agent.sendTurn(text: "the new question", sessionID: session)
        await f.agent.drainAnswers(inSession: session)

        // Eligible: 20 pair messages + 2 orphaned user turns + the new user
        // turn = 23 → capped to the LAST 20 (cutting at "answer 2"), then
        // normalized for the API alternation rules: the three trailing
        // consecutive user turns coalesce into ONE message and the leading
        // assistant "answer 2" is dropped → 17 messages, user-first.
        let request = try XCTUnwrap(f.client.requests.first)
        XCTAssertEqual(request.messages.count, 17)
        XCTAssertEqual(request.messages.first, APIMessage(role: .user, content: [.text("question 3")]))
        XCTAssertEqual(request.messages.last, APIMessage(
            role: .user,
            content: [.text("failed question\n\npending question\n\nthe new question")]
        ))
        let blocks = request.messages.flatMap(\.content)
        XCTAssertFalse(blocks.contains(.text("boom")), "error reply must be skipped")
        XCTAssertFalse(blocks.contains(.text("")), "incomplete placeholders must be skipped")
        XCTAssertFalse(blocks.contains(.text("answer 2")), "cap-cut leading assistant entry must be dropped")
    }

    func testHistoryNeverStartsWithAssistantAndAlternatesRoles() async throws {
        let f = try makeFixtures(scripts: [[
            .yield(.textDelta("ok")),
            .yield(.finished(stopReason: "end_turn"))
        ]])
        let session = try await seedHistoryEdgeCases(f)

        _ = try await f.agent.sendTurn(text: "the new question", sessionID: session)
        await f.agent.drainAnswers(inSession: session)

        // The raw eligible list starts at an assistant row (the cap cuts
        // inside pair 2) AND carries adjacent user rows (the error-turn and
        // incomplete-turn skips orphan their user turns next to the new
        // question). The live API rejects both shapes with a 400 — the
        // request that actually went out must be user-first and STRICTLY
        // role-alternating.
        let request = try XCTUnwrap(f.client.requests.first)
        XCTAssertFalse(request.messages.isEmpty)
        for (index, message) in request.messages.enumerated() {
            XCTAssertEqual(
                message.role,
                index.isMultiple(of: 2) ? .user : .assistant,
                "message \(index) breaks user-first strict role alternation"
            )
        }
    }

    // MARK: - Reentrancy

    func testConcurrentSendTurnCoalescesAnswer() async throws {
        let gate = Gate()
        let f = try makeFixtures(scripts: [
            [
                .wait(gate),
                .yield(.textDelta("first answer")),
                .yield(.finished(stopReason: "end_turn"))
            ],
            [
                .yield(.textDelta("second answer")),
                .yield(.finished(stopReason: "end_turn"))
            ]
        ])

        let (sessionID, firstID) = try await f.agent.sendTurn(text: "first question", sessionID: nil)
        f.assemblerClock.advance(by: 60)
        let (_, secondID) = try await f.agent.sendTurn(text: "second question", sessionID: sessionID)
        gate.open()
        await f.agent.drainAnswers(inSession: sessionID)

        let first = try message(f.store, sessionID: sessionID, id: firstID)
        XCTAssertEqual(first.text, "first answer")
        XCTAssertTrue(first.isComplete)
        XCTAssertFalse(first.isError)
        let second = try message(f.store, sessionID: sessionID, id: secondID)
        XCTAssertEqual(second.text, "second answer")
        XCTAssertTrue(second.isComplete)
        XCTAssertFalse(second.isError)

        // Turn 2's history was snapshotted at ITS send — answer 1 was still
        // streaming (held at the gate), so it is absent by design and the
        // two user turns coalesce per the API alternation normalization.
        let requests = f.client.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].messages, [
            APIMessage(role: .user, content: [.text("first question\n\nsecond question")])
        ])
    }

    func testQueuedTurnDoesNotLeakIntoEarlierHistory() async throws {
        let gate = Gate()
        let f = try makeFixtures(scripts: [
            [
                .wait(gate),
                .yield(.textDelta("first answer")),
                .yield(.finished(stopReason: "end_turn"))
            ],
            [
                .yield(.textDelta("second answer")),
                .yield(.finished(stopReason: "end_turn"))
            ]
        ])

        let (sessionID, _) = try await f.agent.sendTurn(text: "first question", sessionID: nil)
        f.assemblerClock.advance(by: 60)
        // Queued while answer 1 is still held open at the gate.
        _ = try await f.agent.sendTurn(text: "second question", sessionID: sessionID)
        gate.open()
        await f.agent.drainAnswers(inSession: sessionID)

        // History snapshots at send: answer 1's request is EXACTLY the
        // thread as it stood when turn 1 was sent. Turn 2's user row must
        // not leak in — that would put consecutive user turns on the wire
        // (a live-API 400) and show the model question 2 while it answers
        // question 1.
        let request = try XCTUnwrap(f.client.requests.first)
        XCTAssertEqual(request.messages, [APIMessage(role: .user, content: [.text("first question")])])
    }

    // MARK: - RelayAgentBackend

    func testRelayAgentBackendSendsThroughRelayRoute() async throws {
        let transport = InMemoryCloudTransport()
        let store = try ReplicaStore.inMemory()
        let assembler = ChatAssembler(transport: transport, store: store)
        let backend = RelayAgentBackend(assembler: assembler)

        let (sessionID, messageID) = try await backend.sendTurn(text: "relay turn", sessionID: nil)

        // The thin wrapper is TODAY's path: the turn ships into the relay
        // zone for the desktop, local rows as usual.
        let batch = try await transport.changes(in: .relay, since: nil)
        XCTAssertEqual(batch.changed.map(\.recordName), ["chatmsg-\(messageID)"])
        XCTAssertEqual(try store.chatMessages(inSession: sessionID).count, 2)
    }

    // MARK: - LocalizedError copy

    func testLocalizedErrorCopy() {
        XCTAssertEqual(AnthropicClientError.invalidKey.localizedDescription, "API key rejected — check Settings")
        XCTAssertEqual(AnthropicClientError.rateLimited(retryAfter: 30).localizedDescription, "Anthropic API is busy — try again")
        XCTAssertEqual(AnthropicClientError.overloaded.localizedDescription, "Anthropic API is busy — try again")
        XCTAssertEqual(
            AnthropicClientError.http(status: 503, body: "upstream unhappy").localizedDescription,
            "Anthropic API error (HTTP 503): upstream unhappy"
        )
        XCTAssertEqual(AnthropicClientError.http(status: 500, body: "").localizedDescription, "Anthropic API error (HTTP 500)")
        XCTAssertEqual(AnthropicClientError.cancelled.localizedDescription, "The request was cancelled")
        XCTAssertEqual(DirectAPIAgentError.missingKey.localizedDescription, "No API key set — add one in Settings")
        XCTAssertEqual(
            DirectAPIAgentError.streamEndedPrematurely.localizedDescription,
            "The answer stream ended unexpectedly — try again"
        )
        XCTAssertEqual(ChatSendError.emptyText.localizedDescription, "Message text is empty")
    }

    // MARK: - System prompt

    func testSystemPromptStatesHonestLimitations() {
        let prompt = MobileSystemPrompt.build()
        // The honesty clauses are load-bearing (Plan 5 Task 5): the phone has
        // no raw Slack messages, quote-level questions need the desktop, and
        // write actions queue until the Mac processes them.
        XCTAssertTrue(prompt.contains("NO raw Slack messages"))
        XCTAssertTrue(prompt.contains("Mac"))
        XCTAssertTrue(prompt.contains("queue"))
        // Summaries-only replica, and the assistant role framing.
        XCTAssertTrue(prompt.contains("summaries"))
        XCTAssertTrue(prompt.contains("Watchtower"))
    }
}

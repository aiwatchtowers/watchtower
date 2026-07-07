import GRDB
import XCTest
@testable import WatchtowerKit

/// URLProtocol stub for the direct loop: serves a QUEUE of canned responses
/// (one per request, in order — the agent's tool rounds make sequential API
/// calls) and records every request body for wire assertions. Unlike
/// `AnthropicStubProtocol`'s single static stub, the queue lets one test
/// script a multi-call conversation.
final class DirectLoopStubProtocol: URLProtocol {
    struct Stub {
        var statusCode: Int
        var headers: [String: String] = [:]
        var body: Data
    }

    private static let lock = NSLock()
    private static var queue: [Stub] = []
    private static var recordedBodies: [Data] = []

    static func script(_ stubs: [Stub]) {
        lock.withLock {
            queue = stubs
            recordedBodies = []
        }
    }

    static var requestBodies: [Data] { lock.withLock { recordedBodies } }

    static func reset() {
        lock.withLock {
            queue = []
            recordedBodies = []
        }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.bodyData(of: request) ?? Data()
        let stub: Stub? = Self.lock.withLock {
            Self.recordedBodies.append(body)
            return Self.queue.isEmpty ? nil : Self.queue.removeFirst()
        }
        guard let stub,
              let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession moves `httpBody` into `httpBodyStream` before the protocol
    /// sees the request — drain the stream to recover the encoded bytes.
    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// THE integration gate for the BYOK fallback (Plan 5 Task 8) — the direct
/// analog of Plan 4's FullLoopTests: the whole offline stack (DirectAPIAgent
/// loop → real AnthropicClient over the wire → ReplicaToolbox → replica →
/// chunk assembly → chat persistence) proven over ONE ReplicaStore +
/// InMemoryCloudTransport, with the network scripted by a URLProtocol stub.
/// Unlike DirectAPIAgentTests' scripted fake client, the REAL wire layer
/// (request encoding, SSE parsing, HTTP error mapping) runs inside the loop.
/// Every test asserts BOTH sides: the bytes that went to (or stayed off) the
/// wire AND the assembled chat thread / overlay rows.
///
/// Scope note: the stub answers instantly and in order; real api.anthropic.com
/// latency, retry-after pacing, and CloudKit propagation are out of scope —
/// per-layer behavior is covered by the per-side suites.
final class DirectLoopTests: XCTestCase {
    private static let testKey = "sk-ant-direct-loop-key"
    /// Matches RelayPayloadTests' frozen fixtures, so the relay pin below can
    /// compare payload bytes against the exact Plan-4 wire shape.
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    override func tearDown() {
        DirectLoopStubProtocol.reset()
        super.tearDown()
    }

    // MARK: - Fixtures

    private struct Fixtures {
        let transport: InMemoryCloudTransport
        let store: ReplicaStore
        let assembler: ChatAssembler
        let agent: DirectAPIAgent
    }

    private func makeFixtures() throws -> Fixtures {
        let transport = InMemoryCloudTransport()
        let store = try ReplicaStore.inMemory()
        let base = base
        let assembler = ChatAssembler(transport: transport, store: store) { base }
        let outbox = ActionOutbox(transport: transport, store: store) { base }
        let toolbox = ReplicaToolbox(store: store, outbox: outbox) { base }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DirectLoopStubProtocol.self]
        let session = URLSession(configuration: config)
        let agent = DirectAPIAgent(
            assembler: assembler,
            store: store,
            toolbox: toolbox,
            apiKey: { Self.testKey },
            model: { .sonnet5 },
            // The REAL client over the stubbed session — the whole point of
            // this suite versus DirectAPIAgentTests' scripted fake.
            clientFactory: { AnthropicClient(apiKey: $0, session: session) }
        )
        return Fixtures(transport: transport, store: store, assembler: assembler, agent: agent)
    }

    private func seedTarget(_ store: ReplicaStore, id: Int, text: String) throws {
        let row = Row([
            "id": id, "text": text, "intent": "do it", "level": "week",
            "period_start": "2026-07-06", "period_end": "2026-07-12",
            "status": "todo", "priority": "high", "ownership": "mine",
            "due_date": "", "progress": 0.0, "source_type": "manual",
            "sub_items": "[]", "notes": "[]",
            "created_at": "2026-07-01T10:00:00Z", "updated_at": "2026-07-02T10:00:00Z"
        ])
        try store.apply(CloudChangeBatch(
            changed: [CloudRecord(
                recordName: SliceKind.target.recordName(id: "\(id)"),
                zone: .data,
                kind: SliceKind.target.rawValue,
                modifiedAt: base,
                payload: try RowPayloadCoder.payload(from: row)
            )],
            deletedRecordNames: [],
            newToken: CloudChangeToken(value: 1)
        ))
    }

    // MARK: - SSE scripting

    private func sse(_ pairs: [(event: String, data: String)]) -> Data {
        Data(pairs.map { "event: \($0.event)\ndata: \($0.data)\n\n" }.joined().utf8)
    }

    /// A streamed tool_use round: the model requests `name` with the input
    /// JSON split across two `input_json_delta` events (the live-API shape —
    /// the loop must assemble them before executing).
    private func toolUseResponse(id: String, name: String, inputParts: (String, String)) -> DirectLoopStubProtocol.Stub {
        func escape(_ fragment: String) -> String {
            fragment
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        return .init(statusCode: 200, body: sse([
            ("message_start", #"{"type":"message_start","message":{"id":"msg_t","role":"assistant","content":[]}}"#),
            // swiftlint:disable:next line_length
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}}"#),
            // swiftlint:disable:next line_length
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\#(escape(inputParts.0))"}}"#),
            // swiftlint:disable:next line_length
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\#(escape(inputParts.1))"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":30}}"#),
            ("message_stop", #"{"type":"message_stop"}"#)
        ]))
    }

    /// A streamed text answer ending with end_turn. Parts must be plain text
    /// (no JSON metacharacters).
    private func textResponse(_ parts: [String]) -> DirectLoopStubProtocol.Stub {
        let deltas: [(event: String, data: String)] = parts.map { part in
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(part)"}}"#)
        }
        return .init(statusCode: 200, body: sse([
            ("message_start", #"{"type":"message_start","message":{"id":"msg_a","role":"assistant","content":[]}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
        ] + deltas + [
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":12}}"#),
            ("message_stop", #"{"type":"message_stop"}"#)
        ]))
    }

    // MARK: - Request-body helpers

    private func requestJSON(_ index: Int) throws -> [String: Any] {
        let bodies = DirectLoopStubProtocol.requestBodies
        guard bodies.indices.contains(index) else {
            XCTFail("no request body at index \(index) — \(bodies.count) recorded")
            return [:]
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bodies[index]) as? [String: Any])
    }

    private func messages(of json: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(json["messages"] as? [[String: Any]])
    }

    private func blocks(of message: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(message["content"] as? [[String: Any]])
    }

    // MARK: - (1) Offline turn end-to-end

    func testOfflineTurnAnswersFromReplicaEndToEnd() async throws {
        let f = try makeFixtures()
        try seedTarget(f.store, id: 7, text: "Ship the direct loop")
        DirectLoopStubProtocol.script([
            toolUseResponse(id: "tu_1", name: "list_targets", inputParts: (#"{"sta"#, #"tus":"todo"}"#)),
            textResponse(["Your one open target: ", "Ship the direct loop."])
        ])

        let (sessionID, messageID) = try await f.agent.sendTurn(text: "Which targets are still open?", sessionID: nil)
        await f.agent.drainAnswers(inSession: sessionID)

        // Wire side, call 1: the turn went out with the system prompt and the
        // full 12-tool contract.
        let first = try requestJSON(0)
        XCTAssertEqual(first["model"] as? String, "claude-sonnet-5")
        XCTAssertEqual(first["max_tokens"] as? Int, 8192)
        XCTAssertEqual(first["stream"] as? Bool, true)
        XCTAssertEqual(first["system"] as? String, MobileSystemPrompt.build())
        let tools = try XCTUnwrap(first["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, [
            "list_targets", "get_target",
            "get_today_briefing", "list_digests", "get_digest",
            "list_tracks", "get_track",
            "list_people", "get_person",
            "list_upcoming_events",
            "create_task", "snooze_item"
        ])
        let firstMessages = try messages(of: first)
        XCTAssertEqual(firstMessages.count, 1)
        XCTAssertEqual(try blocks(of: firstMessages[0]).first?["text"] as? String, "Which targets are still open?")

        // Wire side, call 2: the split input deltas were assembled into one
        // JSON object, and the tool_result carries the SEEDED target — the
        // toolbox really executed against the replica, over the real wire.
        let second = try requestJSON(1)
        let secondMessages = try messages(of: second)
        XCTAssertEqual(secondMessages.count, 3)
        let toolUse = try blocks(of: secondMessages[1]).first { $0["type"] as? String == "tool_use" }
        XCTAssertEqual(try XCTUnwrap(toolUse)["id"] as? String, "tu_1")
        XCTAssertEqual((try XCTUnwrap(toolUse)["input"] as? [String: Any])?["status"] as? String, "todo")
        let toolResult = try XCTUnwrap(blocks(of: secondMessages[2]).first)
        XCTAssertEqual(toolResult["type"] as? String, "tool_result")
        XCTAssertEqual(toolResult["tool_use_id"] as? String, "tu_1")
        let resultJSON = try XCTUnwrap(toolResult["content"] as? String)
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(resultJSON.utf8)) as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?["id"] as? Int, 7)
        XCTAssertEqual(items.first?["text"] as? String, "Ship the direct loop")

        // Thread side: the assistant row completed with the full streamed text.
        let thread = try f.store.chatMessages(inSession: sessionID)
        XCTAssertEqual(thread.map(\.role), [.user, .assistant])
        let reply = try XCTUnwrap(thread.last)
        XCTAssertEqual(reply.id, messageID)
        XCTAssertEqual(reply.text, "Your one open target: Ship the direct loop.")
        XCTAssertTrue(reply.isComplete)
        XCTAssertFalse(reply.isError)

        // And the offline turn left the relay zone EMPTY — .localOnly means
        // no wire record for the Mac, ever.
        let relay = try await f.transport.changes(in: .relay, since: nil)
        XCTAssertTrue(relay.changed.isEmpty, "an offline turn must not ship anything into the relay zone")
    }

    // MARK: - (2) Write-tool loop

    func testWriteToolQueuesActionForTheMac() async throws {
        let f = try makeFixtures()
        DirectLoopStubProtocol.script([
            toolUseResponse(id: "tu_w", name: "create_task", inputParts: (#"{"text": "Follo"#, #"w up with Aly"}"#)),
            textResponse(["Queued — your Mac will create it."])
        ])

        let (sessionID, messageID) = try await f.agent.sendTurn(text: "remind me to follow up with Aly", sessionID: nil)
        await f.agent.drainAnswers(inSession: sessionID)

        // Overlay side: the pending_actions row exists, optimistic and pending.
        let pending = try XCTUnwrap(f.store.pendingActions().first)
        XCTAssertEqual(pending.action.kind, .taskCreate)
        XCTAssertEqual(pending.state, .pending)
        XCTAssertEqual(pending.action.params["text"], .string("Follow up with Aly"))
        XCTAssertNil(pending.entityRecordName)

        // Wire-to-Mac side: the relay zone holds the ActionRequest record the
        // desktop RelayProcessor will consume, in the frozen Plan-4 shape.
        let relay = try await f.transport.changes(in: .relay, since: nil)
        let record = try XCTUnwrap(relay.changed.first)
        XCTAssertEqual(relay.changed.count, 1)
        XCTAssertEqual(record.recordName, "action-\(pending.id)")
        XCTAssertEqual(record.zone, .relay)
        XCTAssertEqual(record.kind, RelayRecordKind.action.rawValue)
        let shipped = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: record.payload)
        XCTAssertEqual(shipped, pending.action)
        XCTAssertEqual(shipped.status, .pending)

        // Model side: call 2's tool_result told the model the truth — queued,
        // not applied (the frozen queued reply).
        let second = try requestJSON(1)
        let toolResult = try XCTUnwrap(blocks(of: try messages(of: second)[2]).first)
        XCTAssertEqual(toolResult["tool_use_id"] as? String, "tu_w")
        XCTAssertEqual(
            toolResult["content"] as? String,
            #"{"note":"will apply when your Mac processes the queue","status":"queued"}"#
        )

        // Thread side: the answer completed normally.
        let reply = try XCTUnwrap(f.store.chatMessages(inSession: sessionID).first { $0.id == messageID })
        XCTAssertEqual(reply.text, "Queued — your Mac will create it.")
        XCTAssertTrue(reply.isComplete)
        XCTAssertFalse(reply.isError)
    }

    // MARK: - (3) Error turn

    func testAPIErrorTurnCompletesWithSettingsHint() async throws {
        let f = try makeFixtures()
        DirectLoopStubProtocol.script([.init(
            statusCode: 401,
            body: Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        )])

        let (sessionID, messageID) = try await f.agent.sendTurn(text: "hello?", sessionID: nil)
        await f.agent.drainAnswers(inSession: sessionID)

        // Thread side: the placeholder completed as an ERROR with the Settings
        // hint — drainAnswers returned, so nothing hung on the 401.
        let reply = try XCTUnwrap(f.store.chatMessages(inSession: sessionID).first { $0.id == messageID })
        XCTAssertTrue(reply.isComplete, "a 401 must still complete the placeholder row")
        XCTAssertTrue(reply.isError)
        XCTAssertEqual(reply.text, "API key rejected — check Settings")
        XCTAssertFalse(reply.text.contains(Self.testKey), "error copy must never leak the API key")

        // Wire side: exactly one request went out — no retry loop — and
        // nothing landed in the relay zone or the overlay.
        XCTAssertEqual(DirectLoopStubProtocol.requestBodies.count, 1)
        let relay = try await f.transport.changes(in: .relay, since: nil)
        XCTAssertTrue(relay.changed.isEmpty)
        XCTAssertTrue(try f.store.pendingActions().isEmpty)
    }

    // MARK: - (4) Relay-path regression pin

    func testRelayBackendStillShipsFrozenPlan4WireRecord() async throws {
        let f = try makeFixtures()
        let backend = RelayAgentBackend(assembler: f.assembler)

        let (sessionID, messageID) = try await backend.sendTurn(text: "hi", sessionID: nil)

        // The relay path must be untouched by all of Plan 5: one chat_message
        // record whose payload bytes are EXACTLY the Plan-4 frozen
        // ChatMessagePayload fixture shape (RelayPayloadTests'
        // testChatMessageWireFormatIsFrozen, with this turn's ids).
        let relay = try await f.transport.changes(in: .relay, since: nil)
        XCTAssertEqual(relay.changed.count, 1)
        let record = try XCTUnwrap(relay.changed.first)
        XCTAssertEqual(record.recordName, "chatmsg-\(messageID)")
        XCTAssertEqual(record.zone, .relay)
        XCTAssertEqual(record.kind, RelayRecordKind.chatMessage.rawValue)
        XCTAssertEqual(
            String(data: record.payload, encoding: .utf8),
            #"{"created_at":1700000000,"id":"\#(messageID)","session_id":"\#(sessionID)","text":"hi"}"#
        )

        // Local side: user row + incomplete placeholder, awaiting the DESKTOP.
        let thread = try f.store.chatMessages(inSession: sessionID)
        XCTAssertEqual(thread.map(\.role), [.user, .assistant])
        XCTAssertEqual(try XCTUnwrap(thread.last).isComplete, false)

        // And the relay path never touches api.anthropic.com.
        XCTAssertTrue(DirectLoopStubProtocol.requestBodies.isEmpty)
    }
}

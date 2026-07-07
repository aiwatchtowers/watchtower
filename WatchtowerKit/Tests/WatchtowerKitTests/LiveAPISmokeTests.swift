import GRDB
import XCTest
@testable import WatchtowerKit

/// Plan 6 Task 5 (Design Decision 7): the ONLY suite where the frozen BYOK
/// wire format meets the real api.anthropic.com. Key-gated — without
/// `ANTHROPIC_LIVE_KEY` in the environment every test skips, so CI and the
/// ordinary Kit run stay hermetic; with the key, `make smoke-live` runs just
/// this suite (~cents on claude-haiku-4-5, the cheapest real validation).
///
/// ZERO production accommodation: a failure here is a FINDING against the
/// frozen wire format (AnthropicWire/AnthropicClient), never something to
/// patch around from this suite.
///
/// Key hygiene: the key is read from the environment only, never persisted,
/// and every failure path routes its message through `redacted(_:)` so no
/// XCTest failure output can embed it.
final class LiveAPISmokeTests: XCTestCase {
    /// Read from the environment ONLY — never persisted, never logged.
    private var apiKey = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_LIVE_KEY"], !key.isEmpty else {
            throw XCTSkip("live smoke needs ANTHROPIC_LIVE_KEY")
        }
        apiKey = key
    }

    /// Belt for failure output: no string may reach an XCTest failure
    /// message without the key scrubbed out first.
    private func redacted(_ text: String) -> String {
        apiKey.isEmpty ? text : text.replacingOccurrences(of: apiKey, with: "[REDACTED-KEY]")
    }

    // MARK: - (1) Raw client round-trip: the frozen request format is server-valid

    /// THE assertion is the transport itself: HTTP 200 + a parseable SSE
    /// stream all the way to `message_stop` proves the frozen request bytes
    /// (headers, body shape, streaming) are accepted by the real server.
    /// The content asserts are sanity on top.
    func testLiveRequestFormatAccepted() async throws {
        let client = AnthropicClient(apiKey: apiKey, session: URLSession(configuration: .ephemeral))
        let request = AnthropicRequest(
            model: .haiku45,
            system: "You are a wire-format probe. Follow the user's instruction exactly.",
            messages: [APIMessage(role: .user, content: [.text("Reply with the single word: pong")])],
            tools: [],
            maxTokens: 64
        )

        var text = ""
        var stopReason: String?
        do {
            for try await event in client.streamMessage(request: request) {
                switch event {
                case let .textDelta(delta):
                    text += delta
                case let .finished(reason):
                    stopReason = reason
                default:
                    break
                }
            }
        } catch {
            XCTFail("live request rejected — frozen wire format vs real server: \(redacted(String(describing: error)))")
            return
        }

        XCTAssertFalse(text.isEmpty, "live model streamed no text")
        XCTAssertEqual(stopReason, "end_turn", "expected a clean end_turn stop")
    }

    // MARK: - (2) One real tool round through the whole shipped stack

    /// DirectAPIAgent (default clientFactory — the REAL AnthropicClient over
    /// the real network) answers a turn that forces a `list_targets` tool
    /// round against a 2-row fixture replica: request format WITH the 12-tool
    /// contract, live tool_use streaming, tool_result follow-up call, and the
    /// assembled answer must carry the count.
    func testLiveToolRoundExecutes() async throws {
        let transport = InMemoryCloudTransport()
        let store = try ReplicaStore.inMemory()
        let assembler = ChatAssembler(transport: transport, store: store)
        let outbox = ActionOutbox(transport: transport, store: store)
        let toolbox = ReplicaToolbox(store: store, outbox: outbox)
        try seedTargets(store, texts: ["Ship the live smoke", "Cut the TestFlight build"])
        let key = apiKey
        let agent = DirectAPIAgent(
            assembler: assembler,
            store: store,
            toolbox: toolbox,
            apiKey: { key },
            model: { .haiku45 }
        )

        let (sessionID, messageID) = try await agent.sendTurn(
            text: "Use the list_targets tool and tell me how many targets exist. Answer with just the number.",
            sessionID: nil
        )
        await agent.drainAnswers(inSession: sessionID)

        let reply = try XCTUnwrap(try store.chatMessages(inSession: sessionID).first { $0.id == messageID })
        XCTAssertTrue(reply.isComplete, "the live tool round must complete the placeholder row")
        XCTAssertFalse(reply.isError, "live tool round errored: \(redacted(reply.text))")
        XCTAssertTrue(reply.text.contains("2"), "expected the target count 2 in: \(redacted(reply.text))")
    }

    // MARK: - Fixture

    /// Seeds `texts.count` open targets into the replica in one batch —
    /// the row shape mirrors DirectLoopTests' fixture.
    private func seedTargets(_ store: ReplicaStore, texts: [String]) throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = try texts.enumerated().map { index, text -> CloudRecord in
            let id = index + 1
            let row = Row([
                "id": id, "text": text, "intent": "do it", "level": "week",
                "period_start": "2026-07-06", "period_end": "2026-07-12",
                "status": "todo", "priority": "high", "ownership": "mine",
                "due_date": "", "progress": 0.0, "source_type": "manual",
                "sub_items": "[]", "notes": "[]",
                "created_at": "2026-07-01T10:00:00Z", "updated_at": "2026-07-02T10:00:00Z"
            ])
            return CloudRecord(
                recordName: SliceKind.target.recordName(id: "\(id)"),
                zone: .data,
                kind: SliceKind.target.rawValue,
                modifiedAt: base,
                payload: try RowPayloadCoder.payload(from: row)
            )
        }
        try store.apply(CloudChangeBatch(
            changed: records,
            deletedRecordNames: [],
            newToken: CloudChangeToken(value: 1)
        ))
    }
}

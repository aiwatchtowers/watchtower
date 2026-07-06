import GRDB
import XCTest
@testable import WatchtowerDesktop
@testable import WatchtowerKit

final class RelayProcessorChatTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private var sidecar: HubSyncState!
    private var transport: InMemoryCloudTransport!

    override func setUpWithError() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        dbPath = path
        dbPool = manager.dbPool
        sidecar = try HubSyncState.inMemory()
        transport = InMemoryCloudTransport()
    }

    override func tearDownWithError() throws {
        transport = nil
        sidecar = nil
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
    }

    private func makeProcessor(
        aiService: any AIServiceProtocol,
        chunkInterval: Duration = .milliseconds(10),
        streamTimeout: Duration = .seconds(300)
    ) -> RelayProcessor {
        RelayProcessor(
            dbPool: dbPool,
            transport: transport,
            sidecar: sidecar,
            aiService: aiService,
            chunkInterval: chunkInterval,
            streamTimeout: streamTimeout
        )
    }

    // MARK: - Helpers

    /// Saves a chat message record to the relay zone, as mobile would.
    @discardableResult
    private func enqueueChat(id: String, sessionID: String, text: String = "hello") async throws -> String {
        let message = ChatMessagePayload(id: id, sessionID: sessionID, text: text, createdAt: Date())
        try await transport.save([try CloudRecordFactory.record(for: message, modifiedAt: Date())])
        return message.recordName
    }

    /// All chunk records for the given message, decoded and ordered by seq.
    private func chunks(messageID: String) async throws -> [ChatChunkPayload] {
        let batch = try await transport.changes(in: .relay, since: nil)
        return try batch.changed
            .filter { $0.kind == RelayRecordKind.chatChunk.rawValue }
            .map { try RelayCoder.makeDecoder().decode(ChatChunkPayload.self, from: $0.payload) }
            .filter { $0.messageID == messageID }
            .sorted { $0.seq < $1.seq }
    }

    // MARK: - Tests

    func testChatMessageStreamsMonotonicChunksAndFinalDone() async throws {
        // Each mock event arrives 30 ms apart while the flush interval is 10 ms,
        // so every text delta lands after the interval elapsed → one chunk per
        // delta plus the final done chunk. Sleeps only ever overshoot, so the
        // per-delta flush is deterministic.
        let mock = MockClaudeService(
            events: [.text("Hello "), .text("streaming "), .text("world"), .done],
            eventDelay: .milliseconds(30)
        )
        try await enqueueChat(id: "m1", sessionID: "s1")

        _ = try await makeProcessor(aiService: mock).processOnce()

        let chunks = try await chunks(messageID: "m1")
        XCTAssertEqual(chunks.count, 4, "three interval-spaced deltas + final done chunk")
        XCTAssertEqual(chunks.map(\.seq), [0, 1, 2, 3], "seq must be monotonic from 0")
        XCTAssertEqual(chunks.map(\.done), [false, false, false, true], "only the last chunk is done")
        XCTAssertEqual(chunks.map(\.text).joined(), "Hello streaming world")
        XCTAssertTrue(chunks.allSatisfy { $0.sessionID == "s1" })

        // Coalescing side of the cadence: deltas faster than the interval are
        // batched — with a huge interval everything lands in one done chunk.
        let fastMock = MockClaudeService(events: [.text("all "), .text("at "), .text("once"), .done])
        try await enqueueChat(id: "m2", sessionID: "s2")
        _ = try await makeProcessor(aiService: fastMock, chunkInterval: .seconds(60)).processOnce()
        let coalesced = try await self.chunks(messageID: "m2")
        XCTAssertEqual(coalesced.count, 1, "deltas inside one interval must coalesce into a single chunk")
        XCTAssertEqual(coalesced.first?.done, true)
        XCTAssertEqual(coalesced.first?.text, "all at once")
    }

    func testSessionIDFromStreamPersistedAndReusedOnSecondTurn() async throws {
        let mock = MockClaudeService(eventSequence: [
            [.sessionID("cli-123"), .text("first answer"), .done],
            [.text("second answer"), .done]
        ])
        let processor = makeProcessor(aiService: mock)

        try await enqueueChat(id: "m1", sessionID: "sess-A")
        _ = try await processor.processOnce()
        try await enqueueChat(id: "m2", sessionID: "sess-A")
        _ = try await processor.processOnce()

        XCTAssertEqual(mock.sessionIDs, [nil, "cli-123"], "second turn must resume the persisted CLI session")
    }

    func testFirstTurnSendsSystemPromptSecondTurnNil() async throws {
        let mock = MockClaudeService(eventSequence: [
            [.sessionID("cli-123"), .text("first answer"), .done],
            [.text("second answer"), .done]
        ])
        let processor = makeProcessor(aiService: mock)

        try await enqueueChat(id: "m1", sessionID: "sess-A")
        _ = try await processor.processOnce()
        try await enqueueChat(id: "m2", sessionID: "sess-A")
        _ = try await processor.processOnce()

        XCTAssertEqual(mock.systemPrompts.count, 2)
        XCTAssertNotNil(mock.systemPrompts[0], "first turn must carry the full system prompt")
        XCTAssertNil(mock.systemPrompts[1], "resumed session must not resend the system prompt")
    }

    func testStreamErrorEmitsDoneChunkWithErrorTextAndMarksProcessed() async throws {
        let failure = NSError(
            domain: "ai", code: 1, userInfo: [NSLocalizedDescriptionKey: "model exploded"]
        )
        let processor = makeProcessor(aiService: MockClaudeService(error: failure))
        let recordName = try await enqueueChat(id: "m1", sessionID: "s1")

        _ = try await processor.processOnce()

        let chunks = try await chunks(messageID: "m1")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.done, true)
        XCTAssertEqual(chunks.first?.text, "⚠️ model exploded")
        XCTAssertTrue(try sidecar.isRelayProcessed(recordName), "failed chat must still be marked processed")

        // No retry loop: another cycle re-runs nothing and emits no new chunks.
        _ = try await processor.processOnce()
        let after = try await self.chunks(messageID: "m1")
        XCTAssertEqual(after.count, 1)
    }

    func testHungStreamTimesOutEmitsErrorChunkAndMarksProcessed() async throws {
        let processor = makeProcessor(
            aiService: HungAIService(),
            streamTimeout: .milliseconds(100)
        )
        let recordName = try await enqueueChat(id: "m1", sessionID: "s1")

        _ = try await processor.processOnce()

        let chunks = try await chunks(messageID: "m1")
        XCTAssertEqual(chunks.count, 1, "a hung stream must produce exactly the error-path final chunk")
        XCTAssertEqual(chunks.first?.done, true)
        XCTAssertEqual(chunks.first?.text, "⚠️ chat stream timed out")
        XCTAssertTrue(try sidecar.isRelayProcessed(recordName), "timed-out chat must still be marked processed")
    }
}

/// A stream that never yields and never finishes — a wedged CLI stand-in.
/// Task cancellation terminates the stream (AsyncThrowingStream honors it),
/// which is exactly what the processor's watchdog must trigger.
private final class HungAIService: AIServiceProtocol {
    func stream(
        prompt: String,
        systemPrompt: String?,
        sessionID: String?,
        dbPath: String?,
        model: String?,
        extraAllowedTools: [String]
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { _ in }
    }
}

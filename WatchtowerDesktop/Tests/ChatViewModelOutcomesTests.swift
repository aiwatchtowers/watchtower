import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The outcomes block's provider independence. A separate file only because
/// `ViewModelTests.swift` sits at its SwiftLint file-length ceiling.
@MainActor
final class ChatViewModelOutcomesTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch {
            XCTFail("setUp failed: \(error)")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    private func makeConversation() throws -> ChatConversation {
        try dbManager.dbPool.write { db in
            try ChatConversationQueries.ensureTable(db)
            try ChatMessageQueries.ensureTable(db)
            try ChatMessageQueries.ensureTurnIDColumn(db)
            return try ChatConversationQueries.create(db, title: "t")
        }
    }

    /// I3: codex never emits a session id, so gating the outcomes block on one
    /// meant codex chats never saw what happened to their proposals. The floor
    /// is the previous owner message, not the session.
    func testOutcomesReachAProviderThatNeverEmitsASessionID() async throws {
        let mock = MockClaudeService(eventSequence: [[.text("a"), .done], [.text("b"), .done]])
        let vm = ChatViewModel(aiService: mock, dbManager: dbManager, provider: .codex)
        let conv = try makeConversation()
        vm.bind(to: conv)
        vm.inputText = "first"
        vm.send()
        for _ in 0..<50 where vm.isStreaming { try await Task.sleep(for: .milliseconds(20)) }

        let applied = AgentActionFeed.timestampString(Date().addingTimeInterval(60))
        try await dbManager.dbPool.write { db in
            try TestDatabase.insertAgentAction(db, conversationID: conv.id, status: "applied",
                                               resultJSON: #"{"target_id":5}"#, appliedAt: applied)
        }
        vm.inputText = "second"
        vm.send()
        for _ in 0..<50 where vm.isStreaming { try await Task.sleep(for: .milliseconds(20)) }

        XCTAssertEqual(mock.sessionIDs, [nil, nil], "codex is ephemeral — no session id is ever passed")
        XCTAssertEqual(mock.prompts.first, "first")
        let second = try XCTUnwrap(mock.prompts.last)
        XCTAssertTrue(second.hasPrefix("=== ACTIONS SINCE YOUR LAST MESSAGE ==="))
        XCTAssertTrue(second.contains("create_target: applied"))
        XCTAssertTrue(second.hasSuffix("second"))
    }
}

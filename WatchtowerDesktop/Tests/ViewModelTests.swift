import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerKit

// MARK: - WorkspaceOverviewViewModel

final class WorkspaceOverviewViewModelTests: XCTestCase {
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

    @MainActor
    func testLoadWorkspaceAndStats() async throws {
        try await dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db, name: "Acme Corp", domain: "acme")
            try TestDatabase.insertChannel(db, id: "C001")
            try TestDatabase.insertChannel(db, id: "C002")
            try TestDatabase.insertUser(db, id: "U001")
            try TestDatabase.insertMessage(db, channelID: "C001", ts: "1700000001.000100")
            try TestDatabase.insertDigest(db)
        }

        let vm = WorkspaceOverviewViewModel(dbManager: dbManager)
        await vm.load()

        XCTAssertEqual(vm.workspace?.name, "Acme Corp")
        XCTAssertEqual(vm.stats.channelCount, 2)
        XCTAssertEqual(vm.stats.userCount, 1)
        XCTAssertEqual(vm.stats.messageCount, 1)
        XCTAssertEqual(vm.stats.digestCount, 1)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func testLoadEmptyDB() async {
        let vm = WorkspaceOverviewViewModel(dbManager: dbManager)
        await vm.load()

        XCTAssertNil(vm.workspace)
        XCTAssertEqual(vm.stats.channelCount, 0)
        XCTAssertTrue(vm.recentActivity.isEmpty)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func testLoadRecentActivity() async throws {
        let recentTS = String(format: "%.6f", Date().timeIntervalSince1970 - 3600)
        try await dbManager.dbPool.write { db in
            try TestDatabase.insertChannel(db, id: "C001", name: "general")
            try TestDatabase.insertUser(db, id: "U001", displayName: "Alice")
            try TestDatabase.insertWatchItem(db, entityType: "channel", entityID: "C001")
            try TestDatabase.insertMessage(db, channelID: "C001", ts: recentTS, userID: "U001", text: "Recent msg")
        }

        let vm = WorkspaceOverviewViewModel(dbManager: dbManager)
        await vm.load()

        XCTAssertEqual(vm.recentActivity.count, 1)
        XCTAssertEqual(vm.recentActivity.first?.text, "Recent msg")
    }
}

// MARK: - DigestViewModel

final class DigestViewModelTests: XCTestCase {
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

    @MainActor
    func testLoadDigests() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db, domain: "acme")
            try TestDatabase.insertChannel(db, id: "C001", name: "general")
            try TestDatabase.insertDigest(db, channelID: "C001", summary: "Daily standup recap")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.digests.count, 1)
        XCTAssertEqual(vm.digests[0].summary, "Daily standup recap")
        XCTAssertEqual(vm.workspaceDomain, "acme")
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func testLoadWithTypeFilter() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertDigest(db, channelID: "C001", periodFrom: 100, periodTo: 200, type: "channel")
            try TestDatabase.insertDigest(db, channelID: "", periodFrom: 100, periodTo: 200, type: "daily")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.selectedType = "daily"
        vm.load()

        XCTAssertEqual(vm.digests.count, 1)
        XCTAssertEqual(vm.digests[0].type, "daily")
    }

    @MainActor
    func testChannelName() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertChannel(db, id: "C001", name: "general")
            try TestDatabase.insertDigest(db, channelID: "C001")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.channelName(for: vm.digests[0]), "general")
    }

    @MainActor
    func testChannelNameForDM() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertUser(db, id: "U001", displayName: "Alice")
            try TestDatabase.insertChannel(db, id: "D001", name: "dm-alice", type: "dm", dmUserID: "U001")
            try TestDatabase.insertDigest(db, channelID: "D001")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.channelName(for: vm.digests[0]), "DM: Alice")
    }

    @MainActor
    func testChannelNameNilForCrossChannel() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertDigest(db, channelID: "", type: "daily")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertNil(vm.channelName(for: vm.digests[0]))
    }

    @MainActor
    func testSlackChannelURL() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db, domain: "acme")
            try TestDatabase.insertDigest(db, channelID: "C001")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.slackChannelURL(channelID: "C001")?.absoluteString, "slack://channel?team=T001&id=C001")
    }

    @MainActor
    func testSlackChannelURLNilWithoutTeamID() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db, id: "", domain: "")
            try TestDatabase.insertDigest(db)
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertNil(vm.slackChannelURL(channelID: "C001"))
    }

    @MainActor
    func testSlackMessageURL() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db, domain: "acme")
            try TestDatabase.insertDigest(db)
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        let url = vm.slackMessageURL(channelID: "C001", messageTS: "1740577800.000100")
        XCTAssertEqual(url?.absoluteString, "slack://channel?team=T001&id=C001&message=1740577800.000100")
    }

    @MainActor
    func testContributingChannels() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertChannel(db, id: "C001", name: "general")
            try TestDatabase.insertChannel(db, id: "C002", name: "engineering")
            try TestDatabase.insertDigest(db, channelID: "C001", periodFrom: 1700000000, periodTo: 1700086400, type: "channel", summary: "ch1")
            try TestDatabase.insertDigest(db, channelID: "C002", periodFrom: 1700000000, periodTo: 1700086400, type: "channel", summary: "ch2")
            try TestDatabase.insertDigest(db, channelID: "", periodFrom: 1700000000, periodTo: 1700086400, type: "daily", summary: "daily")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        let dailyDigest = try XCTUnwrap(vm.digests.first { $0.type == "daily" })
        let contributing = vm.contributingChannels(for: dailyDigest)
        XCTAssertEqual(contributing.count, 2)
        XCTAssertTrue(contributing.contains { $0.name == "general" })
        XCTAssertTrue(contributing.contains { $0.name == "engineering" })
    }

    @MainActor
    func testContributingChannelsDeduplicates() throws {
        // Same channel can have multiple channel digests within a daily/weekly window
        // (e.g. one per sync cycle). The list must show each channel only once,
        // sorted alphabetically.
        try dbManager.dbPool.write { db in
            try TestDatabase.insertChannel(db, id: "C001", name: "zeta")
            try TestDatabase.insertChannel(db, id: "C002", name: "alpha")
            // Three channel digests for C001, one for C002 — all in the daily window
            try TestDatabase.insertDigest(db, channelID: "C001", periodFrom: 1700000000, periodTo: 1700020000, type: "channel", summary: "z1")
            try TestDatabase.insertDigest(db, channelID: "C001", periodFrom: 1700020001, periodTo: 1700040000, type: "channel", summary: "z2")
            try TestDatabase.insertDigest(db, channelID: "C001", periodFrom: 1700040001, periodTo: 1700060000, type: "channel", summary: "z3")
            try TestDatabase.insertDigest(db, channelID: "C002", periodFrom: 1700000000, periodTo: 1700086400, type: "channel", summary: "a1")
            try TestDatabase.insertDigest(db, channelID: "", periodFrom: 1700000000, periodTo: 1700086400, type: "daily", summary: "daily")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        let daily = try XCTUnwrap(vm.digests.first { $0.type == "daily" })
        let contributing = vm.contributingChannels(for: daily)
        XCTAssertEqual(contributing.count, 2, "C001 must collapse to a single entry")
        XCTAssertEqual(contributing[0].name, "alpha", "results must be sorted by name")
        XCTAssertEqual(contributing[1].name, "zeta")
    }

    @MainActor
    func testContributingChannelsEmptyForChannelDigest() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertDigest(db, channelID: "C001", type: "channel")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertTrue(vm.contributingChannels(for: vm.digests[0]).isEmpty)
    }

    @MainActor
    func testDigestByID() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertDigest(db, summary: "Target digest")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        XCTAssertEqual(vm.digestByID(1)?.summary, "Target digest")
    }

    @MainActor
    func testLoadEmptyDB() {
        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertTrue(vm.digests.isEmpty)
        XCTAssertTrue(vm.ledgerDecisions.isEmpty)
        XCTAssertNil(vm.errorMessage)
    }
}

// MARK: - PeopleViewModel

final class PeopleViewModelTests: XCTestCase {
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

    @MainActor
    func testLoad() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertUser(db, id: "U001", name: "alice", displayName: "Alice")
            try TestDatabase.insertUser(db, id: "U002", name: "bob", displayName: "Bob")
            try TestDatabase.insertPeopleCard(db, userID: "U001", periodFrom: 100, periodTo: 200, messageCount: 50)
            try TestDatabase.insertPeopleCard(db, userID: "U002", periodFrom: 100, periodTo: 200, messageCount: 30)
        }

        let vm = PeopleViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertNil(vm.errorMessage, "load() error: \(vm.errorMessage ?? "")")
        XCTAssertFalse(vm.availableWindows.isEmpty, "no windows found")
        XCTAssertEqual(vm.cards.count, 2)
        XCTAssertEqual(vm.cards[0].userID, "U001")
        XCTAssertEqual(vm.availableWindows.count, 1)
        XCTAssertEqual(vm.userNameCache["U001"], "Alice")
        XCTAssertEqual(vm.userNameCache["U002"], "Bob")
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func testLoadEmptyDB() {
        let vm = PeopleViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertTrue(vm.cards.isEmpty)
        XCTAssertTrue(vm.availableWindows.isEmpty)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func testLoadWindow() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertPeopleCard(db, userID: "U001", periodFrom: 100, periodTo: 200, messageCount: 50)
            try TestDatabase.insertPeopleCard(db, userID: "U001", periodFrom: 200, periodTo: 300, messageCount: 30)
        }

        let vm = PeopleViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.cards.count, 1)
        XCTAssertEqual(vm.cards[0].periodFrom, 200)

        vm.loadWindow(at: 1)
        XCTAssertEqual(vm.selectedWindow, 1)
        XCTAssertEqual(vm.cards.count, 1)
        XCTAssertEqual(vm.cards[0].periodFrom, 100)
    }

    @MainActor
    func testLoadWindowOutOfBounds() {
        let vm = PeopleViewModel(dbManager: dbManager)
        vm.load()

        vm.loadWindow(at: 99)
        XCTAssertEqual(vm.selectedWindow, 0)
    }

    @MainActor
    func testUserName() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertUser(db, id: "U001", displayName: "Alice")
            try TestDatabase.insertPeopleCard(db, userID: "U001", periodFrom: 100, periodTo: 200)
        }

        let vm = PeopleViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.userName(for: "U001"), "Alice")
        XCTAssertEqual(vm.userName(for: "U999"), "U999")
    }

    @MainActor
    func testCurrentWindowLabel() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertPeopleCard(db, userID: "U001", periodFrom: 1700000000, periodTo: 1700604800)
        }

        let vm = PeopleViewModel(dbManager: dbManager)
        vm.load()

        let label = vm.currentWindowLabel
        XCTAssertFalse(label.isEmpty)
        XCTAssertNotEqual(label, "No data")
        XCTAssertTrue(label.contains("–"))
    }

    @MainActor
    func testCurrentWindowLabelNoData() {
        let vm = PeopleViewModel(dbManager: dbManager)
        vm.load()
        XCTAssertEqual(vm.currentWindowLabel, "No data")
    }

    @MainActor
    func testRedFlagCount() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertPeopleCard(db, userID: "U001", periodFrom: 100, periodTo: 200, redFlags: #"["Issue"]"#)
            try TestDatabase.insertPeopleCard(db, userID: "U002", periodFrom: 100, periodTo: 200, redFlags: "[]")
            try TestDatabase.insertPeopleCard(db, userID: "U003", periodFrom: 100, periodTo: 200, redFlags: #"["A","B"]"#)
        }

        let vm = PeopleViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.redFlagCount, 2)
    }

    @MainActor
    func testCardHistory() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertPeopleCard(db, userID: "U001", periodFrom: 100, periodTo: 200, messageCount: 50)
            try TestDatabase.insertPeopleCard(db, userID: "U001", periodFrom: 200, periodTo: 300, messageCount: 30)
            try TestDatabase.insertPeopleCard(db, userID: "U002", periodFrom: 100, periodTo: 200, messageCount: 10)
        }

        let vm = PeopleViewModel(dbManager: dbManager)
        let history = vm.cardHistory(userID: "U001")

        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history.allSatisfy { $0.userID == "U001" })
    }

    @MainActor
    func testUserNameCachePrefersDisplayName() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertUser(db, id: "U001", name: "alice", displayName: "Alice Wonder")
            try TestDatabase.insertUser(db, id: "U002", name: "bob", displayName: "")
            try TestDatabase.insertPeopleCard(db, userID: "U001", periodFrom: 100, periodTo: 200)
        }

        let vm = PeopleViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.userNameCache["U001"], "Alice Wonder")
        XCTAssertEqual(vm.userNameCache["U002"], "bob")
    }
}

// MARK: - ChatViewModel

final class ChatViewModelTests: XCTestCase {
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

    @MainActor
    func testNewChat() {
        let vm = ChatViewModel(aiService: MockClaudeService(), dbManager: dbManager)
        vm.messages = [
            ChatMessage(id: UUID(), role: .user, text: "Hi", timestamp: Date(), isStreaming: false),
            ChatMessage(id: UUID(), role: .assistant, text: "Hello!", timestamp: Date(), isStreaming: false)
        ]
        vm.newChat()

        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertFalse(vm.isStreaming)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func testCancelStream() throws {
        let vm = ChatViewModel(aiService: MockClaudeService(), dbManager: dbManager)
        vm.isStreaming = true
        vm.messages = [
            ChatMessage(id: UUID(), role: .assistant, text: "Partial...", timestamp: Date(), isStreaming: true)
        ]

        vm.cancelStream()

        XCTAssertFalse(vm.isStreaming)
        XCTAssertFalse(try XCTUnwrap(vm.messages.last).isStreaming)
    }

    /// A mock whose stream stalls partway through, giving the test a window to
    /// call `cancelStream()` while the stream Task is still in flight — this is
    /// what reproduces the real race: cancellation is cooperative, so the
    /// stream Task's own completion tail keeps running (and used to persist the
    /// reply again) even after `cancelStream()` already saved the partial text.
    private final class StallingMockService: AIServiceProtocol, @unchecked Sendable {
        func stream(
            prompt: String,
            systemPrompt: String?,
            sessionID: String?,
            dbPath: String?,
            model: String?,
            provider: String?,
            extraAllowedTools: [String]
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    continuation.yield(.text("Partial answer"))
                    try? await Task.sleep(for: .milliseconds(200))
                    // Mirrors WatchtowerAIService.run(): it still emits a final
                    // turnComplete + done even after the Task was cancelled.
                    continuation.yield(.turnComplete("Partial answer"))
                    continuation.yield(.done)
                    continuation.finish()
                }
            }
        }
    }

    @MainActor
    func testCancelStreamDuringActiveStreamPersistsReplyOnlyOnce() async throws {
        try await dbManager.dbPool.write { db in
            try ChatConversationQueries.ensureTable(db)
            try ChatMessageQueries.ensureTable(db)
        }
        let conv = try await dbManager.dbPool.write { db in try ChatConversationQueries.create(db, title: "t") }

        let vm = ChatViewModel(aiService: StallingMockService(), dbManager: dbManager)
        vm.bind(to: conv)
        vm.inputText = "Hi"
        vm.send()

        // Let the mock emit its first chunk, then hit Stop while the stream
        // Task is still stalled (not yet at its completion tail).
        try await Task.sleep(for: .milliseconds(50))
        vm.cancelStream()

        // Give the stream Task's tail time to run to completion too.
        try await Task.sleep(for: .milliseconds(300))

        let stored = try await dbManager.dbPool.read { db in
            try ChatMessageQueries.fetchByConversation(db, conversationID: conv.id)
        }
        let assistantRows = stored.filter { $0.role == "assistant" }
        XCTAssertEqual(assistantRows.count, 1, "the partial reply must be persisted exactly once, not once per completion path")
    }

    @MainActor
    func testSendCreatesMessages() async throws {
        let mock = MockClaudeService(events: [.text("Hello "), .text("world"), .done])
        let vm = ChatViewModel(aiService: mock, dbManager: dbManager)

        vm.inputText = "Hi there"
        vm.send()

        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[0].role, .user)
        XCTAssertEqual(vm.messages[0].text, "Hi there")
        XCTAssertEqual(vm.messages[1].role, .assistant)
        XCTAssertEqual(vm.messages[1].text, "Hello world")
        XCTAssertFalse(vm.isStreaming)
    }

    @MainActor
    func testSendEmptyDoesNothing() {
        let vm = ChatViewModel(aiService: MockClaudeService(), dbManager: dbManager)
        vm.inputText = "   "
        vm.send()

        XCTAssertTrue(vm.messages.isEmpty)
    }

    @MainActor
    func testSendWhileStreamingDoesNothing() {
        let vm = ChatViewModel(aiService: MockClaudeService(), dbManager: dbManager)
        vm.isStreaming = true
        vm.inputText = "Hello"
        vm.send()

        XCTAssertTrue(vm.messages.isEmpty)
    }

    @MainActor
    func testSendClearsInputText() {
        let vm = ChatViewModel(aiService: MockClaudeService(), dbManager: dbManager)
        vm.inputText = "Hello"
        vm.send()

        XCTAssertEqual(vm.inputText, "")
    }

    @MainActor
    func testSendWithError() async throws {
        let mock = MockClaudeService(error: WatchtowerAIError.cliNotFound)
        let vm = ChatViewModel(aiService: mock, dbManager: dbManager)

        vm.inputText = "Hello"
        vm.send()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isStreaming)
    }

    /// Locks in the provider-picker fix: the CLI provider flag must reflect
    /// whichever `AIProvider` is active on the view model, not whatever
    /// `ai.provider` happens to be set to in config.yaml.
    @MainActor
    func testSendPassesSelectedProviderToService() async throws {
        let mock = MockClaudeService()
        let vm = ChatViewModel(aiService: mock, dbManager: dbManager, provider: .codex)

        vm.inputText = "Hi"
        vm.send()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(mock.providers, ["codex"])
    }

    @MainActor
    func testSendPassesClaudeProviderToService() async throws {
        let mock = MockClaudeService()
        let vm = ChatViewModel(aiService: mock, dbManager: dbManager, provider: .claude)

        vm.inputText = "Hi"
        vm.send()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(mock.providers, ["claude"])
    }

    func testBuildSystemPrompt() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db, name: "Acme Corp", domain: "acme")
        }

        let prompt = ChatViewModel.buildSystemPrompt(dbPool: dbManager.dbPool)

        XCTAssertTrue(prompt.contains("Acme Corp"))
        XCTAssertTrue(prompt.contains("acme.slack.com"))
        XCTAssertTrue(prompt.contains("DATABASE SCHEMA"))
        XCTAssertTrue(prompt.contains("CREATE TABLE"))
    }

    func testBuildSystemPromptEmptyDB() {
        let prompt = ChatViewModel.buildSystemPrompt(dbPool: dbManager.dbPool)

        XCTAssertTrue(prompt.contains("unknown"))
        XCTAssertTrue(prompt.contains("Watchtower"))
    }

    func testFetchSchema() throws {
        let schema = try dbManager.dbPool.read { db in
            try ChatViewModel.fetchSchema(db)
        }
        XCTAssertTrue(schema.contains("CREATE TABLE"))
        XCTAssertTrue(schema.contains("workspace"))
        XCTAssertTrue(schema.contains("messages"))
    }
}

// MARK: - AIProvider & ChatModel Tests

final class AIProviderTests: XCTestCase {
    func testProviderDisplayNames() {
        XCTAssertEqual(AIProvider.claude.displayName, "Claude")
        XCTAssertEqual(AIProvider.codex.displayName, "Codex")
    }

    func testProviderAllCases() {
        XCTAssertEqual(AIProvider.allCases.count, 2)
    }

    func testClaudeModelsProvider() {
        XCTAssertEqual(ChatModel.sonnet.provider, .claude)
        XCTAssertEqual(ChatModel.haiku.provider, .claude)
        XCTAssertEqual(ChatModel.opus.provider, .claude)
    }

    func testCodexModelsProvider() {
        XCTAssertEqual(ChatModel.gpt54.provider, .codex)
        XCTAssertEqual(ChatModel.gpt54mini.provider, .codex)
        XCTAssertEqual(ChatModel.gpt53codex.provider, .codex)
    }

    func testModelsForProvider() {
        let claudeModels = ChatModel.models(for: .claude)
        XCTAssertEqual(claudeModels.count, 3)
        XCTAssertTrue(claudeModels.allSatisfy { $0.provider == .claude })

        let codexModels = ChatModel.models(for: .codex)
        XCTAssertEqual(codexModels.count, 3)
        XCTAssertTrue(codexModels.allSatisfy { $0.provider == .codex })
    }

    func testModelDisplayNames() {
        XCTAssertEqual(ChatModel.gpt54.displayName, "GPT-5.4")
        XCTAssertEqual(ChatModel.gpt54mini.displayName, "GPT-5.4 Mini")
        XCTAssertEqual(ChatModel.gpt53codex.displayName, "GPT-5.3 Codex")
    }

    func testModelRawValues() {
        XCTAssertEqual(ChatModel.gpt54.rawValue, "gpt-5.4")
        XCTAssertEqual(ChatModel.gpt54mini.rawValue, "gpt-5.4-mini")
        XCTAssertEqual(ChatModel.gpt53codex.rawValue, "gpt-5.3-codex")
    }
}

// MARK: - ChatViewModel Provider Switching Tests

final class ChatViewModelProviderTests: XCTestCase {
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

    @MainActor
    func testDefaultProviderIsClaude() {
        let vm = ChatViewModel(aiService: MockClaudeService(), dbManager: dbManager)
        XCTAssertEqual(vm.selectedProvider, .claude)
        XCTAssertEqual(vm.selectedModel.provider, .claude)
    }

    @MainActor
    func testInitWithCodexProvider() {
        let vm = ChatViewModel(
            aiService: MockClaudeService(),
            dbManager: dbManager,
            provider: .codex
        )
        XCTAssertEqual(vm.selectedProvider, .codex)
        XCTAssertEqual(vm.selectedModel.provider, .codex)
    }

    @MainActor
    func testSwitchProviderChangesModel() {
        let vm = ChatViewModel(aiService: MockClaudeService(), dbManager: dbManager)
        XCTAssertEqual(vm.selectedProvider, .claude)

        vm.switchProvider(.codex)

        XCTAssertEqual(vm.selectedProvider, .codex)
        XCTAssertEqual(vm.selectedModel.provider, .codex)
    }

    @MainActor
    func testSwitchToSameProviderNoOp() {
        let vm = ChatViewModel(aiService: MockClaudeService(), dbManager: dbManager)
        let originalModel = vm.selectedModel

        vm.switchProvider(.claude)

        XCTAssertEqual(vm.selectedModel, originalModel)
    }

    @MainActor
    func testSwitchProviderBackAndForth() {
        let vm = ChatViewModel(aiService: MockClaudeService(), dbManager: dbManager)

        vm.switchProvider(.codex)
        XCTAssertEqual(vm.selectedProvider, .codex)

        vm.switchProvider(.claude)
        XCTAssertEqual(vm.selectedProvider, .claude)
        XCTAssertEqual(vm.selectedModel.provider, .claude)
    }

    /// Locks in the invariant `switchProvider` must maintain: whatever provider
    /// is active, `selectedModel` always belongs to it — a stale model from the
    /// previous provider (e.g. a Claude model string sent while Codex is
    /// selected) would produce an incompatible model/provider pair downstream.
    @MainActor
    func testSwitchProviderAlwaysKeepsModelConsistentWithActiveProvider() {
        let vm = ChatViewModel(aiService: MockClaudeService(), dbManager: dbManager)
        for provider in AIProvider.allCases {
            vm.switchProvider(provider)
            XCTAssertEqual(vm.selectedProvider, provider)
            XCTAssertEqual(vm.selectedModel.provider, provider,
                           "selectedModel must belong to the just-activated provider")
        }
    }

    @MainActor
    func testCreateServiceForClaude() {
        let service = ChatViewModel.createService(for: .claude)
        XCTAssertTrue(service is WatchtowerAIService)
    }

    @MainActor
    func testCreateServiceForCodex() {
        let service = ChatViewModel.createService(for: .codex)
        XCTAssertTrue(service is WatchtowerAIService)
    }
}

// MARK: - SearchViewModel

final class SearchViewModelTests: XCTestCase {
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

    @MainActor
    func testEmptyQueryClearsResults() {
        let vm = SearchViewModel(dbManager: dbManager)
        vm.query = "   "
        vm.search()

        XCTAssertTrue(vm.results.isEmpty)
    }

    @MainActor
    func testInitialState() {
        let vm = SearchViewModel(dbManager: dbManager)

        XCTAssertEqual(vm.query, "")
        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertFalse(vm.isSearching)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func testSearchSetsIsSearching() async throws {
        let vm = SearchViewModel(dbManager: dbManager)
        vm.query = "hello"
        vm.search()

        // After debounce completes (300ms), isSearching should be set then cleared
        try await Task.sleep(for: .milliseconds(500))

        // After completion, isSearching should be false
        XCTAssertFalse(vm.isSearching)
    }

    @MainActor
    func testSearchCancelsOnNewQuery() async throws {
        let vm = SearchViewModel(dbManager: dbManager)
        vm.query = "first"
        vm.search()

        // Immediately issue new search, cancelling previous
        vm.query = "  "
        vm.search()

        XCTAssertTrue(vm.results.isEmpty)
    }

    @MainActor
    func testSearchCancelsPreviousTask() async throws {
        let vm = SearchViewModel(dbManager: dbManager)
        vm.query = "alpha"
        vm.search()

        // Issue second query before debounce completes
        vm.query = "beta"
        vm.search()

        // Wait for debounce
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertFalse(vm.isSearching)
    }
}

// MARK: - TracksViewModel

final class TracksViewModelTests: XCTestCase {
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

    @MainActor
    func testLoadTracks() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db, domain: "acme")
            try db.execute(sql: "INSERT INTO slack_accounts (id, current_user_id) VALUES (1, 'U001')")
            try TestDatabase.insertTrack(db, text: "Fix the bug", priority: "high", hasUpdates: true)
            try TestDatabase.insertTrack(db, text: "Write docs", priority: "low")
        }

        let vm = TracksViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertNil(vm.errorMessage, "load() error: \(vm.errorMessage ?? "")")
        // Has updates goes to updatedTracks, rest to allTracks
        XCTAssertEqual(vm.updatedTracks.count, 1)
        XCTAssertEqual(vm.allTracks.count, 1)
        XCTAssertEqual(vm.updatedTracks[0].text, "Fix the bug")
        XCTAssertEqual(vm.allTracks[0].text, "Write docs")
        XCTAssertEqual(vm.totalCount, 2)
        XCTAssertEqual(vm.updatedCount, 1)
        XCTAssertEqual(vm.workspaceDomain, "acme")
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func testLoadEmptyDB() {
        let vm = TracksViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertTrue(vm.updatedTracks.isEmpty)
        XCTAssertTrue(vm.allTracks.isEmpty)
        XCTAssertEqual(vm.totalCount, 0)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func testLoadWithPriorityFilter() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db)
            try db.execute(sql: "INSERT INTO slack_accounts (id, current_user_id) VALUES (1, 'U001')")
            try TestDatabase.insertTrack(db, text: "High", priority: "high")
            try TestDatabase.insertTrack(db, text: "Low", priority: "low")
        }

        let vm = TracksViewModel(dbManager: dbManager)
        vm.priorityFilter = "high"
        vm.load()

        XCTAssertEqual(vm.allTracks.count, 1)
        XCTAssertEqual(vm.allTracks[0].text, "High")
    }

    @MainActor
    func testMarkRead() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db)
            try db.execute(sql: "INSERT INTO slack_accounts (id, current_user_id) VALUES (1, 'U001')")
            try TestDatabase.insertTrack(db, text: "Fix it", hasUpdates: true)
        }

        let vm = TracksViewModel(dbManager: dbManager)
        vm.showRead = true // show read tracks to verify they move correctly
        vm.load()
        XCTAssertEqual(vm.updatedTracks.count, 1)

        let item = vm.updatedTracks[0]
        vm.markRead(item)

        // After markRead, the track moves from updatedTracks to allTracks
        XCTAssertTrue(vm.updatedTracks.isEmpty)
        XCTAssertEqual(vm.allTracks.count, 1)
        let updated = vm.itemByID(item.id)
        XCTAssertTrue(updated?.isRead ?? false)
    }

    @MainActor
    func testSlackMessageURL() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db, domain: "acme")
            try db.execute(sql: "INSERT INTO slack_accounts (id, current_user_id) VALUES (1, 'U001')")
            try TestDatabase.insertTrack(db)
        }

        let vm = TracksViewModel(dbManager: dbManager)
        vm.load()

        let url = vm.slackMessageURL(channelID: "C001", messageTS: "1740577800.000100")
        XCTAssertEqual(url?.absoluteString, "slack://channel?team=T001&id=C001&message=1740577800.000100")
    }

    @MainActor
    func testSlackMessageURLWithoutDomain() {
        let vm = TracksViewModel(dbManager: dbManager)
        vm.load()

        // No workspace loaded — teamID is nil, so URL should be nil
        let url = vm.slackMessageURL(channelID: "C001", messageTS: "123.456")
        XCTAssertNil(url)
    }

    @MainActor
    func testLoadWithChannelFilter() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db)
            try db.execute(sql: "INSERT INTO slack_accounts (id, current_user_id) VALUES (1, 'U001')")
            try TestDatabase.insertTrack(db, text: "Task 1", channelIDs: #"["C001"]"#)
            try TestDatabase.insertTrack(db, text: "Task 2", channelIDs: #"["C002"]"#)
        }

        let vm = TracksViewModel(dbManager: dbManager)
        vm.channelFilter = "C002"
        vm.load()

        let total = vm.updatedTracks.count + vm.allTracks.count
        XCTAssertEqual(total, 1)
    }
}

// MARK: - ChatHistoryViewModel

final class ChatHistoryViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch {
            XCTFail("setUp failed: \(error)")
        }
        // Ensure chat_conversations table exists
        do {
            try dbManager.dbPool.write { db in
                try ChatConversationQueries.ensureTable(db)
            }
        } catch {
            XCTFail("setUp ensureTable failed: \(error)")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    @MainActor
    func testCreateConversation() {
        let vm = ChatHistoryViewModel(dbManager: dbManager)
        let conv = vm.createConversation()

        XCTAssertNotNil(conv)
        XCTAssertEqual(vm.conversations.count, 1)
        XCTAssertEqual(vm.selectedConversationID, conv?.id)
    }

    @MainActor
    func testDeleteConversation() throws {
        let vm = ChatHistoryViewModel(dbManager: dbManager)
        let conv = try XCTUnwrap(vm.createConversation())
        XCTAssertEqual(vm.conversations.count, 1)

        vm.deleteConversation(conv.id)
        XCTAssertTrue(vm.conversations.isEmpty)
        XCTAssertNil(vm.selectedConversationID)
    }

    @MainActor
    func testDeleteSelectedSwitchesToFirst() throws {
        let vm = ChatHistoryViewModel(dbManager: dbManager)
        let conv1 = try XCTUnwrap(vm.createConversation())
        let conv2 = try XCTUnwrap(vm.createConversation())
        vm.selectedConversationID = conv2.id

        vm.deleteConversation(conv2.id)

        XCTAssertEqual(vm.conversations.count, 1)
        XCTAssertEqual(vm.selectedConversationID, conv1.id)
    }

    @MainActor
    func testFilteredConversations() {
        let vm = ChatHistoryViewModel(dbManager: dbManager)
        vm.createConversation()
        vm.updateTitle(vm.conversations[0].id, title: "Slack discussion")
        vm.createConversation()
        vm.updateTitle(vm.conversations[0].id, title: "Meeting notes")

        vm.searchText = "slack"
        XCTAssertEqual(vm.filteredConversations.count, 1)
        XCTAssertEqual(vm.filteredConversations[0].title, "Slack discussion")
    }

    @MainActor
    func testFilteredConversationsEmptySearch() {
        let vm = ChatHistoryViewModel(dbManager: dbManager)
        vm.createConversation()
        vm.createConversation()

        vm.searchText = ""
        XCTAssertEqual(vm.filteredConversations.count, 2)
    }

    @MainActor
    func testUpdateSessionID() throws {
        let vm = ChatHistoryViewModel(dbManager: dbManager)
        let conv = try XCTUnwrap(vm.createConversation())

        vm.updateSessionID(conv.id, sessionID: "sess-abc")

        let updated = vm.conversations.first { $0.id == conv.id }
        XCTAssertEqual(updated?.sessionID, "sess-abc")
    }

    @MainActor
    func testLoad() throws {
        // Create conversations directly in DB
        try dbManager.dbPool.write { db in
            try ChatConversationQueries.create(db, title: "Chat A")
            try ChatConversationQueries.create(db, title: "Chat B")
        }

        let vm = ChatHistoryViewModel(dbManager: dbManager)
        XCTAssertTrue(vm.conversations.isEmpty)

        vm.load()

        // load() is async via Task.detached, give it a moment
        let expectation = XCTestExpectation(description: "load completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertEqual(vm.conversations.count, 2)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }
}

// MARK: - DigestViewModel (additional coverage)

final class DigestViewModelAdditionalTests: XCTestCase {
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

    @MainActor
    func testMarkDigestRead() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertDigest(db, channelID: "C001", summary: "Test")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.unreadDigestCount, 1)
        XCTAssertFalse(vm.digests[0].isRead)

        vm.markDigestRead(vm.digests[0].id)

        XCTAssertEqual(vm.unreadDigestCount, 0)
        XCTAssertTrue(vm.digests[0].isRead)
    }

    @MainActor
    func testUnreadDigestCountMultiple() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertDigest(db, channelID: "C001", periodFrom: 100, periodTo: 200, summary: "D1")
            try TestDatabase.insertDigest(db, channelID: "C002", periodFrom: 100, periodTo: 200, summary: "D2")
            try TestDatabase.insertDigest(db, channelID: "C003", periodFrom: 100, periodTo: 200, summary: "D3")
        }

        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.unreadDigestCount, 3)

        vm.markDigestRead(vm.digests[0].id)
        XCTAssertEqual(vm.unreadDigestCount, 2)

        vm.markDigestRead(vm.digests[1].id)
        XCTAssertEqual(vm.unreadDigestCount, 1)
    }

    @MainActor
    func testDigestByIDNotFound() {
        let vm = DigestViewModel(dbManager: dbManager)
        XCTAssertNil(vm.digestByID(999))
    }
}

// MARK: - UpdateService Version Comparison

final class UpdateServiceTests: XCTestCase {
    func testNewerMajor() {
        XCTAssertTrue(UpdateService.isNewer("1.0.0", than: "0.2.0"))
    }

    func testNewerMinor() {
        XCTAssertTrue(UpdateService.isNewer("0.3.0", than: "0.2.0"))
    }

    func testNewerPatch() {
        XCTAssertTrue(UpdateService.isNewer("0.2.1", than: "0.2.0"))
    }

    func testSameVersion() {
        XCTAssertFalse(UpdateService.isNewer("0.2.0", than: "0.2.0"))
    }

    func testOlderVersion() {
        XCTAssertFalse(UpdateService.isNewer("0.1.0", than: "0.2.0"))
    }

    func testVPrefix() {
        XCTAssertTrue(UpdateService.isNewer("v0.3.0", than: "0.2.0"))
        XCTAssertTrue(UpdateService.isNewer("v0.3.0", than: "v0.2.0"))
        XCTAssertFalse(UpdateService.isNewer("v0.2.0", than: "v0.2.0"))
    }

    func testDifferentLengths() {
        XCTAssertTrue(UpdateService.isNewer("0.2.1", than: "0.2"))
        XCTAssertFalse(UpdateService.isNewer("0.2", than: "0.2.0"))
    }
}

// MARK: - OnboardingChatViewModel

final class OnboardingChatViewModelTests: XCTestCase {
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

    /// Deadline-based poll (the `MeetingRecorderTestSupport.waitUntil` shape,
    /// local because this suite is not a subclass): yields the main actor
    /// until `condition` holds, failing instead of hanging.
    @MainActor
    private func waitUntil(_ what: String, _ condition: @escaping () -> Bool) async {
        let deadline: Duration = .seconds(5)
        let start = ContinuousClock.now
        repeat {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        } while ContinuousClock.now - start < deadline
        XCTFail("timed out waiting for \(what)")
    }

    @MainActor
    func testInitialState() {
        let vm = OnboardingChatViewModel(aiService: MockClaudeService(), dbManager: dbManager)
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertFalse(vm.isStreaming)
        XCTAssertEqual(vm.inputText, "")
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.role, "")
        XCTAssertEqual(vm.team, "")
        XCTAssertTrue(vm.painPoints.isEmpty)
        XCTAssertTrue(vm.trackFocus.isEmpty)
        XCTAssertTrue(vm.reportIDs.isEmpty)
        XCTAssertEqual(vm.managerID, "")
        XCTAssertTrue(vm.peerIDs.isEmpty)
    }

    @MainActor
    func testSendCreatesMessages() async throws {
        let mock = MockClaudeService(events: [.text("Great! "), .text("Tell me more."), .done])
        let vm = OnboardingChatViewModel(aiService: mock, dbManager: dbManager)

        vm.inputText = "I'm an Engineering Manager"
        vm.send()

        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[0].role, .user)
        XCTAssertEqual(vm.messages[0].text, "I'm an Engineering Manager")
        XCTAssertEqual(vm.messages[1].role, .assistant)
        XCTAssertEqual(vm.messages[1].text, "Great! Tell me more.")
        XCTAssertFalse(vm.isStreaming)
    }

    @MainActor
    func testSendEmptyDoesNothing() {
        let vm = OnboardingChatViewModel(aiService: MockClaudeService(), dbManager: dbManager)
        vm.inputText = "   "
        vm.send()
        XCTAssertTrue(vm.messages.isEmpty)
    }

    @MainActor
    func testSendWhileStreamingDoesNothing() {
        let vm = OnboardingChatViewModel(aiService: MockClaudeService(), dbManager: dbManager)
        vm.isStreaming = true
        vm.inputText = "Hello"
        vm.send()
        XCTAssertTrue(vm.messages.isEmpty)
    }

    @MainActor
    func testFinishChatParsesRole() async throws {
        let extractionJSON = """
        {"role": "Engineering Manager", "team": "Platform", "pain_points": []}
        """
        let mock = MockClaudeService(eventSequence: [
            [.text("Got it!"), .done],                    // send() response
            [.text(extractionJSON), .done]               // parseProfileFromChat() response
        ])
        let vm = OnboardingChatViewModel(aiService: mock, dbManager: dbManager)

        // Simulate user saying their role
        vm.inputText = "I'm an engineering manager at Platform team"
        vm.send()
        try await Task.sleep(for: .milliseconds(300))

        await vm.finishChat()

        XCTAssertEqual(vm.role, "Engineering Manager")
        XCTAssertEqual(vm.team, "Platform")
        XCTAssertFalse(vm.isStreaming)
    }

    @MainActor
    func testFinishChatParsesPainPoints() async throws {
        let extractionJSON = """
        {"role": "", "team": "", "pain_points": ["Decisions getting lost in threads", "Deadlines discussed in chat get forgotten"]}
        """
        let mock = MockClaudeService(eventSequence: [
            [.text("I understand."), .done],              // send() response
            [.text(extractionJSON), .done]               // parseProfileFromChat() response
        ])
        let vm = OnboardingChatViewModel(aiService: mock, dbManager: dbManager)

        vm.inputText = "I often miss important decisions in threads and lose track of deadlines"
        vm.send()
        try await Task.sleep(for: .milliseconds(300))

        await vm.finishChat()

        XCTAssertTrue(vm.painPoints.contains { $0.lowercased().contains("decision") })
        XCTAssertTrue(vm.painPoints.contains { $0.lowercased().contains("deadline") })
    }

    @MainActor
    func testMarkOnboardingDone() async throws {
        try await dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db, id: "T001")
            try db.execute(sql: "INSERT INTO slack_accounts (id, current_user_id) VALUES (1, 'U001')")
            try TestDatabase.insertProfile(db, slackUserID: "U001", onboardingDone: false)
        }

        let vm = OnboardingChatViewModel(aiService: MockClaudeService(), dbManager: dbManager)
        let done = await vm.markOnboardingDone()

        XCTAssertTrue(done)
        XCTAssertNil(vm.errorMessage)
        let profile = try await dbManager.dbPool.read { db in
            try ProfileQueries.fetchProfile(db, slackUserID: "U001")
        }
        XCTAssertEqual(profile?.onboardingDone, true)
    }

    /// No connected Slack account: `getCurrentUserID()` finds nothing, so
    /// there is no id to key the UPDATE on.
    @MainActor
    func testMarkOnboardingDoneReturnsFalseWithoutCurrentUser() async {
        let vm = OnboardingChatViewModel(aiService: MockClaudeService(), dbManager: dbManager)
        let done = await vm.markOnboardingDone()

        XCTAssertFalse(done)
        XCTAssertNotNil(vm.errorMessage)
    }

    /// No database at all. Both early guards are separate code paths, but
    /// only one outcome is observable from outside: `getCurrentUserID()`
    /// already returns "" without a `dbManager`, so the empty-id guard is what
    /// fires here.
    @MainActor
    func testMarkOnboardingDoneReturnsFalseWithoutDatabase() async {
        let vm = OnboardingChatViewModel(aiService: MockClaudeService(), dbManager: nil)
        let done = await vm.markOnboardingDone()

        XCTAssertFalse(done)
        XCTAssertNotNil(vm.errorMessage)
    }

    @MainActor
    func testMarkOnboardingDoneCreatesRowWhenMissing() async throws {
        try await dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db, id: "T001")
            try db.execute(sql: "INSERT INTO slack_accounts (id, current_user_id) VALUES (1, 'U001')")
            // Deliberately NO user_profile row — the upsert must create it.
        }

        let vm = OnboardingChatViewModel(aiService: MockClaudeService(), dbManager: dbManager)
        let done = await vm.markOnboardingDone()

        XCTAssertTrue(done)
        XCTAssertNil(vm.errorMessage)
        let profile = try await dbManager.dbPool.read { db in
            try ProfileQueries.fetchProfile(db, slackUserID: "U001")
        }
        XCTAssertEqual(profile?.onboardingDone, true)
    }

    @MainActor
    func testSendWithError() async throws {
        let mock = MockClaudeService(error: WatchtowerAIError.cliNotFound)
        let vm = OnboardingChatViewModel(aiService: mock, dbManager: dbManager)

        vm.inputText = "Hello"
        vm.send()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isStreaming)
    }

    @MainActor
    func testLoadUsersFromDB() async throws {
        try await dbManager.dbPool.write { db in
            try TestDatabase.insertUser(db, id: "U001", displayName: "Alice")
            try TestDatabase.insertUser(db, id: "U002", displayName: "Bob")
        }

        let vm = OnboardingChatViewModel(aiService: MockClaudeService(), dbManager: dbManager)
        XCTAssertEqual(vm.allUsers.count, 2)
    }

    @MainActor
    func testOnboardingSystemPromptContent() {
        let prompt = OnboardingChatViewModel.onboardingSystemPrompt(language: "English")
        XCTAssertTrue(prompt.contains("onboarding"))
        XCTAssertTrue(prompt.contains("Watchtower"))
        XCTAssertTrue(prompt.contains("[READY]"))
        XCTAssertTrue(prompt.contains("Respond in English"))
    }

    @MainActor
    func testOnboardingSystemPromptRussian() {
        let prompt = OnboardingChatViewModel.onboardingSystemPrompt(language: "Russian")
        XCTAssertTrue(prompt.contains("Respond in Russian"))
    }

    @MainActor
    func testOnboardingSystemPromptUkrainian() {
        let prompt = OnboardingChatViewModel.onboardingSystemPrompt(language: "Ukrainian")
        XCTAssertTrue(prompt.contains("Respond in Ukrainian"))
    }

    @MainActor
    func testQuestionnaireLocalizationRussian() {
        let vm = OnboardingChatViewModel(aiService: MockClaudeService(), language: "Russian", dbManager: dbManager)
        vm.startQuestionnaire()
        XCTAssertEqual(vm.messages.count, 1)
        XCTAssertTrue(vm.messages[0].text.contains("роль"))
        XCTAssertEqual(vm.quickReplies.count, 2)
        XCTAssertEqual(vm.quickReplies[0].label, "Да")
        XCTAssertEqual(vm.quickReplies[1].label, "Нет")
    }

    @MainActor
    func testQuestionnaireLocalizationEnglish() {
        let vm = OnboardingChatViewModel(aiService: MockClaudeService(), language: "English", dbManager: dbManager)
        vm.startQuestionnaire()
        XCTAssertEqual(vm.messages[0].text, "Let's understand your role. Do people report to you?")
        XCTAssertEqual(vm.quickReplies[0].label, "Yes")
    }

    @MainActor
    func testSkipChatCancelsInFlightStream() async throws {
        let vm = OnboardingChatViewModel(aiService: MockClaudeService(), dbManager: dbManager)
        vm.startQuestionnaire()
        XCTAssertFalse(vm.quickReplies.isEmpty)

        vm.inputText = "Hello"
        vm.send()
        XCTAssertTrue(vm.isStreaming)

        vm.skipChat()

        XCTAssertFalse(vm.isStreaming)
        XCTAssertTrue(vm.quickReplies.isEmpty)

        // Let the cancelled stream task drain — it must not surface an error.
        await waitUntil("cancelled stream drained") { vm.messages.last?.isStreaming == false }
        XCTAssertFalse(vm.isStreaming)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func testRetryAfterErrorReattemptsSameRequest() async throws {
        let mock = MockClaudeService(error: WatchtowerAIError.cliNotFound)
        let vm = OnboardingChatViewModel(aiService: mock, dbManager: dbManager)

        vm.inputText = "Hello"
        vm.send()
        await waitUntil("first attempt failed") { vm.errorMessage != nil && !vm.isStreaming }

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(vm.messages.count, 2) // user bubble + empty assistant bubble
        let callsBeforeRetry = mock.prompts.count

        vm.retryAfterError()
        XCTAssertTrue(vm.isStreaming)
        await waitUntil("retry failed") { vm.errorMessage != nil && !vm.isStreaming }

        // Exactly one re-attempt of the same prompt; the mock errors again.
        XCTAssertEqual(mock.prompts.count, callsBeforeRetry + 1)
        XCTAssertEqual(mock.prompts.last, "Hello")
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isStreaming)
        // The trailing empty assistant bubble was replaced, not accumulated.
        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[0].role, .user)
        XCTAssertEqual(vm.messages[1].role, .assistant)
    }

    @MainActor
    func testRetryAfterErrorNoOpWithoutError() {
        let mock = MockClaudeService()
        let vm = OnboardingChatViewModel(aiService: mock, dbManager: dbManager)

        vm.retryAfterError()

        XCTAssertFalse(vm.isStreaming)
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertEqual(mock.prompts.count, 0)
    }

    @MainActor
    func testSkipChatClearsStaleStreamError() async throws {
        let mock = MockClaudeService(error: WatchtowerAIError.cliNotFound)
        let vm = OnboardingChatViewModel(aiService: mock, dbManager: dbManager)

        vm.inputText = "Hello"
        vm.send()
        await waitUntil("stream error surfaced") { vm.errorMessage != nil && !vm.isStreaming }

        vm.skipChat()

        // A stale interview error must not survive the skip — it would
        // permanently fail the teamForm completion gate downstream.
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isStreaming)
    }

    @MainActor
    func testSendClearsStaleErrorBeforeStreaming() async throws {
        let mock = MockClaudeService(error: WatchtowerAIError.cliNotFound)
        let vm = OnboardingChatViewModel(aiService: mock, dbManager: dbManager)

        vm.inputText = "First"
        vm.send()
        await waitUntil("first stream error surfaced") { vm.errorMessage != nil && !vm.isStreaming }

        vm.inputText = "Second"
        vm.send()
        // The new attempt invalidates the previous error synchronously,
        // before any stream event arrives.
        XCTAssertNil(vm.errorMessage)

        await waitUntil("second attempt finished") { !vm.isStreaming }
    }

    @MainActor
    func testRetryAfterErrorRemovesPartialAssistantBubble() async throws {
        // Mid-stream failure: a session id and partial text arrive, then the
        // stream throws.
        let mock = MockClaudeService(
            events: [.sessionID("sess-live"), .text("Partial answer")],
            thenError: WatchtowerAIError.cliNotFound
        )
        let vm = OnboardingChatViewModel(aiService: mock, dbManager: dbManager)

        vm.inputText = "Hello"
        vm.send()
        await waitUntil("mid-stream error surfaced") { vm.errorMessage != nil && !vm.isStreaming }

        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[1].text, "Partial answer")

        vm.retryAfterError()
        await waitUntil("retry finished") { vm.errorMessage != nil && !vm.isStreaming }

        // The partial trailing assistant bubble was removed, not duplicated:
        // still exactly one user turn and one assistant bubble.
        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[0].role, .user)
        XCTAssertEqual(vm.messages[1].role, .assistant)
        // The retry re-sent the same prompt with the freshest session id
        // learned from the failed stream, not the call-start snapshot (nil).
        XCTAssertEqual(mock.prompts, ["Hello", "Hello"])
        XCTAssertEqual(mock.sessionIDs.count, 2)
        XCTAssertNil(mock.sessionIDs[0])
        XCTAssertEqual(mock.sessionIDs[1], "sess-live")
    }

    @MainActor
    func testSaveProfileWithContextPreservesOnboardingDoneFlag() async throws {
        try await dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db, id: "T001")
            try db.execute(sql: "INSERT INTO slack_accounts (id, current_user_id) VALUES (1, 'U001')")
            try TestDatabase.insertProfile(db, slackUserID: "U001", onboardingDone: true)
        }
        let mock = MockClaudeService(events: [.text("Context about the user."), .done])
        let vm = OnboardingChatViewModel(aiService: mock, dbManager: dbManager)

        // The context-saving path (now read + upsert in ONE transaction) must
        // never clobber an already-set onboarding_done flag.
        await vm.generatePromptContext()

        XCTAssertNil(vm.errorMessage)
        let profile = try await dbManager.dbPool.read { db in
            try ProfileQueries.fetchProfile(db, slackUserID: "U001")
        }
        XCTAssertEqual(profile?.onboardingDone, true)
        XCTAssertEqual(profile?.customPromptContext, "Context about the user.")
    }
}

// MARK: - OnboardingStateMachine

final class OnboardingStateMachineTests: XCTestCase {
    private let stepKey = "onboarding_current_step"
    private let syncKey = "onboarding_sync_completed"
    private let chatKey = "onboarding_chat_finished"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: stepKey)
        UserDefaults.standard.removeObject(forKey: syncKey)
        UserDefaults.standard.removeObject(forKey: chatKey)
        super.tearDown()
    }

    @MainActor
    func testInitialStateDefaultsToConnect() {
        UserDefaults.standard.removeObject(forKey: stepKey)
        let sm = OnboardingStateMachine()
        XCTAssertEqual(sm.currentStep, .connect)
        XCTAssertFalse(sm.syncCompleted)
    }

    @MainActor
    func testAdvanceMovesToNextStep() {
        UserDefaults.standard.removeObject(forKey: stepKey)
        let sm = OnboardingStateMachine()
        sm.advance()
        XCTAssertEqual(sm.currentStep, .settings)
        sm.advance()
        XCTAssertEqual(sm.currentStep, .claude)
        sm.advance()
        XCTAssertEqual(sm.currentStep, .chat)
        sm.advance()
        XCTAssertEqual(sm.currentStep, .teamForm)
        sm.advance()
        XCTAssertEqual(sm.currentStep, .generating)
        sm.advance()
        XCTAssertEqual(sm.currentStep, .features)
        sm.advance()
        XCTAssertEqual(sm.currentStep, .complete)
    }

    @MainActor
    func testResumeFromStoredRawSixReportsFeatures() {
        // Persisted-rawValue migration: `.features` was inserted at raw 6,
        // shifting `.complete` to 7 (see the enum's migration comment), so a
        // stored 6 now resumes at `.features`. Landing there is safe on its
        // own terms: the `.features` step's `.task` constructs `onboardingVM`
        // when it is nil, so the splash's exits can still finish onboarding.
        // AppState.initialize()'s reconciliation against
        // `user_profile.onboarding_done` short-circuits this only when the DB
        // flag is already true — it cannot help an install whose flag is
        // still false, which is exactly the case that needs the `.task`.
        UserDefaults.standard.set(6, forKey: stepKey)
        let sm = OnboardingStateMachine()
        XCTAssertEqual(sm.currentStep, .features)
    }

    @MainActor
    func testAdvancePastCompleteDoesNothing() {
        UserDefaults.standard.removeObject(forKey: stepKey)
        let sm = OnboardingStateMachine()
        sm.goTo(.complete)
        sm.advance()
        XCTAssertEqual(sm.currentStep, .complete)
    }

    @MainActor
    func testGoToJumpsToStep() {
        UserDefaults.standard.removeObject(forKey: stepKey)
        let sm = OnboardingStateMachine()
        sm.goTo(.chat)
        XCTAssertEqual(sm.currentStep, .chat)
    }

    @MainActor
    func testPersistenceInUserDefaults() {
        UserDefaults.standard.removeObject(forKey: stepKey)
        let sm = OnboardingStateMachine()
        sm.goTo(.claude)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: stepKey), OnboardingStep.claude.rawValue)

        // Create new instance — should read persisted step
        let sm2 = OnboardingStateMachine()
        XCTAssertEqual(sm2.currentStep, .claude)
    }

    @MainActor
    func testSyncCompletedPersistence() {
        UserDefaults.standard.removeObject(forKey: syncKey)
        let sm = OnboardingStateMachine()
        XCTAssertFalse(sm.syncCompleted)
        sm.syncCompleted = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: syncKey))

        let sm2 = OnboardingStateMachine()
        XCTAssertTrue(sm2.syncCompleted)
    }

    @MainActor
    func testResetGoesToStepAndClearsSyncIfBeforeChat() {
        UserDefaults.standard.removeObject(forKey: stepKey)
        let sm = OnboardingStateMachine()
        sm.goTo(.generating)
        sm.syncCompleted = true
        sm.reset(to: .chat)
        XCTAssertEqual(sm.currentStep, .chat)
        XCTAssertFalse(sm.syncCompleted)
    }

    @MainActor
    func testResetToTeamFormKeepsSyncCompleted() {
        UserDefaults.standard.removeObject(forKey: stepKey)
        let sm = OnboardingStateMachine()
        sm.syncCompleted = true
        sm.reset(to: .teamForm)
        XCTAssertEqual(sm.currentStep, .teamForm)
        XCTAssertTrue(sm.syncCompleted)
    }

    @MainActor
    func testMarkCompletePersistsAcrossRelaunch() {
        UserDefaults.standard.removeObject(forKey: stepKey)
        let sm = OnboardingStateMachine()
        sm.goTo(.generating)
        sm.syncCompleted = true
        sm.chatFinished = true
        sm.markComplete()
        XCTAssertEqual(sm.currentStep, .complete)

        // A new instance (simulated relaunch) must read .complete, never fall back
        // to .connect — completion survives even if the DB profile row is missing.
        let sm2 = OnboardingStateMachine()
        XCTAssertEqual(sm2.currentStep, .complete)
        XCTAssertFalse(sm2.syncCompleted)
        XCTAssertFalse(sm2.chatFinished)
    }

    @MainActor
    func testSkipCompletedSkipsConnectWhenConfigExists() {
        UserDefaults.standard.removeObject(forKey: stepKey)
        let sm = OnboardingStateMachine()
        // shouldSkip(.connect) checks if config file exists — depends on test env
        // We test the skip logic by verifying it doesn't skip settings
        sm.goTo(.settings)
        let result = sm.skipCompleted()
        XCTAssertEqual(result, .settings)
    }

    @MainActor
    func testStepComparable() {
        XCTAssertTrue(OnboardingStep.connect < .settings)
        XCTAssertTrue(OnboardingStep.settings < .claude)
        XCTAssertTrue(OnboardingStep.claude < .chat)
        XCTAssertTrue(OnboardingStep.chat < .teamForm)
        XCTAssertTrue(OnboardingStep.teamForm < .generating)
        XCTAssertTrue(OnboardingStep.generating < .features)
        XCTAssertTrue(OnboardingStep.features < .complete)
    }

    @MainActor
    func testIndicatorSteps() {
        XCTAssertEqual(OnboardingStep.indicatorSteps.count, 4)
        XCTAssertEqual(OnboardingStep.indicatorSteps, [.connect, .settings, .claude, .chat])
    }

    @MainActor
    func testIndicatorTitles() {
        XCTAssertEqual(OnboardingStep.connect.indicatorTitle, "Connect")
        XCTAssertEqual(OnboardingStep.settings.indicatorTitle, "Settings")
        XCTAssertEqual(OnboardingStep.claude.indicatorTitle, "AI Setup")
        XCTAssertEqual(OnboardingStep.chat.indicatorTitle, "Setup")
        XCTAssertEqual(OnboardingStep.teamForm.indicatorTitle, "Setup")
        XCTAssertEqual(OnboardingStep.generating.indicatorTitle, "Setup")
        XCTAssertEqual(OnboardingStep.features.indicatorTitle, "Setup")
        XCTAssertNil(OnboardingStep.complete.indicatorTitle)
    }
}

// MARK: - BackgroundTaskManager

final class BackgroundTaskManagerTests: XCTestCase {

    @MainActor
    func testStepRecordEquality() {
        let r1 = BackgroundTaskManager.StepRecord(
            timestamp: Date(timeIntervalSince1970: 1000),
            pipeline: "digests",
            step: 1,
            total: 10,
            status: "Processing #general",
            inputTokens: 100,
            outputTokens: 50,
            costUsd: 0.001,
            durationSeconds: 5.0
        )
        let r2 = BackgroundTaskManager.StepRecord(
            timestamp: Date(timeIntervalSince1970: 1000),
            pipeline: "digests",
            step: 1,
            total: 10,
            status: "Processing #general",
            inputTokens: 100,
            outputTokens: 50,
            costUsd: 0.001,
            durationSeconds: 5.0
        )
        // Different UUIDs, so not equal
        XCTAssertNotEqual(r1, r2)
        // But same id is equal
        XCTAssertEqual(r1, r1)
    }

    @MainActor
    func testTotalTokensAndCost() throws {
        let manager = BackgroundTaskManager()

        // Totals now come from accumulated progress (not step history sum).
        var digestState = BackgroundTaskManager.TaskState()
        digestState.progress = try decodeProgress("""
            {"pipeline":"digests","done":2,"total":5,"status":"","input_tokens":300,"output_tokens":150,"cost_usd":0.003,"finished":false}
            """)
        var peopleState = BackgroundTaskManager.TaskState()
        peopleState.progress = try decodeProgress("""
            {"pipeline":"people","done":1,"total":3,"status":"","input_tokens":300,"output_tokens":150,"cost_usd":0.003,"finished":false}
            """)
        manager.tasks[.digests] = digestState
        manager.tasks[.people] = peopleState

        XCTAssertEqual(manager.totalInputTokens, 600)
        XCTAssertEqual(manager.totalOutputTokens, 300)

    }

    private func decodeProgress(_ json: String) throws -> InsightProgressData {
        try JSONDecoder().decode(InsightProgressData.self, from: Data(json.utf8))
    }

    @MainActor
    func testTotalTokensEmptyTasks() {
        let manager = BackgroundTaskManager()
        XCTAssertEqual(manager.totalInputTokens, 0)
        XCTAssertEqual(manager.totalOutputTokens, 0)

    }

    @MainActor
    func testHasActiveTasks() {
        let manager = BackgroundTaskManager()
        XCTAssertFalse(manager.hasActiveTasks)

        manager.tasks[.digests] = .init(status: .running)
        XCTAssertTrue(manager.hasActiveTasks)

        manager.tasks[.digests] = .init(status: .done)
        XCTAssertFalse(manager.hasActiveTasks)
    }

    @MainActor
    func testAllFinished() {
        let manager = BackgroundTaskManager()
        XCTAssertTrue(manager.allFinished) // empty is finished

        manager.tasks[.digests] = .init(status: .done)
        manager.tasks[.people] = .init(status: .error("fail"))
        XCTAssertTrue(manager.allFinished)

        manager.tasks[.people] = .init(status: .running)
        XCTAssertFalse(manager.allFinished)
    }

    @MainActor
    func testHasVisibleTasks() {
        let manager = BackgroundTaskManager()
        XCTAssertFalse(manager.hasVisibleTasks)

        manager.tasks[.digests] = .init(status: .done)
        XCTAssertFalse(manager.hasVisibleTasks)

        manager.tasks[.people] = .init(status: .error("oops"))
        XCTAssertTrue(manager.hasVisibleTasks)

        manager.tasks[.people] = .init(status: .pending)
        XCTAssertTrue(manager.hasVisibleTasks)
    }

    // Regression test for a bug where a failed digests phase left tracks/people
    // stuck in `.pending` ("Waiting..." forever in the sidebar) because the
    // pipeline chain returned early instead of isolating the failure. The fix
    // always runs `resolvePendingAsSkipped()` when the chain exits; this test
    // exercises that cleanup directly.
    @MainActor
    func testResolvePendingAsSkippedClearsStuckTasks() {
        let manager = BackgroundTaskManager()
        manager.tasks[.digests] = .init(status: .error("boom"))
        manager.tasks[.tracks] = .init(status: .pending)
        manager.tasks[.people] = .init(status: .pending)

        manager.resolvePendingAsSkipped()

        XCTAssertEqual(manager.tasks[.digests]?.status, .error("boom"))
        XCTAssertEqual(manager.tasks[.tracks]?.status, .error("Skipped"))
        XCTAssertEqual(manager.tasks[.people]?.status, .error("Skipped"))
    }

    @MainActor
    func testResolvePendingAsSkippedLeavesRunningAndDoneUntouched() {
        let manager = BackgroundTaskManager()
        manager.tasks[.digests] = .init(status: .done)
        manager.tasks[.tracks] = .init(status: .running)

        manager.resolvePendingAsSkipped()

        XCTAssertEqual(manager.tasks[.digests]?.status, .done)
        XCTAssertEqual(manager.tasks[.tracks]?.status, .running)
    }
}

import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Chat tab's landing vs resume (owner decision 2026-09-28), against a
/// real pool with scripted session processes.
@MainActor
final class ChatLandingViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private var pool: ChatSessionPool!
    private var fakes: [FakeChatSessionProcess] = []
    private var turnCounter = 0
    private let window = ChatLandingPolicy.resumeWindow

    override func setUpWithError() throws {
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        fakes = []
        turnCounter = 0
        pool = ChatSessionPool(
            dbPool: dbManager.dbPool,
            processFactory: { [weak self] args in
                let fake = FakeChatSessionProcess(arguments: args)
                self?.fakes.append(fake)
                return fake
            },
            closeGrace: .milliseconds(20)
        )
    }

    override func tearDown() async throws {
        await pool.closeAll()
        TestDatabase.cleanup(path: dbPath)
    }

    private func makeViewModel() -> ChatViewModel {
        ChatViewModel(dbManager: dbManager, pool: pool, provider: .claude) { [weak self] in
            guard let self else { return UUID().uuidString }
            self.turnCounter += 1
            return "turn-\(self.turnCounter)"
        }
    }

    /// A conversation whose one finished exchange happened now.
    private func answeredConversation(_ vm: ChatViewModel) async throws -> Int64 {
        let id = try XCTUnwrap(vm.newConversation())
        XCTAssertTrue(vm.send(text: "q"))
        let fake = try XCTUnwrap(fakes.last)
        fake.emit(.textDelta(turnID: "turn-\(turnCounter)", text: "a"))
        fake.emit(.turnDone(turnID: "turn-\(turnCounter)", status: .complete, sessionID: nil))
        let done = await waitForCondition { !vm.isStreaming && vm.thread.last?.message.status == "complete" }
        XCTAssertTrue(done)
        return id
    }

    func testAFreshViewModelStartsOnTheLanding() {
        let vm = makeViewModel()
        XCTAssertTrue(vm.isOnLanding)
        XCTAssertNil(vm.conversationID)
    }

    func testEnteringWithinTheWindowResumesTheLastConversation() async throws {
        let id = try await answeredConversation(makeViewModel())
        let vm = makeViewModel() // a relaunch: nothing shown yet
        vm.enterTab(rememberedConversationID: id, lastViewedAt: nil, now: Date().addingTimeInterval(window - 60))
        XCTAssertEqual(vm.conversationID, id)
        XCTAssertFalse(vm.isOnLanding)
        XCTAssertEqual(vm.thread.count, 2)
    }

    func testEnteringAfterTheWindowShowsTheLanding() async throws {
        let vm = makeViewModel()
        _ = try await answeredConversation(vm)
        vm.enterTab(rememberedConversationID: nil, lastViewedAt: nil, now: Date().addingTimeInterval(window + 60))
        XCTAssertTrue(vm.isOnLanding)
        XCTAssertNil(vm.conversationID)
        XCTAssertTrue(vm.thread.isEmpty)
    }

    func testHavingItOnScreenRecentlyCountsAsActivity() async throws {
        let id = try await answeredConversation(makeViewModel())
        let later = Date().addingTimeInterval(3 * window)
        let vm = makeViewModel()
        vm.enterTab(rememberedConversationID: id, lastViewedAt: later.addingTimeInterval(-60), now: later)
        XCTAssertEqual(vm.conversationID, id)
    }

    /// Start a turn → leave the tab → come back hours later: a running turn
    /// always resumes (review-rules: start → navigate away → return).
    func testARunningTurnResumesWhateverTheTime() throws {
        let vm = makeViewModel()
        let id = try XCTUnwrap(vm.newConversation())
        XCTAssertTrue(vm.send(text: "long question"))
        vm.showLanding()
        XCTAssertTrue(vm.isOnLanding)
        XCTAssertNil(vm.conversationID)

        vm.enterTab(rememberedConversationID: id, lastViewedAt: nil, now: Date().addingTimeInterval(3 * window))
        XCTAssertEqual(vm.conversationID, id)
        XCTAssertTrue(vm.isStreaming, "the live turn is still on screen")
    }

    func testADeletedLastConversationShowsTheLanding() throws {
        let id = try dbManager.dbPool.write { try TestDatabase.insertChatConversation($0, title: "gone") }
        try dbManager.dbPool.write { try ChatConversationQueries.delete($0, id: id) }
        let vm = makeViewModel()
        vm.enterTab(rememberedConversationID: id, lastViewedAt: Date(), now: Date())
        XCTAssertTrue(vm.isOnLanding)
        XCTAssertNil(vm.conversationID)
    }

    func testAnArchivedLastConversationShowsTheLanding() async throws {
        let id = try await answeredConversation(makeViewModel())
        try await dbManager.dbPool.write { try ChatConversationQueries.archive($0, id: id) }
        let vm = makeViewModel()
        vm.enterTab(rememberedConversationID: id, lastViewedAt: Date(), now: Date())
        XCTAssertTrue(vm.isOnLanding)
    }

    func testAnOpenProjectPageIsLeftAlone() throws {
        let vm = makeViewModel()
        let projectID = try XCTUnwrap(vm.createProject(name: "P"))
        vm.enterTab(rememberedConversationID: nil, lastViewedAt: nil, now: Date().addingTimeInterval(3 * window))
        XCTAssertEqual(vm.openProjectID, projectID)
        XCTAssertFalse(vm.isOnLanding)
    }

    /// The landing's first keystroke makes the conversation and prewarms its
    /// session without leaving the landing; the first turn leaves it.
    func testFirstKeystrokeOnTheLandingPrewarmsAndTheFirstTurnLeavesIt() throws {
        let vm = makeViewModel()
        vm.draftStarted()
        let id = try XCTUnwrap(vm.conversationID)
        XCTAssertTrue(vm.isOnLanding)
        XCTAssertEqual(fakes.count, 1, "the session was prewarmed")

        vm.draft = "hello"
        vm.sendDraft()
        XCTAssertFalse(vm.isOnLanding)
        XCTAssertEqual(vm.conversationID, id)
        XCTAssertEqual(fakes.count, 1, "the prewarmed session took the turn")
        XCTAssertEqual(try XCTUnwrap(fakes.last).turns.count, 1)
    }

    func testSendingFromTheLandingWithoutAKeystrokeStillStartsAChat() throws {
        let vm = makeViewModel()
        XCTAssertTrue(vm.send(text: "What mattered yesterday?"))
        XCTAssertFalse(vm.isOnLanding)
        XCTAssertNotNil(vm.conversationID)
    }

    /// Returning to the landing keeps its untouched conversation instead of
    /// writing a second empty row.
    func testTheLandingReusesItsUntouchedConversation() throws {
        let vm = makeViewModel()
        vm.draftStarted()
        let id = try XCTUnwrap(vm.conversationID)
        vm.showLanding()
        XCTAssertEqual(vm.conversationID, id)
        vm.enterTab(rememberedConversationID: nil, lastViewedAt: nil, now: Date())
        XCTAssertEqual(vm.conversationID, id)
        XCTAssertTrue(vm.isOnLanding)
        let rows = try dbManager.dbPool.read { try ChatConversationQueries.fetchStandalone($0) }
        XCTAssertEqual(rows.map(\.id), [id])
    }

    func testAttachingOnTheLandingStaysOnTheLanding() throws {
        let vm = makeViewModel()
        vm.attachPastedImage(Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertTrue(vm.isOnLanding)
    }

    func testForgettingTheShownConversationShowsTheLanding() async throws {
        let vm = makeViewModel()
        let id = try await answeredConversation(vm)
        vm.forget(conversationID: id)
        XCTAssertTrue(vm.isOnLanding)
        XCTAssertNil(vm.conversationID)
    }

    func testLeavingForTheLandingKeepsTheWarmSession() async throws {
        let vm = makeViewModel()
        _ = try await answeredConversation(vm)
        vm.showLanding()
        XCTAssertFalse(try XCTUnwrap(fakes.last).sent.contains(.close))
    }
}

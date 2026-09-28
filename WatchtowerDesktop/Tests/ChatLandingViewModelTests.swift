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

    // MARK: - Review round 1

    private func rowExists(_ id: Int64) throws -> Bool {
        try dbManager.dbPool.read { try ChatConversationQueries.fetchByID($0, id: id) } != nil
    }

    /// The main chat's two VMs wired exactly as AppState wires them.
    private func wiredPair() -> (ChatViewModel, ChatHistoryViewModel) {
        let vm = makeViewModel()
        let history = ChatHistoryViewModel(dbManager: dbManager, attachmentsRoot: nil)
        AppState.wireChat(vm, history: history)
        return (vm, history)
    }

    /// I-1: only the landing's own first turn announces itself — once.
    func testTheLandingsFirstTurnIsAnnouncedOnce() throws {
        let vm = makeViewModel()
        var started: [Int64] = []
        vm.onLandingTurnStarted = { started.append($0) }
        vm.draftStarted()
        let id = try XCTUnwrap(vm.conversationID)
        XCTAssertTrue(started.isEmpty, "a keystroke is not a turn")
        XCTAssertTrue(vm.send(text: "q"))
        XCTAssertEqual(started, [id])
        XCTAssertNil(vm.landingDraftID)
        try XCTUnwrap(fakes.last).emit(.turnDone(turnID: "turn-1", status: .complete, sessionID: nil))
        vm.select(conversationID: id)
        XCTAssertEqual(started, [id], "leaving the landing any other way is not announced")
    }

    /// I-1 glue: landing → type a character → open a project shows the
    /// project page; the history selection is not moved to the draft.
    func testLandingKeystrokeThenOpenProjectShowsTheProjectPage() throws {
        let (vm, history) = wiredPair()
        let projectID = try dbManager.dbPool.write { try ChatProjectQueries.create($0, name: "P") }.id
        vm.draftStarted()
        let draftID = try XCTUnwrap(vm.conversationID)
        vm.openProject(projectID)
        XCTAssertEqual(vm.openProjectID, projectID)
        XCTAssertFalse(vm.isOnLanding)
        XCTAssertNil(history.selectedConversationID)
        XCTAssertNil(vm.conversationID)
        XCTAssertFalse(try rowExists(draftID), "the untouched draft goes (I-2)")
        XCTAssertNil(pool.client(for: draftID), "and so does its session")
    }

    func testLandingsFirstTurnBecomesTheHistorySelection() throws {
        let (vm, history) = wiredPair()
        XCTAssertTrue(vm.send(text: "hi"))
        XCTAssertEqual(history.selectedConversationID, vm.conversationID)
    }

    /// I-2: picking another chat discards the untouched draft and its session.
    func testSelectingAnotherChatDiscardsTheUntouchedDraft() async throws {
        let other = try await answeredConversation(makeViewModel())
        let vm = makeViewModel()
        vm.draftStarted()
        let draftID = try XCTUnwrap(vm.conversationID)
        XCTAssertNotNil(pool.client(for: draftID))
        vm.select(conversationID: other)
        XCTAssertFalse(try rowExists(draftID))
        XCTAssertNil(pool.client(for: draftID))
    }

    func testOpeningASearchHitDiscardsTheUntouchedDraft() async throws {
        let other = try await answeredConversation(makeViewModel())
        let vm = makeViewModel()
        vm.draftStarted()
        let draftID = try XCTUnwrap(vm.conversationID)
        vm.open(ChatSearchHit(conversationID: other, messageID: nil, title: "", snippet: ""))
        XCTAssertFalse(try rowExists(draftID))
        XCTAssertEqual(vm.conversationID, other)
    }

    /// A draft that gained a message elsewhere (never through this VM in
    /// practice) is not deleted: the delete re-checks untouched-ness.
    func testADraftWithAMessageIsNeverDiscarded() async throws {
        let other = try await answeredConversation(makeViewModel())
        let vm = makeViewModel()
        vm.draftStarted()
        let draftID = try XCTUnwrap(vm.conversationID)
        try await dbManager.dbPool.write {
            try TestDatabase.insertChatMessage($0, conversationID: draftID, role: "user", text: "x")
        }
        vm.select(conversationID: other)
        XCTAssertTrue(try rowExists(draftID))
    }

    func testDraftStartedReusesAnExistingUntouchedRow() throws {
        let existing = try dbManager.dbPool.write { try TestDatabase.insertChatConversation($0, title: "") }
        let vm = makeViewModel()
        vm.draftStarted()
        XCTAssertEqual(vm.conversationID, existing)
        XCTAssertTrue(vm.isOnLanding)
        let rows = try dbManager.dbPool.read { try ChatConversationQueries.fetchStandalone($0) }
        XCTAssertEqual(rows.map(\.id), [existing])
    }

    func testLaunchCleanupDropsOnlyUntouchedStandaloneChats() async throws {
        let answered = try await answeredConversation(makeViewModel())
        let (empty, inProject) = try await dbManager.dbPool.write { d -> (Int64, Int64) in
            let empty = try TestDatabase.insertChatConversation(d, title: "")
            let project = try ChatProjectQueries.create(d, name: "P")
            let inProject = try ChatConversationQueries.create(d, projectID: project.id).id
            return (empty, inProject)
        }
        makeViewModel().cleanUpUntouchedConversations()
        XCTAssertFalse(try rowExists(empty))
        XCTAssertTrue(try rowExists(answered))
        XCTAssertTrue(try rowExists(inProject))
    }

    /// I-3: unsent text forces a resume whatever the time.
    func testUnsentDraftResumesAfterTheWindow() async throws {
        let vm = makeViewModel()
        let id = try await answeredConversation(vm)
        vm.draft = "half-typed"
        vm.enterTab(rememberedConversationID: id, lastViewedAt: nil, now: Date().addingTimeInterval(3 * window))
        XCTAssertEqual(vm.conversationID, id)
        XCTAssertFalse(vm.isOnLanding)
    }

    func testWhitespaceDraftIsNotUnsentInput() async throws {
        let vm = makeViewModel()
        _ = try await answeredConversation(vm)
        vm.draft = "  \n "
        vm.enterTab(rememberedConversationID: nil, lastViewedAt: nil, now: Date().addingTimeInterval(3 * window))
        XCTAssertTrue(vm.isOnLanding)
    }

    func testTheLandingWithUnsentTextStaysPut() throws {
        let vm = makeViewModel()
        vm.draft = "hello"
        vm.draftStarted()
        let draftID = try XCTUnwrap(vm.conversationID)
        vm.enterTab(rememberedConversationID: nil, lastViewedAt: nil, now: Date().addingTimeInterval(3 * window))
        XCTAssertTrue(vm.isOnLanding)
        XCTAssertEqual(vm.conversationID, draftID)
        XCTAssertEqual(vm.draft, "hello")
    }

    /// M-3: deleting the open project lands.
    func testDeletingTheOpenProjectShowsTheLanding() throws {
        let vm = makeViewModel()
        let projectID = try XCTUnwrap(vm.createProject(name: "P"))
        _ = try dbManager.dbPool.write { try ChatProjectQueries.delete($0, id: projectID) }
        vm.projectDeleted(projectID)
        XCTAssertNil(vm.openProjectID)
        XCTAssertTrue(vm.isOnLanding)
    }
}

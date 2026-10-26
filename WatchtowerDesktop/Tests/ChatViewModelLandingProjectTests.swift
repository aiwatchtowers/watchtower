import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The landing in a project (spec 2026-10-26 §4): its composer makes the
/// conversation in that project, and its draft is reused or dropped like the
/// landing's draft outside one.
@MainActor
final class ChatViewModelLandingProjectTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private var pool: ChatSessionPool!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUpWithError() throws {
        defaultsSuite = "ChatViewModelLandingProjectTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        pool = ChatSessionPool(
            dbPool: dbManager.dbPool,
            processFactory: { FakeChatSessionProcess(arguments: $0) },
            closeGrace: .milliseconds(20)
        )
    }

    override func tearDown() async throws {
        await pool.closeAll()
        TestDatabase.cleanup(path: dbPath)
        defaults.removePersistentDomain(forName: defaultsSuite)
    }

    private func makeViewModel() -> ChatViewModel {
        ChatViewModel(dbManager: dbManager, pool: pool, provider: .claude, defaults: defaults)
    }

    private func project(_ name: String) async throws -> Int64 {
        try await dbManager.dbPool.write { try ChatProjectQueries.create($0, name: name).id }
    }

    private func conversation(_ id: Int64) throws -> ChatConversation? {
        try dbManager.dbPool.read { try ChatConversationQueries.fetchByID($0, id: id) }
    }

    func testTheLandingInAProjectMakesItsChatThere() async throws {
        let projectID = try await project("P")
        let vm = makeViewModel()
        vm.showLanding(inProject: projectID)
        XCTAssertEqual(vm.landingProjectID, projectID)
        await vm.draftStarted()
        let id = try XCTUnwrap(vm.conversationID)
        XCTAssertTrue(vm.isOnLanding, "the landing stays up until the first turn")
        XCTAssertEqual(try conversation(id)?.projectID, projectID)
        XCTAssertEqual(vm.landingDraftID, id)

        // Back to the landing in the same project: its draft is kept.
        vm.showLanding(inProject: projectID)
        XCTAssertEqual(vm.conversationID, id)
    }

    /// A draft made for one project is not the landing's for another: the
    /// next keystroke makes a new chat there and the old draft goes.
    func testSwitchingTheLandingsProjectDropsTheOtherDraft() async throws {
        let projectID = try await project("P")
        let vm = makeViewModel()
        vm.showLanding(inProject: projectID)
        await vm.draftStarted()
        let inProject = try XCTUnwrap(vm.conversationID)

        vm.showLanding(inProject: nil)
        XCTAssertNil(vm.conversationID, "the project's draft is not shown outside it")
        await vm.draftStarted()
        let outside = try XCTUnwrap(vm.conversationID)
        XCTAssertNotEqual(outside, inProject)
        XCTAssertNil(try conversation(outside)?.projectID)
        await vm.writesSettled()
        XCTAssertNil(try conversation(inProject), "the untouched project draft is gone")
    }

    func testLaunchCleanupDropsAnAbandonedProjectDraft() async throws {
        let projectID = try await project("P")
        let first = makeViewModel()
        first.showLanding(inProject: projectID)
        await first.draftStarted()
        let draft = try XCTUnwrap(first.conversationID)

        let relaunched = makeViewModel()
        relaunched.cleanUpUntouchedConversations()
        await relaunched.writesSettled()
        XCTAssertNil(try conversation(draft))
    }

    func testTheTabEntryKeepsTheLandingsProjectAndADeletedOneClearsIt() async throws {
        let projectID = try await project("P")
        let vm = makeViewModel()
        vm.showLanding(inProject: projectID)
        vm.enterTab(rememberedConversationID: nil, lastViewedAt: nil, now: Date())
        XCTAssertTrue(vm.isOnLanding)
        XCTAssertEqual(vm.landingProjectID, projectID)

        _ = try await dbManager.dbPool.write { try ChatProjectQueries.delete($0, id: projectID) }
        vm.projectDeleted(projectID)
        XCTAssertNil(vm.landingProjectID)
        vm.showLanding()
        XCTAssertNil(vm.landingProjectID, "the plain landing is outside any project")
    }

    func testIsShowingIsTheThreadOnScreen() async throws {
        let projectID = try await project("P")
        let vm = makeViewModel()
        let created = await vm.newConversation()
        let id = try XCTUnwrap(created)
        XCTAssertTrue(vm.isShowing(conversationID: id))
        XCTAssertFalse(vm.isShowing(conversationID: id + 1))
        vm.openProject(projectID)
        XCTAssertFalse(vm.isShowing(conversationID: id), "a project page is not the chat")
        vm.select(conversationID: id)
        vm.showLanding()
        XCTAssertFalse(vm.isShowing(conversationID: id))
        XCTAssertFalse(vm.isAnswering(conversationID: id))
    }

    func testTheStoredDraftKeepsItsProject() {
        let draft = LandingDraft(id: 42, createdAt: 1_700_000_000.5, projectID: 7)
        XCTAssertEqual(LandingDraft(stored: draft.stored), draft)
        XCTAssertEqual(LandingDraft(stored: "42|1.5"), LandingDraft(id: 42, createdAt: 1.5), "an older value reads")
        XCTAssertNil(LandingDraft(stored: "42|1.5|x"))
        XCTAssertNil(LandingDraft(stored: "42|1.5|"))
        XCTAssertNil(LandingDraft(stored: "42|1.5|7|8"))
    }

    // MARK: - The project page's composer (spec 2026-10-26 §7)

    /// The page's composer is the landing's in its project: the first
    /// keystroke makes the chat there and the page stays; the first turn
    /// leaves the page for the chat and is announced (the panel selects it).
    func testTheProjectPageComposerMakesItsChatInTheProjectAndItsTurnLeavesThePage() async throws {
        let projectID = try await project("P")
        let vm = makeViewModel()
        var started: [Int64] = []
        vm.onLandingTurnStarted = { started.append($0) }
        vm.openProject(projectID)
        XCTAssertEqual(vm.landingProjectID, projectID)
        XCTAssertNil(vm.conversationID)

        vm.draft = "h"
        await vm.draftStarted()
        let id = try XCTUnwrap(vm.conversationID)
        XCTAssertEqual(vm.openProjectID, projectID, "a keystroke keeps the page")
        XCTAssertEqual(try conversation(id)?.projectID, projectID)
        XCTAssertEqual(vm.landingDraftID, id)
        XCTAssertFalse(vm.isShowing(conversationID: id))

        vm.draft = "hello"
        await vm.sendDraft()
        XCTAssertEqual(started, [id])
        XCTAssertNil(vm.openProjectID, "the first turn leaves the page")
        XCTAssertFalse(vm.isOnLanding)
        XCTAssertNil(vm.landingDraftID)
        XCTAssertTrue(vm.isShowing(conversationID: id))
        XCTAssertEqual(vm.draft, "")
    }

    /// A chat on screen is let go when a page opens: the page's composer
    /// never writes into it. The page's own draft stays when it is reopened.
    func testOpeningThePageLetsTheShownChatGoAndKeepsItsOwnDraft() async throws {
        let projectID = try await project("P")
        let vm = makeViewModel()
        let created = await vm.newConversation()
        let shown = try XCTUnwrap(created)
        vm.openProject(projectID)
        XCTAssertNil(vm.conversationID)
        await vm.draftStarted()
        let draft = try XCTUnwrap(vm.conversationID)
        XCTAssertNotEqual(draft, shown)

        vm.openProject(projectID)
        XCTAssertEqual(vm.conversationID, draft, "the page's draft stays its draft")

        let other = try await project("Q")
        vm.openProject(other)
        XCTAssertNil(vm.conversationID)
        XCTAssertEqual(vm.landingProjectID, other)
        await vm.writesSettled()
        XCTAssertNil(try conversation(draft), "the other project's untouched draft goes")
        XCTAssertNotNil(try conversation(shown), "a real chat is never discarded")
    }

    /// Deleting the project keeps its page's draft as the landing's draft
    /// outside any project: it is still discarded once untouched.
    func testDeletingTheProjectKeepsThePagesDraftDiscardable() async throws {
        let projectID = try await project("P")
        let vm = makeViewModel()
        vm.openProject(projectID)
        await vm.draftStarted()
        let draft = try XCTUnwrap(vm.conversationID)
        _ = try await dbManager.dbPool.write { try ChatProjectQueries.delete($0, id: projectID) }
        vm.projectDeleted(projectID)
        XCTAssertNil(vm.openProjectID)
        XCTAssertNil(vm.landingProjectID)
        XCTAssertEqual(vm.conversationID, draft, "the plain landing keeps it")
        XCTAssertNil(vm.currentConversation?.projectID, "reread detached")

        let other = try await project("Q")
        vm.openProject(other)
        await vm.writesSettled()
        XCTAssertNil(try conversation(draft))
    }

    /// New Project… (`createProject`) asks its page to focus the name;
    /// opening an existing project does not.
    func testNewProjectAsksForTheNameFocus() async throws {
        let vm = makeViewModel()
        let existing = try await project("P")
        vm.openProject(existing)
        XCTAssertNil(vm.projectNameFocusRequest)
        let created = await vm.createProject(name: "")
        let id = try XCTUnwrap(created)
        XCTAssertEqual(vm.projectNameFocusRequest, id)
        XCTAssertEqual(vm.openProjectID, id)
    }
}

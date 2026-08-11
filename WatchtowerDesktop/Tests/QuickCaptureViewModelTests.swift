import XCTest
import GRDB
@testable import WatchtowerDesktop

// MARK: - QuickCaptureViewModel Tests

@MainActor
final class QuickCaptureViewModelTests: XCTestCase {
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

    // MARK: - save()

    func testSaveHappyPathInsertsIdeaAndMention() throws {
        let vm = QuickCaptureViewModel()
        vm.result = DictationCleanResult(title: "Ship a weekly digest", text: "we should ship a weekly digest email")

        vm.save(dbPool: dbManager.dbPool)

        let ideaID = try XCTUnwrap(vm.savedIdeaID)
        XCTAssertNil(vm.error)
        let idea = try dbManager.dbPool.read { try IdeaQueries.fetchOne($0, id: Int(ideaID)) }
        XCTAssertEqual(idea?.title, "Ship a weekly digest")
        XCTAssertEqual(idea?.essence, "we should ship a weekly digest email")
        XCTAssertEqual(idea?.statusRaw, "active")
        XCTAssertEqual(idea?.source, "owner")

        let mentions = try dbManager.dbPool.read { try IdeaQueries.fetchMentions($0, ideaID: Int(ideaID)) }
        XCTAssertEqual(mentions.map(\.quote), ["we should ship a weekly digest email"])
    }

    func testSaveWithEmptyResultInsertsNothingAndSetsError() throws {
        let vm = QuickCaptureViewModel()
        vm.result = DictationCleanResult(title: nil, text: "")

        vm.save(dbPool: dbManager.dbPool)

        XCTAssertNil(vm.savedIdeaID)
        XCTAssertNotNil(vm.error)
        let ideas = try dbManager.dbPool.read { try IdeaQueries.fetchList($0, kind: nil, status: nil, query: nil, limit: 10) }
        XCTAssertTrue(ideas.isEmpty)
    }

    func testSaveWithNoResultYetSetsErrorWithoutInserting() throws {
        let vm = QuickCaptureViewModel()

        vm.save(dbPool: dbManager.dbPool)

        XCTAssertNil(vm.savedIdeaID)
        XCTAssertNotNil(vm.error)
        let ideas = try dbManager.dbPool.read { try IdeaQueries.fetchList($0, kind: nil, status: nil, query: nil, limit: 10) }
        XCTAssertTrue(ideas.isEmpty)
    }

    func testSaveFallsBackToTextPrefixWhenCleanupReturnedNoTitle() throws {
        let vm = QuickCaptureViewModel()
        let longText = String(repeating: "a", count: 120)
        vm.result = DictationCleanResult(title: nil, text: longText)

        vm.save(dbPool: dbManager.dbPool)

        let ideaID = try XCTUnwrap(vm.savedIdeaID)
        let idea = try dbManager.dbPool.read { try IdeaQueries.fetchOne($0, id: Int(ideaID)) }
        XCTAssertEqual(idea?.title, String(longText.prefix(80)))
        XCTAssertEqual(idea?.essence, longText)
    }
}

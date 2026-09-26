import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// `AppState.navigateToIdea` / `IdeasViewModel.reveal` — the Inbox strip
/// card's "Open" for a `create_idea` action must land on the idea even when
/// the Ideas tab's browse state (segment, status filter, search) hides it.
@MainActor
final class IdeaNavigationTests: XCTestCase {
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

    /// Browse state that hides every active idea: the Notes segment, a
    /// "rejected" status filter and a search nothing matches.
    private func hideEverything(_ vm: IdeasViewModel, selecting id: Int?) {
        vm.kindMode = "note"
        vm.statusFilter = "rejected"
        vm.searchText = "zzz-no-match"
        vm.load()
        vm.select(id)
    }

    func testNavigateToIdeaRevealsAnIdeaHiddenByFiltersAndSurvivesReturning() throws {
        let (visibleID, targetID) = try dbManager.dbPool.write { db in
            (try TestDatabase.insertIdea(db, kind: "note", title: "A note", status: "rejected"),
             try TestDatabase.insertIdea(db, title: "Reacted idea", status: "active", source: "owner"))
        }
        let appState = AppState()
        appState.initIdeas(dbManager: dbManager)
        let vm = try XCTUnwrap(appState.ideasViewModel)
        hideEverything(vm, selecting: Int(visibleID))
        XCTAssertFalse(vm.registryItems.contains { $0.id == Int(targetID) }, "precondition: hidden")

        appState.navigateToIdea(Int(targetID))

        XCTAssertEqual(appState.selectedDestination, .ideas)
        XCTAssertEqual(vm.kindMode, "idea")
        XCTAssertNil(vm.statusFilter)
        XCTAssertEqual(vm.searchText, "")
        XCTAssertEqual(vm.selectedID, Int(targetID))
        XCTAssertEqual(vm.selectedItem?.title, "Reacted idea")

        // Leave the tab and come back: IdeasView's onAppear refresh must not
        // move the selection off the revealed idea.
        appState.selectedDestination = .inbox
        vm.refresh()
        XCTAssertEqual(vm.selectedID, Int(targetID))
    }

    func testRevealSwitchesToTheNotesSegmentForANote() throws {
        let noteID = try dbManager.dbPool.write { db in
            try TestDatabase.insertIdea(db, kind: "note", title: "Scratch", status: "active")
        }
        let vm = IdeasViewModel(dbManager: dbManager)
        vm.load()
        XCTAssertEqual(vm.kindMode, "idea")

        vm.reveal(Int(noteID))

        XCTAssertEqual(vm.kindMode, "note")
        XCTAssertEqual(vm.selectedItem?.title, "Scratch")
    }

    func testRevealFindsAnIdeaInTheReviewQueue() throws {
        let id = try dbManager.dbPool.write { db in
            try TestDatabase.insertIdea(db, title: "Proposed one", status: "proposed")
        }
        let vm = IdeasViewModel(dbManager: dbManager)
        hideEverything(vm, selecting: nil)

        vm.reveal(Int(id))

        XCTAssertEqual(vm.selectedItem?.title, "Proposed one")
        XCTAssertTrue(vm.reviewItems.contains { $0.id == Int(id) })
    }

    /// A deleted idea's link degrades to the Ideas segment with the ordinary
    /// fallback selection — never an error, never a stale id.
    func testRevealOfAMissingIdeaFallsBackToTheFirstRow() throws {
        let otherID = try dbManager.dbPool.write { db in
            try TestDatabase.insertIdea(db, title: "Only idea", status: "active")
        }
        let vm = IdeasViewModel(dbManager: dbManager)
        hideEverything(vm, selecting: nil)

        vm.reveal(99_999)

        XCTAssertEqual(vm.kindMode, "idea")
        XCTAssertEqual(vm.selectedID, Int(otherID))
        XCTAssertNil(vm.errorMessage)
    }
}

import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// `AppState.navigateToIdea` — an Inbox action card's "Open" for a
/// `create_idea` action, Quick Capture's Open Ideas — lands on the idea's
/// card in the Inbox's Idea finder list (the root's legacy entry). The Ideas
/// screen's browse state (its segment, status filter and search, which
/// `IdeasViewModel.reveal` used to clear) is gone: the Idea finder lists
/// every idea, note and decision but merged ones, so any of them opens.
@MainActor
final class IdeaNavigationTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath = ""
    private var savedFolder: Any?

    override func setUp() async throws {
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        savedFolder = UserDefaults.standard.object(forKey: ActionStripViewModel.folderKey)
        UserDefaults.standard.removeObject(forKey: ActionStripViewModel.folderKey)
    }

    override func tearDown() async throws {
        IdeaBatchDefaults.clearStandard()
        UserDefaults.standard.set(savedFolder, forKey: ActionStripViewModel.folderKey)
        TestDatabase.cleanup(path: dbPath)
        dbManager = nil
    }

    private func appStateOnTheInbox() throws -> (AppState, ActionStripViewModel) {
        let appState = AppState.isolated()
        appState.databaseManager = dbManager
        appState.initActionStrip(dbPool: dbManager.dbPool)
        return (appState, try XCTUnwrap(appState.actionStripViewModel))
    }

    func testNavigateToIdeaOpensItsCardInTheIdeaFinder() async throws {
        let ids = try await dbManager.dbPool.write { db in
            [try TestDatabase.insertIdea(db, kind: "note", title: "A note", status: "rejected"),
             try TestDatabase.insertIdea(db, title: "Reacted idea", status: "active", source: "owner"),
             try TestDatabase.insertIdea(db, kind: "decision", title: "Ship on Fridays", status: "active")]
        }
        for id in ids.map(Int.init) {
            let (appState, inbox) = try appStateOnTheInbox()
            inbox.openLegacy(.messages)
            await appState.navigateToIdea(id)?.value

            XCTAssertEqual(appState.selectedDestination, .inbox)
            XCTAssertEqual(inbox.legacyList, .ideas)
            XCTAssertEqual(inbox.entrySelection, InboxFolderEntry.legacyIdeas.id)
            XCTAssertEqual(inbox.selection, .idea(id))
            XCTAssertTrue(inbox.feed.ideas.contains { $0.id == id }, "the card is listed")
        }
    }

    /// A deleted idea's link still opens the Idea finder — never an error.
    func testNavigateToAMissingIdeaStillOpensTheIdeaFinder() async throws {
        let (appState, inbox) = try appStateOnTheInbox()
        await appState.navigateToIdea(99_999)?.value

        XCTAssertEqual(appState.selectedDestination, .inbox)
        XCTAssertEqual(inbox.legacyList, .ideas)
        XCTAssertNil(inbox.selection)
        XCTAssertFalse(inbox.feed.ideas.contains { $0.id == 99_999 })
        XCTAssertNil(inbox.lastError)
    }
}

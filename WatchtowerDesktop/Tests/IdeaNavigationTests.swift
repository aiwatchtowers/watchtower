import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// `AppState.navigateToIdea` — an Inbox action card's "Open" for a
/// `create_idea` action, Quick Capture's Open Ideas — lands on the idea's
/// card in the Inbox's Ideas filter. The Ideas screen's browse state (its
/// segment, status filter and search, which `IdeasViewModel.reveal` used to
/// clear) is gone: the Ideas filter lists every idea, note and decision but
/// merged ones, so any of them opens.
@MainActor
final class IdeaNavigationTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath = ""
    private var savedFilter: Any?

    override func setUp() async throws {
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        savedFilter = UserDefaults.standard.object(forKey: "inbox.filter")
        UserDefaults.standard.removeObject(forKey: "inbox.filter")
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(savedFilter, forKey: "inbox.filter")
        TestDatabase.cleanup(path: dbPath)
        dbManager = nil
    }

    private func appStateOnTheInbox() throws -> (AppState, ActionStripViewModel) {
        let appState = AppState.isolated()
        appState.databaseManager = dbManager
        appState.initActionStrip(dbPool: dbManager.dbPool)
        return (appState, try XCTUnwrap(appState.actionStripViewModel))
    }

    func testNavigateToIdeaOpensItsCardOnTheIdeasFilter() async throws {
        let ids = try await dbManager.dbPool.write { db in
            [try TestDatabase.insertIdea(db, kind: "note", title: "A note", status: "rejected"),
             try TestDatabase.insertIdea(db, title: "Reacted idea", status: "active", source: "owner"),
             try TestDatabase.insertIdea(db, kind: "decision", title: "Ship on Fridays", status: "active")]
        }
        for id in ids.map(Int.init) {
            let (appState, inbox) = try appStateOnTheInbox()
            inbox.filter = .messages
            await appState.navigateToIdea(id)?.value

            XCTAssertEqual(appState.selectedDestination, .inbox)
            XCTAssertEqual(inbox.filter, .ideas)
            XCTAssertEqual(inbox.selection, .idea(id))
            XCTAssertTrue(inbox.feed.ideas.contains { $0.id == id }, "the card is listed")
        }
    }

    /// A deleted idea's link still opens the Ideas filter — never an error.
    func testNavigateToAMissingIdeaStillOpensTheIdeasFilter() async throws {
        let (appState, inbox) = try appStateOnTheInbox()
        await appState.navigateToIdea(99_999)?.value

        XCTAssertEqual(appState.selectedDestination, .inbox)
        XCTAssertEqual(inbox.filter, .ideas)
        XCTAssertFalse(inbox.feed.ideas.contains { $0.id == 99_999 })
        XCTAssertNil(inbox.lastError)
    }
}

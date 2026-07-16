import XCTest
import GRDB
@testable import WatchtowerDesktop

// MARK: - AppState Tests
//
// AppState.initialize() resolves a real DB path (Constants.configPath /
// Constants.databasePath) and shells out to the real `watchtower` CLI binary
// (runCLIMigrations) — neither is injectable, so it can't be exercised
// hermetically from XCTest. Instead these tests call `initDashboard(dbManager:)`
// directly (it's `func`, not `private func`, specifically so @testable import
// can reach it) with a test-only DatabaseManager, mirroring what `initialize()`
// does after the real DB opens.

@MainActor
final class AppStateTests: XCTestCase {
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

    /// The bug: DashboardViewModel used to be created view-locally in InboxFeedView,
    /// so navigating away from the Dashboard tab destroyed the VM (and the isGenerating
    /// flag + in-flight "Generate" Task) with it. The fix makes AppState the owner —
    /// this test proves that ownership is structural: repeated accesses of
    /// `appState.dashboardViewModel` return the exact same instance, not a fresh one
    /// per access, so state (and any in-flight generation) survives navigation.
    func testDashboardViewModelIdentityPersistsAcrossRepeatedAccesses() {
        let appState = AppState()
        appState.databaseManager = dbManager

        appState.initDashboard(dbManager: dbManager)

        let first = appState.dashboardViewModel
        let second = appState.dashboardViewModel

        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "dashboardViewModel must be a stored, app-owned instance, not recreated per access")
    }
}

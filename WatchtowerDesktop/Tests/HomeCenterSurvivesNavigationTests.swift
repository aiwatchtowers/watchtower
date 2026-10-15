import XCTest
import Observation
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Home's snapshot lives on AppState: a read started on Home lands even after
/// the owner switched tabs, and coming back shows it without reading again.
@MainActor
final class HomeCenterSurvivesNavigationTests: XCTestCase {
    func testSnapshotLandsAfterNavigatingAway() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let appState = AppState.isolated()
        appState.databaseManager = manager
        appState.selectedDestination = .home
        appState.homeCenter.beginReading(pool: manager.dbPool)
        defer { appState.homeCenter.endReading() }
        appState.selectedDestination = .targets
        XCTAssertNil(appState.homeCenter.snapshot)

        let landed = expectation(description: "snapshot landed")
        func check() {
            if appState.homeCenter.snapshot != nil {
                landed.fulfill()
                return
            }
            withObservationTracking { _ = appState.homeCenter.snapshot } onChange: {
                Task { @MainActor in check() }
            }
        }
        check()
        await fulfillment(of: [landed], timeout: 5)
        let reads = appState.homeCenter.todayReads

        appState.selectedDestination = .home
        XCTAssertNotNil(appState.homeCenter.snapshot)
        XCTAssertEqual(appState.homeCenter.todayReads, reads)
    }
}

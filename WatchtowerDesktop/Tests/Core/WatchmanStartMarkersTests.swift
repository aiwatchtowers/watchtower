import XCTest
@testable import WatchtowerCore

/// The owed-start markers are Go's (`db.WatchmanStartPending`,
/// `db.WatchmanStartClaimed`), pinned by a golden Go writes under -update.
final class WatchmanStartMarkersTests: XCTestCase {
    static let goGolden = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Core
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerDesktop
        .deletingLastPathComponent() // repository root
        .appendingPathComponent("internal/db/testdata/watchman_start_markers.golden")

    func testStartOwedErrorsMatchGo() throws {
        let text = try String(contentsOf: Self.goGolden, encoding: .utf8)
        let go = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(WatchmanItem.startOwedErrors, go)
    }

    /// The SQL fragment (Mark done's reader) is built from the markers; Go's
    /// `db.WatchmanWaitingClause` names the same constants.
    func testSQLFragmentNamesEveryMarker() {
        for marker in WatchmanItem.startOwedErrors {
            XCTAssertTrue(WatchmanItem.failedStepSQL.contains("'\(marker)'"), marker)
        }
    }
}

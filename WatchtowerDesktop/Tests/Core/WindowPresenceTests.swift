import XCTest
@testable import WatchtowerCore

final class WindowPresenceTests: XCTestCase {
    private struct Row {
        var name: String
        var occlusionVisible = false
        var isVisible = false
        var isMiniaturized = false
        var appHidden = false
        var windowExists = true
        var want: WindowPresence
    }

    func testTable() {
        let rows = [
            Row(name: "on screen", occlusionVisible: true, isVisible: true, want: .onScreen),
            Row(name: "other Space or display asleep", isVisible: true, want: .occluded),
            Row(name: "minimised", isMiniaturized: true, want: .occluded),
            Row(name: "app hidden", appHidden: true, want: .occluded),
            Row(name: "app hidden, window flags stale", occlusionVisible: true, isVisible: true, appHidden: true, want: .occluded),
            Row(name: "ordered out", want: .gone),
            Row(name: "no window", windowExists: false, want: .gone)
        ]
        for row in rows {
            XCTAssertEqual(
                WindowPresence.of(
                    occlusionVisible: row.occlusionVisible, isVisible: row.isVisible, isMiniaturized: row.isMiniaturized,
                    appHidden: row.appHidden, windowExists: row.windowExists
                ),
                row.want, row.name
            )
        }
    }
}

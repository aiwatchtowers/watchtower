import XCTest
@testable import WatchtowerDesktop

final class OwnerAskDrawerLayoutTests: XCTestCase {
    func testExpandingNeverResizesTheContent() {
        let beside = OwnerAskDrawerLayout.frames(total: 1200, drawerWidth: 440, hasDrawer: true, expanded: false)
        let expanded = OwnerAskDrawerLayout.frames(total: 1200, drawerWidth: 440, hasDrawer: true, expanded: true)
        XCTAssertEqual(beside, .init(content: 760, drawerX: 760, drawer: 440))
        XCTAssertEqual(expanded.content, beside.content, "the terminal keeps its columns under an expanded drawer")
        XCTAssertEqual(expanded.drawerX, 0)
        XCTAssertEqual(expanded.drawer, 1200, "the drawer covers the whole width")
    }

    func testTheContentKeepsAFloorBesideAWideDrawer() {
        for expanded in [false, true] {
            let frames = OwnerAskDrawerLayout.frames(total: 500, drawerWidth: 900, hasDrawer: true, expanded: expanded)
            XCTAssertEqual(frames.content, OwnerAskDrawerLayout.minContentWidth, "never squeezed to a few columns")
        }
    }

    func testNoDrawerLeavesTheContentAlone() {
        let frames = OwnerAskDrawerLayout.frames(total: 800, drawerWidth: 440, hasDrawer: false, expanded: true)
        XCTAssertEqual(frames.content, 800)
        XCTAssertEqual(frames.drawer, 0)
    }
}

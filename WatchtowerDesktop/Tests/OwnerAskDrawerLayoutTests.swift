import XCTest
@testable import WatchtowerDesktop

final class OwnerAskDrawerLayoutTests: XCTestCase {
    func testExpandingNeverResizesTheContent() {
        let beside = OwnerAskDrawerLayout.frames(total: 1200, drawerWidth: 440, hasDrawer: true, expanded: false)
        let expanded = OwnerAskDrawerLayout.frames(total: 1200, drawerWidth: 440, hasDrawer: true, expanded: true)
        XCTAssertEqual(beside, .init(content: 760, drawerX: 760, drawer: 440, covers: false))
        XCTAssertEqual(expanded.content, beside.content, "the terminal keeps its columns under an expanded drawer")
        XCTAssertEqual(expanded.drawerX, 0)
        XCTAssertEqual(expanded.drawer, 1200, "the drawer covers the whole width")
        XCTAssertTrue(expanded.covers)
    }

    func testTheContentKeepsAFloorBesideAWideDrawer() {
        let frames = OwnerAskDrawerLayout.frames(total: 700, drawerWidth: 900, hasDrawer: true, expanded: false)
        XCTAssertEqual(frames, .init(content: OwnerAskDrawerLayout.minContentWidth, drawerX: 200, drawer: 500, covers: false),
                       "never squeezed to a few columns")
    }

    func testTheDrawerNeverGoesBelowItsMinimum() {
        let frames = OwnerAskDrawerLayout.frames(total: 1000, drawerWidth: 100, hasDrawer: true, expanded: false)
        XCTAssertEqual(frames.drawer, OwnerAskDrawerLayout.minDrawerWidth)
        let tight = OwnerAskDrawerLayout.frames(total: 520, drawerWidth: 440, hasDrawer: true, expanded: false)
        XCTAssertEqual(tight, .init(content: 200, drawerX: 200, drawer: 320, covers: false), "exactly room for both")
    }

    func testANarrowPaneShowsTheDrawerCovering() {
        for total: CGFloat in [519, 400, 120] {
            let frames = OwnerAskDrawerLayout.frames(total: total, drawerWidth: 440, hasDrawer: true, expanded: false)
            XCTAssertEqual(frames, .init(content: total, drawerX: 0, drawer: total, covers: true),
                           "\(total) pt: no room for a 320 pt drawer beside 200 pt of content")
        }
    }

    func testNoDrawerLeavesTheContentAlone() {
        let frames = OwnerAskDrawerLayout.frames(total: 800, drawerWidth: 440, hasDrawer: false, expanded: true)
        XCTAssertEqual(frames, .init(content: 800, drawerX: 800, drawer: 0, covers: false))
    }
}

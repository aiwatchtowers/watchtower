import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop

/// The chat project page (spec 2026-10-26 §7) lays its Instructions and
/// Knowledge cards beside the chats from `HomeContent.twoColumnWidth` of
/// content, and under them below it. Read off the rendered page: a card's
/// inner corner shows the card fill, open page shows the detail backdrop.
/// Coordinates follow `ProjectPageShotFixtures` (its `chat-project-page-*`
/// shots show the same pages).
@MainActor
final class ProjectDetailRenderTests: XCTestCase {
    override func tearDown() {
        ProjectPageShotFixtures.cleanUp()
        super.tearDown()
    }

    private func backdrop(_ appearance: NSAppearance) throws -> ViewRenderProbe.RGBA {
        let probe = ViewRenderProbe(size: NSSize(width: 100, height: 100))
        return try probe.pixel(probe.render(Color.clear.detailBackground(), appearance), x: 50, y: 50)
    }

    func testWideThePageSetsTheCardsBesideTheChats() throws {
        let probe = ViewRenderProbe(size: NSSize(width: 1100, height: 720))
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let detail = try backdrop(appearance)
            XCTAssertEqual(detail.alpha, 255, "an empty capture would compare equal to another one")
            let page = try probe.render(ProjectPageShotFixtures.page(), appearance)
            // Right of the composer, at its height: the Instructions card.
            XCTAssertNotEqual(try probe.pixel(page, x: 1050, y: 142), detail, "\(name): the card beside the composer")
            // Below the chats in the main column: nothing.
            XCTAssertEqual(try probe.pixel(page, x: 600, y: 340), detail, "\(name): the main column ends with the chats")
            XCTAssertEqual(try probe.pixel(page, x: 1050, y: 600), detail, "\(name): below the cards")
        }
    }

    func testNarrowThePageStacksTheCardsUnderTheChats() throws {
        let probe = ViewRenderProbe(size: NSSize(width: 640, height: 1000))
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let detail = try backdrop(appearance)
            let page = try probe.render(ProjectPageShotFixtures.page(), appearance)
            // Right of the composer: no card any more.
            XCTAssertEqual(try probe.pixel(page, x: 590, y: 150), detail, "\(name): nothing beside the composer")
            // Under the chats, full width: the Instructions card.
            XCTAssertNotEqual(try probe.pixel(page, x: 590, y: 342), detail, "\(name): the card under the chats")
            XCTAssertNotEqual(try probe.pixel(page, x: 50, y: 342), detail, "\(name): across the column")
        }
    }
}

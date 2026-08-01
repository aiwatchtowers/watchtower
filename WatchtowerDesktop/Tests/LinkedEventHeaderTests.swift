import XCTest
import SwiftUI
import GRDB
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class LinkedEventHeaderTests: XCTestCase {
    private func makeLink(
        id: String = "evt-1",
        title: String = "Design Review",
        startTime: String = "2026-05-01T09:00:00Z"
    ) -> CalendarQueries.EventLink {
        CalendarQueries.EventLink(row: ["id": id, "title": title, "start_time": startTime])
    }

    func test_resolvableLinkRendersTappableButtonPassingTheLink() throws {
        var opened: CalendarQueries.EventLink?
        let view = LinkedEventHeader(linkedEvent: makeLink()) { opened = $0 }

        let button = try view.inspect().find(ViewType.Button.self)
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        XCTAssertTrue(texts.contains { $0.contains("Linked to: Design Review") })

        try button.tap()
        XCTAssertEqual(opened?.id, "evt-1")
        XCTAssertEqual(opened?.startTime, "2026-05-01T09:00:00Z",
                       "the host needs the start time to pin the event's day into the window")
    }

    func test_prunedLinkRendersPlainPastEventLabelWithoutButton() throws {
        let view = LinkedEventHeader(linkedEvent: nil) { _ in }
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        XCTAssertTrue(texts.contains("Linked to a past event"))
        XCTAssertThrowsError(try view.inspect().find(ViewType.Button.self),
                             "a pruned link must never navigate")
    }

    func test_nilNavigationRendersInformationalLabelWithoutButton() throws {
        let view = LinkedEventHeader(linkedEvent: makeLink(), onOpenEvent: nil)
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        XCTAssertTrue(texts.contains { $0.contains("Linked to: Design Review") },
                      "the link text stays informational when no navigation is available")
        XCTAssertThrowsError(try view.inspect().find(ViewType.Button.self),
                             "no host navigation → no tappable affordance")
    }

    func test_emptyTitleFallsBackToPlaceholder() throws {
        // Degenerate: schema-default '' title must not render "Linked to:  · <date>".
        let view = LinkedEventHeader(linkedEvent: makeLink(title: "")) { _ in }
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        XCTAssertTrue(texts.contains { $0.contains("Linked to: (untitled event)") })
    }

    func test_startDateParsesISOAndNilsOnGarbage() {
        XCTAssertNotNil(makeLink().startDate)
        XCTAssertNil(makeLink(startTime: "").startDate)
        XCTAssertNil(makeLink(startTime: "not-a-date").startDate)
    }
}

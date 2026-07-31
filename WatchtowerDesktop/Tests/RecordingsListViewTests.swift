import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class RecordingsListViewTests: XCTestCase {
    private func makeItem(
        id: Int64,
        title: String = "Rec",
        eventID: String? = nil,
        eventTitle: String? = nil,
        hasRecap: Bool = false,
        hasNotes: Bool = false,
        snippet: String = "…"
    ) -> RecordingListItem {
        RecordingListItem(
            id: id, eventID: eventID, eventTitle: eventTitle, title: title, durationSec: 125,
            langStats: #"{"ru":3}"#, createdAt: "2026-07-15T10:00:00Z",
            hasRecap: hasRecap, hasNotes: hasNotes, snippet: snippet)
    }

    func test_rendersRowPerItemWithTitle() throws {
        let view = RecordingsListView(
            items: [makeItem(id: 1, title: "Weekly Sync"), makeItem(id: 2, title: "1:1")],
            selectedID: .constant(nil))
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        XCTAssertTrue(texts.contains("Weekly Sync"))
        XCTAssertTrue(texts.contains("1:1"))
    }

    func test_emptyStateShown() throws {
        let view = RecordingsListView(items: [], selectedID: .constant(nil))
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        XCTAssertTrue(texts.contains { $0.contains("No recordings") })
    }

    func test_rowTapWritesThroughSuppliedBinding() throws {
        // The list writes selection through whatever binding the host hands
        // it — the same path serves the plain tab (local @State) and the
        // Events-tab deep link (hoisted external binding).
        var selected: Int64?
        let binding = Binding(get: { selected }, set: { selected = $0 })
        let view = RecordingsListView(items: [makeItem(id: 7)], selectedID: binding)

        try view.inspect().find(ViewType.Button.self).tap()
        XCTAssertEqual(selected, 7)

        // Second tap on the now-selected row toggles it off.
        try view.inspect().find(ViewType.Button.self).tap()
        XCTAssertNil(selected)
    }

    func test_linkedEventSubtitleShownOnlyWhenPresent() throws {
        let view = RecordingsListView(
            items: [
                makeItem(id: 1, title: "Linked", eventID: "evt-1", eventTitle: "Design Review"),
                makeItem(id: 2, title: "AdHoc"),
                // Degenerate: link kept but the event row was pruned — no
                // subtitle, no error.
                makeItem(id: 3, title: "Pruned", eventID: "evt-gone", eventTitle: nil),
            ],
            selectedID: .constant(nil))
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        XCTAssertTrue(texts.contains("Design Review"))
        XCTAssertEqual(texts.filter { $0 == "Design Review" }.count, 1,
                       "only the linked row carries the event subtitle")
    }
}

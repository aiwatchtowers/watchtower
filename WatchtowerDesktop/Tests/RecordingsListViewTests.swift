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
        hasRecap: Bool = false,
        hasNotes: Bool = false,
        snippet: String = "…"
    ) -> RecordingListItem {
        RecordingListItem(
            id: id, eventID: eventID, title: title, durationSec: 125,
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
}

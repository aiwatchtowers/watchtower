import XCTest
@testable import WatchtowerDesktop

/// Logic-level tests for `MeetingRecordingRow`'s pure subtitle-resolution
/// helper (house pattern, see `MeetingDetailViewTests`). Migrates the
/// linked-event-subtitle assertion that the deleted `RecordingsListView` used
/// to cover — a `.recording` entry whose event was pruned (non-nil
/// `eventTitle`) still needs a visible provenance label in the unified list.
final class MeetingRecordingRowTests: XCTestCase {
    private func makeItem(title: String = "Rec", eventTitle: String?) -> RecordingListItem {
        RecordingListItem(
            id: 1, eventID: eventTitle == nil ? nil : "e1", eventTitle: eventTitle, title: title,
            durationSec: 60, langStats: #"{"ru":1}"#, createdAt: "2026-08-04T10:00:00Z",
            hasRecap: false, hasNotes: false, snippet: "")
    }

    /// Linked event with a distinct title → shown as the subtitle.
    func test_subtitle_shownWhenEventTitlePresentAndDifferent() {
        let item = makeItem(title: "Rec 1", eventTitle: "Weekly Sync")
        XCTAssertEqual(MeetingRecordingRow.subtitle(for: item), "Weekly Sync")
    }

    /// Ad-hoc recording (no linked event) → no subtitle.
    func test_subtitle_nilWhenEventTitleAbsent() {
        let item = makeItem(title: "Rec 1", eventTitle: nil)
        XCTAssertNil(MeetingRecordingRow.subtitle(for: item))
    }

    /// Linked event title identical to the recording title → redundant, no subtitle.
    func test_subtitle_nilWhenEventTitleEqualsTitle() {
        let item = makeItem(title: "Standup", eventTitle: "Standup")
        XCTAssertNil(MeetingRecordingRow.subtitle(for: item))
    }

    /// Empty-string eventTitle (defensive — same handling as the deleted
    /// RecordingsListView's `!eventTitle.isEmpty` guard) → no subtitle.
    func test_subtitle_nilWhenEventTitleEmpty() {
        let item = makeItem(title: "Rec 1", eventTitle: "")
        XCTAssertNil(MeetingRecordingRow.subtitle(for: item))
    }
}

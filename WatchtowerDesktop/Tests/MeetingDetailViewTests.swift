import XCTest
import GRDB
@testable import WatchtowerDesktop

/// Logic-level tests for `MeetingDetailView`'s pure static helpers — the
/// record-affordance gate and the transcript-id resolution formula — rather
/// than mounting the view (house pattern, see `MeetingListBuilderTests`).
final class MeetingDetailViewTests: XCTestCase {
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    // MARK: - Fixture helpers

    private func makeEvent(id: String = "e1", start: Date, end: Date) -> CalendarEvent {
        CalendarEvent(row: Row([
            "id": id,
            "calendar_id": "cal1",
            "title": "Event \(id)",
            "start_time": Self.iso8601Formatter.string(from: start),
            "end_time": Self.iso8601Formatter.string(from: end)
        ]))
    }

    private func makeRecording(
        id: Int64, eventID: String? = nil, createdAt: Date, duration: Int = 300
    ) -> RecordingListItem {
        RecordingListItem(
            id: id, eventID: eventID, eventTitle: nil, title: "Rec \(id)", durationSec: duration,
            langStats: #"{"ru":3}"#, createdAt: Self.iso8601Formatter.string(from: createdAt),
            hasRecap: false, hasNotes: false, snippet: "…")
    }

    // MARK: - showsRecordButton

    /// Ended event → no Record affordance.
    func test_showsRecordButton_hiddenForEndedEvent() {
        let now = Date()
        let event = makeEvent(start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600))
        XCTAssertFalse(MeetingDetailView.showsRecordButton(for: event, now: now))
    }

    /// Future event → Record affordance shown.
    func test_showsRecordButton_visibleForFutureEvent() {
        let now = Date()
        let event = makeEvent(start: now.addingTimeInterval(600), end: now.addingTimeInterval(4200))
        XCTAssertTrue(MeetingDetailView.showsRecordButton(for: event, now: now))
    }

    /// Meeting currently in progress (endDate still ahead) → still shown.
    func test_showsRecordButton_visibleWhileOngoing() {
        let now = Date()
        let event = makeEvent(start: now.addingTimeInterval(-600), end: now.addingTimeInterval(600))
        XCTAssertTrue(MeetingDetailView.showsRecordButton(for: event, now: now))
    }

    // MARK: - descriptionNeedsToggle

    /// A short one-liner never grows a Show more affordance.
    func test_descriptionNeedsToggle_falseForShortText() {
        XCTAssertFalse(MeetingDetailView.descriptionNeedsToggle("Weekly sync"))
    }

    /// Three short lines still fit the collapsed preview — no toggle.
    func test_descriptionNeedsToggle_falseForThreeShortLines() {
        XCTAssertFalse(MeetingDetailView.descriptionNeedsToggle("Agenda\nDuration\nAttendees"))
    }

    /// A fourth line means the 3-line clamp hides content → toggle shown.
    func test_descriptionNeedsToggle_trueBeyondThreeLines() {
        XCTAssertTrue(MeetingDetailView.descriptionNeedsToggle("Agenda\nDuration\nAttendees\nGoals"))
    }

    /// A long single paragraph wraps past three lines even without newlines.
    func test_descriptionNeedsToggle_trueForLongSingleLine() {
        XCTAssertTrue(MeetingDetailView.descriptionNeedsToggle(String(repeating: "status update ", count: 30)))
    }

    // MARK: - embeddedTranscriptID

    /// No explicit selection yet on an `.event` entry → falls back to
    /// `MeetingListBuilder.defaultRecordingID` (longest recording wins) —
    /// pins the initial `selectedRecordingID` seeded by `.onAppear`.
    func test_embeddedTranscriptID_eventFallsBackToDefaultRecording() {
        let now = Date()
        let event = makeEvent(start: now, end: now.addingTimeInterval(1800))
        let short = makeRecording(id: 1, eventID: event.id, createdAt: now.addingTimeInterval(-3600), duration: 60)
        let long = makeRecording(id: 2, eventID: event.id, createdAt: now.addingTimeInterval(-7200), duration: 900)
        let entry = MeetingListEntry(
            kind: .event(event, recordings: [short, long]),
            id: .event(event.id), sortDate: event.startDate, recordingCount: 2)

        let resolved = MeetingDetailView.embeddedTranscriptID(entry: entry, selectedRecordingID: nil)

        XCTAssertEqual(resolved, MeetingListBuilder.defaultRecordingID([short, long]))
        XCTAssertEqual(resolved, 2)
    }

    /// An explicit chip selection wins over the default.
    func test_embeddedTranscriptID_eventHonorsExplicitSelection() {
        let now = Date()
        let event = makeEvent(start: now, end: now.addingTimeInterval(1800))
        let short = makeRecording(id: 1, eventID: event.id, createdAt: now.addingTimeInterval(-3600), duration: 60)
        let long = makeRecording(id: 2, eventID: event.id, createdAt: now.addingTimeInterval(-7200), duration: 900)
        let entry = MeetingListEntry(
            kind: .event(event, recordings: [short, long]),
            id: .event(event.id), sortDate: event.startDate, recordingCount: 2)

        XCTAssertEqual(MeetingDetailView.embeddedTranscriptID(entry: entry, selectedRecordingID: 1), 1)
    }

    /// An `.event` entry with no recordings resolves to nil (renders `Spacer()`).
    func test_embeddedTranscriptID_eventWithNoRecordingsIsNil() {
        let now = Date()
        let event = makeEvent(start: now, end: now.addingTimeInterval(1800))
        let entry = MeetingListEntry(
            kind: .event(event, recordings: []), id: .event(event.id), sortDate: event.startDate, recordingCount: 0)

        XCTAssertNil(MeetingDetailView.embeddedTranscriptID(entry: entry, selectedRecordingID: nil))
    }

    /// A `.recording` entry always resolves to its own transcript id,
    /// regardless of whatever `selectedRecordingID` state is passed in.
    func test_embeddedTranscriptID_recordingEntryIgnoresSelection() {
        let item = makeRecording(id: 42, eventID: nil, createdAt: Date())
        let entry = MeetingListEntry(
            kind: .recording(item), id: .recording(item.id), sortDate: Date(), recordingCount: 1)

        XCTAssertEqual(MeetingDetailView.embeddedTranscriptID(entry: entry, selectedRecordingID: 999), 42)
    }
}

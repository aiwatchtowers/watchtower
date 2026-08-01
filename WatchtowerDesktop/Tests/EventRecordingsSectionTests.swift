import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class EventRecordingsSectionTests: XCTestCase {
    private func makeTranscript(
        id: Int64,
        durationSec: Int = 125,
        summaryJSON: String? = nil,
        notesMD: String? = nil
    ) -> MeetingTranscript {
        MeetingTranscript(
            id: id, eventID: "evt-1", title: "Rec", audioPath: nil,
            durationSec: durationSec, langStats: #"{"ru":3}"#, transcriptText: "text",
            summaryJSON: summaryJSON, notesMD: notesMD, segmentsJSON: nil,
            createdAt: "2026-07-15T10:00:00Z", updatedAt: "2026-07-15T10:00:00Z")
    }

    func test_hiddenWhenNoRecordings() throws {
        let view = EventRecordingRows(transcripts: [], hasEventRecap: true) { _ in }
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        XCTAssertTrue(texts.isEmpty, "empty section must render nothing, not a stray header")
    }

    func test_showsHeaderAndOneRowPerRecording() throws {
        let view = EventRecordingRows(
            transcripts: [makeTranscript(id: 1), makeTranscript(id: 2, durationSec: 65)],
            hasEventRecap: false
        ) { _ in }
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        XCTAssertTrue(texts.contains("Recordings"))
        XCTAssertTrue(texts.contains(TranscriptFormatting.formatDuration(125)))
        XCTAssertTrue(texts.contains(TranscriptFormatting.formatDuration(65)))
    }

    func test_recapBadgeLightsFromEventRecapAlone() throws {
        // The documented recap-collision dual path: the recap may live in
        // meeting_recaps while the transcript's own summary_json stays nil —
        // hasEventRecap alone must light the badge (kills a ||→&& mutation).
        let view = EventRecordingRows(
            transcripts: [makeTranscript(id: 1, summaryJSON: nil)],
            hasEventRecap: true
        ) { _ in }
        let images = try view.inspect()
            .findAll(ViewType.Image.self)
            .map { try $0.actualImage().name() }
        XCTAssertTrue(images.contains("sparkles"))
    }

    func test_noRecapBadgeWhenNeitherSourceHasOne() throws {
        let view = EventRecordingRows(
            transcripts: [makeTranscript(id: 1, summaryJSON: nil)],
            hasEventRecap: false
        ) { _ in }
        let images = try view.inspect()
            .findAll(ViewType.Image.self)
            .map { try $0.actualImage().name() }
        XCTAssertFalse(images.contains("sparkles"))
    }

    func test_tapReportsRecordingID() throws {
        var opened: Int64?
        let view = EventRecordingRows(
            transcripts: [makeTranscript(id: 42)], hasEventRecap: false
        ) { opened = $0 }
        try view.inspect().find(ViewType.Button.self).tap()
        XCTAssertEqual(opened, 42)
    }
}

/// Frozen wire fixtures for the plan C DataZone mirrors (mobile POC spec
/// §4.10–§4.12): `calendar_event`, `meeting_transcript` (plus its
/// `segments.json` asset) and `recording_job`. Each mirror encodes to the
/// literal and decodes back to the value; a nil optional is an ABSENT key.
///
/// Plain import (no @testable): these are the public mirrors the phone app
/// decodes, and the hub's encoders pin the same literals on their side.
import WatchtowerKit
import WatchtowerSync
import XCTest

final class CalendarMirrorFixtureTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func encoded<P: Encodable>(_ payload: P) throws -> String {
        try XCTUnwrap(String(data: try RelayCoder.makeEncoder().encode(payload), encoding: .utf8))
    }

    private func assertFixture<P: Codable & Equatable>(
        _ payload: P,
        _ fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(try encoded(payload), fixture, file: file, line: line)
        XCTAssertEqual(
            try RelayCoder.makeDecoder().decode(P.self, from: Data(fixture.utf8)),
            payload,
            file: file,
            line: line
        )
    }

    // MARK: - Kinds

    func testSliceKindRawValues() {
        XCTAssertEqual(SliceKind.calendarEvent.rawValue, "calendar_event")
        XCTAssertEqual(SliceKind.meetingTranscript.rawValue, "meeting_transcript")
        XCTAssertEqual(SliceKind.recordingJob.rawValue, "recording_job")
    }

    func testRecordNames() {
        XCTAssertEqual(SliceKind.calendarEvent.recordName(id: "evt-1"), "calendar_event-evt-1")
        XCTAssertEqual(SliceKind.meetingTranscript.recordName(id: "7"), "meeting_transcript-7")
        XCTAssertEqual(SliceKind.recordingJob.recordName(id: "R1"), "recording_job-R1")
    }

    // MARK: - calendar_event

    func testCalendarEventFixture() throws {
        let event = CalendarEvent(
            id: "evt-1",
            startTime: "2026-10-08T09:00:00Z",
            endTime: "2026-10-08T09:30:00Z",
            isAllDay: false,
            isRecurring: true,
            eventStatus: .confirmed,
            organizerEmail: "colleague-a@example.com",
            htmlLink: "https://calendar.example.com/e/1",
            conferenceURL: "https://meet.example.com/abc",
            title: "Acme standup",
            titleClipped: true,
            location: "Room 1",
            description: "Agenda: status",
            attendees: [
                EventAttendee(email: "colleague-a@example.com", displayName: "Colleague A", responseStatus: "accepted")
            ],
            attendeesMore: 3,
            prepBullets: ["Ask about the release"],
            prepGeneratedAt: "2026-10-08T08:00:00Z",
            linkedTargets: [LinkedTarget(id: 42, text: "Send the notes", status: .todo)]
        )
        try assertFixture(
            event,
            // swiftlint:disable:next line_length
            #"{"attendees":[{"display_name":"Colleague A","email":"colleague-a@example.com","response_status":"accepted"}],"attendees_more":3,"conference_url":"https:\/\/meet.example.com\/abc","description":"Agenda: status","end_time":"2026-10-08T09:30:00Z","event_status":"confirmed","html_link":"https:\/\/calendar.example.com\/e\/1","id":"evt-1","is_all_day":false,"is_recurring":true,"linked_targets":[{"id":42,"status":"todo","text":"Send the notes"}],"location":"Room 1","organizer_email":"colleague-a@example.com","prep_bullets":["Ask about the release"],"prep_generated_at":"2026-10-08T08:00:00Z","start_time":"2026-10-08T09:00:00Z","title":"Acme standup","title_clipped":true}"#
        )
        XCTAssertEqual(event.recordName, "calendar_event-evt-1")
        XCTAssertEqual(event.conferenceLink?.host, "meet.example.com")
    }

    func testCalendarEventNilOptionalsAreAbsentKeys() throws {
        let event = CalendarEvent(
            id: "evt-2",
            startTime: "2026-10-25T00:00:00Z",
            endTime: "2026-10-26T00:00:00Z",
            isAllDay: true,
            isRecurring: false,
            eventStatus: .tentative,
            organizerEmail: "",
            htmlLink: "",
            conferenceURL: "",
            title: "Offsite",
            location: "",
            description: "",
            attendees: [],
            prepBullets: [],
            linkedTargets: []
        )
        try assertFixture(
            event,
            // swiftlint:disable:next line_length
            #"{"attendees":[],"conference_url":"","description":"","end_time":"2026-10-26T00:00:00Z","event_status":"tentative","html_link":"","id":"evt-2","is_all_day":true,"is_recurring":false,"linked_targets":[],"location":"","organizer_email":"","prep_bullets":[],"start_time":"2026-10-25T00:00:00Z","title":"Offsite"}"#
        )
        XCTAssertNil(event.conferenceLink, "an empty conference_url means no Join button")
    }

    func testCalendarEventWithFutureStatusesStillDecodes() throws {
        // swiftlint:disable:next line_length
        let json = #"{"attendees":[],"conference_url":"","description":"","end_time":"2026-10-08T10:00:00Z","event_status":"moved","html_link":"","id":"evt-3","is_all_day":false,"is_recurring":false,"linked_targets":[{"id":1,"status":"parked","text":"t"}],"location":"","organizer_email":"","prep_bullets":[],"start_time":"2026-10-08T09:00:00Z","title":"x"}"#
        let event = try RelayCoder.makeDecoder().decode(CalendarEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.eventStatus.rawValue, "moved")
        XCTAssertFalse(event.eventStatus.isKnown)
        XCTAssertEqual(event.linkedTargets.first?.status.rawValue, "parked")
        XCTAssertEqual(event.linkedTargets.first?.status.isKnown, false)
        XCTAssertEqual(try encoded(event), json)
    }

    func testCalendarEnumsAreFrozen() {
        XCTAssertEqual(CalendarEventStatus.knownValues.map(\.rawValue), ["confirmed", "tentative", "cancelled"])
        XCTAssertEqual(
            LinkedTargetStatus.knownValues.map(\.rawValue),
            ["todo", "in_progress", "blocked", "done", "dismissed", "snoozed"]
        )
    }

    // MARK: - meeting_transcript

    func testMeetingTranscriptFixture() throws {
        let transcript = MeetingTranscript(
            id: 7,
            eventID: "evt-1",
            title: "Acme standup",
            durationSec: 754,
            createdAt: "2026-10-08T09:31:00Z",
            updatedAt: "2026-10-08T09:40:00Z",
            phoneRecordingID: "R1",
            speakers: ["Colleague A", "Speaker 2"],
            summary: "Release is on track.",
            keyDecisions: ["Ship on Friday"],
            actionItems: ["Send the notes"],
            actionItemsMore: 2,
            openQuestions: [],
            overview: "A short standup.",
            segmentsClipped: true
        )
        try assertFixture(
            transcript,
            // swiftlint:disable:next line_length
            #"{"action_items":["Send the notes"],"action_items_more":2,"created_at":"2026-10-08T09:31:00Z","duration_sec":754,"event_id":"evt-1","id":7,"key_decisions":["Ship on Friday"],"open_questions":[],"overview":"A short standup.","phone_recording_id":"R1","segments_clipped":true,"speakers":["Colleague A","Speaker 2"],"summary":"Release is on track.","title":"Acme standup","updated_at":"2026-10-08T09:40:00Z"}"#
        )
        XCTAssertEqual(transcript.recordName, "meeting_transcript-7")
    }

    func testAdHocTranscriptNilOptionalsAreAbsentKeys() throws {
        let transcript = MeetingTranscript(
            id: 8,
            title: "Voice note",
            durationSec: 60,
            createdAt: "2026-10-08T09:31:00Z",
            updatedAt: "2026-10-08T09:31:00Z",
            speakers: [],
            keyDecisions: [],
            actionItems: [],
            openQuestions: []
        )
        try assertFixture(
            transcript,
            // swiftlint:disable:next line_length
            #"{"action_items":[],"created_at":"2026-10-08T09:31:00Z","duration_sec":60,"id":8,"key_decisions":[],"open_questions":[],"speakers":[],"title":"Voice note","updated_at":"2026-10-08T09:31:00Z"}"#
        )
        XCTAssertNil(transcript.eventID)
        XCTAssertNil(transcript.summary, "no recap yet")
    }

    func testSegmentsAssetFixture() throws {
        let segments = [
            TranscriptSegment(startSec: 0, endSec: 4.5, speaker: "Colleague A", text: "Morning."),
            TranscriptSegment(startSec: 4.5, endSec: 9, speaker: "", text: "Hi.")
        ]
        // swiftlint:disable:next line_length
        let json = #"[{"end_sec":4.5,"speaker":"Colleague A","start_sec":0,"text":"Morning."},{"end_sec":9,"speaker":"","start_sec":4.5,"text":"Hi."}]"#
        XCTAssertEqual(try encoded(segments), json)
        XCTAssertEqual(try TranscriptSegment.decodeAsset(Data(json.utf8)), segments)
    }

    func testSegmentsAssetWithZeroSegmentsDecodesToAnEmptyList() throws {
        XCTAssertEqual(try TranscriptSegment.decodeAsset(Data("[]".utf8)), [])
    }

    // MARK: - recording_job

    func testRecordingJobTranscribingFixture() throws {
        let job = RecordingJob(id: "R1", status: .transcribing, percent: 25, updatedAt: t0)
        try assertFixture(job, #"{"id":"R1","percent":25,"status":"transcribing","updated_at":1700000000}"#)
        XCTAssertEqual(job.recordName, "recording_job-R1")
    }

    func testRecordingJobDoneFixture() throws {
        let job = RecordingJob(id: "R1", status: .done, transcriptID: 7, updatedAt: t0)
        try assertFixture(job, #"{"id":"R1","status":"done","transcript_id":7,"updated_at":1700000000}"#)
    }

    func testRecordingJobFailedFixture() throws {
        let job = RecordingJob(id: "R2", status: .failed, error: "Transcription failed", updatedAt: t0)
        try assertFixture(
            job,
            #"{"error":"Transcription failed","id":"R2","status":"failed","updated_at":1700000000}"#
        )
    }

    func testRecordingJobStatusesAreFrozen() {
        XCTAssertEqual(
            RecordingJobStatus.allCases.map(\.rawValue),
            ["received", "queued", "transcribing", "diarizing", "summarizing", "done", "failed"]
        )
    }

    func testUnknownRecordingJobStatusDecodesAsQueued() throws {
        let json = #"{"id":"R3","status":"translating","updated_at":1700000000}"#
        let job = try RelayCoder.makeDecoder().decode(RecordingJob.self, from: Data(json.utf8))
        XCTAssertEqual(job.status, .queued)
        XCTAssertEqual(job.updatedAt, t0)
    }
}

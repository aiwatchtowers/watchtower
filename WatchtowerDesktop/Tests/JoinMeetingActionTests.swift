import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop

/// Minimal scriptable `AudioRecording` for driving `MeetingRecorderCenter`
/// into a recording state; never touches real audio.
private final class JoinFakeRecorder: AudioRecording, @unchecked Sendable {
    private(set) var startCalls = 0
    let liveSamples: AsyncStream<[Float]>
    private var liveContinuation: AsyncStream<[Float]>.Continuation!

    init() {
        var c: AsyncStream<[Float]>.Continuation!
        liveSamples = AsyncStream { c = $0 }
        liveContinuation = c
    }

    func start(to url: URL) async throws { startCalls += 1 }

    func stop() async throws -> RecordingResult {
        liveContinuation.finish()
        throw AudioRecordingError.deviceSetupFailed("JoinFakeRecorder never stops")
    }
}

private struct JoinTestError: Error {}

@MainActor
final class JoinMeetingActionTests: XCTestCase {

    // MARK: - Helpers

    /// `CalendarEvent` has only `init(row:)` — build the fixture from a
    /// dictionary Row, mirroring `CalendarEventRowViewTests.makeEvent`.
    private func makeEvent(id: String = "ev1", conferenceURL: String) -> CalendarEvent {
        let row: Row = [
            "id": id,
            "calendar_id": "cal1",
            "title": "Sync",
            "description": "",
            "location": "",
            "start_time": "2099-01-01T10:00:00Z",
            "end_time": "2099-01-01T11:00:00Z",
            "organizer_email": "",
            "attendees": "[]",
            "is_recurring": 0,
            "is_all_day": 0,
            "event_status": "confirmed",
            "event_type": "",
            "html_link": "",
            "conference_url": conferenceURL,
            "raw_json": "{}",
            "synced_at": "",
            "updated_at": ""
        ]
        return CalendarEvent(row: row)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "JoinMeetingActionTests-\(UUID().uuidString)"))
    }

    private func makeCenter(recorder: JoinFakeRecorder, defaults: UserDefaults) -> MeetingRecorderCenter {
        MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in throw JoinTestError() },
            decode: { _ in [] },
            runnerResolver: { nil },
            notifier: JoinFakeNotifier(),
            defaults: defaults
        )
    }

    // MARK: - conferenceLink decoding

    func testConferenceLinkNilWhenEmpty() {
        XCTAssertNil(makeEvent(conferenceURL: "").conferenceLink)
    }

    func testConferenceLinkParsesValidURL() {
        let link = makeEvent(conferenceURL: "https://meet.google.com/abc-defg-hij").conferenceLink
        XCTAssertEqual(link, URL(string: "https://meet.google.com/abc-defg-hij"))
    }

    func testConferenceLinkNilWhenMalformed() {
        // Whitespace makes URL(string:) fail outright.
        XCTAssertNil(makeEvent(conferenceURL: "not a url at all").conferenceLink)
        // Parses as a URL but is not an http(s) link — never handed to open().
        XCTAssertNil(makeEvent(conferenceURL: "file:///etc/passwd").conferenceLink)
        // Scheme without a host.
        XCTAssertNil(makeEvent(conferenceURL: "https://").conferenceLink)
    }

    // MARK: - Join action

    /// Idle recorder + default (absent) auto-record preference → the link
    /// opens AND an event-linked recording starts.
    func testJoinOpensLinkAndStartsRecordingByDefault() async throws {
        let recorder = JoinFakeRecorder()
        let center = makeCenter(recorder: recorder, defaults: try isolatedDefaults())
        let event = makeEvent(id: "evt-join", conferenceURL: "https://meet.google.com/abc-defg-hij")

        var opened: [URL] = []
        await JoinMeetingAction.join(
            event: event, center: center, defaults: try isolatedDefaults(),
            openURL: { opened.append($0) }
        )

        XCTAssertEqual(opened, [URL(string: "https://meet.google.com/abc-defg-hij")])
        XCTAssertEqual(recorder.startCalls, 1)
        XCTAssertEqual(center.currentEventID, "evt-join")
        guard case .recording = center.phase else {
            return XCTFail("expected .recording, got \(center.phase)")
        }
    }

    /// A recording already in flight (another event) must never be interrupted
    /// or double-started — the link still opens.
    func testJoinWhileRecordingOpensLinkOnly() async throws {
        let recorder = JoinFakeRecorder()
        let center = makeCenter(recorder: recorder, defaults: try isolatedDefaults())
        await center.startRecording(eventID: "evt-a", title: "First")
        guard case .recording = center.phase else {
            return XCTFail("expected .recording, got \(center.phase)")
        }

        let other = makeEvent(id: "evt-b", conferenceURL: "https://company.zoom.us/j/123")
        var opened: [URL] = []
        await JoinMeetingAction.join(
            event: other, center: center, defaults: try isolatedDefaults(),
            openURL: { opened.append($0) }
        )

        XCTAssertEqual(opened, [URL(string: "https://company.zoom.us/j/123")],
                       "the link must open even while a recording runs")
        XCTAssertEqual(recorder.startCalls, 1, "no second recording start")
        XCTAssertEqual(center.currentEventID, "evt-a", "the running recording keeps its event link")
    }

    /// Auto-record disabled → open only, recorder stays idle.
    func testJoinWithAutoRecordOffOpensLinkOnly() async throws {
        let recorder = JoinFakeRecorder()
        let center = makeCenter(recorder: recorder, defaults: try isolatedDefaults())
        let defaults = try isolatedDefaults()
        defaults.set(false, forKey: JoinMeetingAction.autoRecordKey)

        var opened: [URL] = []
        await JoinMeetingAction.join(
            event: makeEvent(conferenceURL: "https://meet.google.com/abc-defg-hij"),
            center: center, defaults: defaults,
            openURL: { opened.append($0) }
        )

        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(recorder.startCalls, 0)
        XCTAssertEqual(center.phase, .idle)
    }

    /// Degenerate input: an event without a (valid) link is a full no-op.
    func testJoinWithoutLinkIsANoOp() async throws {
        let recorder = JoinFakeRecorder()
        let center = makeCenter(recorder: recorder, defaults: try isolatedDefaults())

        var opened: [URL] = []
        await JoinMeetingAction.join(
            event: makeEvent(conferenceURL: ""),
            center: center, defaults: try isolatedDefaults(),
            openURL: { opened.append($0) }
        )

        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(recorder.startCalls, 0)
        XCTAssertEqual(center.phase, .idle)
    }
}

private final class JoinFakeNotifier: MeetingTranscriptNotifying, @unchecked Sendable {
    func sendTranscriptReadyNotification(title: String) {}
    func sendTranscriptFailedNotification(reason: String) {}
}

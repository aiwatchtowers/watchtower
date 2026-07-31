import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop

/// Minimal scriptable `AudioRecording` for driving `MeetingRecorderCenter`
/// into a recording state; never touches real audio.
private final class JoinFakeRecorder: AudioRecording, @unchecked Sendable {
    private(set) var startCalls = 0
    /// When set, `start` throws it — the recorder-failure path.
    var startError: Error?
    /// When true, `start` suspends until `releaseStart()` — holds the Center
    /// inside its pre-`.recording` suspension window.
    var holdStart = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    /// When set, `stop` returns it instead of throwing — lets a test walk the
    /// Center into the post-Stop `.transcribing` phase.
    var stopResult: RecordingResult?
    let liveSamples: AsyncStream<[Float]>
    private var liveContinuation: AsyncStream<[Float]>.Continuation!

    init() {
        var c: AsyncStream<[Float]>.Continuation!
        liveSamples = AsyncStream { c = $0 }
        liveContinuation = c
    }

    func start(to url: URL) async throws {
        startCalls += 1
        if let startError { throw startError }
        if holdStart {
            await withCheckedContinuation { startContinuation = $0 }
        }
    }

    func releaseStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func stop() async throws -> RecordingResult {
        liveContinuation.finish()
        if let stopResult { return stopResult }
        throw AudioRecordingError.deviceSetupFailed("JoinFakeRecorder never stops")
    }
}

private struct JoinTestError: Error {}

/// Reusable async gate: `wait()` suspends until `release()`; once released it
/// passes through immediately (the engine factory is invoked twice — live pass
/// and batch fallback — in the busy-phase test).
private final class JoinGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { c in
            lock.lock()
            if released {
                lock.unlock()
                c.resume()
                return
            }
            waiters.append(c)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        let resumable = waiters
        waiters = []
        released = true
        lock.unlock()
        resumable.forEach { $0.resume() }
    }
}

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

    private func makeCenter(
        recorder: JoinFakeRecorder,
        defaults: UserDefaults,
        engineFactory: @escaping (TranscriptionConfig) async throws -> Transcriber = { _ in throw JoinTestError() }
    ) -> MeetingRecorderCenter {
        MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: engineFactory,
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
            recordingSupported: true,
            openURL: { opened.append($0); return true }
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
            recordingSupported: true,
            openURL: { opened.append($0); return true }
        )

        XCTAssertEqual(opened, [URL(string: "https://company.zoom.us/j/123")],
                       "the link must open even while a recording runs")
        XCTAssertEqual(recorder.startCalls, 1, "no second recording start")
        XCTAssertEqual(center.currentEventID, "evt-a", "the running recording keeps its event link")
    }

    /// Two rapid Joins (the event row and the sidebar both target the same
    /// next event) must not double-start: `MeetingRecorderCenter`'s busy latch
    /// flips synchronously BEFORE the recorder's own async start, so the
    /// second Join sees busy while the first is still suspended inside
    /// `recorder.start`.
    func testRapidDoubleJoinStartsExactlyOneRecording() async throws {
        let recorder = JoinFakeRecorder()
        recorder.holdStart = true
        let center = makeCenter(recorder: recorder, defaults: try isolatedDefaults())
        let defaults = try isolatedDefaults()
        let first = makeEvent(id: "evt-1", conferenceURL: "https://meet.google.com/abc-defg-hij")
        let second = makeEvent(id: "evt-2", conferenceURL: "https://meet.google.com/abc-defg-hij")

        let firstJoin = Task {
            await JoinMeetingAction.join(
                event: first, center: center, defaults: defaults,
                recordingSupported: true, openURL: { _ in true }
            )
        }
        for _ in 0..<1000 where recorder.startCalls == 0 { await Task.yield() }
        XCTAssertEqual(recorder.startCalls, 1, "first join must be suspended inside recorder.start")

        var opened: [URL] = []
        await JoinMeetingAction.join(
            event: second, center: center, defaults: defaults,
            recordingSupported: true,
            openURL: { opened.append($0); return true }
        )
        XCTAssertEqual(opened.count, 1, "the second join still opens its link")
        XCTAssertEqual(recorder.startCalls, 1, "no second recorder start while the first is mid-start")

        recorder.releaseStart()
        await firstJoin.value
        XCTAssertEqual(center.currentEventID, "evt-1", "the first join owns the recording")
        guard case .recording = center.phase else {
            return XCTFail("expected .recording, got \(center.phase)")
        }
    }

    /// Post-Stop processing counts as busy too (`.transcribing`, not just
    /// `.recording`): Join opens the link only and never disturbs the
    /// pipeline finishing another recording.
    func testJoinDuringTranscribingOpensLinkOnly() async throws {
        let recorder = JoinFakeRecorder()
        recorder.stopResult = RecordingResult(
            audioURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("join-busy-test.caf"),
            durationSec: 1
        )
        let gate = JoinGate()
        let center = makeCenter(
            recorder: recorder, defaults: try isolatedDefaults(),
            engineFactory: { _ in
                await gate.wait()
                throw JoinTestError()
            }
        )
        let config = TranscriptionConfig.fromDefaults(try isolatedDefaults())
        await center.startRecording(eventID: "evt-a", title: "First", config: config)
        guard case .recording = center.phase else {
            return XCTFail("expected .recording, got \(center.phase)")
        }

        // Stop: the Center parks in `.transcribing` awaiting the gated engine.
        let stopTask = Task { await center.stopAndProcess(config: config) }
        for _ in 0..<1000 where center.phase != .transcribing(done: 0, total: 0) { await Task.yield() }
        XCTAssertEqual(center.phase, .transcribing(done: 0, total: 0))

        let other = makeEvent(id: "evt-b", conferenceURL: "https://company.zoom.us/j/123")
        var opened: [URL] = []
        await JoinMeetingAction.join(
            event: other, center: center, defaults: try isolatedDefaults(),
            recordingSupported: true,
            openURL: { opened.append($0); return true }
        )

        XCTAssertEqual(opened, [URL(string: "https://company.zoom.us/j/123")],
                       "the link must open while transcription runs")
        XCTAssertEqual(recorder.startCalls, 1, "no recording start during post-Stop processing")
        XCTAssertEqual(center.currentEventID, "evt-a", "the finishing pipeline keeps its event link")

        // Cleanup: unblock the engine; both the live pass and the batch
        // fallback then fail fast (JoinTestError) and the run lands in .failed.
        gate.release()
        await stopTask.value
        guard case .failed = center.phase else {
            return XCTFail("expected .failed after cleanup, got \(center.phase)")
        }
    }

    /// The spec's core error clause: recorder problems must never block
    /// joining — the link opens FIRST, and the start failure surfaces through
    /// the Center's own `.failed` path.
    func testJoinRecorderStartFailureStillOpensLinkFirst() async throws {
        let recorder = JoinFakeRecorder()
        recorder.startError = JoinTestError()
        let center = makeCenter(recorder: recorder, defaults: try isolatedDefaults())
        let event = makeEvent(id: "evt-fail", conferenceURL: "https://meet.google.com/abc-defg-hij")

        var opened: [URL] = []
        await JoinMeetingAction.join(
            event: event, center: center, defaults: try isolatedDefaults(),
            recordingSupported: true,
            openURL: { opened.append($0); return true }
        )

        XCTAssertEqual(opened, [URL(string: "https://meet.google.com/abc-defg-hij")],
                       "the link must open even when the recorder fails to start")
        XCTAssertEqual(recorder.startCalls, 1)
        guard case .failed = center.phase else {
            return XCTFail("expected .failed, got \(center.phase)")
        }
    }

    /// An open failure (LaunchServices refusal) means the user never joined —
    /// auto-record must not start a recording of a meeting nobody is in.
    func testJoinSkipsRecordingWhenOpenFails() async throws {
        let recorder = JoinFakeRecorder()
        let center = makeCenter(recorder: recorder, defaults: try isolatedDefaults())

        var attempted: [URL] = []
        await JoinMeetingAction.join(
            event: makeEvent(conferenceURL: "https://meet.google.com/abc-defg-hij"),
            center: center, defaults: try isolatedDefaults(),
            recordingSupported: true,
            openURL: { attempted.append($0); return false }
        )

        XCTAssertEqual(attempted.count, 1, "the open must still be attempted")
        XCTAssertEqual(recorder.startCalls, 0, "no recording when the meeting never opened")
        XCTAssertEqual(center.phase, .idle)
    }

    /// macOS without recording support (`SystemAudioRecorder.isSupported`
    /// false, 14.0–14.3): Join opens the link only — parity with the manual
    /// Record button's disabled gate, never a failure banner for a recording
    /// the user didn't request.
    func testJoinWithoutRecordingSupportOpensLinkOnly() async throws {
        let recorder = JoinFakeRecorder()
        let center = makeCenter(recorder: recorder, defaults: try isolatedDefaults())

        var opened: [URL] = []
        await JoinMeetingAction.join(
            event: makeEvent(conferenceURL: "https://meet.google.com/abc-defg-hij"),
            center: center, defaults: try isolatedDefaults(),
            recordingSupported: false,
            openURL: { opened.append($0); return true }
        )

        XCTAssertEqual(opened.count, 1, "joining is unaffected by the recording gate")
        XCTAssertEqual(recorder.startCalls, 0)
        XCTAssertEqual(center.phase, .idle)
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
            recordingSupported: true,
            openURL: { opened.append($0); return true }
        )

        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(recorder.startCalls, 0)
        XCTAssertEqual(center.phase, .idle)
    }

    /// The notification's "Join + Record" action (spec §2): `forceRecord`
    /// starts an event-linked recording even with auto-record switched OFF.
    func testJoinForceRecordOverridesAutoRecordOff() async throws {
        let recorder = JoinFakeRecorder()
        let center = makeCenter(recorder: recorder, defaults: try isolatedDefaults())
        let defaults = try isolatedDefaults()
        defaults.set(false, forKey: JoinMeetingAction.autoRecordKey)

        var opened: [URL] = []
        await JoinMeetingAction.join(
            event: makeEvent(id: "evt-force", conferenceURL: "https://meet.google.com/abc-defg-hij"),
            center: center, forceRecord: true, defaults: defaults,
            recordingSupported: true,
            openURL: { opened.append($0); return true }
        )

        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(recorder.startCalls, 1, "forceRecord must start recording despite auto-record off")
        XCTAssertEqual(center.currentEventID, "evt-force")
        guard case .recording = center.phase else {
            return XCTFail("expected .recording, got \(center.phase)")
        }
    }

    /// `forceRecord` never overrides the single-slot recorder guard: with a
    /// recording already in flight the link opens and nothing is interrupted
    /// or double-started.
    func testJoinForceRecordWhileBusyOpensLinkOnly() async throws {
        let recorder = JoinFakeRecorder()
        let center = makeCenter(recorder: recorder, defaults: try isolatedDefaults())
        await center.startRecording(eventID: "evt-a", title: "First")
        guard case .recording = center.phase else {
            return XCTFail("expected .recording, got \(center.phase)")
        }

        var opened: [URL] = []
        await JoinMeetingAction.join(
            event: makeEvent(id: "evt-b", conferenceURL: "https://company.zoom.us/j/123"),
            center: center, forceRecord: true, defaults: try isolatedDefaults(),
            recordingSupported: true,
            openURL: { opened.append($0); return true }
        )

        XCTAssertEqual(opened, [URL(string: "https://company.zoom.us/j/123")],
                       "the link must open even when the recorder is busy")
        XCTAssertEqual(recorder.startCalls, 1, "forceRecord must not double-start or interrupt")
        XCTAssertEqual(center.currentEventID, "evt-a", "the running recording keeps its event link")
    }

    /// Degenerate input: an event without a (valid) link is a full no-op.
    func testJoinWithoutLinkIsANoOp() async throws {
        let recorder = JoinFakeRecorder()
        let center = makeCenter(recorder: recorder, defaults: try isolatedDefaults())

        var opened: [URL] = []
        await JoinMeetingAction.join(
            event: makeEvent(conferenceURL: ""),
            center: center, defaults: try isolatedDefaults(),
            recordingSupported: true,
            openURL: { opened.append($0); return true }
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

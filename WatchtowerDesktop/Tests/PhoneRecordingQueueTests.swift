import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// The Go hub's control socket as the queue sees it: every request
/// recorded; a claim answers with the job's audio file unless the test
/// refuses it.
private final class FakeRecordingHub: HubControlClienting, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [HubControlRequest] = []
    private var isReachable = true
    private var refusedClaims: Set<String> = []
    let audioDir: URL

    init(audioDir: URL) { self.audioDir = audioDir }

    var reachable: Bool {
        get { lock.withLock { isReachable } }
        set { lock.withLock { isReachable = newValue } }
    }

    /// Claims of these uploads are refused `job_state` (done, failed, hub_moved).
    func refuseClaims(_ ids: Set<String>) { lock.withLock { refusedClaims = ids } }

    var sent: [HubControlRequest] { lock.withLock { requests } }
    func sent(_ op: String) -> [HubControlRequest] { sent.filter { $0.op == op } }

    func audio(_ upload: String) -> URL { audioDir.appendingPathComponent("\(upload).m4a") }

    func send(_ request: HubControlRequest) async throws -> HubControlAnswer {
        guard reachable else { throw HubControlError.noHub }
        lock.withLock { requests.append(request) }
        let upload = request.upload ?? ""
        switch request.op {
        case HubControlRequest.recordingClaim:
            if lock.withLock({ refusedClaims.contains(upload) }) {
                return HubControlAnswer(op: request.op, error: "job_state")
            }
            return HubControlAnswer(op: request.op, ok: true, uploadID: upload, status: "claimed", audioPath: audio(upload).path)
        case HubControlRequest.recordingFinish:
            return HubControlAnswer(op: request.op, ok: true, uploadID: upload, status: request.transcriptID != nil ? "done" : "failed")
        default:
            return HubControlAnswer(op: request.op, ok: true, uploadID: upload, status: "claimed")
        }
    }

    func watch() -> AsyncThrowingStream<HubEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// `hub recording list --json` with a scripted queue.
private final class FakeListCLI: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [[String: Any]] = []
    private var calls: [[String]] = []

    var invocations: [[String]] { lock.withLock { calls } }

    func setRows(_ next: [[String: Any]]) { lock.withLock { rows = next } }

    func run(args: [String]) async throws -> Data {
        let rows = lock.withLock { () -> [[String: Any]] in
            calls.append(args)
            return self.rows
        }
        return try JSONSerialization.data(withJSONObject: rows)
    }
}

/// The transcriber's observers, driven by the test.
@MainActor
private final class FakeTranscriber: PhoneRecordingJobObserving {
    var observers: [UUID: MeetingRecorderCenter.JobObserver] = [:]

    func addJobObserver(_ observer: MeetingRecorderCenter.JobObserver) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func removeJobObserver(_ token: UUID) { observers[token] = nil }

    func phase(_ url: URL, _ phase: MeetingRecorderCenter.ProcessingJob.Phase) {
        observers.values.forEach { $0.phase(url, phase) }
    }

    func finished(_ url: URL, _ transcriptID: Int64) {
        observers.values.forEach { $0.finished(url, transcriptID) }
    }
}

@MainActor
final class PhoneRecordingQueueTests: XCTestCase {
    private var dir: URL!
    private var hub: FakeRecordingHub!
    private var cli: FakeListCLI!
    private var transcriber: FakeTranscriber!
    private var defaults: UserDefaults!
    private var suite: String!
    /// The audio each ingest took, and what it answered.
    private var ingested: [URL] = []
    private var ingestError: Error?
    private var queues: [PhoneRecordingQueue] = []

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("prq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        hub = FakeRecordingHub(audioDir: dir)
        cli = FakeListCLI()
        transcriber = FakeTranscriber()
        suite = "PhoneRecordingQueueTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        ingested = []
        ingestError = nil
    }

    override func tearDown() async throws {
        queues.forEach { $0.stop() }
        queues = []
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    private func makeQueue() -> PhoneRecordingQueue {
        let queue = PhoneRecordingQueue(client: hub, cli: cli, observing: transcriber, defaults: defaults) { [weak self] audio in
            guard let self else { throw CancellationError() }
            if let ingestError { throw ingestError }
            ingested.append(audio)
            return URL(fileURLWithPath: "/recordings/rec_\(ingested.count).m4a")
        }
        queue.start()
        queues.append(queue)
        return queue
    }

    private func writeAudio(_ upload: String) throws {
        try Data([0x41]).write(to: hub.audio(upload))
    }

    private func row(_ id: String, _ status: String) -> [String: Any] {
        ["upload_id": id, "status": status, "phase": "", "percent": NSNull(), "audio_path": hub.audio(id).path]
    }

    // MARK: - Claim and ingest

    func testQueuedRecordingIsClaimedAndIngested() async throws {
        try writeAudio("u1")
        let queue = makeQueue()
        queue.recordingQueued("u1")
        await queue.idle()
        XCTAssertEqual(hub.sent(HubControlRequest.recordingClaim).map(\.upload), ["u1"])
        XCTAssertEqual(ingested, [hub.audio("u1")], "the transcriber takes the file the claim named")
        XCTAssertEqual(queue.tracked["u1"]?.path, "/recordings/rec_1.m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: hub.audio("u1").path), "the hub's plaintext copy goes once ingested")

        // A second event for it, and a rescan seeing it claimed, take nothing more.
        queue.recordingQueued("u1")
        cli.setRows([row("u1", "claimed")])
        queue.rescan()
        await queue.idle()
        XCTAssertEqual(ingested.count, 1)

        // A new queue (the next launch) remembers it.
        let next = makeQueue()
        XCTAssertEqual(next.tracked["u1"]?.path, "/recordings/rec_1.m4a")
    }

    func testRescanTakesTheJobsQueuedWhileNoWatchListened() async throws {
        try writeAudio("u1")
        try writeAudio("u2")
        cli.setRows([row("u1", "queued"), row("u2", "claimed"), row("u3", "done"), row("u4", "failed")])
        let queue = makeQueue()
        queue.rescan()
        await queue.idle()
        XCTAssertEqual(cli.invocations, [PhoneRecordingQueue.listArgs])
        XCTAssertEqual(hub.sent(HubControlRequest.recordingClaim).map(\.upload), ["u1", "u2"],
                       "queued, and claimed by a Desktop that quit before ingesting; never done or failed")
        XCTAssertEqual(ingested, [hub.audio("u1"), hub.audio("u2")])
    }

    // MARK: - Reports

    func testProgressPhasesReachTheHub() async throws {
        try writeAudio("u1")
        let queue = makeQueue()
        queue.recordingQueued("u1")
        await queue.idle()
        let url = URL(fileURLWithPath: "/recordings/rec_1.m4a")
        transcriber.phase(url, .transcribing(done: 0, total: 0))
        transcriber.phase(url, .transcribing(done: 1, total: 4))
        transcriber.phase(url, .transcribing(done: 1, total: 4)) // unchanged: not sent again
        transcriber.phase(url, .transcribing(done: 4, total: 4))
        transcriber.phase(url, .diarizing)
        transcriber.phase(url, .summarizing)
        // A job the queue did not ingest (the Mac's own recording) is not reported.
        transcriber.phase(URL(fileURLWithPath: "/recordings/rec_mac.m4a"), .diarizing)
        await queue.idle()
        let progress = hub.sent(HubControlRequest.recordingProgress)
        XCTAssertEqual(progress.map(\.upload), Array(repeating: "u1", count: 5))
        XCTAssertEqual(progress.map(\.phase), ["transcribing", "transcribing", "transcribing", "diarizing", "summarizing"])
        XCTAssertEqual(progress.map(\.percent), [0, 25, 100, nil, nil])
    }

    func testFinishCarriesTheTranscriptID() async throws {
        try writeAudio("u1")
        let queue = makeQueue()
        queue.recordingQueued("u1")
        await queue.idle()
        transcriber.finished(URL(fileURLWithPath: "/recordings/rec_1.m4a"), 42)
        await queue.idle()
        let finish = try XCTUnwrap(hub.sent(HubControlRequest.recordingFinish).first)
        XCTAssertEqual(finish.upload, "u1")
        XCTAssertEqual(finish.transcriptID, 42)
        XCTAssertNil(finish.errorClass)
        XCTAssertNil(queue.tracked["u1"], "a done job is forgotten")
    }

    func testAFinishTheHubMissedIsSentAgainAtTheNextRescan() async throws {
        try writeAudio("u1")
        let queue = makeQueue()
        queue.recordingQueued("u1")
        await queue.idle()
        hub.reachable = false
        transcriber.finished(URL(fileURLWithPath: "/recordings/rec_1.m4a"), 42)
        await queue.idle()
        XCTAssertEqual(queue.tracked["u1"]?.pendingTranscript, 42)
        hub.reachable = true
        cli.setRows([row("u1", "claimed")])
        queue.rescan()
        await queue.idle()
        XCTAssertEqual(hub.sent(HubControlRequest.recordingFinish).map(\.transcriptID), [42])
        XCTAssertNil(queue.tracked["u1"])
    }

    func testFailureSendsAClassNeverText() async throws {
        try writeAudio("u1")
        try writeAudio("u2")
        let queue = makeQueue()
        queue.recordingQueued("u1")
        queue.recordingQueued("u2")
        await queue.idle()
        transcriber.phase(URL(fileURLWithPath: "/recordings/rec_1.m4a"), .failed("No speech recognized — no call audio was captured at all."))
        transcriber.phase(URL(fileURLWithPath: "/recordings/rec_2.m4a"), .failed("The file /Users/x/rec.m4a could not be opened"))
        await queue.idle()
        let finishes = hub.sent(HubControlRequest.recordingFinish)
        XCTAssertEqual(finishes.map(\.errorClass), ["no_speech", "transcription_failed"])
        XCTAssertEqual(finishes.map(\.transcriptID), [nil, nil])
        let line = try XCTUnwrap(String(bytes: JSONEncoder().encode(finishes[1]), encoding: .utf8))
        XCTAssertFalse(line.contains("Users") || line.contains("opened"), "only the class goes on: \(line)")

        // An ingest that fails ends the job with its class too.
        try writeAudio("u3")
        ingestError = MeetingRecorderCenter.PhoneIngestError.notAudio
        queue.recordingQueued("u3")
        // A missing file is missing_audio, before any ingest.
        queue.recordingQueued("u4")
        await queue.idle()
        XCTAssertEqual(hub.sent(HubControlRequest.recordingFinish).suffix(2).map(\.errorClass), ["not_audio", "missing_audio"])
    }

    func testATransientIngestFailureIsTriedAgainNotReported() async throws {
        try writeAudio("u1")
        ingestError = MeetingRecorderCenter.PhoneIngestError.databaseUnavailable
        let queue = makeQueue()
        queue.recordingQueued("u1")
        await queue.idle()
        XCTAssertTrue(hub.sent(HubControlRequest.recordingFinish).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hub.audio("u1").path), "the audio stays for the retry")
        ingestError = nil
        cli.setRows([row("u1", "claimed")])
        queue.rescan()
        await queue.idle()
        XCTAssertEqual(ingested, [hub.audio("u1")])
    }

    func testTheOwnersRetryClaimsTheFailedJobAgain() async throws {
        try writeAudio("u1")
        let queue = makeQueue()
        queue.recordingQueued("u1")
        await queue.idle()
        let url = URL(fileURLWithPath: "/recordings/rec_1.m4a")
        transcriber.phase(url, .failed("boom"))
        await queue.idle()
        transcriber.phase(url, .queued)
        transcriber.phase(url, .transcribing(done: 0, total: 0))
        transcriber.finished(url, 7)
        await queue.idle()
        XCTAssertEqual(hub.sent.map(\.op), [
            HubControlRequest.recordingClaim, HubControlRequest.recordingFinish,
            HubControlRequest.recordingClaim, HubControlRequest.recordingProgress, HubControlRequest.recordingFinish
        ])
        XCTAssertEqual(hub.sent(HubControlRequest.recordingFinish).last?.transcriptID, 7)
    }

    // MARK: - What it leaves alone

    func testAHubMovedJobIsNeverClaimed() async throws {
        try writeAudio("moved")
        cli.setRows([row("moved", "failed")])
        let queue = makeQueue()
        queue.rescan()
        await queue.idle()
        XCTAssertTrue(hub.sent(HubControlRequest.recordingClaim).isEmpty, "a failed row is never claimed from the list")

        // An event for it (a hub that queued it before adopting) is refused by the hub: nothing ingested, nothing reported.
        hub.refuseClaims(["moved"])
        queue.recordingQueued("moved")
        await queue.idle()
        XCTAssertTrue(ingested.isEmpty)
        XCTAssertTrue(hub.sent(HubControlRequest.recordingFinish).isEmpty)
        XCTAssertTrue(hub.sent(HubControlRequest.recordingProgress).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hub.audio("moved").path), "its kept audio is the hub's")

        // The recorder's own job for that audio (the Swift hub ingested it) is not followed.
        transcriber.phase(hub.audio("moved"), .diarizing)
        transcriber.finished(hub.audio("moved"), 3)
        await queue.idle()
        XCTAssertTrue(hub.sent(HubControlRequest.recordingFinish).isEmpty)
    }

    func testNoHubLeavesTheQueueAlone() async throws {
        try writeAudio("u1")
        hub.reachable = false
        cli.setRows([row("u1", "queued")])
        let queue = makeQueue()
        queue.recordingQueued("u1")
        queue.rescan()
        await queue.idle()
        XCTAssertTrue(ingested.isEmpty)
        XCTAssertTrue(queue.tracked.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hub.audio("u1").path))
    }

    // MARK: - Pinned

    /// The classes are the Go side's (`state.ClassNoSpeech` …), whose phone
    /// texts Go pins in `TestRecordingFailureTextsPinned`.
    func testFailureClassesPinned() {
        XCTAssertEqual(PhoneRecordingQueue.FailureClass.allCases.map(\.rawValue), [
            "no_speech", "transcription_failed", "not_audio", "unreadable", "ingest_failed", "missing_audio"
        ])
        XCTAssertEqual(PhoneRecordingQueue.failureClass(transcriberMessage: "No speech recognized"), .noSpeech)
        XCTAssertEqual(PhoneRecordingQueue.failureClass(transcriberMessage: MeetingRecorderCenter.noSpeechMessage(nil)), .noSpeech)
        XCTAssertEqual(PhoneRecordingQueue.failureClass(transcriberMessage: "Model failed to load"), .transcriptionFailed)
        XCTAssertEqual(PhoneRecordingQueue.failureClass(ingestError: MeetingRecorderCenter.PhoneIngestError.unreadable("x")), .unreadable)
        XCTAssertEqual(PhoneRecordingQueue.failureClass(ingestError: CocoaError(.fileWriteOutOfSpace)), .ingestFailed)
        XCTAssertNil(PhoneRecordingQueue.failureClass(ingestError: MeetingRecorderCenter.PhoneIngestError.databaseUnavailable))
        XCTAssertEqual(PhoneRecordingQueue.listArgs, ["hub", "recording", "list", "--json"])
    }

    func testRequestsEncodeTheGoKeys() throws {
        func keys(_ r: HubControlRequest) throws -> [String: AnyHashable] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: AnyHashable])
        }
        XCTAssertEqual(try keys(.claim("u1")), ["op": "recording_claim", "upload": "u1"])
        XCTAssertEqual(try keys(.progress("u1", phase: "transcribing", percent: 0)),
                       ["op": "recording_progress", "upload": "u1", "phase": "transcribing", "percent": 0])
        XCTAssertEqual(try keys(.finish("u1", transcriptID: 9)), ["op": "recording_finish", "upload": "u1", "transcript_id": 9])
        XCTAssertEqual(try keys(.finish("u1", errorClass: "no_speech")),
                       ["op": "recording_finish", "upload": "u1", "error_class": "no_speech"])
        let answer = try JSONDecoder().decode(HubControlAnswer.self, from: Data(
            #"{"ok":true,"upload_id":"u1","status":"claimed","audio_path":"/tmp/u1.m4a"}"#.utf8))
        XCTAssertEqual(answer.audioPath, "/tmp/u1.m4a")
        XCTAssertEqual(answer.status, "claimed")
    }
}

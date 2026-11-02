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
    private var jobOrigins: [String: (eventID: String?, startedAt: Date?)] = [:]
    let audioDir: URL

    init(audioDir: URL) { self.audioDir = audioDir }

    var reachable: Bool {
        get { lock.withLock { isReachable } }
        set { lock.withLock { isReachable = newValue } }
    }

    /// Claims of these uploads are refused `job_state` (done, hub_moved, an adopted failure).
    func refuseClaims(_ ids: Set<String>) { lock.withLock { refusedClaims = ids } }

    /// The origin a claim of `upload` answers with.
    func setOrigin(_ upload: String, eventID: String?, startedAt: Date?) {
        lock.withLock { jobOrigins[upload] = (eventID, startedAt) }
    }

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
            let origin = lock.withLock { jobOrigins[upload] }
            return HubControlAnswer(
                op: request.op, ok: true, uploadID: upload, status: "claimed", audioPath: audio(upload).path,
                eventID: origin?.eventID, startedAt: origin?.startedAt
            )
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
    private var answer: [String: Any] = ["ready": true, "jobs": [[String: Any]]()]
    private var calls: [[String]] = []

    var invocations: [[String]] { lock.withLock { calls } }

    func setRows(_ rows: [[String: Any]], ready: Bool = true) {
        lock.withLock { answer = ["ready": ready, "jobs": rows] }
    }

    func run(args: [String]) async throws -> Data {
        let answer = lock.withLock { () -> [String: Any] in
            calls.append(args)
            return self.answer
        }
        return try JSONSerialization.data(withJSONObject: answer)
    }
}

/// The transcriber's observers and pending reservations, driven by the test.
@MainActor
private final class FakeTranscriber: PhoneRecordingJobObserving {
    var observers: [UUID: MeetingRecorderCenter.JobObserver] = [:]
    /// Upload id → the recording its ingest reserved (`pending_transcripts.upload_id`).
    var reserved: [String: URL] = [:]
    var lookupError: Error?

    func addJobObserver(_ observer: MeetingRecorderCenter.JobObserver) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func removeJobObserver(_ token: UUID) { observers[token] = nil }

    func phoneRecording(forUpload uploadID: String) throws -> URL? {
        if let lookupError { throw lookupError }
        return reserved[uploadID]
    }

    func phase(_ url: URL, _ phase: MeetingRecorderCenter.ProcessingJob.Phase) {
        observers.values.forEach { $0.phase(url, phase) }
    }

    func finished(_ url: URL, _ transcriptID: Int64) {
        observers.values.forEach { $0.finished(url, transcriptID) }
    }
}

/// The queue's backoff waits, parked until the test releases them.
private final class RetrySleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var all: [Duration] = []

    var waits: [Duration] { lock.withLock { all } }
    var parkedCount: Int { lock.withLock { parked.count } }

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                all.append(duration)
                parked.append(continuation)
            }
        }
    }

    func releaseAll() {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { parked = [] }
            return parked
        }
        due.forEach { $0.resume() }
    }
}

private struct CalendarDown: Error {}

@MainActor
final class PhoneRecordingQueueTests: XCTestCase {
    private var dir: URL!
    private var hub: FakeRecordingHub!
    private var cli: FakeListCLI!
    private var transcriber: FakeTranscriber!
    private var sleeper: RetrySleeper!
    private var defaults: UserDefaults!
    private var suite: String!
    /// The audio each ingest took, and what it answered.
    private var ingested: [URL] = []
    private var ingestError: Error?
    private var queues: [PhoneRecordingQueue] = []
    /// This Mac's calendar: event id → title.
    private var calendar: [String: String] = [:]
    private var calendarError: Error?
    private struct Origin: Equatable {
        let eventID: String?
        let title: String?
    }
    private var origins: [Origin] = []
    /// What was remembered when each ingest started.
    private var stagesAtIngest: [PhoneRecordingQueue.Tracked.Stage?] = []

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("prq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        hub = FakeRecordingHub(audioDir: dir)
        cli = FakeListCLI()
        transcriber = FakeTranscriber()
        sleeper = RetrySleeper()
        suite = "PhoneRecordingQueueTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        ingested = []
        ingestError = nil
        calendar = [:]
        calendarError = nil
        origins = []
        stagesAtIngest = []
    }

    override func tearDown() async throws {
        queues.forEach { $0.stop() }
        queues = []
        sleeper.releaseAll()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    private func makeQueue() -> PhoneRecordingQueue {
        let sleeper: RetrySleeper = self.sleeper
        let defaults: UserDefaults = self.defaults
        let queue = PhoneRecordingQueue(
            client: hub, cli: cli, observing: transcriber, defaults: defaults,
            sleep: { await sleeper.sleep($0) },
            eventTitle: { [weak self] id in
                if let error = self?.calendarError { throw error }
                return self?.calendar[id]
            },
            ingest: { [weak self] audio, eventID, title, uploadID in
                guard let self else { throw CancellationError() }
                stagesAtIngest.append(Self.remembered(defaults)[uploadID]?.stage)
                if let ingestError { throw ingestError }
                ingested.append(audio)
                origins.append(Origin(eventID: eventID, title: title))
                return URL(fileURLWithPath: "/recordings/rec_\(ingested.count).m4a")
            }
        )
        queue.start()
        queues.append(queue)
        return queue
    }

    private static func remembered(_ defaults: UserDefaults) -> [String: PhoneRecordingQueue.Tracked] {
        guard let data = defaults.data(forKey: PhoneRecordingQueue.defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: PhoneRecordingQueue.Tracked].self, from: data)) ?? [:]
    }

    private func writeAudio(_ upload: String) throws {
        try Data([0x41]).write(to: hub.audio(upload))
    }

    private func hubHas(_ upload: String) -> Bool {
        FileManager.default.fileExists(atPath: hub.audio(upload).path)
    }

    private func row(_ id: String, _ status: String, errorClass: String = "") -> [String: Any] {
        ["upload_id": id, "status": status, "phase": "", "percent": NSNull(), "audio_path": hub.audio(id).path,
         "event_id": "", "started_at": NSNull(), "error_class": errorClass]
    }

    private func waitForRetry(_ count: Int) async {
        for _ in 0..<500 where sleeper.parkedCount < count {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(sleeper.parkedCount, count, "retries parked")
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
        XCTAssertTrue(hubHas("u1"), "the hub's copy stays until the transcript is saved")

        // A second event for it, and a rescan seeing it claimed, take nothing more.
        queue.recordingQueued("u1")
        cli.setRows([row("u1", "claimed")])
        queue.rescan()
        await queue.idle()
        XCTAssertEqual(ingested.count, 1)
    }

    func testTheUploadIsRememberedBeforeTheIngestStarts() async throws {
        try writeAudio("u1")
        let queue = makeQueue()
        queue.recordingQueued("u1")
        await queue.idle()
        XCTAssertEqual(stagesAtIngest, [.ingesting])
        XCTAssertEqual(Self.remembered(defaults)["u1"]?.stage, .ingested)
    }

    func testRescanTakesTheJobsQueuedWhileNoWatchListened() async throws {
        try writeAudio("u1")
        try writeAudio("u2")
        cli.setRows([row("u1", "queued"), row("u2", "claimed"), row("u3", "done"), row("u4", "failed", errorClass: "other")])
        let queue = makeQueue()
        queue.rescan()
        await queue.idle()
        XCTAssertEqual(cli.invocations, [PhoneRecordingQueue.listArgs])
        XCTAssertEqual(hub.sent(HubControlRequest.recordingClaim).map(\.upload), ["u1", "u2"],
                       "queued, and claimed with no reservation; never done or a failure this Desktop did not report")
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
        XCTAssertFalse(hubHas("u1"), "the hub's copy goes once the transcript is saved")
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
        XCTAssertTrue(hubHas("u1"), "unsent: the hub's copy stays")
        hub.reachable = true
        cli.setRows([row("u1", "claimed")])
        queue.rescan()
        await queue.idle()
        XCTAssertEqual(hub.sent(HubControlRequest.recordingFinish).map(\.transcriptID), [42])
        XCTAssertNil(queue.tracked["u1"])
    }

    func testARelaunchFollowsARememberedUpload() async throws {
        try writeAudio("u1")
        let first = makeQueue()
        first.recordingQueued("u1")
        await first.idle()
        first.stop()
        // The next launch: the recorder's recovery saves the transcript of the remembered recording.
        let next = makeQueue()
        XCTAssertEqual(next.tracked["u1"]?.path, "/recordings/rec_1.m4a")
        transcriber.finished(URL(fileURLWithPath: "/recordings/rec_1.m4a"), 9)
        await next.idle()
        XCTAssertEqual(hub.sent(HubControlRequest.recordingFinish).map(\.transcriptID), [9])
        XCTAssertFalse(hubHas("u1"))
    }

    // MARK: - Failures keep the audio

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
        XCTAssertTrue(hubHas("u1") && hubHas("u2"), "a failed transcription keeps the hub's copy")

        // A missing file is missing_audio, before any ingest.
        queue.recordingQueued("u4")
        await queue.idle()
        XCTAssertEqual(hub.sent(HubControlRequest.recordingFinish).last?.errorClass, "missing_audio")
        XCTAssertEqual(ingested.count, 2)
    }

    /// Every ingest failure keeps the hub's audio; each is reported by
    /// class (but a database not open yet), and all but not_audio are tried
    /// again on their own.
    func testEveryIngestFailureKeepsTheHubAudio() async throws {
        let cases: [(String, Error, String?, Bool)] = [
            ("not-audio", MeetingRecorderCenter.PhoneIngestError.notAudio, "not_audio", false),
            ("unreadable", MeetingRecorderCenter.PhoneIngestError.unreadable("x"), "unreadable", true),
            ("disk-full", CocoaError(.fileWriteOutOfSpace), "ingest_failed", true),
            ("cancelled", CancellationError(), "ingest_failed", true),
            ("db-closed", MeetingRecorderCenter.PhoneIngestError.databaseUnavailable, nil, true)
        ]
        let queue = makeQueue()
        var retried = 0
        for (id, error, reported, retries) in cases {
            try writeAudio(id)
            ingestError = error
            queue.recordingQueued(id)
            await queue.idle()
            XCTAssertTrue(hubHas(id), "\(id): the hub's copy stays")
            XCTAssertNil(queue.tracked[id], "\(id): nothing landed")
            let finish = hub.sent(HubControlRequest.recordingFinish).last { $0.upload == id }
            XCTAssertEqual(finish?.errorClass, reported, id)
            if retries { retried += 1 }
            await waitForRetry(retried)
        }
        XCTAssertEqual(sleeper.waits, Array(repeating: PhoneRecordingQueue.firstRetry, count: retried))
    }

    func testARetriedFailureBacksOffAndIngestsLater() async throws {
        try writeAudio("u1")
        ingestError = CocoaError(.fileWriteOutOfSpace)
        let queue = makeQueue()
        queue.recordingQueued("u1")
        await queue.idle()
        await waitForRetry(1)
        sleeper.releaseAll() // still failing: the next wait doubles
        await waitForRetry(1)
        XCTAssertEqual(sleeper.waits, [.seconds(30), .seconds(60)])
        ingestError = nil
        sleeper.releaseAll()
        for _ in 0..<500 where ingested.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
        await queue.idle()
        XCTAssertEqual(ingested, [hub.audio("u1")])
        XCTAssertEqual(hub.sent(HubControlRequest.recordingClaim).count, 3, "each retry claims the failed job again")
        XCTAssertTrue(hubHas("u1"))
    }

    func testACalendarReadErrorIsTriedAgainNeverSavedAdHoc() async throws {
        try writeAudio("u1")
        hub.setOrigin("u1", eventID: "evt-1", startedAt: nil)
        calendar = ["evt-1": "Acme sync"]
        calendarError = CalendarDown()
        let queue = makeQueue()
        queue.recordingQueued("u1")
        await queue.idle()
        XCTAssertTrue(ingested.isEmpty, "not ingested ad-hoc on a read error")
        XCTAssertTrue(hub.sent(HubControlRequest.recordingFinish).isEmpty, "nothing reported")
        await waitForRetry(1)
        calendarError = nil
        sleeper.releaseAll()
        for _ in 0..<500 where ingested.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
        await queue.idle()
        XCTAssertEqual(origins, [Origin(eventID: "evt-1", title: "Acme sync")])
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

    // MARK: - Exactly once across a crash

    /// The app stopped between the ingest's reservation and remembering it
    /// ingested: the reservation, found by upload id, is followed, not
    /// ingested again; with no reservation the upload is ingested once.
    func testACrashBetweenTheReservationAndTheSaveIsNotIngestedTwice() async throws {
        try writeAudio("u1")
        try writeAudio("u2")
        let crashed = [
            "u1": PhoneRecordingQueue.Tracked(stage: .ingesting, hubAudio: hub.audio("u1").path),
            "u2": PhoneRecordingQueue.Tracked(stage: .ingesting, hubAudio: hub.audio("u2").path)
        ]
        defaults.set(try JSONEncoder().encode(crashed), forKey: PhoneRecordingQueue.defaultsKey)
        transcriber.reserved["u1"] = URL(fileURLWithPath: "/recordings/rec_reserved.m4a")
        cli.setRows([row("u1", "claimed"), row("u2", "claimed")])
        let queue = makeQueue()
        queue.rescan()
        await queue.idle()
        XCTAssertEqual(ingested, [hub.audio("u2")], "only the upload with no reservation is ingested")
        XCTAssertEqual(queue.tracked["u1"]?.stage, .ingested)
        transcriber.finished(URL(fileURLWithPath: "/recordings/rec_reserved.m4a"), 5)
        await queue.idle()
        XCTAssertEqual(hub.sent(HubControlRequest.recordingFinish).map(\.transcriptID), [5])
        XCTAssertFalse(hubHas("u1"))
    }

    /// Unreadable bookkeeping is a third state: claimed jobs are matched by
    /// upload id; one with no reservation is left alone, never re-ingested.
    func testUnreadableBookkeepingMatchesClaimedJobsByUploadID() async throws {
        try writeAudio("u1")
        try writeAudio("u2")
        defaults.set(Data("not json".utf8), forKey: PhoneRecordingQueue.defaultsKey)
        transcriber.reserved["u1"] = URL(fileURLWithPath: "/recordings/rec_reserved.m4a")
        cli.setRows([row("u1", "claimed"), row("u2", "claimed")])
        let queue = makeQueue()
        XCTAssertTrue(queue.bookkeepingLost)
        queue.rescan()
        await queue.idle()
        XCTAssertTrue(ingested.isEmpty)
        XCTAssertTrue(hub.sent(HubControlRequest.recordingClaim).isEmpty)
        XCTAssertEqual(queue.tracked["u1"]?.path, "/recordings/rec_reserved.m4a")
        XCTAssertNil(queue.tracked["u2"])
        XCTAssertTrue(queue.bookkeepingLost, "u2 is still undecided")
        XCTAssertTrue(hubHas("u2"))
    }

    func testALookupErrorDefersTheCrashedUpload() async throws {
        try writeAudio("u1")
        defaults.set(try JSONEncoder().encode(["u1": PhoneRecordingQueue.Tracked(stage: .ingesting, hubAudio: hub.audio("u1").path)]),
                     forKey: PhoneRecordingQueue.defaultsKey)
        transcriber.lookupError = CalendarDown()
        cli.setRows([row("u1", "claimed")])
        let queue = makeQueue()
        queue.rescan()
        await queue.idle()
        XCTAssertTrue(ingested.isEmpty)
        XCTAssertEqual(queue.tracked["u1"]?.stage, .ingesting)
    }

    // MARK: - What it leaves alone

    func testAnUnreadyOrEmptyListingKeepsTheBookkeeping() async throws {
        try writeAudio("u1")
        let queue = makeQueue()
        queue.recordingQueued("u1")
        await queue.idle()
        cli.setRows([], ready: false)
        queue.rescan()
        await queue.idle()
        XCTAssertNotNil(queue.tracked["u1"], "not ready: skipped")
        cli.setRows([])
        queue.rescan()
        await queue.idle()
        XCTAssertNotNil(queue.tracked["u1"], "an empty answer erases nothing")
        cli.setRows([row("u9", "queued")])
        queue.rescan()
        await queue.idle()
        XCTAssertNil(queue.tracked["u1"], "a job the hub no longer lists, while it lists others, goes")
    }

    func testAHubMovedJobIsNeverClaimed() async throws {
        try writeAudio("moved")
        cli.setRows([row("moved", "failed", errorClass: "hub_moved")])
        let queue = makeQueue()
        queue.rescan()
        await queue.idle()
        XCTAssertTrue(hub.sent(HubControlRequest.recordingClaim).isEmpty, "a hub_moved row is never claimed from the list")

        // An event for it is refused by the hub: nothing ingested, nothing reported.
        hub.refuseClaims(["moved"])
        queue.recordingQueued("moved")
        await queue.idle()
        XCTAssertTrue(ingested.isEmpty)
        XCTAssertTrue(hub.sent(HubControlRequest.recordingFinish).isEmpty)
        XCTAssertTrue(hub.sent(HubControlRequest.recordingProgress).isEmpty)
        XCTAssertTrue(hubHas("moved"), "its kept audio is the hub's")

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
        XCTAssertTrue(hubHas("u1"))
    }

    // MARK: - Origin

    /// The phone's title comes back from its origin, as the Swift hub's
    /// `title_hint` path ended: a meeting on this Mac links the transcript
    /// and takes the event's title; a meeting this Mac lacks saves ad-hoc
    /// (the Swift hub dropped the event too, but kept the phone's title —
    /// the one gap, the title is never stored); no event is the phone's
    /// voice note, titled by its start.
    func testTheEventLinkAndTitleComeBackFromTheOrigin() async throws {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        calendar = ["evt-1": "Acme sync"]
        for id in ["meeting", "elsewhere", "note", "bare"] { try writeAudio(id) }
        hub.setOrigin("meeting", eventID: "evt-1", startedAt: started)
        hub.setOrigin("elsewhere", eventID: "evt-gone", startedAt: started)
        hub.setOrigin("note", eventID: nil, startedAt: started)
        let queue = makeQueue()
        for id in ["meeting", "elsewhere", "note", "bare"] { queue.recordingQueued(id) }
        await queue.idle()
        XCTAssertEqual(origins, [
            Origin(eventID: "evt-1", title: "Acme sync"),
            Origin(eventID: nil, title: nil),
            Origin(eventID: nil, title: PhoneRecordingQueue.voiceNoteTitle(started)),
            Origin(eventID: nil, title: nil)
        ])
    }

    /// The phone's voice-note title (`PhoneRecorderController.finalTitleAndEvent`), byte for byte.
    func testVoiceNoteTitlePinned() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(PhoneRecordingQueue.voiceNoteTitle(Date(timeIntervalSince1970: 1_800_000_000), timeZone: utc),
                       "Voice note — 15 Jan, 08:00")
    }

    // MARK: - Pinned

    /// The classes are the Go side's (`state.ClassNoSpeech` …), whose phone
    /// texts Go pins in `TestRecordingFailureTextsPinned`.
    func testFailureClassesPinned() {
        XCTAssertEqual(PhoneRecordingQueue.FailureClass.allCases.map(\.rawValue), [
            "no_speech", "transcription_failed", "not_audio", "unreadable", "ingest_failed", "missing_audio"
        ])
        XCTAssertEqual(PhoneRecordingQueue.FailureClass.allCases.filter(\.retried), [.unreadable, .ingestFailed])
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
            #"{"ok":true,"upload_id":"u1","status":"claimed","audio_path":"/tmp/u1.m4a","event_id":"evt-1","started_at":1800000000.5}"#
                .utf8))
        XCTAssertEqual(answer.audioPath, "/tmp/u1.m4a")
        XCTAssertEqual(answer.status, "claimed")
        XCTAssertEqual(answer.eventID, "evt-1")
        XCTAssertEqual(answer.startedAt, Date(timeIntervalSince1970: 1_800_000_000.5))
    }
}

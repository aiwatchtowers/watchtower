import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerSync
import WatchtowerTestSupport

/// The `recording_job` slice (mobile POC spec §4.12) and the tracker that
/// feeds it from the transcriber's job callbacks (§6.4 step 4): progress,
/// failure, retention and the cap, the Kit wire shape, and the transcript
/// link the `meeting_transcript` slice reads.
@MainActor
final class RecordingJobSliceTests: XCTestCase {
    private var sidecar: HubSyncState!
    private var dbPool: DatabasePool!
    private var dbPath: String!
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recording-job-\(UUID().uuidString)", isDirectory: true)
    private let nudges = NudgeLog()
    private let clock = TestClock(Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
    private let day: TimeInterval = 86_400

    override func setUp() async throws {
        sidecar = try HubSyncState.inMemory()
        (dbPool, dbPath) = try TestDatabase.createPool()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        sidecar = nil
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
    }

    private func makeJobs(events: (any PhoneRecordingJobEvents)? = nil) throws -> PhoneRecordingJobs {
        let dir = self.dir
        let jobs = try PhoneRecordingJobs(
            sidecar: sidecar, dbPool: dbPool, events: events, now: { [clock] in clock.now },
            // The ingested file's name, as the transcriber would report it.
            enqueue: { _, _, _ in dir.appendingPathComponent("rec_\(UUID().uuidString).m4a") }
        )
        jobs.setOnChange { [nudges] in nudges.append($0) }
        return jobs
    }

    private func upload(_ id: String = "R1") -> RecordingUploadPayload {
        RecordingUploadPayload(
            id: id, startedAt: clock.now.addingTimeInterval(-60), endedAt: clock.now, durationSec: 60,
            sampleFormat: "aac-64k-mono", deviceID: "device-a"
        )
    }

    /// Ingests `id` and returns the audio URL its job reports under.
    private func ingest(_ jobs: PhoneRecordingJobs, _ id: String = "R1") async throws -> URL {
        try await jobs.ingest(upload(id), audio: dir.appendingPathComponent("phone.m4a"))
        let job = try XCTUnwrap(try sidecar.phoneRecordings().first { $0.uploadID == id })
        return URL(fileURLWithPath: job.audioPath)
    }

    private func records() throws -> [SliceRecord] {
        let slice = RecordingJobSlice(sidecar: sidecar) { [clock] in clock.now }
        return try dbPool.read { try slice.records($0) }
    }

    private func payload(_ id: String = "R1") throws -> [String: Any] {
        let record = try XCTUnwrap(try records().first { $0.id == id }, "no recording_job-\(id)")
        XCTAssertEqual(record.kind, .recordingJob)
        XCTAssertEqual(record.recordName, "recording_job-\(id)")
        return try SliceJSON.object(record.payload)
    }

    private func seed(_ id: String, status: HubSyncState.PhoneRecordingJob.Status, updatedAt: Date) throws {
        try sidecar.savePhoneRecording(.init(
            uploadID: id, audioPath: "/recordings/rec_\(id).m4a", status: status, percent: nil,
            transcriptID: status == .done ? 1 : nil, error: nil, updatedAt: updatedAt
        ))
    }

    // MARK: - Progress

    func testProgressReportsQueuedThenTranscribing25ThenDoneWithTheTranscriptID() async throws {
        let jobs = try makeJobs()
        let audio = try await ingest(jobs)

        XCTAssertEqual(try payload()["status"] as? String, "queued")
        XCTAssertNil(try payload()["percent"])

        clock.advance(5)
        jobs.phaseChanged(audioURL: audio, phase: .transcribing(done: 3, total: 12))
        var job = try payload()
        XCTAssertEqual(job["status"] as? String, "transcribing")
        XCTAssertEqual(job["percent"] as? Int, 25)
        XCTAssertEqual(job["updated_at"] as? Int, Int(clock.now.timeIntervalSince1970))

        jobs.phaseChanged(audioURL: audio, phase: .diarizing)
        XCTAssertEqual(try payload()["status"] as? String, "diarizing")
        XCTAssertNil(try payload()["percent"], "percent only while transcribing")
        jobs.phaseChanged(audioURL: audio, phase: .summarizing)
        XCTAssertEqual(try payload()["status"] as? String, "summarizing")

        jobs.finished(audioURL: audio, transcriptID: 7)
        job = try payload()
        XCTAssertEqual(job["status"] as? String, "done")
        XCTAssertEqual(job["transcript_id"] as? Int, 7)
        XCTAssertNil(job["error"])
        XCTAssertEqual(jobs.uploadID(forTranscript: 7), "R1", "the meeting_transcript slice's phone_recording_id")
        XCTAssertNil(jobs.uploadID(forTranscript: 8))

        XCTAssertTrue(nudges.all.allSatisfy { $0.contains(.recordingJob) }, "every change takes the fast lane")
        XCTAssertEqual(nudges.all.last, [.recordingJob, .meetingTranscript], "a finished job also links its transcript")
    }

    func testFirstPhaseBeforeAnyWindowIsZeroPercent() async throws {
        let jobs = try makeJobs()
        let audio = try await ingest(jobs)

        jobs.phaseChanged(audioURL: audio, phase: .transcribing(done: 0, total: 0))

        XCTAssertEqual(try payload()["percent"] as? Int, 0)
    }

    func testAnUnchangedPhaseWritesNothing() async throws {
        let jobs = try makeJobs()
        let audio = try await ingest(jobs)
        jobs.phaseChanged(audioURL: audio, phase: .transcribing(done: 3, total: 12))
        let count = nudges.all.count

        // The same window again, then another window of the same percent.
        jobs.phaseChanged(audioURL: audio, phase: .transcribing(done: 3, total: 12))
        jobs.phaseChanged(audioURL: audio, phase: .transcribing(done: 6, total: 24))

        XCTAssertEqual(nudges.all.count, count)
    }

    func testPhasesOfAMacRecordingAreIgnored() async throws {
        let jobs = try makeJobs()

        jobs.phaseChanged(audioURL: dir.appendingPathComponent("rec_desk.caf"), phase: .transcribing(done: 1, total: 2))
        jobs.finished(audioURL: dir.appendingPathComponent("rec_desk.caf"), transcriptID: 3)

        XCTAssertTrue(try records().isEmpty)
        XCTAssertNil(jobs.uploadID(forTranscript: 3))
        XCTAssertTrue(nudges.all.isEmpty)
    }

    func testAPhaseAfterDoneIsIgnored() async throws {
        let jobs = try makeJobs()
        let audio = try await ingest(jobs)
        jobs.finished(audioURL: audio, transcriptID: 7)

        jobs.phaseChanged(audioURL: audio, phase: .failed("late"))

        XCTAssertEqual(try payload()["status"] as? String, "done")
    }

    // MARK: - Failure

    func testAFailedJobPublishesFailedWithTheErrorCutTo300() async throws {
        let jobs = try makeJobs()
        let audio = try await ingest(jobs)

        jobs.phaseChanged(audioURL: audio, phase: .failed(String(repeating: "e", count: 400)))

        let job = try payload()
        XCTAssertEqual(job["status"] as? String, "failed")
        let error = try XCTUnwrap(job["error"] as? String)
        XCTAssertEqual(error.count, 300)
        XCTAssertTrue(error.hasSuffix("…"))
        XCTAssertNil(job["percent"])
    }

    func testAFailedJobRetriedOnTheMacGoesBackToQueued() async throws {
        let jobs = try makeJobs()
        let audio = try await ingest(jobs)
        jobs.phaseChanged(audioURL: audio, phase: .failed("No speech recognized"))

        jobs.phaseChanged(audioURL: audio, phase: .queued)

        let job = try payload()
        XCTAssertEqual(job["status"] as? String, "queued")
        XCTAssertNil(job["error"])
    }

    // MARK: - Retention and cap

    func testARecordSevenDaysAndOneSecondAfterDoneIsDeleted() throws {
        try seed("old-done", status: .done, updatedAt: clock.now.addingTimeInterval(-7 * day - 1))
        try seed("old-failed", status: .failed, updatedAt: clock.now.addingTimeInterval(-7 * day - 1))
        try seed("edge-done", status: .done, updatedAt: clock.now.addingTimeInterval(-7 * day))
        try seed("old-queued", status: .queued, updatedAt: clock.now.addingTimeInterval(-8 * day))

        XCTAssertEqual(
            Set(try records().map(\.id)), ["edge-done", "old-queued"],
            "kept 7 days after done/failed; an unfinished job stays"
        )
    }

    func testAtMost100JobsTheNewestFirst() throws {
        for index in 0...100 {
            try seed("R\(index)", status: .queued, updatedAt: clock.now.addingTimeInterval(TimeInterval(index)))
        }

        let ids = try records().map(\.id)

        XCTAssertEqual(ids.count, 100, "101 jobs → 100")
        XCTAssertFalse(ids.contains("R0"), "the oldest is left out")
        XCTAssertEqual(ids.first, "R100")
    }

    func testTheSidecarForgetsARecordingAfter31Days() throws {
        try seed("ancient", status: .done, updatedAt: clock.now.addingTimeInterval(-31 * day - 1))
        try seed("month", status: .done, updatedAt: clock.now.addingTimeInterval(-30 * day))

        _ = try records()

        XCTAssertEqual(try sidecar.phoneRecordings().map(\.uploadID), ["month"], "the transcript link outlives the job record")
    }

    // MARK: - Wire shape

    /// The hub payload has the Kit literal's keys and literal types.
    private func assertMatchesKit(_ test: String, _ payload: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        let fixture = try SliceJSON.object(
            try SliceJSON.kitInlineFixture("WatchtowerKitTests/CalendarMirrorFixtureTests.swift", test: test)
        )
        XCTAssertEqual(Set(payload.keys), Set(fixture.keys), test, file: file, line: line)
        for (key, value) in fixture {
            XCTAssertEqual(SliceJSON.literalKind(payload[key] as Any), SliceJSON.literalKind(value), "\(test).\(key)", file: file, line: line)
        }
    }

    func testPayloadsMatchTheKitFixtures() async throws {
        let jobs = try makeJobs()
        let audio = try await ingest(jobs)
        jobs.phaseChanged(audioURL: audio, phase: .transcribing(done: 3, total: 12))
        try assertMatchesKit("testRecordingJobTranscribingFixture", try payload())

        jobs.finished(audioURL: audio, transcriptID: 7)
        try assertMatchesKit("testRecordingJobDoneFixture", try payload())

        let failed = try await ingest(jobs, "R2")
        jobs.phaseChanged(audioURL: failed, phase: .failed("Transcription failed"))
        try assertMatchesKit("testRecordingJobFailedFixture", try payload("R2"))
    }

    // MARK: - Lifecycle

    func testARebuiltTrackerKeepsFollowingTheJobsItRemembers() async throws {
        let audio = try await ingest(try makeJobs())

        let rebuilt = try makeJobs()
        rebuilt.phaseChanged(audioURL: audio, phase: .transcribing(done: 6, total: 12))
        XCTAssertEqual(try payload()["percent"] as? Int, 50)
        rebuilt.finished(audioURL: audio, transcriptID: 9)

        XCTAssertEqual(try makeJobs().uploadID(forTranscript: 9), "R1", "the link survives a relaunch")
    }

    func testStartChainsTheRecorderCallbacksAndStopRestoresThem() async throws {
        let events = FakeJobEvents()
        var earlier: [String] = []
        events.onJobPhase = { url, _ in earlier.append("phase \(url.lastPathComponent)") }
        events.onJobFinished = { url, _ in earlier.append("finished \(url.lastPathComponent)") }
        let jobs = try makeJobs(events: events)
        let audio = try await ingest(jobs)

        jobs.start()
        events.onJobPhase?(audio, .transcribing(done: 3, total: 12))
        events.onJobFinished?(audio, 7)

        XCTAssertEqual(earlier, ["phase \(audio.lastPathComponent)", "finished \(audio.lastPathComponent)"], "the earlier closures still run")
        XCTAssertEqual(try payload()["status"] as? String, "done")

        jobs.stop()
        earlier = []
        events.onJobPhase?(audio, .failed("x"))
        XCTAssertEqual(earlier, ["phase \(audio.lastPathComponent)"], "stop hands the recorder back its own closure")
        XCTAssertEqual(try payload()["status"] as? String, "done")
    }
}

/// The recorder's job callbacks, as a test drives them.
@MainActor
private final class FakeJobEvents: PhoneRecordingJobEvents {
    var onJobPhase: ((_ audioURL: URL, _ phase: MeetingRecorderCenter.ProcessingJob.Phase) -> Void)?
    var onJobFinished: ((_ audioURL: URL, _ transcriptID: Int64) -> Void)?
}

/// Every fast-lane nudge the tracker sent.
private final class NudgeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Set<SliceKind>] = []

    var all: [Set<SliceKind>] { lock.withLock { log } }

    func append(_ kinds: Set<SliceKind>) {
        lock.withLock { log.append(kinds) }
    }
}

/// A settable wall clock.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

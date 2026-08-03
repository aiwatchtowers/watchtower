import Foundation
import XCTest
@testable import WatchtowerDesktop

/// The capture/post-processing decoupling: the FIFO job queue, the
/// engine-slot handoff to a waiting live pass, and the crash-recovery
/// sidecars. Split from `MeetingRecorderCenterTests` (fixtures in
/// `MeetingRecorderTestCase`) to keep both files within the lint budget.
@MainActor
final class MeetingRecorderQueueTests: MeetingRecorderTestCase {

    // MARK: - Processing queue (capture decoupled from post-processing)

    /// The back-to-back-meetings case: the next meeting starts capturing while
    /// the previous recording is still being transcribed. Its live pass waits
    /// for the engine slot the running job holds — one engine, ever — and loads
    /// only once that job is done.
    func testRecordingStartsWhileJobTranscribesAndLivePassWaitsForTheSlot() async throws {
        let audio1 = try makeDummyAudioFile()
        let audio2 = try makeDummyAudioFile()
        defer {
            for audio in [audio1, audio2] {
                try? FileManager.default.removeItem(at: audio)
                removeSidecars(audio)
            }
        }

        let recorder1 = FakeRecorder()
        recorder1.stopResult = RecordingResult(audioURL: audio1, durationSec: 1)
        let recorder2 = FakeRecorder()
        recorder2.stopResult = RecordingResult(audioURL: audio2, durationSec: 1)
        let gate = GateEngine(texts: ["job one"])
        var recorderCalls = 0
        var engineLoads = 0
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(engineLoads == 1 ? gate : ScriptedEngine(texts: ["job two"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = singleWindowConfig()

        await center.startRecording(eventID: nil, title: "First", config: config)
        let stopFirst = Task { await center.stopAndProcess(config: config) }
        // Job 1 is now parked inside the gated engine.
        var entered = gate.enteredStream.makeAsyncIterator()
        _ = await entered.next()
        XCTAssertEqual(engineLoads, 1, "the live pass's engine is handed to the batch fallback, not reloaded")

        await center.startRecording(eventID: "evt-2", title: "Second", config: config)

        guard case .recording = center.captureState else {
            return XCTFail("a new recording must start while a job is transcribing, got \(center.captureState)")
        }
        XCTAssertEqual(center.liveEngineState, .waiting,
                       "the live pass must wait for the engine slot the running job holds")
        XCTAssertEqual(engineLoads, 1, "no second engine may load while the job owns the slot")
        XCTAssertEqual(center.jobs.count, 1)
        XCTAssertEqual(center.jobs.first?.phase, .transcribing(done: 0, total: 0),
                       "the running job is untouched by the new recording")

        gate.release()
        await stopFirst.value
        XCTAssertTrue(center.jobs.isEmpty, "job 1 saved and left the queue")
        XCTAssertEqual(runner.invocations.count, 1)

        // The waiting live pass gets the slot now — and only now.
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(engineLoads, 2, "the waiting live pass loads its engine after the job finished")
        XCTAssertNotEqual(center.liveEngineState, .waiting)

        // Hygiene: drive recording 2 to completion so no task is left dangling.
        await center.stopAndProcess(config: config)
        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertEqual(center.phase, .idle)
    }

    /// Two stopped recordings queue FIFO behind one another and both save, in
    /// the order they were stopped — the queue is serial, never concurrent.
    func testSecondStopQueuesBehindTheRunningJobAndBothSave() async throws {
        let audio1 = try makeDummyAudioFile()
        let audio2 = try makeDummyAudioFile()
        defer {
            for audio in [audio1, audio2] {
                try? FileManager.default.removeItem(at: audio)
                removeSidecars(audio)
            }
        }

        let recorder1 = FakeRecorder()
        recorder1.stopResult = RecordingResult(audioURL: audio1, durationSec: 1)
        let recorder2 = FakeRecorder()
        recorder2.stopResult = RecordingResult(audioURL: audio2, durationSec: 1)
        let gate = GateEngine(texts: ["job one"])
        var recorderCalls = 0
        var engineLoads = 0
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(engineLoads == 1 ? gate : ScriptedEngine(texts: ["job two"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = singleWindowConfig()

        await center.startRecording(eventID: nil, title: "First", config: config)
        let stopFirst = Task { await center.stopAndProcess(config: config) }
        var entered = gate.enteredStream.makeAsyncIterator()
        _ = await entered.next()

        await center.startRecording(eventID: nil, title: "Second", config: config)
        let stopSecond = Task { await center.stopAndProcess(config: config) }
        for _ in 0..<12 { await Task.yield() }

        XCTAssertEqual(center.jobs.map(\.audioURL), [audio1, audio2], "the queue is FIFO")
        XCTAssertEqual(center.jobs.last?.phase, .queued,
                       "the second job waits — exactly one job processes at a time")

        gate.release()
        await stopFirst.value
        await stopSecond.value

        XCTAssertEqual(runner.savedTranscripts, ["job one", "job two"],
                       "both recordings save, in the order they were stopped")
        XCTAssertTrue(center.jobs.isEmpty)
        XCTAssertEqual(center.phase, .idle)
    }

    /// A failed job stays in the queue for retry without blocking anything: the
    /// job behind it still runs, a new recording still starts, and retrying
    /// re-enqueues the failed one.
    func testFailedJobBlocksNeitherTheQueueNorNewRecordings() async throws {
        let audio1 = try makeDummyAudioFile()
        let audio2 = try makeDummyAudioFile()
        defer {
            for audio in [audio1, audio2] {
                try? FileManager.default.removeItem(at: audio)
                removeSidecars(audio)
            }
        }

        let recorder1 = FakeRecorder()
        recorder1.stopResult = RecordingResult(audioURL: audio1, durationSec: 1)
        let recorder2 = FakeRecorder()
        recorder2.stopResult = RecordingResult(audioURL: audio2, durationSec: 1)
        var recorderCalls = 0
        var engineLoads = 0
        // Recording 1's decode fails once, so its job lands `.failed` with the
        // audio kept; the retry below decodes fine.
        var failFirstDecode = true
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: [engineLoads == 2 ? "job two" : "job one"]))
            },
            decode: { url in
                if url == audio1, failFirstDecode { throw AudioFileDecoderError.unsupportedFormat }
                return [Float](repeating: 0, count: 1600)
            },
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = singleWindowConfig()

        await center.startRecording(eventID: nil, title: "First", config: config)
        await center.stopAndProcess(config: config)

        XCTAssertEqual(center.jobs.count, 1)
        XCTAssertTrue(try XCTUnwrap(center.jobs.first).phase.isFailed)
        XCTAssertEqual(center.pendingAudioURL, audio1, "the audio must be kept for retry")
        XCTAssertFalse(center.isCapturing, "a failed job must never gate the next recording")

        // A whole second recording runs to completion past the failed job.
        await center.startRecording(eventID: nil, title: "Second", config: config)
        await center.stopAndProcess(config: config)

        XCTAssertEqual(runner.savedTranscripts, ["job two"],
                       "the queue advanced past the failure")
        XCTAssertEqual(center.jobs.map(\.audioURL), [audio1],
                       "only the failed job is left, still visible for retry")

        // Retry re-enqueues the SAME job.
        failFirstDecode = false
        await center.retryTranscription(config: config)

        XCTAssertEqual(runner.savedTranscripts, ["job two", "job one"])
        XCTAssertTrue(center.jobs.isEmpty)
        XCTAssertEqual(center.phase, .idle)
        XCTAssertNil(center.pendingAudioURL)
    }

    /// The tightest window the decoupling opens: recording 2 is started AND
    /// stopped while recording 1's live pass is still draining its tail. The
    /// second recording never had a live pass of its own, so it must not consume
    /// the first one's output (or its engine) — it goes through the batch path,
    /// and the live text lands on the recording that produced it.
    func testRecordingStoppedWhileWaitingNeverConsumesThePriorLiveTail() async throws {
        let audio1 = try makeDummyAudioFile()
        let audio2 = try makeDummyAudioFile()
        defer {
            for audio in [audio1, audio2] {
                try? FileManager.default.removeItem(at: audio)
                removeSidecars(audio)
            }
        }

        let recorder1 = FakeRecorder()
        recorder1.stopResult = RecordingResult(audioURL: audio1, durationSec: 1)
        let recorder2 = FakeRecorder()
        recorder2.stopResult = RecordingResult(audioURL: audio2, durationSec: 1)
        // Gating the LIVE engine parks recording 1's tail mid-window.
        let gate = GateEngine(texts: ["live one"])
        var recorderCalls = 0
        var engineLoads = 0
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(engineLoads == 1 ? gate : ScriptedEngine(texts: ["batch two"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = threeWindowConfig() // 0.1 s windows → 1600 samples per window

        await center.startRecording(eventID: nil, title: "First", config: config)
        recorder1.emitLive([Float](repeating: 0, count: 1600)) // exactly one window
        let stopFirst = Task { await center.stopAndProcess(config: config) }
        var entered = gate.enteredStream.makeAsyncIterator()
        _ = await entered.next() // recording 1's live pass is parked in the engine
        for _ in 0..<12 { await Task.yield() }

        await center.startRecording(eventID: nil, title: "Second", config: config)
        XCTAssertEqual(center.liveEngineState, .waiting,
                       "the draining tail still owns the engine slot")
        XCTAssertEqual(engineLoads, 1)

        let stopSecond = Task { await center.stopAndProcess(config: config) }
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(center.jobs.map(\.audioURL), [audio1, audio2], "queue order is stop order")

        gate.release()
        await stopFirst.value
        await stopSecond.value

        XCTAssertEqual(runner.savedTranscripts, ["live one", "batch two"],
                       "the live text belongs to the recording that produced it; "
                       + "the second recording is transcribed from its own file")
        XCTAssertEqual(engineLoads, 2, "the second recording's job loads its own engine")
        XCTAssertTrue(center.jobs.isEmpty)
    }

    // MARK: - Crash-recovery sidecars

    /// `rec_X.meta` is the per-recording replacement for the single-slot
    /// `UserDefaults` pointer: written before capture starts, removed once the
    /// transcript is saved (so "sidecar present" == "never saved").
    func testMetaSidecarWrittenAtStartAndRemovedAfterSave() async throws {
        let recorder = FakeRecorder()
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["hello"])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        await center.startRecording(eventID: "evt-1", title: "Weekly", config: singleWindowConfig())

        let started = try XCTUnwrap(recorder.lastStartURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metaSidecar(started).path),
                      "the recovery sidecar must exist from record start, before any audio is finalized")

        // Production's recorder finalizes the very file it was started on.
        recorder.stopResult = RecordingResult(audioURL: started, durationSec: 1)
        defer { removeSidecars(started) }
        await center.stopAndProcess(config: singleWindowConfig())

        XCTAssertEqual(center.phase, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metaSidecar(started).path),
                       "a saved transcript must remove the recovery sidecar")
    }

    /// Recovery generalizes to N recordings: every `rec_*.caf` that still has a
    /// `.meta` sidecar comes back (oldest first, event link intact), while one
    /// whose sidecar is gone — i.e. already saved — is left alone.
    func testRecoveryScanFindsEveryOrphanedRecording() async throws {
        let older = recordingsDir.appendingPathComponent("rec_20260803_100000.caf")
        let newer = recordingsDir.appendingPathComponent("rec_20260803_120000.caf")
        let saved = recordingsDir.appendingPathComponent("rec_20260803_110000.caf")
        for audio in [older, newer, saved] {
            try Data([0x00]).write(to: audio)
        }
        try #"{"eventID":"evt-older","title":"Older"}"#
            .write(to: metaSidecar(older), atomically: true, encoding: .utf8)
        try #"{"title":"Newer ad-hoc"}"#
            .write(to: metaSidecar(newer), atomically: true, encoding: .utf8)

        let center = MeetingRecorderCenter(
            recorderFactory: { FakeRecorder() },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: [])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { nil },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        center.restorePendingOnLaunch()

        XCTAssertEqual(center.recoverable.map(\.audioURL), [older, newer],
                       "every unsaved recording is recovered, oldest first; a sidecar-less one is not")
        XCTAssertEqual(center.recoverable.map(\.eventID), ["evt-older", nil])
        XCTAssertEqual(center.recoverable.map(\.title), ["Older", "Newer ad-hoc"])
        // The legacy pill acts on the oldest, so its event link is the current one.
        XCTAssertEqual(center.currentEventID, "evt-older")
        XCTAssertEqual(center.pendingAudioURL, older)
    }

    /// A recording captured by a pre-queue build lives in three `UserDefaults`
    /// keys. They are read once, converted to a recoverable recording, and
    /// cleared — so a second launch neither re-reads nor duplicates them.
    func testLegacyPendingDefaultsMigrateOnceAndAreCleared() async throws {
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        let defaults = try isolatedDefaults()
        defaults.set(audio.path, forKey: MeetingRecorderCenter.pendingAudioPathKey)
        defaults.set("evt-legacy", forKey: MeetingRecorderCenter.pendingEventIDKey)
        defaults.set("Legacy build", forKey: MeetingRecorderCenter.pendingTitleKey)
        let center = MeetingRecorderCenter(
            recorderFactory: { FakeRecorder() },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: [])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { nil },
            notifier: FakeNotifier(),
            defaults: defaults,
            recordingsDirectory: recordingsDir
        )

        center.restorePendingOnLaunch()

        XCTAssertEqual(center.recoverable.map(\.audioURL), [audio])
        XCTAssertEqual(center.recoverable.first?.eventID, "evt-legacy")
        XCTAssertEqual(center.recoverable.first?.title, "Legacy build")
        for key in [MeetingRecorderCenter.pendingAudioPathKey,
                    MeetingRecorderCenter.pendingEventIDKey,
                    MeetingRecorderCenter.pendingTitleKey] {
            XCTAssertNil(defaults.string(forKey: key), "\(key) must be cleared by the one-shot migration")
        }

        // A second launch of the same Center must not re-add or duplicate it.
        center.restorePendingOnLaunch()
        XCTAssertEqual(center.recoverable.map(\.audioURL), [audio])
    }
}

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
        // Job 1 saves AFTER recording 2 started, so a save reading the Center's
        // single-slot `currentEventID`/`currentTitle` would file the first
        // meeting's transcript under the second meeting's event.
        let firstSave = try XCTUnwrap(runner.invocations.first)
        XCTAssertNil(savedFlag(firstSave, "--event-id"),
                     "the ad-hoc first recording must save unlinked, not under recording 2's event")
        XCTAssertEqual(savedFlag(firstSave, "--title"), "First")

        // The waiting live pass gets the slot now — and only now.
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(engineLoads, 2, "the waiting live pass loads its engine after the job finished")
        XCTAssertNotEqual(center.liveEngineState, .waiting)

        // Hygiene: drive recording 2 to completion so no task is left dangling.
        await center.stopAndProcess(config: config)
        XCTAssertEqual(runner.invocations.count, 2)
        let secondSave = try XCTUnwrap(runner.invocations.last)
        XCTAssertEqual(savedFlag(secondSave, "--event-id"), "evt-2",
                       "each job carries its own event link")
        XCTAssertEqual(savedFlag(secondSave, "--title"), "Second")
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

        await center.startRecording(eventID: "evt-2", title: "Second", config: config)
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
        // Both jobs sat in the queue together, so each must carry its OWN event
        // link and title — never the Center's last-writer pair.
        XCTAssertEqual(runner.invocations.map { savedFlag($0, "--event-id") }, [nil, "evt-2"])
        XCTAssertEqual(runner.invocations.map { savedFlag($0, "--title") }, ["First", "Second"])
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
        // The legacy pill acts on the oldest.
        XCTAssertEqual(center.pendingAudioURL, older)
    }

    /// Two recordings started inside the same second differ only by the `-N`
    /// collision suffix, and `-` sorts before `.` — so plain lexicographic order
    /// hands the pill the NEWEST of them, and `-10` before `-2`. The pill acts on
    /// `recoverable.first`, so the order is the behavior.
    func testRecoveryScanOrdersSameSecondRecordingsOldestFirst() throws {
        let first = recordingsDir.appendingPathComponent("rec_20260803_100000.caf")
        let second = recordingsDir.appendingPathComponent("rec_20260803_100000-2.caf")
        let tenth = recordingsDir.appendingPathComponent("rec_20260803_100000-10.caf")
        let nextSecond = recordingsDir.appendingPathComponent("rec_20260803_100001.caf")
        for audio in [first, second, tenth, nextSecond] {
            try Data([0x00]).write(to: audio)
            try Data("{}".utf8).write(to: metaSidecar(audio))
        }

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

        XCTAssertEqual(center.recoverable.map(\.audioURL), [first, second, tenth, nextSecond],
                       "the suffix orders numerically, after the timestamp")
        XCTAssertEqual(center.pendingAudioURL, first, "the pill acts on the oldest recording")
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

    /// A `.meta` that is present but corrupt still proves the recording was
    /// never saved (the save removes the sidecar), so it must come back — just
    /// without the event link it can no longer supply. Skipping it would strand
    /// the audio behind an orphan sweep instead of offering it to the user.
    func testCorruptMetaSidecarStillRecoversTheRecording() async throws {
        let audio = recordingsDir.appendingPathComponent("rec_20260803_100000.caf")
        try Data([0x00]).write(to: audio)
        try Data("not json{".utf8).write(to: metaSidecar(audio))

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

        XCTAssertEqual(center.recoverable.map(\.audioURL), [audio],
                       "an unreadable sidecar must not lose the recording")
        XCTAssertNil(center.recoverable.first?.eventID, "the link it could not supply degrades to ad-hoc")
        XCTAssertNil(center.recoverable.first?.title)
    }

    // MARK: - Recording filenames

    /// `rec_<timestamp>` has one-second resolution, so two recordings started in
    /// the same second would share a path — the second overwriting the first's
    /// audio and stealing its recovery sidecar.
    func testCollidingRecordingFilenamesAreDisambiguated() throws {
        let date = Date()
        let first = MeetingRecorderCenter.uniqueRecordingURL(in: recordingsDir, date: date)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("rec_"),
                      "the Go orphan sweep matches on the rec_ family")
        XCTAssertEqual(first.pathExtension, "caf")

        try Data([0x00]).write(to: first)
        let second = MeetingRecorderCenter.uniqueRecordingURL(in: recordingsDir, date: date)
        XCTAssertNotEqual(second, first, "an existing recording's name must never be reused")
        XCTAssertTrue(second.lastPathComponent.hasPrefix("rec_"))

        // A leftover sidecar with no audio reserves its name too: it is the only
        // pointer a crashed recording has left.
        try Data("{}".utf8).write(to: metaSidecar(second))
        let third = MeetingRecorderCenter.uniqueRecordingURL(in: recordingsDir, date: date)
        XCTAssertEqual(Set([first, second, third]).count, 3,
                       "every candidate must be distinct, audio or sidecar")
    }

    /// End to end: two back-to-back recordings each keep their own audio path and
    /// their own recovery sidecar, event links intact.
    func testBackToBackRecordingsKeepSeparateFilesAndSidecars() async throws {
        let recorder1 = FakeRecorder()
        recorder1.stopError = AudioRecordingError.deviceSetupFailed("device vanished")
        let recorder2 = FakeRecorder()
        var recorderCalls = 0
        let center = MeetingRecorderCenter(
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: [])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { FakeCLIRunner(stdout: self.recapOKEnvelope) },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = singleWindowConfig()

        await center.startRecording(eventID: "evt-1", title: "First", config: config)
        // Stop fails, so recording 1's sidecar stays on disk — exactly the state
        // recording 2 must not overwrite.
        await center.stopAndProcess(config: config)
        await center.startRecording(eventID: "evt-2", title: "Second", config: config)

        let url1 = try XCTUnwrap(recorder1.lastStartURL)
        let url2 = try XCTUnwrap(recorder2.lastStartURL)
        XCTAssertNotEqual(url1, url2, "two recordings must never share an audio file")
        for url in [url1, url2] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: metaSidecar(url).path),
                          "\(url.lastPathComponent) must keep its own recovery sidecar")
        }
        let firstMeta = try String(contentsOf: metaSidecar(url1), encoding: .utf8)
        XCTAssertTrue(firstMeta.contains("evt-1"),
                      "recording 1's event link must survive recording 2's start, got \(firstMeta)")
    }

    // MARK: - Save notification (savedTick)

    /// The reload consumers key on `savedTick`, not on the recorder settling: a
    /// transcript that lands while a failed job lingers never sees `phase` reach
    /// `.idle`, so a `phase`-keyed reload would silently miss the new row.
    func testSavedTickBumpsWhileAFailedJobLingers() async throws {
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        var recorderCalls = 0
        var firstAudio: URL?
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["some talk"])) },
            decode: { url in
                if url == firstAudio { throw AudioFileDecoderError.unsupportedFormat }
                return [Float](repeating: 0, count: 1600)
            },
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = singleWindowConfig()

        await center.startRecording(eventID: nil, title: "First", config: config)
        firstAudio = try XCTUnwrap(recorder1.lastStartURL)
        recorder1.stopResult = RecordingResult(audioURL: try XCTUnwrap(firstAudio), durationSec: 1)
        await center.stopAndProcess(config: config)
        XCTAssertTrue(try XCTUnwrap(center.jobs.first).phase.isFailed)
        XCTAssertEqual(center.savedTick, 0, "nothing was persisted yet")

        await center.startRecording(eventID: nil, title: "Second", config: config)
        recorder2.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder2.lastStartURL), durationSec: 1)
        await center.stopAndProcess(config: config)

        XCTAssertEqual(center.savedTick, 1, "the second recording's transcript landed")
        XCTAssertEqual(runner.invocations.count, 1)
        guard case .failed = center.phase else {
            return XCTFail("the lingering failure still owns `phase` — this is the state a phase-keyed "
                           + "reload would never fire in, got \(center.phase)")
        }
    }

    // MARK: - Engine handover

    /// A failed job can sit in the queue indefinitely; it must not pin the whole
    /// transcription model the recording's live pass handed over.
    func testFailedLivePathJobReleasesItsEngine() async throws {
        let recorder = FakeRecorder()
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "db locked"))
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["live one"])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = threeWindowConfig()

        await center.startRecording(eventID: nil, title: "Live", config: config)
        recorder.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder.lastStartURL), durationSec: 1)
        recorder.emitLive([Float](repeating: 0, count: 1600)) // one window → a live result
        await center.stopAndProcess(config: config)

        let job = try XCTUnwrap(center.jobs.first)
        XCTAssertTrue(job.phase.isFailed, "the save failed, so the job stays for retry")
        XCTAssertNil(job.transcriber,
                     "the engine the live pass handed over must not be pinned by a parked failure")
    }

    /// The other release of the handed-over engine, on the one path that returns
    /// before `renderAndSave` reaches its own: the live pass produced nothing, so
    /// the batch pass reuses its engine and finds only silence. The engine must
    /// be released by the failure itself, not left pinned on a job that can sit
    /// in the queue indefinitely.
    func testEmptyTranscriptFailureReleasesTheLiveHandedEngine() async throws {
        let recorder = FakeRecorder()
        var engineLoads = 0
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let notifier = FakeNotifier()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: [])) // silence, every window
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: notifier,
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = singleWindowConfig()

        // No live samples emitted → no live output → the batch path runs with the
        // engine the live pass loaded and hands nothing but silence back.
        await center.startRecording(eventID: nil, title: "Silent", config: config)
        recorder.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder.lastStartURL), durationSec: 1)
        await center.stopAndProcess(config: config)

        let job = try XCTUnwrap(center.jobs.first)
        XCTAssertEqual(job.phase, .failed("No speech recognized"))
        XCTAssertNil(job.transcriber,
                     "an empty transcript must release the engine, not pin it on the parked failure")
        XCTAssertEqual(engineLoads, 1, "the batch pass reused the engine the live pass loaded")
        XCTAssertEqual(runner.savedTranscripts, [], "an empty transcript is never saved")
        XCTAssertEqual(notifier.failedReasons, ["No speech recognized"])
    }

    // MARK: - Failure dismissal

    /// `dismissFailure` clears a capture error before it ever reaches a job (they
    /// are different surfaces), and a dismissed job becomes a recoverable
    /// recording rather than disappearing — audio and sidecar both kept.
    func testDismissFailureClearsCaptureErrorBeforeAnyFailedJob() async throws {
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        recorder2.startError = AudioRecordingError.microphonePermissionDenied
        var recorderCalls = 0
        let center = MeetingRecorderCenter(
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["hello"])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "db locked")) },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = singleWindowConfig()

        await center.startRecording(eventID: "evt-1", title: "First", config: config)
        let started = try XCTUnwrap(recorder1.lastStartURL)
        try Data([0x00]).write(to: started) // production finalizes the file it started
        recorder1.stopResult = RecordingResult(audioURL: started, durationSec: 1)
        await center.stopAndProcess(config: config)
        XCTAssertEqual(center.jobs.count, 1, "the save failed → one failed job")

        await center.startRecording(eventID: nil, title: "Denied", config: config)
        XCTAssertNotNil(center.captureError)

        center.dismissFailure()
        XCTAssertNil(center.captureError, "the capture error is cleared first")
        XCTAssertEqual(center.jobs.count, 1, "the failed job must survive dismissing the capture error")
        XCTAssertTrue(center.recoverable.isEmpty)

        center.dismissFailure()
        XCTAssertTrue(center.jobs.isEmpty, "the second dismiss drops the failed job")
        XCTAssertEqual(center.recoverable.map(\.audioURL), [started],
                       "its audio stays retriable rather than disappearing")
        XCTAssertEqual(center.recoverable.first?.eventID, "evt-1", "with the event link intact")
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: metaSidecar(started).path),
                      "the recovery sidecar is kept — forgetting for good is dismissRecovered's job")
    }

    /// A save must never leave a failed job pointing at the SAME audio behind:
    /// retrying it would persist the very recording that just landed a second
    /// time.
    func testSuccessfulSaveDropsAFailedSiblingForTheSameAudio() async throws {
        let recorder = FakeRecorder()
        let failingRunner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "db locked"))
        let goodRunner = FakeCLIRunner(stdout: recapOKEnvelope)
        var activeRunner: CLIRunnerProtocol = failingRunner
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["one take"])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { activeRunner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = singleWindowConfig()

        await center.startRecording(eventID: "evt-1", title: "Dup", config: config)
        let started = try XCTUnwrap(recorder.lastStartURL)
        try Data([0x00]).write(to: started)
        recorder.stopResult = RecordingResult(audioURL: started, durationSec: 1)
        await center.stopAndProcess(config: config)
        XCTAssertTrue(try XCTUnwrap(center.jobs.first).phase.isFailed)

        // An explicit re-transcribe of the same file, this time saving fine.
        activeRunner = goodRunner
        center.prepareRetry(audioURL: started, eventID: "evt-1", title: "Dup")
        await center.retryTranscription(config: config)

        XCTAssertEqual(goodRunner.invocations.count, 1)
        XCTAssertTrue(center.jobs.isEmpty,
                      "the failed sibling for the same audio must go with the save, or its retry "
                      + "would persist a duplicate transcript")
        XCTAssertTrue(center.recoverable.isEmpty)
    }

    // MARK: - Retry/dismiss eligibility

    /// Both actions take the NEWEST failure — dismiss that one and the next
    /// becomes eligible in turn.
    func testNewestFailureIsTheOneRetryAndDismissActOn() async throws {
        let center = try makeAlwaysFailingCenter()
        try await failOneRecording(center, title: "Older")
        try await failOneRecording(center, title: "Newer")

        XCTAssertEqual(center.jobs.count, 2)
        let newest = try XCTUnwrap(center.jobs.last?.id)
        XCTAssertEqual(center.retriableFailureID, newest)
        XCTAssertEqual(center.dismissableFailureID, newest)

        center.dismissFailure()
        XCTAssertEqual(center.jobs.count, 1)
        XCTAssertEqual(center.dismissableFailureID, center.jobs.first?.id,
                       "the failure behind it becomes eligible in turn")
    }

    /// `retryTranscription` takes a recovered recording ahead of any job, so no
    /// failed pill may offer Retry while one is listed. Dismiss is unaffected —
    /// it never looks at `recoverable`.
    func testRecoveredRecordingOutranksAFailedJobForRetry() async throws {
        let center = try makeAlwaysFailingCenter()
        try await failOneRecording(center, title: "Failed")
        let recovered = recordingsDir.appendingPathComponent("rec_19700101_000000.caf")
        try Data([0x00]).write(to: recovered)

        center.prepareRetry(audioURL: recovered, eventID: nil, title: "Recovered")

        XCTAssertNil(center.retriableFailureID, "the recovered recording is what retry would act on")
        XCTAssertEqual(center.dismissableFailureID, center.jobs.first?.id,
                       "dismiss never consults `recoverable`")
    }

    /// `dismissFailure` clears a capture error first, so no failed pill may offer
    /// Dismiss while one stands. Retry is unaffected — it never looks at
    /// `captureError`.
    func testCaptureErrorOutranksAFailedJobForDismiss() async throws {
        let center = try makeAlwaysFailingCenter(startFailsAfter: 1)
        try await failOneRecording(center, title: "Failed")

        await center.startRecording(eventID: nil, title: "Denied", config: singleWindowConfig())
        XCTAssertNotNil(center.captureError)

        XCTAssertNil(center.dismissableFailureID, "the capture error is what dismiss would clear")
        XCTAssertEqual(center.retriableFailureID, center.jobs.first?.id,
                       "retry never consults `captureError`")
    }

    func testNothingIsRetriableOrDismissableWithoutAFailure() async throws {
        let center = try makeAlwaysFailingCenter()
        XCTAssertNil(center.retriableFailureID)
        XCTAssertNil(center.dismissableFailureID)
        XCTAssertFalse(center.isBusy)
    }

    /// A job parked on the engine slot has no `activeJobID` yet, but it WILL run
    /// with no further input — so the Center counts as busy and retry stays
    /// parked. Dismiss does not: it only drops a queue entry the user is looking
    /// at, and never touches the running pipeline.
    func testJobWaitingForTheEngineSlotStillCountsAsBusy() async throws {
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        var recorderCalls = 0
        var firstAudio: URL?
        let gate = GateEngine(texts: ["live two"])
        var engineLoads = 0
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(engineLoads == 1 ? ScriptedEngine(texts: []) : gate)
            },
            decode: { url in
                if url == firstAudio { throw AudioFileDecoderError.unsupportedFormat }
                return [Float](repeating: 0, count: 1600)
            },
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = threeWindowConfig()

        // A failed job to be (in)eligible, then a recording whose live pass is
        // parked mid-window so its job cannot claim the engine slot yet.
        await center.startRecording(eventID: nil, title: "Failed", config: config)
        firstAudio = try XCTUnwrap(recorder1.lastStartURL)
        recorder1.stopResult = RecordingResult(audioURL: try XCTUnwrap(firstAudio), durationSec: 1)
        await center.stopAndProcess(config: config)
        XCTAssertTrue(try XCTUnwrap(center.jobs.first).phase.isFailed)

        await center.startRecording(eventID: nil, title: "Second", config: config)
        recorder2.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder2.lastStartURL), durationSec: 1)
        recorder2.emitLive([Float](repeating: 0, count: 1600))
        let stopSecond = Task { await center.stopAndProcess(config: config) }
        var entered = gate.enteredStream.makeAsyncIterator()
        _ = await entered.next() // the live pass owns the engine; job 2 is parked

        // `phase` still reports the lingering failure, which is only possible
        // while NO job is running — job 2 is parked, not active.
        guard case .failed = center.phase else {
            return XCTFail("expected no running job, got \(center.phase)")
        }
        XCTAssertTrue(center.isBusy, "a job that will run without further input keeps the Center busy")
        XCTAssertNil(center.retriableFailureID, "retry must stay parked until the queue drains")
        XCTAssertEqual(center.dismissableFailureID, center.jobs.first?.id,
                       "dismiss only drops a queue entry, so it stays available")

        gate.release()
        await stopSecond.value
        XCTAssertEqual(runner.invocations.count, 1)
    }

    // MARK: - Engine-slot handoff

    /// A start that FAILS still has to hand the engine slot on: it claimed it
    /// synchronously (`isStarting`), and a job that parked on it in the meantime
    /// has nothing else to wake it. Regression = a permanently stuck queue.
    func testFailedStartWakesAJobParkedOnTheEngineSlot() async throws {
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        let startGate = OneShotGate()
        let recorder3 = GatedFailingRecorder(gate: startGate)
        let gate = GateEngine(texts: ["job one"])
        var recorderCalls = 0
        var engineLoads = 0
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: {
                recorderCalls += 1
                switch recorderCalls {
                case 1: return recorder1
                case 2: return recorder2
                default: return recorder3
                }
            },
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

        // Job 1 runs (no live output — nothing was emitted) and parks inside the
        // gated engine, holding the slot.
        await center.startRecording(eventID: nil, title: "First", config: config)
        recorder1.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder1.lastStartURL), durationSec: 1)
        let stopFirst = Task { await center.stopAndProcess(config: config) }
        var entered = gate.enteredStream.makeAsyncIterator()
        _ = await entered.next()

        // Job 2 queues behind it.
        await center.startRecording(eventID: nil, title: "Second", config: config)
        recorder2.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder2.lastStartURL), durationSec: 1)
        let stopSecond = Task { await center.stopAndProcess(config: config) }
        await waitUntil("job 2 to be queued") { center.jobs.count == 2 }

        // A third start claims capture, then parks before it can fail.
        let startThird = Task { await center.startRecording(eventID: nil, title: "Third", config: config) }
        var startEntered = startGate.enteredStream.makeAsyncIterator()
        _ = await startEntered.next()

        // Job 1 finishes; job 2 now parks on the engine slot the pending start holds.
        gate.release()
        await stopFirst.value
        await waitUntil("job 1 to leave the queue") { center.jobs.count == 1 }
        XCTAssertEqual(center.jobs.first?.phase, .queued,
                       "job 2 must wait while a start is claiming the capture slot")

        startGate.release()
        await startThird.value
        XCTAssertNotNil(center.captureError, "the third start failed")

        let ran = await waitUntil("job 2 to run once the failed start released the slot") {
            runner.savedTranscripts.count == 2
        }
        guard ran else { return }
        await stopSecond.value
        XCTAssertEqual(runner.savedTranscripts, ["job one", "job two"])
        XCTAssertTrue(center.jobs.isEmpty)
    }

    /// A stop-time error cancels the live pass, but cancellation cannot interrupt
    /// an in-progress `transcribeWindow` — the engine is still resident. So the
    /// slot may only be handed on once that orphan has actually exited, or a
    /// parked job loads a second model alongside it.
    func testStopErrorHandsTheEngineSlotOnOnlyAfterTheOrphanExits() async throws {
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        var recorderCalls = 0
        let liveGate1 = GateEngine(texts: ["live A"])
        let liveGate2 = GateEngine(texts: ["live B"])
        var engineLoads = 0
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(engineLoads == 1 ? liveGate1 : liveGate2)
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = threeWindowConfig()

        // Recording A's live pass parks mid-window; its job parks behind it.
        await center.startRecording(eventID: nil, title: "A", config: config)
        recorder1.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder1.lastStartURL), durationSec: 1)
        recorder1.emitLive([Float](repeating: 0, count: 1600))
        let stopA = Task { await center.stopAndProcess(config: config) }
        var enteredA = liveGate1.enteredStream.makeAsyncIterator()
        _ = await enteredA.next()

        // Recording B starts while A's tail drains, then takes the slot over.
        await center.startRecording(eventID: nil, title: "B", config: config)
        XCTAssertEqual(center.liveEngineState, .waiting)
        // Two windows, so B's live pass has a decidable cut and parks in the
        // engine while still recording.
        recorder2.emitLive([Float](repeating: 0, count: 3200))
        liveGate1.release()
        var enteredB = liveGate2.enteredStream.makeAsyncIterator()
        _ = await enteredB.next()
        XCTAssertEqual(engineLoads, 2)
        XCTAssertEqual(center.jobs.first?.phase, .queued, "job A re-parked behind B's live pass")

        // B's stop errors while its own live pass is still inside the engine.
        recorder2.stopError = AudioRecordingError.deviceSetupFailed("device vanished")
        await center.stopAndProcess(config: config)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(center.jobs.first?.phase, .queued,
                       "the orphaned live pass still holds the engine, so job A must not start")
        XCTAssertEqual(runner.savedTranscripts, [],
                       "nothing may be saved while the cancelled pass is still resident")

        liveGate2.release()
        let ran = await waitUntil("job A to run once the orphan exited") {
            runner.savedTranscripts.count == 1
        }
        guard ran else { return }
        await stopA.value
        XCTAssertEqual(runner.savedTranscripts, ["live A"])
        XCTAssertEqual(engineLoads, 2, "job A reuses the engine handed to it, never a third")
    }

    /// A slow engine load orphaned by a stop-time error is still resident, so a
    /// recording that starts while it hangs parks instead of loading a second
    /// engine — and when the orphan finally resolves, its late writes are fenced:
    /// neither `liveEngineState` nor the engine the new recording's job will
    /// reuse may be clobbered by it.
    func testOrphanedEngineLoadCannotClobberTheNewLivePass() async throws {
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        var recorderCalls = 0
        let loadGate = OneShotGate()
        var engineLoads = 0
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in
                engineLoads += 1
                if engineLoads == 1 {
                    await loadGate.wait()
                    return TestTranscriber(ScriptedEngine(texts: ["orphan text"]))
                }
                // Batch-only, so the new recording's state is distinguishable.
                return TestTranscriber(ScriptedEngine(texts: ["second"]), supportsLive: false)
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = singleWindowConfig()

        // Recording 1's engine load is still parked when its stop errors.
        await center.startRecording(eventID: nil, title: "First", config: config)
        recorder1.stopError = AudioRecordingError.deviceSetupFailed("device vanished")
        await center.stopAndProcess(config: config)
        guard case .failed = center.phase else {
            return XCTFail("expected .failed after a stop() error, got \(center.phase)")
        }

        // Recording 2 starts while the orphan is still inside the engine
        // factory: the slot is not free, so its live pass parks.
        await center.startRecording(eventID: nil, title: "Second", config: config)
        recorder2.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder2.lastStartURL), durationSec: 1)
        XCTAssertEqual(center.liveEngineState, .waiting,
                       "the orphaned load still owns the engine slot")
        XCTAssertEqual(engineLoads, 1, "no second engine may load beside the resident orphan")

        // The orphaned load finally resolves and hands the slot on. Every write
        // it makes on the way out is stale: the state the user sees is recording
        // 2's own (batch-only) engine's.
        loadGate.release()
        let handedOn = await waitUntil("the parked live pass to take the slot over") {
            center.liveEngineState == .unavailable
        }
        guard handedOn else { return }
        XCTAssertEqual(engineLoads, 2,
                       "the orphan's exit hands the slot to the parked pass — one more engine, not two at once")

        await center.stopAndProcess(config: config)

        XCTAssertEqual(runner.savedTranscripts, ["second"],
                       "recording 2's job must reuse ITS engine, not the orphan's")
        XCTAssertTrue(center.liveChunks.isEmpty)
    }

    /// The same residency rule seen from the capture side: a whole NEW recording
    /// started while a cancelled-but-resident live pass is still decoding must
    /// park its live pass rather than load a second model beside the orphan.
    func testNewRecordingParksWhileAStopErrorOrphanIsStillResident() async throws {
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        var recorderCalls = 0
        let liveGate = GateEngine(texts: ["orphaned"])
        var engineLoads = 0
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(engineLoads == 1 ? liveGate : ScriptedEngine(texts: ["second"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = threeWindowConfig()

        // Recording 1's live pass is inside the engine when its stop errors, so
        // cancelling it cannot evict the model it is decoding through. Two
        // windows, so the pass has a decidable cut and parks in the engine while
        // the recording is still running (one window only cuts at stream end).
        await center.startRecording(eventID: nil, title: "First", config: config)
        recorder1.emitLive([Float](repeating: 0, count: 3200))
        var entered = liveGate.enteredStream.makeAsyncIterator()
        _ = await entered.next()
        recorder1.stopError = AudioRecordingError.deviceSetupFailed("device vanished")
        await center.stopAndProcess(config: config)
        XCTAssertEqual(center.jobs.count, 1, "the partial recording is kept as a failed job")

        await center.startRecording(eventID: nil, title: "Second", config: config)
        recorder2.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder2.lastStartURL), durationSec: 1)
        XCTAssertEqual(center.liveEngineState, .waiting,
                       "the cancelled-but-resident pass still owns the engine slot")
        XCTAssertEqual(engineLoads, 1, "two engines must never be resident at once")

        liveGate.release()
        let started = await waitUntil("the parked live pass to load its engine") { engineLoads == 2 }
        guard started else { return }
        XCTAssertNotEqual(center.liveEngineState, .waiting,
                          "the orphan's exit is what hands the slot on")

        await center.stopAndProcess(config: config)
        XCTAssertEqual(runner.savedTranscripts, ["second"])
    }

    /// The Retry door is open the moment a stop fails (nothing is capturing, no
    /// job is queued), so the retried job is the other way into the engine slot
    /// the orphan still holds — it must park there too.
    func testRetryAfterAStopErrorParksUntilTheOrphanExits() async throws {
        let recorder = FakeRecorder()
        let liveGate = GateEngine(texts: ["orphaned"])
        var engineLoads = 0
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(engineLoads == 1 ? liveGate : ScriptedEngine(texts: ["retried"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = threeWindowConfig()

        // Two windows, so the live pass parks in the engine while the recording
        // is still running (one window only cuts once the stream ends).
        await center.startRecording(eventID: nil, title: "Only", config: config)
        recorder.emitLive([Float](repeating: 0, count: 3200))
        var entered = liveGate.enteredStream.makeAsyncIterator()
        _ = await entered.next()
        recorder.stopError = AudioRecordingError.deviceSetupFailed("device vanished")
        await center.stopAndProcess(config: config)

        XCTAssertNotNil(center.retriableFailureID, "the failure is retriable straight away")
        let retry = Task { await center.retryTranscription(config: config) }
        let parked = await waitUntil("the retried job to be re-enqueued") {
            center.jobs.first?.phase == .queued
        }
        guard parked else { return }
        XCTAssertEqual(engineLoads, 1, "the retry must not load a second engine beside the orphan")
        XCTAssertEqual(runner.savedTranscripts, [])

        liveGate.release()
        let ran = await waitUntil("the retried job to run once the orphan exited") {
            runner.savedTranscripts.count == 1
        }
        guard ran else { return }
        await retry.value
        XCTAssertEqual(runner.savedTranscripts, ["retried"])
        XCTAssertEqual(engineLoads, 2, "the retry loads its own engine, once the slot is free")
    }

    // MARK: - Capture-error dismissal

    /// The capture-error capsule has exactly one action, and `dismissFailure`
    /// clears that error ahead of any job — so a job merely sitting in the queue
    /// must not disable it. Only a job the queue is actively working can (it owns
    /// `phase`, which is what `dismissFailure` guards on).
    func testCaptureErrorIsDismissableWhileAJobIsMerelyQueued() async throws {
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        recorder2.startError = AudioRecordingError.microphonePermissionDenied
        var recorderCalls = 0
        let liveGate = GateEngine(texts: ["queued job"])
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in TestTranscriber(liveGate) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = threeWindowConfig()

        // Recording 1's live tail parks mid-window, so its job sits `.queued`:
        // the Center is busy, but nothing is running.
        await center.startRecording(eventID: nil, title: "First", config: config)
        recorder1.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder1.lastStartURL), durationSec: 1)
        recorder1.emitLive([Float](repeating: 0, count: 1600))
        let stopFirst = Task { await center.stopAndProcess(config: config) }
        var entered = liveGate.enteredStream.makeAsyncIterator()
        _ = await entered.next()
        let queued = await waitUntil("job 1 to be queued") { center.jobs.first?.phase == .queued }
        guard queued else { return }

        await center.startRecording(eventID: nil, title: "Denied", config: config)
        XCTAssertNotNil(center.captureError)
        XCTAssertTrue(center.isBusy, "the queued job keeps the Center busy")
        XCTAssertTrue(center.captureErrorDismissable,
                      "a queued job must not disable the capture error's only action")

        center.dismissFailure()
        XCTAssertNil(center.captureError, "Dismiss actually clears it")
        XCTAssertEqual(center.jobs.count, 1, "the queued job is untouched")

        liveGate.release()
        await stopFirst.value
        XCTAssertEqual(runner.savedTranscripts, ["queued job"])
    }

    /// While the queue is actively working a job, `phase` describes that job
    /// rather than the failure behind it, so `dismissFailure` would no-op — an
    /// enabled Dismiss button would be lying.
    func testNothingIsDismissableWhileAJobIsActivelyRunning() async throws {
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        var recorderCalls = 0
        var firstAudio: URL?
        let gate = GateEngine(texts: ["job two"])
        var engineLoads = 0
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(engineLoads == 1 ? ScriptedEngine(texts: []) : gate)
            },
            decode: { url in
                if url == firstAudio { throw AudioFileDecoderError.unsupportedFormat }
                return [Float](repeating: 0, count: 1600)
            },
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = singleWindowConfig()

        await center.startRecording(eventID: nil, title: "Failed", config: config)
        firstAudio = try XCTUnwrap(recorder1.lastStartURL)
        recorder1.stopResult = RecordingResult(audioURL: try XCTUnwrap(firstAudio), durationSec: 1)
        await center.stopAndProcess(config: config)
        XCTAssertTrue(try XCTUnwrap(center.jobs.first).phase.isFailed)

        await center.startRecording(eventID: nil, title: "Second", config: config)
        recorder2.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder2.lastStartURL), durationSec: 1)
        let stopSecond = Task { await center.stopAndProcess(config: config) }
        var entered = gate.enteredStream.makeAsyncIterator()
        _ = await entered.next() // job 2 is inside the engine — genuinely running

        XCTAssertEqual(center.phase, .transcribing(done: 0, total: 0),
                       "the running job owns `phase`, hiding the failure behind it")
        XCTAssertNil(center.dismissableFailureID,
                     "dismissFailure would no-op here, so no pill may offer Dismiss")
        XCTAssertNil(center.retriableFailureID)

        gate.release()
        await stopSecond.value
        XCTAssertEqual(runner.savedTranscripts, ["job two"])
    }

    // MARK: - Diarizer configuration

    /// The clustering threshold is a Settings value, so it has to survive the
    /// whole trip: `UserDefaults` → `TranscriptionConfig` → `diarizerFactory`.
    func testDiarizerReceivesTheConfiguredClusteringThreshold() async throws {
        let defaults = try isolatedDefaults()
        defaults.set(0.45, forKey: "transcription.diarizationThreshold")
        defaults.set(true, forKey: "transcription.diarization")
        var config = TranscriptionConfig.fromDefaults(defaults)
        config.forcedLanguage = "en"
        config.windowSec = 0.1
        config.overlapSec = 0
        config.boundarySnapSec = 0
        XCTAssertEqual(config.diarizationThreshold, 0.45, accuracy: 0.0001,
                       "the settings key must reach the config")
        XCTAssertTrue(config.diarization)

        let diarizer = FakeDiarizer()
        diarizer.segments = [SpeakerSegment(speakerID: "A", startSec: 0, endSec: 0.3)]
        var seenThresholds: [Float] = []
        let recorder = FakeRecorder()
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["привет"])) },
            diarizerFactory: { config in
                seenThresholds.append(config.diarizationThreshold)
                return diarizer
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: defaults,
            recordingsDirectory: recordingsDir
        )

        await center.startRecording(eventID: nil, title: "Roles", config: config)
        recorder.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder.lastStartURL), durationSec: 1)
        await center.stopAndProcess(config: config)

        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(seenThresholds, [0.45],
                       "the diarizer must be built from the run's config, never a hardcoded default")
        XCTAssertEqual(diarizer.calls, 1)
    }

    // MARK: - Fixtures

    /// A Center whose save always fails, so `failOneRecording` can stock the
    /// queue with failures. `startFailsAfter` recordings, the recorder's `start`
    /// throws instead — the capture-error surface.
    private func makeAlwaysFailingCenter(startFailsAfter: Int = .max) throws -> MeetingRecorderCenter {
        var recorderCalls = 0
        return MeetingRecorderCenter(
            recorderFactory: {
                recorderCalls += 1
                let recorder = FakeRecorder()
                if recorderCalls > startFailsAfter {
                    recorder.startError = AudioRecordingError.microphonePermissionDenied
                }
                return recorder
            },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["talk"])) },
            decode: { _ in throw AudioFileDecoderError.unsupportedFormat },
            runnerResolver: { FakeCLIRunner(stdout: self.recapOKEnvelope) },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
    }

    /// Records and stops once against `makeAlwaysFailingCenter`, leaving exactly
    /// one more failed job in the queue.
    private func failOneRecording(_ center: MeetingRecorderCenter, title: String) async throws {
        let before = center.jobs.count
        await center.startRecording(eventID: nil, title: title, config: singleWindowConfig())
        await center.stopAndProcess(config: singleWindowConfig())
        XCTAssertEqual(center.jobs.count, before + 1, "\(title) must land as a failed job")
    }
}

// MARK: - Local fakes

/// One-shot async gate: `wait()` parks the caller until `release()` lets it
/// through (order-independent, like `GateEngine`'s), and `enteredStream`
/// announces the arrival so a test can act on the parked state.
private final class OneShotGate: @unchecked Sendable {
    let enteredStream: AsyncStream<Void>

    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    init() { (enteredStream, enteredContinuation) = AsyncStream<Void>.makeStream() }

    func wait() async {
        enteredContinuation.yield(())
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume()
    }
}

/// `AudioRecording` whose `start` parks in the gate and then throws — the window
/// in which `startRecording` holds the capture slot (through `isStarting`) while
/// a job is already waiting for the engine.
private final class GatedFailingRecorder: AudioRecording, @unchecked Sendable {
    let liveSamples: AsyncStream<[Float]>

    private let gate: OneShotGate

    init(gate: OneShotGate) {
        self.gate = gate
        liveSamples = AsyncStream { $0.finish() }
    }

    func start(to url: URL) async throws {
        await gate.wait()
        throw AudioRecordingError.microphonePermissionDenied
    }

    func stop() async throws -> RecordingResult {
        throw AudioRecordingError.deviceSetupFailed("never started")
    }
}

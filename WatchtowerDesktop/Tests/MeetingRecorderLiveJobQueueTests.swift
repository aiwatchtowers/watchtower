import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Holds every `transcript save --stdin` until `releaseAll()`, so a test can
/// keep a job inside its save while something else happens. Records the saved
/// text like `TranscriptCapturingRunner`.
final class GatedSaveRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let stdoutData: Data
    private let lock = NSLock()
    private var held: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var saved: [String] = []

    init(stdout: Data) { self.stdoutData = stdout }

    var savedTranscripts: [String] { lock.withLock { saved } }
    var isHoldingASave: Bool { lock.withLock { !held.isEmpty } }

    func run(args: [String]) async throws -> Data { stdoutData }

    func run(args: [String], stdin: Data) async throws -> Data {
        guard args.contains("--stdin") else { return stdoutData }
        if let payload = TranscriptStdinPayload.decode(stdin) {
            lock.withLock { saved.append(payload.transcript) }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                held.append(continuation)
                lock.unlock()
            }
        }
        return stdoutData
    }

    /// Lets every held save (and every later one) return.
    func releaseAll() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            defer { held = [] }
            return held
        }
        for continuation in waiting { continuation.resume() }
    }
}

/// Back-to-back meetings: a job whose text is already in hand (the live
/// pass's output) is processed while the next meeting captures, without the
/// engine slot and without parking that meeting's live pass; a job that has
/// to transcribe still waits for the capture to stop — labelled so — and
/// never holds up the live-text jobs behind it. Split from
/// `MeetingRecorderQueueTests` (fixtures in `MeetingRecorderTestCase`) to keep
/// both files within the lint budget.
@MainActor
final class MeetingRecorderLiveJobQueueTests: MeetingRecorderTestCase {

    /// The shipping warm-slot default (absent = ON); see
    /// `MeetingRecorderWarmEngineTests.warmDefaults`.
    private func warmDefaults() throws -> UserDefaults {
        let defaults = try isolatedDefaults()
        defaults.removeObject(forKey: MeetingRecorderCenter.preloadBeforeMeetingsKey)
        return defaults
    }

    /// Answers every engine window as soon as it is entered, from now on.
    private func autoRelease(_ gate: GateEngine) -> Task<Void, Never> {
        Task {
            for await _ in gate.enteredStream { gate.release() }
        }
    }

    /// Lets go of whatever a test bailing out early may leave parked: every
    /// gate window from now on, every held save, and a capture still running
    /// (stopped, not awaited — the failure is already recorded).
    private func bailOut(
        _ center: MeetingRecorderCenter,
        gate: GateEngine? = nil,
        runner: GatedSaveRunner? = nil,
        recorder: FakeRecorder? = nil
    ) {
        if let gate {
            gate.release()
            _ = autoRelease(gate)
        }
        runner?.releaseAll()
        guard let recorder, center.isCapturing, let url = recorder.lastStartURL else { return }
        if recorder.stopResult == nil { recorder.stopResult = RecordingResult(audioURL: url, durationSec: 1) }
        let config = threeWindowConfig()
        Task { await center.stopAndProcess(config: config) }
    }

    /// The live-text job saves while the next meeting records, and holds no
    /// engine claim meanwhile: the new meeting's live pass runs instead of
    /// waiting for the save, on the engine the finished recording parked.
    func testLiveTextJobSavingDoesNotParkTheNextRecordingsLivePass() async throws {
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        var recorderCalls = 0
        var engineLoads = 0
        let runner = GatedSaveRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            pendingStore: pendingStore,
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["live one", "live two"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try warmDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = threeWindowConfig()

        await center.startRecording(eventID: nil, title: "First", config: config)
        recorder1.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder1.lastStartURL), durationSec: 1)
        recorder1.emitLive([Float](repeating: 0, count: 1600)) // one window → live text
        let stopFirst = Task { await center.stopAndProcess(config: config) }
        let saving = await waitUntil("the first job to be inside its save") { runner.isHoldingASave }
        guard saving else { runner.releaseAll(); return }
        let firstJob = try XCTUnwrap(center.jobs.first)
        XCTAssertEqual(center.activeJobID, firstJob.id, "the queue is working the first job")
        XCTAssertNil(center.engineJobID, "a job saving live text holds no engine")

        await center.startRecording(eventID: nil, title: "Second", config: config)
        let running = await waitUntil("the second recording's live pass to run") {
            center.liveEngineState == .running
        }
        XCTAssertTrue(running, "the live pass must not wait for a job that needs no engine")
        XCTAssertEqual(engineLoads, 1, "the second live pass takes the engine the first job parked")

        runner.releaseAll()
        await stopFirst.value
        XCTAssertEqual(runner.savedTranscripts, ["live one"])
        XCTAssertTrue(center.isCapturing, "the first recording saved while the second one records")

        recorder2.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder2.lastStartURL), durationSec: 1)
        recorder2.emitLive([Float](repeating: 0, count: 1600))
        await center.stopAndProcess(config: config)
        XCTAssertEqual(runner.savedTranscripts, ["live one", "live two"])
        XCTAssertEqual(engineLoads, 1, "one engine across both meetings")
        XCTAssertTrue(center.jobs.isEmpty)
    }

    /// The live-site case: Stop of meeting 1 and Start of meeting 2 land
    /// together — meeting 2 starts while meeting 1's live tail is still
    /// draining. Meeting 1's job has live text, so it is saved while meeting 2
    /// records (it used to sit "Queued" until meeting 2 stopped), and meeting
    /// 2's live pass gets meeting 1's engine straight from the drained tail
    /// instead of loading a second one — whichever of the two then runs first.
    func testStopThenImmediateStartSavesTheLiveJobDuringTheNextCapture() async throws {
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        var recorderCalls = 0
        var engineLoads = 0
        let gate = GateEngine(texts: ["live one", "live two"])
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            pendingStore: pendingStore,
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(gate)
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(), // preloading off: no warm slot to hide a second load
            recordingsDirectory: recordingsDir
        )
        var claimedWhileCapturing: [Bool] = []
        center.onJobTurnStartedForTesting = { claimedWhileCapturing.append(center.isCapturing) }
        let config = threeWindowConfig()

        await center.startRecording(eventID: nil, title: "First", config: config)
        recorder1.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder1.lastStartURL), durationSec: 1)
        recorder1.emitLive([Float](repeating: 0, count: 1600))
        let stopFirst = Task { await center.stopAndProcess(config: config) }
        var entered = gate.enteredStream.makeAsyncIterator()
        _ = await entered.next() // meeting 1's tail is parked in the engine
        let queued = await waitUntil("the first stop to enqueue its job") { center.jobs.count == 1 }
        guard queued else { bailOut(center, gate: gate); return }

        await center.startRecording(eventID: "evt-2", title: "Second", config: config)
        XCTAssertEqual(center.liveEngineState, .waiting, "the draining tail still owns the engine")

        gate.release()
        let saved = await waitUntil("meeting 1's live text to be saved while meeting 2 records") {
            runner.savedTranscripts == ["live one"]
        }
        XCTAssertTrue(saved, "meeting 1's live text is saved without waiting for meeting 2 to stop")
        guard saved else { bailOut(center, gate: gate, recorder: recorder2); return }
        await stopFirst.value
        XCTAssertEqual(claimedWhileCapturing, [true], "it started while meeting 2 was recording")
        XCTAssertTrue(center.isCapturing)
        let running = await waitUntil("meeting 2's live pass to run") { center.liveEngineState == .running }
        guard running else { bailOut(center, gate: gate, recorder: recorder2); return }
        XCTAssertEqual(engineLoads, 1, "meeting 2's live pass took the tail's engine — never two loaded")

        recorder2.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder2.lastStartURL), durationSec: 1)
        recorder2.emitLive([Float](repeating: 0, count: 1600))
        gate.release()
        await center.stopAndProcess(config: config)
        XCTAssertEqual(runner.savedTranscripts, ["live one", "live two"])
        XCTAssertEqual(runner.invocations.compactMap { savedFlag($0, "--event-id") }, ["evt-2"],
                       "each job keeps its own event link")
        XCTAssertEqual(engineLoads, 1)
        XCTAssertTrue(center.jobs.isEmpty)
    }

    /// The drained tail hands its engine to the recording parked on it only
    /// while Settings still name the model it was loaded for. Switched in
    /// between, the stale engine goes to meeting 1's job instead — which
    /// never parks it under the new Settings — and meeting 2's live pass
    /// loads the model now selected.
    func testDrainedTailNeverHandsAStaleEngineToTheParkedRecording() async throws {
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        var recorderCalls = 0
        var engineLoads = 0
        var key = "whisperkit|model-a"
        let currentKey: () -> String = { key }
        let gate = GateEngine(texts: ["live one", "stale two"])
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            pendingStore: pendingStore,
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in
                engineLoads += 1
                return engineLoads == 1
                    ? TestTranscriber(gate)
                    : TestTranscriber(ScriptedEngine(texts: ["fresh two"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try warmDefaults(), // the warm slot is where a stale engine could linger
            recordingsDirectory: recordingsDir,
            engineKey: currentKey
        )
        var handedToJob: [String?] = []
        center.onLiveEngineHandedOnForTesting = { [weak center] in
            handedToJob.append(center?.jobs.first?.engine?.key)
        }
        let config = threeWindowConfig()

        await center.startRecording(eventID: nil, title: "First", config: config)
        recorder1.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder1.lastStartURL), durationSec: 1)
        recorder1.emitLive([Float](repeating: 0, count: 1600))
        let stopFirst = Task { await center.stopAndProcess(config: config) }
        var entered = gate.enteredStream.makeAsyncIterator()
        _ = await entered.next() // meeting 1's tail is parked in the engine
        guard await waitUntil("the first stop to enqueue its job", { center.jobs.count == 1 }) else {
            bailOut(center, gate: gate)
            return
        }
        await center.startRecording(eventID: nil, title: "Second", config: config)
        XCTAssertEqual(center.liveEngineState, .waiting, "meeting 2 is parked on the draining tail")
        key = "whisperkit|model-b" // Settings switch before the tail drains

        gate.release()
        let releaser = autoRelease(gate) // a stale pass would block here; let it through to fail the asserts
        defer { releaser.cancel() }
        await stopFirst.value
        XCTAssertEqual(handedToJob, ["whisperkit|model-a"], "the stale engine went to the job, not to meeting 2")
        let running = await waitUntil("meeting 2's live pass to run") { center.liveEngineState == .running }
        guard running else { bailOut(center, gate: gate, recorder: recorder2); return }
        XCTAssertEqual(engineLoads, 2, "meeting 2's live pass loads the model Settings now select")
        XCTAssertTrue(center.jobs.allSatisfy { $0.engine == nil }, "no job is left holding the stale engine")
        XCTAssertFalse(center.isEngineWarm, "the stale engine is dropped, never parked")

        recorder2.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder2.lastStartURL), durationSec: 1)
        recorder2.emitLive([Float](repeating: 0, count: 1600))
        await center.stopAndProcess(config: config)
        XCTAssertEqual(runner.savedTranscripts, ["live one", "fresh two"], "meeting 2 ran on the fresh engine")
        XCTAssertEqual(engineLoads, 2)
    }

    /// Meeting 2 capturing (capture only) with meeting 1's batch job queued
    /// behind it — what `makeWaitingBatchJob` leaves running.
    private struct WaitingBatchJob {
        let center: MeetingRecorderCenter
        let jobID: MeetingRecorderCenter.ProcessingJob.ID
        let stopFirst: Task<Void, Never>
        let releaser: Task<Void, Never>
        let captureOnly: TranscriptionConfig

        /// Stops meeting 2 and awaits both recordings' jobs.
        func finish() async {
            await center.stopAndProcess(config: captureOnly)
            await stopFirst.value
            releaser.cancel()
        }
    }

    /// Meeting 1 stops into a batch job (its live window is silence) while
    /// capture-only meeting 2 starts on its tail. Returns once the job waits
    /// for meeting 2, labelled so; nil (with everything let go) when it never
    /// gets there. The batch passes save "batch one", then "batch two".
    private func makeWaitingBatchJob(runner: CLIRunnerProtocol,
                                     store: PendingTranscriptStore? = nil) async throws -> WaitingBatchJob? {
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        var recorderCalls = 0
        var engineLoads = 0
        let gate = GateEngine(texts: ["", "batch one"])
        let center = MeetingRecorderCenter(
            pendingStore: store ?? pendingStore,
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
        let config = threeWindowConfig()
        var captureOnly = config
        captureOnly.liveTranscription = false

        await center.startRecording(eventID: nil, title: "First", config: config)
        recorder1.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder1.lastStartURL), durationSec: 1)
        recorder1.emitLive([Float](repeating: 0, count: 1600))
        let stopFirst = Task { await center.stopAndProcess(config: config) }
        var entered = gate.enteredStream.makeAsyncIterator()
        _ = await entered.next()
        let queued = await waitUntil("the first stop to enqueue its job") { center.jobs.count == 1 }
        guard queued, let jobID = center.jobs.first?.id else { bailOut(center, gate: gate); return nil }

        await center.startRecording(eventID: nil, title: "Second", config: captureOnly)
        XCTAssertTrue(center.jobsWaitingForCapture.isEmpty, "a job still awaiting its live tail is never labelled")
        gate.release() // meeting 1's tail; the batch pass's window is answered by the releaser
        recorder2.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder2.lastStartURL), durationSec: 1)
        let waiting = WaitingBatchJob(center: center, jobID: jobID, stopFirst: stopFirst,
                                      releaser: autoRelease(gate), captureOnly: captureOnly)
        let labelled = await waitUntil("the batch job to be listed as waiting for the capture") {
            center.jobsWaitingForCapture.contains(jobID)
        }
        guard labelled else { Task { await waiting.finish() }; return nil }
        return waiting
    }

    /// A job that has to transcribe (the live pass produced nothing) still
    /// waits for the running capture to stop — exactly as before — and says
    /// so: it is listed in `jobsWaitingForCapture` for the indicator's label.
    func testBatchJobStillWaitsForTheCaptureAndIsLabelledWaiting() async throws {
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        guard let waiting = try await makeWaitingBatchJob(runner: runner) else { return }
        let center = waiting.center
        var claimedWhileCapturing: [Bool] = []
        center.onJobTurnStartedForTesting = { claimedWhileCapturing.append(center.isCapturing) }
        await runEnqueuedMainActorWork()
        XCTAssertEqual(center.jobs.first?.phase, .queued)
        XCTAssertNil(center.activeJobID, "a batch job never starts while a recording captures")
        XCTAssertTrue(runner.savedTranscripts.isEmpty)
        let pill = RecordingIndicatorView.jobPillItems(center).visible.first { $0.id == waiting.jobID }
        XCTAssertEqual(pill?.waitingForCapture, true, "the indicator hands the Center's flag to the pill")

        await waiting.finish()
        XCTAssertEqual(runner.savedTranscripts, ["batch one", "batch two"], "FIFO among batch jobs")
        XCTAssertEqual(claimedWhileCapturing, [false, false])
        XCTAssertTrue(center.jobsWaitingForCapture.isEmpty, "nothing waits once the capture stopped")
        XCTAssertTrue(center.jobs.isEmpty)
    }

    /// The "Waiting for the recording to stop" label goes in the same step
    /// the capture ends — while the job is still there, not once it is gone.
    func testWaitingLabelClearsTheMomentTheCaptureStops() async throws {
        let runner = GatedSaveRunner(stdout: recapOKEnvelope)
        guard let waiting = try await makeWaitingBatchJob(runner: runner) else { return }
        let center = waiting.center
        var labelledAtTurn: [Bool] = []
        center.onJobTurnStartedForTesting = { labelledAtTurn.append(!center.jobsWaitingForCapture.isEmpty) }

        let stop = Task { await center.stopAndProcess(config: waiting.captureOnly) }
        let stopped = await waitUntil("meeting 2's capture to end") { !center.isCapturing }
        XCTAssertTrue(stopped)
        XCTAssertTrue(center.jobsWaitingForCapture.isEmpty, "the label goes with the capture")
        XCTAssertTrue(center.jobs.contains { $0.id == waiting.jobID }, "while the job is still queued or running")
        XCTAssertFalse(RecordingIndicatorView.jobPillItems(center).visible.contains { $0.waitingForCapture })

        runner.releaseAll()
        await stop.value
        await waiting.stopFirst.value
        waiting.releaser.cancel()
        XCTAssertEqual(labelledAtTurn, [false, false])
        XCTAssertEqual(runner.savedTranscripts, ["batch one", "batch two"])
    }

    /// A queued job's input (it reads the job's pending row) is worked out
    /// once, not again on every wake of the queue and every label refresh.
    func testAQueuedJobsInputIsWorkedOutOnceNotOnEveryWake() async throws {
        let store = CountingPendingStore(pendingStore)
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        guard let waiting = try await makeWaitingBatchJob(runner: runner, store: store) else { return }
        let name = try XCTUnwrap(waiting.center.jobs.first?.audioURL.lastPathComponent)
        let readsWhenLabelled = store.transcriptReads(name)
        XCTAssertGreaterThan(readsWhenLabelled, 0, "the label is decided from the job's input")

        await waiting.finish() // the stop wakes the queue, the job starts and runs
        XCTAssertEqual(store.transcriptReads(name), readsWhenLabelled,
                       "the start decision reuses the input worked out for the label")
        XCTAssertEqual(runner.savedTranscripts, ["batch one", "batch two"])
    }

    /// A batch job parked on a capture does not starve the live-text job queued
    /// behind it: that one starts (and saves) while the capture runs, and the
    /// batch job still goes first among the rest once the capture stops.
    func testLiveTextJobBehindAWaitingBatchJobIsNotStarved() async throws {
        let recorders = [FakeRecorder(), FakeRecorder(), FakeRecorder()]
        var recorderCalls = 0
        var engineLoads = 0
        // One engine throughout (the warm slot carries it between jobs).
        // Windows in order: meeting 1's live (silence → batch), meeting 2's
        // live, then the batch passes of meetings 1 and 3.
        let gate = GateEngine(texts: ["", "live two", "batch one", "batch three"])
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            pendingStore: pendingStore,
            recorderFactory: { recorderCalls += 1; return recorders[recorderCalls - 1] },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(gate)
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try warmDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = threeWindowConfig()
        var captureOnly = config
        captureOnly.liveTranscription = false
        var entered = gate.enteredStream.makeAsyncIterator()

        // Meeting 1 stops into a batch job while meeting 2 starts on its tail.
        await center.startRecording(eventID: nil, title: "One", config: config)
        recorders[0].stopResult = RecordingResult(audioURL: try XCTUnwrap(recorders[0].lastStartURL),
                                                  durationSec: 1)
        recorders[0].emitLive([Float](repeating: 0, count: 1600))
        let stopOne = Task { await center.stopAndProcess(config: config) }
        _ = await entered.next()
        guard await waitUntil("meeting 1's job", { center.jobs.count == 1 }) else { bailOut(center, gate: gate); return }
        await center.startRecording(eventID: nil, title: "Two", config: config)
        gate.release()
        guard await waitUntil("meeting 2's live pass", { center.liveEngineState == .running }) else {
            bailOut(center, gate: gate, recorder: recorders[1])
            return
        }
        let batchJob = try XCTUnwrap(center.jobs.first)

        // Meeting 2 stops with live text while meeting 3 starts on its tail.
        recorders[1].stopResult = RecordingResult(audioURL: try XCTUnwrap(recorders[1].lastStartURL),
                                                  durationSec: 1)
        recorders[1].emitLive([Float](repeating: 0, count: 1600))
        let stopTwo = Task { await center.stopAndProcess(config: config) }
        _ = await entered.next() // meeting 2's tail is parked in the engine
        guard await waitUntil("meeting 2's job", { center.jobs.count == 2 }) else { bailOut(center, gate: gate); return }
        await center.startRecording(eventID: nil, title: "Three", config: captureOnly)
        gate.release()

        await stopTwo.value
        XCTAssertEqual(runner.savedTranscripts, ["live two"],
                       "the live-text job ran past the batch job parked on meeting 3")
        XCTAssertEqual(center.jobs.map(\.id), [batchJob.id])
        XCTAssertEqual(center.jobs.first?.phase, .queued)
        XCTAssertTrue(center.jobsWaitingForCapture.contains(batchJob.id))
        XCTAssertTrue(center.isCapturing)
        XCTAssertEqual(engineLoads, 1)

        let releaser = autoRelease(gate)
        defer { releaser.cancel() }
        recorders[2].stopResult = RecordingResult(audioURL: try XCTUnwrap(recorders[2].lastStartURL),
                                                  durationSec: 1)
        await center.stopAndProcess(config: captureOnly)
        await stopOne.value
        XCTAssertEqual(runner.savedTranscripts, ["live two", "batch one", "batch three"],
                       "once meeting 3 stops the parked batch job goes ahead of the later one")
        XCTAssertEqual(engineLoads, 1, "never a second engine")
        XCTAssertTrue(center.jobs.isEmpty)
    }

    // MARK: - Engine slot release after a batch transcription

    /// A batch job lets go of the engine slot once its transcription is over:
    /// a recording started while it saves runs its live pass at once — not
    /// `.waiting` for the save — on the engine the job just parked.
    func testRecordingStartedWhileABatchJobSavesRunsItsLivePassOnTheParkedEngine() async throws {
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        var recorderCalls = 0
        var engineLoads = 0
        let runner = GatedSaveRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            pendingStore: pendingStore,
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["batch one", "live two"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try warmDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = threeWindowConfig()
        var captureOnly = config
        captureOnly.liveTranscription = false

        await center.startRecording(eventID: nil, title: "First", config: captureOnly)
        recorder1.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder1.lastStartURL), durationSec: 1)
        let stopFirst = Task { await center.stopAndProcess(config: captureOnly) }
        let saving = await waitUntil("the batch job to be inside its save") { runner.isHoldingASave }
        guard saving else { runner.releaseAll(); return }
        XCTAssertEqual(center.jobs.first?.phase, .summarizing)
        XCTAssertNotNil(center.activeJobID, "the job still has its turn")
        XCTAssertNil(center.engineJobID, "a batch job past its transcription holds no engine")

        await center.startRecording(eventID: nil, title: "Second", config: config)
        XCTAssertNotEqual(center.liveEngineState, .waiting, "the live pass must not wait for the save")
        let running = await waitUntil("the second recording's live pass to run") {
            center.liveEngineState == .running
        }
        XCTAssertTrue(running)
        XCTAssertEqual(engineLoads, 1, "the live pass takes the engine the batch job parked")

        runner.releaseAll()
        await stopFirst.value
        recorder2.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder2.lastStartURL), durationSec: 1)
        recorder2.emitLive([Float](repeating: 0, count: 1600))
        await center.stopAndProcess(config: config)
        XCTAssertEqual(runner.savedTranscripts, ["batch one", "live two"])
        XCTAssertEqual(engineLoads, 1, "one engine across both meetings")
        XCTAssertTrue(center.jobs.isEmpty)
    }

    /// A batch job whose transcription throws releases the engine slot too:
    /// the recording parked on it starts its live pass once the job failed.
    func testBatchJobWhoseTranscriptionThrowsReleasesTheParkedLivePass() async throws {
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        var recorderCalls = 0
        var engineLoads = 0
        let failing = FailAfterGateEngine()
        let center = MeetingRecorderCenter(
            pendingStore: pendingStore,
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(engineLoads == 1 ? failing : ScriptedEngine(texts: ["live two"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { TranscriptCapturingRunner(stdout: self.recapOKEnvelope) },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = threeWindowConfig()
        var captureOnly = config
        captureOnly.liveTranscription = false

        await center.startRecording(eventID: nil, title: "First", config: captureOnly)
        recorder1.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder1.lastStartURL), durationSec: 1)
        let stopFirst = Task { await center.stopAndProcess(config: captureOnly) }
        var entered = failing.gate.enteredStream.makeAsyncIterator()
        _ = await entered.next() // the batch job is transcribing
        await center.startRecording(eventID: nil, title: "Second", config: config)
        XCTAssertEqual(center.liveEngineState, .waiting, "a batch job still transcribing owns the engine")

        failing.gate.release()
        await stopFirst.value
        XCTAssertTrue(center.jobs.first?.phase.isFailed == true)
        XCTAssertNil(center.engineJobID)
        let running = await waitUntil("the parked live pass to run") { center.liveEngineState == .running }
        XCTAssertTrue(running, "the failed job released the engine slot")
        XCTAssertEqual(engineLoads, 2, "the thrown engine is dropped and the live pass loads fresh")

        recorder2.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder2.lastStartURL), durationSec: 1)
        recorder2.emitLive([Float](repeating: 0, count: 1600))
        await center.stopAndProcess(config: config)
    }

    /// A live-text job parks its engine when it starts, then renders roles and
    /// saves. A warm-policy tick meanwhile must not unload that engine — the
    /// job counts as busy — or the next recording would load it again.
    func testWarmTickDuringALiveTextJobKeepsTheParkedEngine() async throws {
        let recorder = FakeRecorder()
        var engineLoads = 0
        let runner = GatedSaveRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            pendingStore: pendingStore,
            recorderFactory: { recorder },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["live one"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try warmDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = threeWindowConfig()

        await center.startRecording(eventID: nil, title: "First", config: config)
        recorder.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder.lastStartURL), durationSec: 1)
        recorder.emitLive([Float](repeating: 0, count: 1600))
        let stop = Task { await center.stopAndProcess(config: config) }
        let saving = await waitUntil("the live-text job to be inside its save") { runner.isHoldingASave }
        guard saving else { runner.releaseAll(); return }
        XCTAssertTrue(center.isEngineWarm, "the job parked its handed-over engine")
        XCTAssertNil(center.engineJobID)

        center.warmPolicyTick(config: config) // no meeting ahead: idle, this would unload
        XCTAssertTrue(center.isEngineWarm, "a running job keeps the warm policy off")

        runner.releaseAll()
        await stop.value
        center.warmPolicyTick(config: config)
        XCTAssertFalse(center.isEngineWarm, "once the queue is idle the policy unloads as before")
        XCTAssertEqual(engineLoads, 1)
    }

    // MARK: - Serial queue, dictation, handed engines, failures

    /// Two live-text jobs stay serial: the second one's save never starts
    /// before the first one's has returned.
    func testTwoLiveTextJobsStaySerial() async throws {
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        var recorderCalls = 0
        let runner = GatedSaveRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            pendingStore: pendingStore,
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["live one", "live two"])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try warmDefaults(),
            recordingsDirectory: recordingsDir
        )
        var jobsAtTurn: [Int] = []
        center.onJobTurnStartedForTesting = { jobsAtTurn.append(center.jobs.count) }
        let config = threeWindowConfig()

        await center.startRecording(eventID: nil, title: "First", config: config)
        recorder1.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder1.lastStartURL), durationSec: 1)
        recorder1.emitLive([Float](repeating: 0, count: 1600))
        let stopFirst = Task { await center.stopAndProcess(config: config) }
        guard await waitUntil("the first job's save", { runner.isHoldingASave }) else {
            bailOut(center, runner: runner)
            return
        }
        await center.startRecording(eventID: nil, title: "Second", config: config)
        recorder2.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder2.lastStartURL), durationSec: 1)
        recorder2.emitLive([Float](repeating: 0, count: 1600))
        let stopSecond = Task { await center.stopAndProcess(config: config) }
        guard await waitUntil("the second job's live text", {
            center.jobs.count == 2 && center.jobs.last?.liveOutput != nil
        }) else {
            bailOut(center, runner: runner)
            return
        }
        await runEnqueuedMainActorWork()
        XCTAssertEqual(runner.savedTranscripts, ["live one"], "only one save at a time")
        XCTAssertEqual(center.jobs.last?.phase, .queued)
        XCTAssertEqual(center.activeJobID, center.jobs.first?.id)

        runner.releaseAll()
        await stopFirst.value
        await stopSecond.value
        XCTAssertEqual(jobsAtTurn, [1, 1], "job 2 started only once job 1 had saved and left the queue")
        XCTAssertEqual(runner.savedTranscripts, ["live one", "live two"])
    }

    /// What `makeLivePassParkedOnDictation` leaves running: meeting 1's
    /// live-text job held in its save, meeting 2's live pass parked on a
    /// dictation engine that is still resident.
    private struct ParkedOnDictation {
        let center: MeetingRecorderCenter
        let runner: GatedSaveRunner
        let recorder2: FakeRecorder
        let stopFirst: Task<Void, Never>
        let dictation: FakeDictationSlot
        let config: TranscriptionConfig

        /// Drives both meetings to their saves.
        func finish() async {
            runner.releaseAll()
            await stopFirst.value
            recorder2.emitLive([Float](repeating: 0, count: 1600))
            await center.stopAndProcess(config: config)
        }
    }

    /// The dictation side of the shared engine slot, as the Center sees it.
    final class FakeDictationSlot {
        var resident = false
        var engineLoads = 0
    }

    private func makeLivePassParkedOnDictation() async throws -> ParkedOnDictation? {
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        var recorderCalls = 0
        let dictation = FakeDictationSlot()
        let runner = GatedSaveRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            pendingStore: pendingStore,
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in
                dictation.engineLoads += 1
                return TestTranscriber(ScriptedEngine(texts: ["live one", "live two"]))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try warmDefaults(),
            recordingsDirectory: recordingsDir
        )
        center.dictationEngineResident = { dictation.resident }
        let config = threeWindowConfig()

        await center.startRecording(eventID: nil, title: "First", config: config)
        recorder1.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder1.lastStartURL), durationSec: 1)
        recorder1.emitLive([Float](repeating: 0, count: 1600))
        let stopFirst = Task { await center.stopAndProcess(config: config) }
        guard await waitUntil("the first job's save", { runner.isHoldingASave }) else {
            bailOut(center, runner: runner)
            return nil
        }
        dictation.resident = true // a dictation still draining when meeting 2 starts
        await center.startRecording(eventID: nil, title: "Second", config: config)
        recorder2.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder2.lastStartURL), durationSec: 1)
        XCTAssertEqual(center.liveEngineState, .waiting, "a resident dictation engine parks the live pass")
        return ParkedOnDictation(center: center, runner: runner, recorder2: recorder2, stopFirst: stopFirst,
                                 dictation: dictation, config: config)
    }

    /// The live-text job's end must not start a live pass parked on a
    /// resident dictation engine (it held no engine), nor load one beside it;
    /// the dictation's release does.
    func testLiveTextJobEndingLeavesALivePassParkedOnDictation() async throws {
        guard let parked = try await makeLivePassParkedOnDictation() else { return }
        let center = parked.center
        parked.runner.releaseAll()
        await parked.stopFirst.value
        await runEnqueuedMainActorWork()
        XCTAssertEqual(center.liveEngineState, .waiting, "the job's end must not start the parked pass")
        XCTAssertEqual(parked.dictation.engineLoads, 1, "nor load an engine beside the dictation's")

        parked.dictation.resident = false
        center.dictationEngineDidRelease()
        let running = await waitUntil("the live pass to run") { center.liveEngineState == .running }
        XCTAssertTrue(running)
        XCTAssertEqual(parked.dictation.engineLoads, 1, "it takes the engine meeting 1's job parked")
        await parked.finish()
        XCTAssertEqual(parked.runner.savedTranscripts, ["live one", "live two"])
    }

    /// The dictation letting go starts the parked live pass even while the
    /// live-text job is still working — that job holds no engine.
    func testDictationReleaseStartsTheParkedPassWhileALiveTextJobRuns() async throws {
        guard let parked = try await makeLivePassParkedOnDictation() else { return }
        let center = parked.center
        parked.dictation.resident = false
        center.dictationEngineDidRelease()
        let running = await waitUntil("the live pass to run") { center.liveEngineState == .running }
        XCTAssertTrue(running)
        XCTAssertNotNil(center.activeJobID, "meeting 1's job is still saving")
        XCTAssertEqual(parked.dictation.engineLoads, 1)
        await parked.finish()
        XCTAssertEqual(parked.runner.savedTranscripts, ["live one", "live two"])
    }

    /// Meeting 0's live-text job holds the queue (save held); meeting 1 stops
    /// behind it, its queued job carrying meeting 1's engine; then meeting 2
    /// starts, so its live pass finds that engine in `takeWarmOrLoad` (step
    /// 2). With `settingsChange` the provider/model switched in between.
    /// Returns the engine loads once meeting 2's pass runs.
    private func loadsForALivePassBesideAQueuedJobsEngine(settingsChange: Bool) async throws -> Int? {
        let recorders = [FakeRecorder(), FakeRecorder(), FakeRecorder()]
        var recorderCalls = 0
        var engineLoads = 0
        var key = "whisperkit|model-a"
        let currentKey: () -> String = { key }
        let runner = GatedSaveRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            pendingStore: pendingStore,
            recorderFactory: { recorderCalls += 1; return recorders[recorderCalls - 1] },
            engineFactory: { _ in
                engineLoads += 1
                let texts = engineLoads == 1 ? ["live zero", "live one", "live two"] : ["live two"]
                return TestTranscriber(ScriptedEngine(texts: texts))
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try warmDefaults(),
            recordingsDirectory: recordingsDir,
            engineKey: currentKey
        )
        let config = threeWindowConfig()
        var stops: [Task<Void, Never>] = []
        for index in 0..<2 {
            await center.startRecording(eventID: nil, title: "Meeting \(index)", config: config)
            guard await waitUntil("meeting \(index)'s live pass", { center.liveEngineState == .running }) else {
                bailOut(center, runner: runner, recorder: recorders[index])
                return nil
            }
            recorders[index].stopResult = RecordingResult(audioURL: try XCTUnwrap(recorders[index].lastStartURL),
                                                          durationSec: 1)
            recorders[index].emitLive([Float](repeating: 0, count: 1600))
            stops.append(Task { await center.stopAndProcess(config: config) })
            guard await waitUntil("meeting \(index)'s job", {
                runner.isHoldingASave && center.jobs.count == index + 1 && center.jobs.last?.liveOutput != nil
            }) else {
                bailOut(center, runner: runner)
                return nil
            }
        }
        XCTAssertNotNil(center.jobs.last?.engine, "meeting 1's queued job carries its engine")
        if settingsChange { key = "whisperkit|model-b" }

        await center.startRecording(eventID: nil, title: "Meeting 2", config: config)
        let running = await waitUntil("meeting 2's live pass") { center.liveEngineState == .running }
        let loads = engineLoads
        XCTAssertNil(center.jobs.last?.engine, "the live pass took the queued job's engine over")
        XCTAssertEqual(center.activeJobID, center.jobs.first?.id, "meeting 1's job never started meanwhile")

        recorders[2].stopResult = RecordingResult(audioURL: try XCTUnwrap(recorders[2].lastStartURL), durationSec: 1)
        recorders[2].emitLive([Float](repeating: 0, count: 1600))
        runner.releaseAll()
        for stop in stops { await stop.value }
        await center.stopAndProcess(config: config)
        XCTAssertEqual(runner.savedTranscripts, ["live zero", "live one", "live two"])
        return running ? loads : nil
    }

    func testLivePassTakesOverAQueuedJobsEngine() async throws {
        let loads = try await loadsForALivePassBesideAQueuedJobsEngine(settingsChange: false)
        XCTAssertEqual(loads, 1, "the handed engine is reused, never a second load beside it")
    }

    func testLivePassNeverServedAQueuedJobsStaleEngine() async throws {
        let loads = try await loadsForALivePassBesideAQueuedJobsEngine(settingsChange: true)
        XCTAssertEqual(loads, 2, "an engine loaded for the old Settings is dropped and loaded fresh")
    }

    /// A live-text job that fails (its save throws) while the next meeting
    /// records fails on its own: the capture and its live pass go on, on the
    /// engine the stopped recording handed over — no extra load.
    func testLiveTextJobFailingDuringTheNextCaptureLeavesTheCaptureAlone() async throws {
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        var recorderCalls = 0
        var engineLoads = 0
        let gate = GateEngine(texts: ["live one", "live two"])
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        runner.shouldThrow = CLIRunnerError.nonZeroExit(code: 1, stderr: "db locked")
        let center = MeetingRecorderCenter(
            pendingStore: pendingStore,
            recorderFactory: { recorderCalls += 1; return recorderCalls == 1 ? recorder1 : recorder2 },
            engineFactory: { _ in
                engineLoads += 1
                return TestTranscriber(gate)
            },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = threeWindowConfig()

        await center.startRecording(eventID: nil, title: "First", config: config)
        recorder1.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder1.lastStartURL), durationSec: 1)
        recorder1.emitLive([Float](repeating: 0, count: 1600))
        let stopFirst = Task { await center.stopAndProcess(config: config) }
        var entered = gate.enteredStream.makeAsyncIterator()
        _ = await entered.next() // meeting 1's tail is parked in the engine
        guard await waitUntil("the first stop to enqueue its job", { center.jobs.count == 1 }) else {
            bailOut(center, gate: gate)
            return
        }
        await center.startRecording(eventID: nil, title: "Second", config: config)
        gate.release()
        await stopFirst.value

        XCTAssertEqual(center.jobs.first?.phase.isFailed, true, "the save failed, so the job is kept for retry")
        XCTAssertNil(center.activeJobID)
        XCTAssertTrue(center.isCapturing, "the failure leaves the running capture alone")
        let running = await waitUntil("meeting 2's live pass to run") { center.liveEngineState == .running }
        guard running else { bailOut(center, gate: gate, recorder: recorder2); return }
        XCTAssertEqual(engineLoads, 1, "no extra engine load")

        runner.shouldThrow = nil
        recorder2.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder2.lastStartURL), durationSec: 1)
        recorder2.emitLive([Float](repeating: 0, count: 1600))
        gate.release()
        await center.stopAndProcess(config: config)
        XCTAssertEqual(runner.savedTranscripts, ["live one", "live two"])
        XCTAssertEqual(center.jobs.count, 1, "only the failed job stays")
    }
}

/// Blocks each window like `GateEngine` (released through `gate`), then throws.
final class FailAfterGateEngine: WhisperWindowEngine, @unchecked Sendable {
    struct EngineError: Error {}
    let gate = GateEngine(texts: [])

    func detectLanguage(_ samples: [Float]) async throws -> [String: Float] { ["en": 1.0] }

    func transcribeWindow(_ samples: [Float], language: String, prompt: String?) async throws -> [TranscribedSegment] {
        _ = try await gate.transcribeWindow(samples, language: language, prompt: prompt)
        throw EngineError()
    }
}

/// The real store underneath, counting `transcript(recording:)` reads per
/// recording.
final class CountingPendingStore: PendingTranscriptStore, @unchecked Sendable {
    private let base: PendingTranscriptStore
    private let lock = NSLock()
    private var reads: [String: Int] = [:]

    init(_ base: PendingTranscriptStore) { self.base = base }

    func transcriptReads(_ recording: String) -> Int { lock.withLock { reads[recording, default: 0] } }

    func transcript(recording: String) throws -> PendingTranscript? {
        lock.withLock { reads[recording, default: 0] += 1 }
        return try base.transcript(recording: recording)
    }

    func begin(recording: String, eventID: String?, title: String?, isPrivate: Bool, at: Date) async throws {
        try await base.begin(recording: recording, eventID: eventID, title: title, isPrivate: isPrivate, at: at)
    }
    func reserve(recording: String, eventID: String?, title: String?, isPrivate: Bool, at: Date) async throws -> Bool {
        try await base.reserve(recording: recording, eventID: eventID, title: title, isPrivate: isPrivate, at: at)
    }
    func setPrivate(recording: String, _ isPrivate: Bool) async throws -> Bool {
        try await base.setPrivate(recording: recording, isPrivate)
    }
    func saveTranscript(recording: String, text: String, metaJSON: String, isPrivate: Bool, at: Date) async throws {
        try await base.saveTranscript(recording: recording, text: text, metaJSON: metaJSON, isPrivate: isPrivate, at: at)
    }
    func clearTranscript(recording: String) async throws { try await base.clearTranscript(recording: recording) }
    func dismiss(recording: String, at: Date) async throws { try await base.dismiss(recording: recording, at: at) }
    func pending() throws -> [PendingTranscript] { try base.pending() }
    func remove(recording: String) async throws { try await base.remove(recording: recording) }
    func savedAudioPaths() throws -> Set<String> { try base.savedAudioPaths() }
}

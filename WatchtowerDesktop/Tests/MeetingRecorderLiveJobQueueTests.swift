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
    /// 2's live pass takes the engine meeting 1 handed to its job instead of
    /// loading a second one.
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
        center.onEngineSlotClaimedForTesting = { claimedWhileCapturing.append(center.isCapturing) }
        let config = threeWindowConfig()

        await center.startRecording(eventID: nil, title: "First", config: config)
        recorder1.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder1.lastStartURL), durationSec: 1)
        recorder1.emitLive([Float](repeating: 0, count: 1600))
        let stopFirst = Task { await center.stopAndProcess(config: config) }
        var entered = gate.enteredStream.makeAsyncIterator()
        _ = await entered.next() // meeting 1's tail is parked in the engine
        let queued = await waitUntil("the first stop to enqueue its job") { center.jobs.count == 1 }
        guard queued else { gate.release(); return }

        await center.startRecording(eventID: "evt-2", title: "Second", config: config)
        XCTAssertEqual(center.liveEngineState, .waiting, "the draining tail still owns the engine")

        gate.release()
        await stopFirst.value
        XCTAssertEqual(runner.savedTranscripts, ["live one"],
                       "meeting 1's live text is saved without waiting for meeting 2 to stop")
        XCTAssertEqual(claimedWhileCapturing, [true], "it started while meeting 2 was recording")
        XCTAssertTrue(center.isCapturing)
        let running = await waitUntil("meeting 2's live pass to run") { center.liveEngineState == .running }
        guard running else { return }
        XCTAssertEqual(engineLoads, 1, "meeting 2's live pass took the handed-over engine — never two loaded")

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

    /// A job that has to transcribe (the live pass produced nothing) still
    /// waits for the running capture to stop — exactly as before — and says
    /// so: it is listed in `jobsWaitingForCapture` for the indicator's label.
    func testBatchJobStillWaitsForTheCaptureAndIsLabelledWaiting() async throws {
        let recorder1 = FakeRecorder()
        let recorder2 = FakeRecorder()
        var recorderCalls = 0
        var engineLoads = 0
        // Meeting 1's live window comes back empty (silence) → batch fallback.
        let gate = GateEngine(texts: ["", "batch one"])
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            pendingStore: pendingStore,
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
        var claimedWhileCapturing: [Bool] = []
        center.onEngineSlotClaimedForTesting = { claimedWhileCapturing.append(center.isCapturing) }
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
        guard queued else { gate.release(); return }
        let firstJob = try XCTUnwrap(center.jobs.first)

        await center.startRecording(eventID: nil, title: "Second", config: captureOnly)
        gate.release() // meeting 1's tail; the batch pass's window is answered below
        let releaser = autoRelease(gate)
        defer { releaser.cancel() }
        let labelled = await waitUntil("the batch job to be listed as waiting for the capture") {
            center.jobsWaitingForCapture.contains(firstJob.id)
        }
        guard labelled else { return }
        await runEnqueuedMainActorWork()
        XCTAssertEqual(center.jobs.first?.phase, .queued)
        XCTAssertNil(center.activeJobID, "a batch job never starts while a recording captures")
        XCTAssertTrue(claimedWhileCapturing.isEmpty)
        XCTAssertTrue(runner.savedTranscripts.isEmpty)

        recorder2.stopResult = RecordingResult(audioURL: try XCTUnwrap(recorder2.lastStartURL), durationSec: 1)
        await center.stopAndProcess(config: captureOnly)
        await stopFirst.value
        XCTAssertEqual(runner.savedTranscripts, ["batch one", "batch two"], "FIFO among batch jobs")
        XCTAssertEqual(claimedWhileCapturing, [false, false])
        XCTAssertTrue(center.jobsWaitingForCapture.isEmpty, "nothing waits once the capture stopped")
        XCTAssertTrue(center.jobs.isEmpty)
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
        guard await waitUntil("meeting 1's job", { center.jobs.count == 1 }) else { gate.release(); return }
        await center.startRecording(eventID: nil, title: "Two", config: config)
        gate.release()
        guard await waitUntil("meeting 2's live pass", { center.liveEngineState == .running }) else { return }
        let batchJob = try XCTUnwrap(center.jobs.first)

        // Meeting 2 stops with live text while meeting 3 starts on its tail.
        recorders[1].stopResult = RecordingResult(audioURL: try XCTUnwrap(recorders[1].lastStartURL),
                                                  durationSec: 1)
        recorders[1].emitLive([Float](repeating: 0, count: 1600))
        let stopTwo = Task { await center.stopAndProcess(config: config) }
        _ = await entered.next() // meeting 2's tail is parked in the engine
        guard await waitUntil("meeting 2's job", { center.jobs.count == 2 }) else { gate.release(); return }
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

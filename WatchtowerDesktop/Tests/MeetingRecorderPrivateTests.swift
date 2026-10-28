import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Private recordings (MEETPRIV, docs/features/private-meetings.md): the flag
/// travels from the start through the capture, the queue, crash recovery and
/// the save's `--private`.
@MainActor
final class MeetingRecorderPrivateTests: MeetingRecorderTestCase {

    private let privateEnvelope = Data((
        #"{"transcript_id":7,"recap_ok":false,"recap_error":"private recording: recap skipped","recap_skipped":true,"#
        + #""recap_skipped_reason":"private","chapters_ok":false,"chapters_skipped":true,"#
        + #""chapters_skipped_reason":"private"}"#).utf8)

    private func makeCenter(recorder: FakeRecorder = FakeRecorder(),
                            runner: CLIRunnerProtocol,
                            notifier: FakeNotifier = FakeNotifier(),
                            defaults: UserDefaults,
                            store: PendingTranscriptStore? = nil) -> MeetingRecorderCenter {
        MeetingRecorderCenter(
            pendingStore: store ?? pendingStore,
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["private talk"])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { runner },
            notifier: notifier,
            defaults: defaults,
            recordingsDirectory: recordingsDir
        )
    }

    private func config(privateByDefault: Bool) -> TranscriptionConfig {
        var config = singleWindowConfig()
        config.privateByDefault = privateByDefault
        return config
    }

    func testMeetPriv01_RecordPrivatelySavesWithPrivateFlagAndKeepsItInThePendingRow() async throws {
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio); removeSidecars(audio) }
        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 12)
        let runner = FakeCLIRunner(stdout: privateEnvelope)
        let notifier = FakeNotifier()
        let center = makeCenter(recorder: recorder, runner: runner, notifier: notifier, defaults: try isolatedDefaults())

        await center.startRecording(eventID: "evt-1", title: "1:1", isPrivate: true,
                                    config: config(privateByDefault: false))

        XCTAssertTrue(center.currentPrivate)
        XCTAssertEqual(pendingRow(try startedRecording())?.isPrivate, true, "a crash recovers the flag")
        await center.stopAndProcess(config: singleWindowConfig())

        XCTAssertEqual(center.phase, .idle)
        let args = try XCTUnwrap(runner.invocations.first)
        XCTAssertTrue(args.contains("--private"))
        XCTAssertEqual(notifier.readyTitles, ["1:1 — saved as private, no recap"])
    }

    func testPlainStartTakesTheSettingsDefault() async throws {
        let center = makeCenter(runner: FakeCLIRunner(stdout: recapOKEnvelope), defaults: try isolatedDefaults())

        await center.startRecording(eventID: nil, title: "Default on", config: config(privateByDefault: true))
        XCTAssertTrue(center.currentPrivate)
        XCTAssertEqual(pendingRow(try startedRecording())?.isPrivate, true)
    }

    func testPlainStartIsNotPrivateByDefault() async throws {
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio); removeSidecars(audio) }
        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 12)
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        let center = makeCenter(recorder: recorder, runner: runner, defaults: try isolatedDefaults())

        await center.startRecording(eventID: nil, title: "Regular", config: config(privateByDefault: false))
        XCTAssertFalse(center.currentPrivate)
        await center.stopAndProcess(config: singleWindowConfig())

        XCTAssertFalse(try XCTUnwrap(runner.invocations.first).contains("--private"))
    }

    /// The indicator's lock during capture: the flag in memory and in the
    /// pending row, and the job the Stop enqueues carries it.
    func testMeetPriv01_LockDuringCaptureReachesTheRowAndTheSave() async throws {
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio); removeSidecars(audio) }
        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 12)
        let runner = FakeCLIRunner(stdout: privateEnvelope)
        let center = makeCenter(recorder: recorder, runner: runner, defaults: try isolatedDefaults())

        await center.startRecording(eventID: nil, title: "Flip", config: config(privateByDefault: false))
        let started = try startedRecording()
        await center.setCapturePrivate(true)

        XCTAssertTrue(center.currentPrivate)
        XCTAssertEqual(pendingRow(started)?.isPrivate, true)
        await center.stopAndProcess(config: singleWindowConfig())
        XCTAssertTrue(try XCTUnwrap(runner.invocations.first).contains("--private"))
    }

    /// The lock stays live while Stop finalizes the file: a flip in that
    /// window reaches the saved job, on the success and the failure path.
    func testMeetPriv01_LockFlippedWhileStopFinalizesReachesTheJob() async throws {
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio); removeSidecars(audio) }
        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 12)
        let runner = FakeCLIRunner(stdout: privateEnvelope)
        let center = makeCenter(recorder: recorder, runner: runner, defaults: try isolatedDefaults())
        recorder.duringStop = { await center.setCapturePrivate(true) }

        await center.startRecording(eventID: nil, title: "Late lock", config: config(privateByDefault: false))
        await center.stopAndProcess(config: singleWindowConfig())

        XCTAssertTrue(try XCTUnwrap(runner.invocations.first).contains("--private"))
    }

    func testMeetPriv01_LockFlippedWhileAFailingStopFinalizesReachesTheFailedJob() async throws {
        let recorder = FakeRecorder()
        recorder.stopError = AudioRecordingError.deviceSetupFailed("device vanished")
        let center = makeCenter(recorder: recorder, runner: FakeCLIRunner(stdout: privateEnvelope),
                                defaults: try isolatedDefaults())
        recorder.duringStop = { await center.setCapturePrivate(true) }

        await center.startRecording(eventID: nil, title: "Late lock", config: config(privateByDefault: false))
        let started = try startedRecording()
        defer { removeSidecars(started) }
        await center.stopAndProcess(config: singleWindowConfig())

        XCTAssertEqual(center.jobs.map(\.isPrivate), [true])
    }

    func testSetCapturePrivateIsANoOpWhenNothingIsCaptured() async throws {
        let center = makeCenter(runner: FakeCLIRunner(stdout: recapOKEnvelope), defaults: try isolatedDefaults())
        await center.setCapturePrivate(true)
        XCTAssertFalse(center.currentPrivate)
    }

    /// A job waiting to be (re)saved — here a failed one, kept with its
    /// pending row — takes the lock, and its retry saves private.
    func testLockOnAQueuedJobReachesTheRowAndTheRetry() async throws {
        let recorder = FakeRecorder()
        recorder.stopError = AudioRecordingError.deviceSetupFailed("device vanished")
        let runner = FakeCLIRunner(stdout: privateEnvelope)
        let center = makeCenter(recorder: recorder, runner: runner, defaults: try isolatedDefaults())

        await center.startRecording(eventID: nil, title: "Later", config: config(privateByDefault: false))
        let started = try startedRecording()
        defer { removeSidecars(started) }
        await center.stopAndProcess(config: singleWindowConfig())
        let job = try XCTUnwrap(center.jobs.first)
        XCTAssertFalse(job.isPrivate)
        XCTAssertTrue(job.canChangePrivate)

        await center.setJobPrivate(job.id, true)
        XCTAssertEqual(center.jobs.first?.isPrivate, true)
        XCTAssertEqual(pendingRow(started)?.isPrivate, true)

        await center.retryTranscription(config: singleWindowConfig())
        XCTAssertTrue(try XCTUnwrap(runner.invocations.first).contains("--private"))
        XCTAssertEqual(runner.invocations.count, 1)
    }

    /// Once the save runs (`.summarizing`) the lock is fixed: the CLI already
    /// has the flag.
    func testLockIsRefusedOnceTheSaveStarted() async throws {
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio); removeSidecars(audio) }
        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 12)
        let runner = GatedSaveRunner(stdout: recapOKEnvelope)
        let center = makeCenter(recorder: recorder, runner: runner, defaults: try isolatedDefaults())

        await center.startRecording(eventID: nil, title: "Saving", config: config(privateByDefault: false))
        let started = try startedRecording()
        defer { removeSidecars(started) }
        // Stop awaits its job's save, which the runner holds.
        let stop = Task { await center.stopAndProcess(config: singleWindowConfig()) }
        await waitUntil { runner.isHoldingASave }
        let job = try XCTUnwrap(center.jobs.first)
        XCTAssertEqual(job.phase, .summarizing)
        XCTAssertFalse(job.canChangePrivate)

        await center.setJobPrivate(job.id, true)
        XCTAssertEqual(center.jobs.first?.isPrivate, false)
        XCTAssertEqual(pendingRow(started)?.isPrivate, false)
        runner.releaseAll()
        await stop.value
        XCTAssertTrue(center.jobs.isEmpty)
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met in \(timeout)s")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testMeetPriv01_CrashRecoveryKeepsTheFlag() async throws {
        let name = "rec_20261028_100000.caf"
        let audio = recordingsDir.appendingPathComponent(name)
        try Data([0x00]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio); removeSidecars(audio) }
        try await pendingStore.begin(recording: name, eventID: "evt-7", title: "Private 1:1", isPrivate: true,
                                     at: Date())
        let runner = FakeCLIRunner(stdout: privateEnvelope)
        let center = makeCenter(runner: runner, defaults: try isolatedDefaults())

        await center.restorePendingOnLaunch()
        XCTAssertEqual(center.recoverable.map(\.isPrivate), [true])
        await center.retryTranscription(config: singleWindowConfig())

        XCTAssertTrue(try XCTUnwrap(runner.invocations.first).contains("--private"))
    }

    /// A recording with no row (the database was not open at its start, or
    /// the start's row write failed) has no recorded choice: it recovers
    /// private whatever the Settings default (MEETPRIV fails closed), and
    /// the recovered pill's lock opens it before Transcribe.
    func testMeetPriv01_AudioOnlyRecoveryIsPrivateUntilTheOwnerOpensTheLock() async throws {
        let name = "rec_20261028_110000.caf"
        let audio = recordingsDir.appendingPathComponent(name)
        try Data([0x00]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio); removeSidecars(audio) }
        let defaults = try isolatedDefaults()
        defaults.set(false, forKey: TranscriptionConfig.privateByDefaultKey)
        // Past the one-time pass that tombstones an older build's audio.
        defaults.set(true, forKey: MeetingRecorderCenter.legacyAudioTombstonedKey)
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        let center = makeCenter(runner: runner, defaults: defaults)

        await center.restorePendingOnLaunch()
        XCTAssertEqual(center.recoverable.map(\.isPrivate), [true])

        await center.setRecoverablePrivate(audio, false)
        XCTAssertEqual(center.recoverable.map(\.isPrivate), [false])
        await center.retryTranscription(config: singleWindowConfig())
        XCTAssertFalse(try XCTUnwrap(runner.invocations.first).contains("--private"))
    }

    /// The recovered pill's lock on a recording with a row reaches the row,
    /// so a second crash keeps the owner's choice.
    func testLockOnARecoveredRecordingReachesItsRow() async throws {
        let name = "rec_20261028_120000.caf"
        let audio = recordingsDir.appendingPathComponent(name)
        try Data([0x00]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio); removeSidecars(audio) }
        try await pendingStore.begin(recording: name, eventID: nil, title: "Kept", isPrivate: false, at: Date())
        let runner = FakeCLIRunner(stdout: privateEnvelope)
        let center = makeCenter(runner: runner, defaults: try isolatedDefaults())

        await center.restorePendingOnLaunch()
        await center.setRecoverablePrivate(audio, true)

        XCTAssertEqual(pendingRow(audio)?.isPrivate, true)
        await center.retryTranscription(config: singleWindowConfig())
        XCTAssertTrue(try XCTUnwrap(runner.invocations.first).contains("--private"))
    }

    /// The pre-queue single-slot pointer recorded no private choice either.
    func testMeetPriv01_LegacyPendingPointerRecoversPrivate() async throws {
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio); removeSidecars(audio) }
        let defaults = try isolatedDefaults()
        defaults.set(audio.path, forKey: MeetingRecorderCenter.pendingAudioPathKey)
        let center = makeCenter(runner: FakeCLIRunner(stdout: privateEnvelope), defaults: defaults)

        await center.restorePendingOnLaunch()

        XCTAssertEqual(center.recoverable.first { $0.audioURL == audio }?.isPrivate, true)
        XCTAssertEqual(pendingRow(audio)?.isPrivate, true)
    }

    func testPrepareRetryOfAPrivateRecordingSavesPrivate() async throws {
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio); removeSidecars(audio) }
        let runner = FakeCLIRunner(stdout: privateEnvelope)
        let center = makeCenter(runner: runner, defaults: try isolatedDefaults())

        await center.prepareRetry(audioURL: audio, eventID: nil, title: "Redo", isPrivate: true)
        await center.retryTranscription(config: singleWindowConfig())

        XCTAssertTrue(try XCTUnwrap(runner.invocations.first).contains("--private"))
    }

    /// A row turned private while its save ran: the save's generators
    /// refused it (`recording <id> is private`) — the private notice, not
    /// "recap needs retry".
    func testRowTurnedPrivateMidSaveGetsThePrivateNotice() async throws {
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio); removeSidecars(audio) }
        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 12)
        let refused = FakeCLIRunner(stdout: Data(
            #"{"transcript_id":7,"recap_ok":false,"recap_error":"recording 7 is private","chapters_ok":false}"#.utf8))
        let notifier = FakeNotifier()
        let center = makeCenter(recorder: recorder, runner: refused, notifier: notifier, defaults: try isolatedDefaults())

        await center.startRecording(eventID: nil, title: "Flipped", config: config(privateByDefault: false))
        await center.stopAndProcess(config: singleWindowConfig())

        XCTAssertEqual(notifier.readyTitles, ["Flipped — saved as private, no recap"])
    }

    /// A failing Stop with the lock on, then the pill's dismiss: the
    /// recovered entry stays private and its retry saves `--private`.
    func testMeetPriv01_DismissedFailureStaysPrivate() async throws {
        let recorder = FakeRecorder()
        recorder.stopError = AudioRecordingError.deviceSetupFailed("device vanished")
        let runner = FakeCLIRunner(stdout: privateEnvelope)
        let center = makeCenter(recorder: recorder, runner: runner, defaults: try isolatedDefaults())

        await center.startRecording(eventID: nil, title: "Locked", isPrivate: true,
                                    config: config(privateByDefault: false))
        let started = try startedRecording()
        defer { removeSidecars(started) }
        await center.stopAndProcess(config: singleWindowConfig())
        XCTAssertEqual(center.jobs.map(\.isPrivate), [true])

        center.dismissFailure()
        XCTAssertEqual(center.recoverable.map(\.isPrivate), [true])
        await center.retryTranscription(config: singleWindowConfig())
        XCTAssertTrue(try XCTUnwrap(runner.invocations.first).contains("--private"))
    }

    /// MEETPRIV-01: a private recording whose start never wrote its row
    /// (`begin` failed) gets its row from the kept transcript, with the
    /// job's flag — so a failed save recovers private on relaunch.
    func testMeetPriv01_KeptTranscriptOfARowlessPrivateRecordingIsPrivate() async throws {
        let audio = recordingsDir.appendingPathComponent("rec_20261028_130000.caf")
        try Data([0x00, 0x01, 0x02]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio); removeSidecars(audio) }
        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 12)
        let failingSave = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "boom"))
        let center = makeCenter(recorder: recorder, runner: failingSave,
                                defaults: try isolatedDefaults(), store: BeginFailingPendingStore(base: pendingStore))

        await center.startRecording(eventID: nil, title: "No row", isPrivate: true,
                                    config: config(privateByDefault: false))
        XCTAssertEqual(try pendingStore.pending(), [], "the start wrote no row")
        await center.stopAndProcess(config: singleWindowConfig())

        let row = try XCTUnwrap(pendingRow(audio))
        XCTAssertNotNil(row.transcript)
        XCTAssertTrue(row.isPrivate)
        let relaunched = makeCenter(runner: FakeCLIRunner(stdout: privateEnvelope), defaults: try isolatedDefaults())
        await relaunched.restorePendingOnLaunch()
        XCTAssertEqual(relaunched.recoverable.first { $0.audioURL == audio }?.isPrivate, true)
    }
}

/// `begin` fails; every other write reaches the real store.
private final class BeginFailingPendingStore: PendingTranscriptStore, @unchecked Sendable {
    struct Failure: Error {}
    private let base: PendingTranscriptStore

    init(base: PendingTranscriptStore) { self.base = base }

    func begin(recording: String, eventID: String?, title: String?, isPrivate: Bool, at: Date) async throws {
        throw Failure()
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
    func transcript(recording: String) throws -> PendingTranscript? { try base.transcript(recording: recording) }
    func remove(recording: String) async throws { try await base.remove(recording: recording) }
    func savedAudioPaths() throws -> Set<String> { try base.savedAudioPaths() }
}

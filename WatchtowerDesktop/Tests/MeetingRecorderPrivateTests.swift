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

    private let privateEnvelope = Data(
        #"{"transcript_id":7,"recap_ok":false,"recap_error":"","recap_skipped":"private"}"#.utf8)

    private func makeCenter(recorder: FakeRecorder = FakeRecorder(),
                            runner: FakeCLIRunner,
                            notifier: FakeNotifier = FakeNotifier(),
                            defaults: UserDefaults) -> MeetingRecorderCenter {
        MeetingRecorderCenter(
            pendingStore: pendingStore,
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

    func testRecordPrivatelySavesWithPrivateFlagAndKeepsItInThePendingRow() async throws {
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
    func testLockDuringCaptureReachesTheRowAndTheSave() async throws {
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

    func testCrashRecoveryKeepsTheFlag() async throws {
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

    /// A recording with no row (the database was not open at its start) has
    /// no recorded choice: it recovers with the Settings default.
    func testAudioOnlyRecoveryTakesTheSettingsDefault() async throws {
        let name = "rec_20261028_110000.caf"
        let audio = recordingsDir.appendingPathComponent(name)
        try Data([0x00]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio); removeSidecars(audio) }

        for privateByDefault in [false, true] {
            let defaults = try isolatedDefaults()
            defaults.set(privateByDefault, forKey: TranscriptionConfig.privateByDefaultKey)
            // Past the one-time pass that tombstones an older build's audio.
            defaults.set(true, forKey: MeetingRecorderCenter.legacyAudioTombstonedKey)
            let center = makeCenter(runner: FakeCLIRunner(stdout: recapOKEnvelope), defaults: defaults)
            await center.restorePendingOnLaunch()
            XCTAssertEqual(center.recoverable.map(\.isPrivate), [privateByDefault])
        }
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
}

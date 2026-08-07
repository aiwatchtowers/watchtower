import XCTest
import AppKit
@testable import WatchtowerDesktop

@MainActor
final class QuitCoordinatorTests: XCTestCase {
    func testIdleSkipsConfirmAndTerminatesLater() async {
        var confirmAsked = false
        let stopped = expectation(description: "daemon stopped")
        let replied = expectation(description: "replied true")
        let reply = QuitCoordinator.shouldTerminate(
            hasBlockingWork: false,
            confirmQuit: { confirmAsked = true; return true },
            stopDaemon: { stopped.fulfill() },
            reply: { ok in XCTAssertTrue(ok); replied.fulfill() })
        XCTAssertEqual(reply, .terminateLater)
        XCTAssertFalse(confirmAsked)
        await fulfillment(of: [stopped, replied], timeout: 5)
    }

    func testBlockingWorkCancelBlocksQuitWithoutStopping() {
        var stoppedCalled = false
        let reply = QuitCoordinator.shouldTerminate(
            hasBlockingWork: true,
            confirmQuit: { false },
            stopDaemon: { stoppedCalled = true },
            reply: { _ in XCTFail("must not reply when quit is cancelled") })
        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertFalse(stoppedCalled)
    }

    func testBlockingWorkConfirmedProceeds() async {
        let replied = expectation(description: "replied")
        let reply = QuitCoordinator.shouldTerminate(
            hasBlockingWork: true,
            confirmQuit: { true },
            stopDaemon: {},
            reply: { ok in XCTAssertTrue(ok); replied.fulfill() })
        XCTAssertEqual(reply, .terminateLater)
        await fulfillment(of: [replied], timeout: 5)
    }

}

/// The quit gate widened from "capturing" to `MeetingRecorderCenter.isBusy`:
/// capture can be finished while the transcription job it produced is still in
/// the queue, and quitting then throws that run away. Driven against a real
/// Center (gated engine) rather than a hand-made flag, so the test would fail
/// if `isBusy` ever stopped covering the post-capture queue.
final class QuitGateBlockingWorkTests: MeetingRecorderTestCase {
    func testQueuedJobAfterCaptureEndsStillRequiresConfirmation() async throws {
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 1)
        let gate = GateEngine(texts: ["still transcribing"])
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(gate) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { FakeCLIRunner(stdout: self.recapOKEnvelope) },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let config = singleWindowConfig()

        await center.startRecording(eventID: nil, title: "Ad hoc", config: config)
        let stopping = Task { await center.stopAndProcess(config: config) }
        // The job is now parked inside the gated engine: capture is over, the
        // transcription is not.
        var entered = gate.enteredStream.makeAsyncIterator()
        _ = await entered.next()

        XCTAssertFalse(center.isCapturing, "capture has finished")
        XCTAssertTrue(center.isBusy, "the transcription job is still in the queue")

        var confirmAsked = false
        let reply = QuitCoordinator.shouldTerminate(
            hasBlockingWork: center.isBusy,
            confirmQuit: { confirmAsked = true; return false },
            stopDaemon: { XCTFail("a cancelled quit must not stop the daemon") },
            reply: { _ in XCTFail("a cancelled quit must not reply") })
        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertTrue(confirmAsked, "a pending transcription must not be quit away silently")

        gate.release()
        await stopping.value
    }
}

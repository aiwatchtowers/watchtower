import XCTest
import AppKit
@testable import WatchtowerDesktop
import WatchtowerTestSupport

@MainActor
final class QuitCoordinatorTests: XCTestCase {
    func testIdleSkipsConfirmAndTerminatesLater() async {
        var confirmAsked = false
        let stopped = expectation(description: "daemon stopped")
        let replied = expectation(description: "replied true")
        let reply = QuitCoordinator.shouldTerminate(
            hasBlockingWork: false,
            confirmQuit: { confirmAsked = true; return .quitStoppingSessions },
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
            confirmQuit: { .cancel },
            stopDaemon: { stoppedCalled = true },
            reply: { _ in XCTFail("must not reply when quit is cancelled") })
        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertFalse(stoppedCalled)
    }

    func testBlockingWorkConfirmedProceeds() async {
        let replied = expectation(description: "replied")
        let reply = QuitCoordinator.shouldTerminate(
            hasBlockingWork: true,
            confirmQuit: { .quitStoppingSessions },
            stopDaemon: {},
            reply: { ok in XCTAssertTrue(ok); replied.fulfill() })
        XCTAssertEqual(reply, .terminateLater)
        await fulfillment(of: [replied], timeout: 5)
    }

    /// CHAT-03: no chat session process outlives the app, and they are closed
    /// BEFORE the daemon stop (each keeps its partial text, CHAT-01).
    /// BEHAVIOR CHAT-03 — see docs/inventory/chat.md
    func testChat03QuitClosesChatSessionsBeforeStoppingTheDaemon() async {
        var order: [String] = []
        let replied = expectation(description: "replied")
        let reply = QuitCoordinator.shouldTerminate(
            hasBlockingWork: false,
            confirmQuit: { .quitStoppingSessions },
            closeChatSessions: { order.append("chat") },
            stopDaemon: { order.append("daemon") },
            reply: { ok in XCTAssertTrue(ok); replied.fulfill() })
        XCTAssertEqual(reply, .terminateLater)
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(order, ["chat", "daemon"])
    }

    func testCancelledQuitLeavesChatSessionsRunning() {
        var closed = false
        let reply = QuitCoordinator.shouldTerminate(
            hasBlockingWork: true,
            confirmQuit: { .cancel },
            closeChatSessions: { closed = true },
            stopDaemon: {},
            reply: { _ in XCTFail("must not reply") })
        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertFalse(closed)
    }

    /// Every embedded project terminal is closed on quit — after the chat
    /// sessions, before the daemon stop — so no `claude` outlives the app.
    func testQuitClosesTerminalsBeforeStoppingTheDaemon() async {
        var order: [String] = []
        let replied = expectation(description: "replied")
        let reply = QuitCoordinator.shouldTerminate(
            hasBlockingWork: false,
            confirmQuit: { .quitStoppingSessions },
            closeChatSessions: { order.append("chat") },
            closeTerminals: { order.append("terminals") },
            stopDaemon: { order.append("daemon") },
            reply: { ok in XCTAssertTrue(ok); replied.fulfill() })
        XCTAssertEqual(reply, .terminateLater)
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(order, ["chat", "terminals", "daemon"])
    }

    /// Runs one quit with `choice` from the prompt; returns the steps taken,
    /// in order, or nil when the quit was cancelled.
    private func quit(choosing choice: QuitChoice) async -> [String]? {
        var order: [String] = []
        let replied = expectation(description: "replied")
        let reply = QuitCoordinator.shouldTerminate(
            hasBlockingWork: true,
            confirmQuit: { choice },
            closeChatSessions: { order.append("chat") },
            closeTerminals: { order.append("close") },
            detachTerminals: { order.append("detach") },
            stopDaemon: { order.append("daemon") },
            reply: { ok in XCTAssertTrue(ok); replied.fulfill() })
        guard reply == .terminateLater else {
            XCTAssertEqual(reply, .terminateCancel)
            replied.isInverted = true
            await fulfillment(of: [replied], timeout: 0.1) // a cancelled quit never replies
            return nil
        }
        await fulfillment(of: [replied], timeout: 5)
        return order
    }

    /// Keep Sessions and Quit leaves the hosted sessions running: they are
    /// detached, never closed; chat sessions still close first and the
    /// daemon still stops last (CHAT-03).
    func testKeepSessionsChoiceDetaches() async {
        let order = await quit(choosing: .quitKeepingSessions)
        XCTAssertEqual(order, ["chat", "detach", "daemon"])
    }

    func testStopSessionsChoiceCloses() async {
        let order = await quit(choosing: .quitStoppingSessions)
        XCTAssertEqual(order, ["chat", "close", "daemon"])
    }

    func testCancelChoiceCancels() {
        let reply = QuitCoordinator.shouldTerminate(
            hasBlockingWork: true,
            confirmQuit: { .cancel },
            closeChatSessions: { XCTFail("a cancelled quit closes nothing") },
            closeTerminals: { XCTFail("a cancelled quit closes nothing") },
            detachTerminals: { XCTFail("a cancelled quit detaches nothing") },
            stopDaemon: { XCTFail("a cancelled quit stops nothing") },
            reply: { _ in XCTFail("must not reply") })
        XCTAssertEqual(reply, .terminateCancel)
    }

    /// Board #588 (PROJ-17): the Undo batch's deletes run alongside the
    /// other quit steps — the daemon stop here waits until they started, so
    /// a serial run would never reply — and the reply waits for them; on a
    /// quit that keeps the sessions (Keep Sessions and Quit, an update's
    /// relaunch) as on one that stops them.
    func testPendingDeletesRunAlongsideTheQuitAndBeforeTheReply() async {
        for keeps in [false, true] {
            var order: [String] = []
            let (started, didStart) = AsyncStream<Void>.makeStream()
            let (finish, letFinish) = AsyncStream<Void>.makeStream()
            let replied = expectation(description: "replied")
            _ = QuitCoordinator.shouldTerminate(
                hasBlockingWork: false,
                confirmQuit: { .cancel },
                keepsSessions: keeps,
                closeTerminals: { order.append("close") },
                detachTerminals: { order.append("detach") },
                stopDaemon: {
                    var iterator = started.makeAsyncIterator()
                    _ = await iterator.next()
                    order.append("daemon")
                    letFinish.yield()
                },
                finishPendingDeletes: {
                    didStart.yield()
                    var iterator = finish.makeAsyncIterator()
                    _ = await iterator.next()
                    order.append("deletes")
                },
                reply: { _ in order.append("reply"); replied.fulfill() })
            await fulfillment(of: [replied], timeout: 5)
            XCTAssertEqual(order, [keeps ? "detach" : "close", "daemon", "deletes", "reply"])
        }
    }

    /// Unasked, a quit that keeps sessions (an update, a logout) detaches.
    func testUnaskedQuitThatKeepsSessionsDetaches() async {
        var order: [String] = []
        let replied = expectation(description: "replied")
        _ = QuitCoordinator.shouldTerminate(
            hasBlockingWork: false,
            confirmQuit: { XCTFail("nothing to ask"); return .cancel },
            keepsSessions: true,
            closeTerminals: { order.append("close") },
            detachTerminals: { order.append("detach") },
            stopDaemon: { order.append("daemon") },
            reply: { _ in replied.fulfill() })
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(order, ["detach", "daemon"])
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
            confirmQuit: { confirmAsked = true; return .cancel },
            stopDaemon: { XCTFail("a cancelled quit must not stop the daemon") },
            reply: { _ in XCTFail("a cancelled quit must not reply") })
        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertTrue(confirmAsked, "a pending transcription must not be quit away silently")

        gate.release()
        await stopping.value
    }
}

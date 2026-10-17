import XCTest
import AppKit
@testable import WatchtowerDesktop

@MainActor
final class TrayAppDelegateTerminateTests: XCTestCase {
    /// A SingleInstanceGuard duplicate must quit instantly and must never
    /// touch the survivor's daemon — the gate, not just the coordinator
    /// behind it, is the load-bearing part.
    func testDuplicateInstanceTerminatesNowWithoutStoppingTheDaemon() {
        var stopped = false
        var confirmed = false
        let reply = TrayAppDelegate.terminateDecision(
            managesLifecycle: false,
            hasBlockingWork: true,
            confirmQuit: { confirmed = true; return .quitStoppingSessions },
            stopDaemon: { stopped = true },
            reply: { _ in XCTFail("terminateNow replies through the return value, not the seam") }
        )
        XCTAssertEqual(reply, .terminateNow)
        XCTAssertFalse(stopped, "a duplicate must never stop the survivor's daemon")
        XCTAssertFalse(confirmed)
    }

    func testSurvivorDelegatesToQuitCoordinator() async {
        let stopped = expectation(description: "daemon stopped")
        let replied = expectation(description: "replied")
        let reply = TrayAppDelegate.terminateDecision(
            managesLifecycle: true,
            hasBlockingWork: false,
            confirmQuit: { XCTFail("nothing in flight, nothing to confirm"); return .quitStoppingSessions },
            stopDaemon: { stopped.fulfill() },
            reply: { ok in XCTAssertTrue(ok); replied.fulfill() }
        )
        XCTAssertEqual(reply, .terminateLater)
        await fulfillment(of: [stopped, replied], timeout: 5)
    }

    func testSurvivorHonoursCancelledConfirmation() {
        var stopped = false
        let reply = TrayAppDelegate.terminateDecision(
            managesLifecycle: true,
            hasBlockingWork: true,
            confirmQuit: { .cancel },
            stopDaemon: { stopped = true },
            reply: { _ in XCTFail("must not reply when quit is cancelled") }
        )
        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertFalse(stopped)
    }

    /// Unsent ask answers live in memory only (spec 2026-10-03 Part 8):
    /// quitting with any asks first; with nothing to lose it does not.
    func testQuittingWithAskDraftsAsksFirst() {
        XCTAssertNil(TrayAppDelegate.quitPrompt(recording: false, askDrafts: 0), "nothing to lose, nothing to ask")

        let one = TrayAppDelegate.quitPrompt(recording: false, askDrafts: 1)
        XCTAssertEqual(one?.message, "You have 1 unsent ask answer")
        XCTAssertEqual(one?.quitTitle, "Quit")
        XCTAssertEqual(TrayAppDelegate.quitPrompt(recording: false, askDrafts: 2)?.message, "You have 2 unsent ask answers")

        let both = TrayAppDelegate.quitPrompt(recording: true, askDrafts: 2)
        XCTAssertEqual(both?.quitTitle, "Stop & Quit")
        XCTAssertTrue(both?.informative.hasSuffix(" Your 2 unsent ask answers will be lost.") == true)
        XCTAssertEqual(TrayAppDelegate.quitPrompt(recording: true, askDrafts: 0)?.informative.contains("ask"), false)

        var confirmed = false
        let reply = TrayAppDelegate.terminateDecision(
            managesLifecycle: true,
            hasBlockingWork: one != nil,
            confirmQuit: { confirmed = true; return .cancel },
            stopDaemon: { XCTFail("a cancelled quit stops nothing") },
            reply: { _ in XCTFail("must not reply when quit is cancelled") }
        )
        XCTAssertTrue(confirmed, "drafts make the quit ask first")
        XCTAssertEqual(reply, .terminateCancel)
    }

    func testTerminateDecisionClosesChatSessionsWhenManagingLifecycle() async {
        var closed = false
        let replied = expectation(description: "replied")
        _ = TrayAppDelegate.terminateDecision(
            managesLifecycle: true, hasBlockingWork: false, confirmQuit: { .quitStoppingSessions },
            closeChatSessions: { closed = true }, stopDaemon: {}, reply: { _ in replied.fulfill() })
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertTrue(closed)
    }

    /// Runs `plan` through the terminate decision, choosing `button` if it
    /// asks; returns the steps taken in order, or nil when cancelled.
    private func run(_ plan: TrayAppDelegate.QuitPlan, button: Int? = nil) async -> [String]? {
        var order: [String] = []
        let replied = expectation(description: "replied")
        let reply = TrayAppDelegate.terminateDecision(
            managesLifecycle: true,
            hasBlockingWork: plan.prompt != nil,
            keepsSessions: plan.keepsSessions,
            confirmQuit: {
                order.append("prompt")
                guard let button else { XCTFail("this quit must not ask"); return .cancel }
                return plan.choice(button: button)
            },
            closeChatSessions: { order.append("chat") },
            closeTerminals: { order.append("close") },
            detachTerminals: { order.append("detach") },
            stopDaemon: { order.append("daemon") },
            reply: { ok in XCTAssertTrue(ok); replied.fulfill() }
        )
        guard reply == .terminateLater else {
            XCTAssertEqual(reply, .terminateCancel)
            replied.isInverted = true
            await fulfillment(of: [replied], timeout: 0.1) // a cancelled quit never replies
            return nil
        }
        await fulfillment(of: [replied], timeout: 5)
        return order
    }

    /// An update's quit never asks about sessions: with hosted sessions
    /// live it detaches them (they keep running in the session host for
    /// the relaunched app to reattach) and never closes them.
    /// BEHAVIOR PROJ-20 — see docs/inventory/workbench.md
    func testProj20_UpdateQuitDetachesHostedSessions() async {
        let plan = TrayAppDelegate.quitPlan(
            forUpdate: true, quitReason: nil, recording: false, askDrafts: 0, liveSessions: 3
        )
        XCTAssertNil(plan.prompt, "an update never asks about sessions")
        XCTAssertTrue(plan.keepsSessions)
        let order = await run(plan)
        XCTAssertEqual(order, ["chat", "detach", "daemon"], "detached, never closed; no prompt")

        // A recording still asks during an update, without the session
        // buttons — and its Quit still keeps the sessions.
        let recording = TrayAppDelegate.quitPlan(
            forUpdate: true, quitReason: nil, recording: true, askDrafts: 0, liveSessions: 3
        )
        XCTAssertNil(recording.prompt?.keepSessionsTitle)
        XCTAssertEqual(recording.prompt?.buttons, ["Stop & Quit", "Cancel"])
        XCTAssertEqual(recording.prompt?.informative.contains("workbench session"), false)
        let recordingOrder = await run(recording, button: 0)
        XCTAssertEqual(recordingOrder, ["prompt", "chat", "detach", "daemon"])
    }

    private func plainQuit(
        liveSessions: Int, recording: Bool = false, askDrafts: Int = 0, unprotectedSessions: Int = 0
    ) -> TrayAppDelegate.QuitPlan {
        TrayAppDelegate.quitPlan(
            forUpdate: false, quitReason: nil, recording: recording, askDrafts: askDrafts,
            liveSessions: liveSessions, unprotectedSessions: unprotectedSessions
        )
    }

    func testKeepSessionsChoiceDetaches() async {
        let plan = plainQuit(liveSessions: 2)
        XCTAssertFalse(plan.keepsSessions)
        XCTAssertEqual(plan.prompt?.message, "2 workbench sessions are running")
        XCTAssertEqual(plan.prompt?.informative,
                       "Keep them running and Watchtower reattaches when you open it again, or stop them now.")
        XCTAssertEqual(plan.prompt?.buttons, ["Keep Sessions and Quit", "Stop Sessions and Quit", "Cancel"])
        let order = await run(plan, button: 0)
        XCTAssertEqual(order, ["prompt", "chat", "detach", "daemon"])
    }

    func testStopSessionsChoiceCloses() async {
        let order = await run(plainQuit(liveSessions: 1), button: 1)
        XCTAssertEqual(order, ["prompt", "chat", "close", "daemon"])
        XCTAssertEqual(plainQuit(liveSessions: 1).prompt?.message, "1 workbench session is running")
    }

    func testCancelChoiceCancels() async {
        let plan = plainQuit(liveSessions: 2)
        let order = await run(plan, button: 2)
        XCTAssertNil(order, "Cancel stops the quit")
        XCTAssertEqual(plan.choice(button: 2), .cancel)
    }

    /// No live hosted session: nothing about sessions is asked and the quit
    /// stops whatever runs (local fallback sessions included), as before.
    func testNoLiveSessionsQuitsWithoutSessionPrompt() async {
        let plan = plainQuit(liveSessions: 0)
        XCTAssertNil(plan.prompt)
        XCTAssertFalse(plan.keepsSessions)
        let order = await run(plan)
        XCTAssertEqual(order, ["chat", "close", "daemon"])

        let drafts = plainQuit(liveSessions: 0, askDrafts: 1)
        XCTAssertNil(drafts.prompt?.keepSessionsTitle)
        XCTAssertEqual(drafts.prompt?.buttons, ["Quit", "Cancel"])
        XCTAssertEqual(drafts.choice(button: 0), .quitStoppingSessions)
    }

    /// One alert for everything live: the recording's and the drafts' text
    /// stay, the sessions' text is added, and it has three buttons.
    func testQuitPromptCombinesRecordingAndSessions() throws {
        let prompt = try XCTUnwrap(TrayAppDelegate.quitPrompt(recording: true, askDrafts: 2, liveSessions: 2))
        XCTAssertEqual(prompt.message, "A recording or transcription is in progress")
        XCTAssertTrue(prompt.informative.hasPrefix("Quitting stops the capture and drops any transcription still running."))
        XCTAssertTrue(prompt.informative.contains(" Your 2 unsent ask answers will be lost."))
        XCTAssertTrue(prompt.informative.hasSuffix(" 2 workbench sessions are running. "
            + "Keep them running and Watchtower reattaches when you open it again, or stop them now."))
        XCTAssertEqual(prompt.buttons, ["Keep Sessions and Quit", "Stop Sessions and Quit", "Cancel"])

        let drafts = try XCTUnwrap(TrayAppDelegate.quitPrompt(recording: false, askDrafts: 1, liveSessions: 1))
        XCTAssertEqual(drafts.message, "You have 1 unsent ask answer")
        XCTAssertTrue(drafts.informative.hasSuffix(" 1 workbench session is running. "
            + "Keep it running and Watchtower reattaches when you open it again, or stop it now."))
        XCTAssertEqual(drafts.keepSessionsTitle, "Keep Sessions and Quit")
        XCTAssertEqual(drafts.quitTitle, "Stop Sessions and Quit")
    }

    /// Local-fallback sessions stop on any quit, Keep included: the prompt
    /// says so instead of keeping quiet about them.
    func testQuitPromptNamesUnprotectedSessionsThatStop() throws {
        let one = try XCTUnwrap(plainQuit(liveSessions: 2, unprotectedSessions: 1).prompt)
        XCTAssertEqual(one.informative, "Keep them running and Watchtower reattaches when you open it again, "
            + "or stop them now. 1 unprotected session will stop.")
        let three = try XCTUnwrap(TrayAppDelegate.quitPrompt(
            recording: true, askDrafts: 0, liveSessions: 1, unprotectedSessions: 3))
        XCTAssertTrue(three.informative.hasSuffix(" or stop it now. 3 unprotected sessions will stop."))
        // Without hosted sessions there is no Keep choice to qualify.
        XCTAssertNil(plainQuit(liveSessions: 0, unprotectedSessions: 2).prompt,
                     "local sessions alone stop as before, unasked")
        let drafts = try XCTUnwrap(plainQuit(liveSessions: 0, askDrafts: 1, unprotectedSessions: 2).prompt)
        XCTAssertFalse(drafts.informative.contains("unprotected"))
    }

    /// Removing all data quits stopping every session: no Keep button, and
    /// the hosted sessions are closed, never detached.
    func testStoppingSessionsQuitNeverOffersKeep() async {
        let plan = TrayAppDelegate.quitPlan(
            forUpdate: false, stopsSessions: true, quitReason: nil, recording: false, askDrafts: 0, liveSessions: 2
        )
        XCTAssertNil(plan.prompt)
        XCTAssertFalse(plan.keepsSessions)
        let order = await run(plan)
        XCTAssertEqual(order, ["chat", "close", "daemon"])

        let recording = TrayAppDelegate.quitPlan(
            forUpdate: false, stopsSessions: true, quitReason: OSType(kAEShutDown),
            recording: true, askDrafts: 0, liveSessions: 2
        )
        XCTAssertNil(recording.prompt?.keepSessionsTitle)
        XCTAssertEqual(recording.choice(button: 0), .quitStoppingSessions)
    }

    /// A logout, restart or shutdown never asks about sessions and leaves
    /// them to the system (detached); any other quit reason asks.
    func testSystemLogoutNeverPrompts() async {
        let reasons = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown]
        for reason in reasons {
            let plan = TrayAppDelegate.quitPlan(
                forUpdate: false, quitReason: OSType(reason), recording: false, askDrafts: 0, liveSessions: 2
            )
            XCTAssertNil(plan.prompt, "reason \(reason) must not ask")
            XCTAssertTrue(plan.keepsSessions)
        }
        let logout = TrayAppDelegate.quitPlan(
            forUpdate: false, quitReason: OSType(kAEReallyLogOut), recording: false, askDrafts: 0, liveSessions: 2
        )
        let order = await run(logout)
        XCTAssertEqual(order, ["chat", "detach", "daemon"])

        let other = TrayAppDelegate.quitPlan(
            forUpdate: false, quitReason: OSType(kAEQuitApplication), recording: false, askDrafts: 0, liveSessions: 2
        )
        XCTAssertEqual(other.prompt?.keepSessionsTitle, "Keep Sessions and Quit", "a user quit asks")
    }
}

final class TrayAppDelegateLoginItemTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "TrayAppDelegateLoginItemTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private struct RegisterFailure: Error {}

    func testRegistersExactlyOncePerBundle() {
        var registrations = 0
        for _ in 0..<3 {
            TrayAppDelegate.registerLoginItem(
                bundlePath: "/Applications/Watchtower.app",
                defaults: defaults
            ) { registrations += 1 }
        }
        XCTAssertEqual(registrations, 1, "re-registering would re-enable an item the user disabled")
        XCTAssertEqual(
            defaults.string(forKey: TrayAppDelegate.loginItemRegisteredPathKey),
            "/Applications/Watchtower.app"
        )
    }

    /// The latch is keyed to the bundle it registered: a worktree dev build
    /// that registered itself must not block the real install from ever
    /// registering.
    func testDifferentBundlePathRegistersAgain() {
        var registered: [String] = []
        TrayAppDelegate.registerLoginItem(
            bundlePath: "/tmp/worktree/Watchtower.app",
            defaults: defaults
        ) { registered.append("/tmp/worktree/Watchtower.app") }
        TrayAppDelegate.registerLoginItem(
            bundlePath: "/Applications/Watchtower.app",
            defaults: defaults
        ) { registered.append("/Applications/Watchtower.app") }
        XCTAssertEqual(registered, ["/tmp/worktree/Watchtower.app", "/Applications/Watchtower.app"])
        XCTAssertEqual(
            defaults.string(forKey: TrayAppDelegate.loginItemRegisteredPathKey),
            "/Applications/Watchtower.app"
        )
    }

    func testFailedRegistrationDoesNotLatch() {
        var attempts = 0
        TrayAppDelegate.registerLoginItem(
            bundlePath: "/Applications/Watchtower.app",
            defaults: defaults
        ) {
            attempts += 1
            throw RegisterFailure()
        }
        XCTAssertNil(defaults.string(forKey: TrayAppDelegate.loginItemRegisteredPathKey))

        TrayAppDelegate.registerLoginItem(
            bundlePath: "/Applications/Watchtower.app",
            defaults: defaults
        ) { attempts += 1 }
        XCTAssertEqual(attempts, 2, "a failure must leave the retry open for the next launch")
        XCTAssertEqual(
            defaults.string(forKey: TrayAppDelegate.loginItemRegisteredPathKey),
            "/Applications/Watchtower.app"
        )
    }
}

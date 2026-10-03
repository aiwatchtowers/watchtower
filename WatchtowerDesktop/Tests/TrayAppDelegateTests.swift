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
            confirmQuit: { confirmed = true; return true },
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
            confirmQuit: { XCTFail("nothing in flight, nothing to confirm"); return true },
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
            confirmQuit: { false },
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
            confirmQuit: { confirmed = true; return false },
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
            managesLifecycle: true, hasBlockingWork: false, confirmQuit: { true },
            closeChatSessions: { closed = true }, stopDaemon: {}, reply: { _ in replied.fulfill() })
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertTrue(closed)
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

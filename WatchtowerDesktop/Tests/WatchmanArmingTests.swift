import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Answers `watchman status` with the current status JSON and `watchman
/// arm|disarm` with a scripted reply per call shape (`arm --check`, `arm`,
/// `disarm`); records every call.
private final class ArmingRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    private var statusJSON: String
    private var replies: [String: CLICapturedResult] = [:]
    private var statusError: Error?

    init(status: String) { statusJSON = status }

    var invocations: [[String]] { lock.withLock { calls } }
    /// The arm/disarm calls only, without the status reads.
    var verbs: [[String]] { invocations.filter { $0.dropFirst().first != "status" } }
    func setStatus(_ json: String) { lock.withLock { statusJSON = json; statusError = nil } }
    func failStatus(_ error: Error) { lock.withLock { statusError = error } }

    /// `key`: "check", "arm" or "disarm".
    func reply(_ key: String, _ json: String, exitCode: Int32 = 0, stderr: String = "") {
        lock.withLock { replies[key] = CLICapturedResult(stdout: Data(json.utf8), exitCode: exitCode, stderr: stderr) }
    }

    func run(args: [String]) async throws -> Data {
        try lock.withLock {
            calls.append(args)
            if let statusError { throw statusError }
            return Data(statusJSON.utf8)
        }
    }

    func capture(args: [String], timeout: TimeInterval) async throws -> CLICapturedResult {
        lock.withLock {
            calls.append(args)
            let key = args.contains("--check") ? "check" : args[1]
            return replies[key] ?? CLICapturedResult(stdout: Data(#"{"ok":true}"#.utf8), exitCode: 0)
        }
    }
}

@MainActor
final class WatchmanArmingTests: XCTestCase {
    private typealias Copy = WatchmanArmingCopy

    private static let unarmed = #"{"ok":true,"workbenches":[],"mode":"off","mode_since":null,"armed":[],"armed_sessions":[],"daemon_running":true}"#
    private static let sessionArmed = #"""
        {"ok":true,"workbenches":[],"mode":"sleep","mode_since":"2026-11-17T01:40:00Z",
         "armed":[{"scope":"session","id":5,"armed_at":"2026-11-17T01:40:00Z"}],
         "armed_sessions":[{"id":5,"target":0,"armed_at":"2026-11-17T01:40:00Z"}],
         "daemon_running":true}
        """#
    private static let firstTimeCheck = #"""
        {"ok":true,"armed":[],"first_time":true,"analytics_turned_on":false,"learning_started":false,
         "estimate":{"decisions":1850,"need_labels":1200,"tokens":1600000},"protection_warning":"","hooks_warning":"",
         "sidecar_error":"","error":""}
        """#

    private func center(_ runner: ArmingRunner) async -> WatchmanCenter {
        let center = WatchmanCenter(runner: runner)
        await center.load()
        return center
    }

    /// A workbench not learned: the sheet shows the estimate, the D21 line
    /// and the parked-while-learning note; its Hand to Watchman calls
    /// `watchman arm` once, which turns analytics and learning on.
    func testFirstArmSheetShowsAnalyticsLineAndStartsLearning() async throws {
        let runner = ArmingRunner(status: Self.unarmed)
        runner.reply("check", Self.firstTimeCheck)
        runner.reply("arm", #"""
            {"ok":true,"armed":[{"scope":"session","id":5,"armed_at":"2026-11-17T01:40:00Z"}],"first_time":true,
             "analytics_turned_on":true,"learning_started":true,"protection_warning":"","hooks_warning":"",
             "sidecar_error":"","error":""}
            """#)
        let center = await center(runner)

        await center.handTo(.session(5), workbench: "acme-api")
        XCTAssertEqual(runner.verbs, [["watchman", "arm", "--session", "5", "--check", "--json"]])
        let sheet = try XCTUnwrap(center.sheet)
        XCTAssertEqual(sheet.scope, .session(5))
        XCTAssertEqual(sheet.content.title, "Hand acme-api to Watchman?")
        let lines = sheet.content.lines.map(\.text)
        XCTAssertTrue(lines.contains(Copy.analyticsLine))
        XCTAssertTrue(lines.contains("Learning from your history: ~1 850 decisions, est. 1.6 M tokens"))
        XCTAssertTrue(lines.contains("Until learning finishes, Watchman parks everything for you"))
        XCTAssertEqual(sheet.content.confirm, "Hand to Watchman")

        runner.setStatus(Self.sessionArmed)
        await center.confirmSheet()
        XCTAssertNil(center.sheet)
        XCTAssertEqual(runner.verbs.filter { !$0.contains("--check") }, [["watchman", "arm", "--session", "5", "--json"]])
        XCTAssertEqual(WatchmanArmControl.arming(.session(5), in: center.lastStatus), .armed)
        // The reply's D21 line stays visible under the control.
        XCTAssertEqual(center.armNotices[.session(5)], Copy.analyticsLine)
    }

    func testArmCallsCLIThenReloads() async throws {
        let runner = ArmingRunner(status: Self.unarmed)
        runner.reply("check", #"{"ok":true,"armed":[],"first_time":false,"estimate":null,"protection_warning":"","hooks_warning":""}"#)
        let center = await center(runner)
        XCTAssertEqual(WatchmanArmControl.arming(.session(5), in: center.lastStatus), .unarmed)

        runner.setStatus(Self.sessionArmed)
        await center.handTo(.session(5), workbench: "acme-api")
        XCTAssertNil(center.sheet, "a learned workbench without warnings arms at once")
        XCTAssertEqual(Array(runner.invocations.suffix(3)), [
            ["watchman", "arm", "--session", "5", "--check", "--json"],
            ["watchman", "arm", "--session", "5", "--json"],
            ["watchman", "status", "--json"]
        ])
        XCTAssertEqual(WatchmanArmControl.arming(.session(5), in: center.lastStatus), .armed)
        XCTAssertEqual(center.lastStatus?.mode, .sleep)

        // Take back: disarm, then the status again.
        runner.setStatus(Self.unarmed)
        await center.disarm(.session(5))
        XCTAssertEqual(Array(runner.invocations.suffix(2)), [
            ["watchman", "disarm", "--session", "5", "--json"],
            ["watchman", "status", "--json"]
        ])
        XCTAssertEqual(WatchmanArmControl.arming(.session(5), in: center.lastStatus), .unarmed)
    }

    func testFirstArmShowsSheetWithEstimateAndWarning() async throws {
        let runner = ArmingRunner(status: Self.unarmed)
        runner.reply("check", #"""
            {"ok":true,"armed":[],"first_time":true,"estimate":{"decisions":620,"need_labels":410,"tokens":500000},
             "protection_warning":"main is not protected on GitHub — an agent's gh pr merge cannot be stopped here",
             "hooks_warning":"Watchman's git guard cannot be installed in /tmp/acme: shared core.worktree/core.bare — the other layers still apply"}
            """#)
        let center = await center(runner)
        await center.handTo(.target(1820), workbench: "acme-web")
        let sheet = try XCTUnwrap(center.sheet)
        XCTAssertEqual(sheet.scope, .target(1820))
        XCTAssertTrue(sheet.content.lines.map(\.text).contains("Learning from your history: ~620 decisions, est. 500 k tokens"))
        XCTAssertEqual(sheet.content.warnings, [
            Copy.protectionWarning,
            "Watchman's git guard cannot be installed in /tmp/acme: shared core.worktree/core.bare — the other layers still apply"
        ])
        XCTAssertEqual(runner.verbs, [["watchman", "arm", "--target", "1820", "--check", "--json"]])

        // Not now writes nothing.
        center.sheet = nil
        XCTAssertEqual(runner.verbs.count, 1)
    }

    /// A CLI error: the control shows it and the strip stays unarmed.
    func testArmFailureShowsErrorAndKeepsControl() async throws {
        let runner = ArmingRunner(status: Self.unarmed)
        runner.reply("check", #"{"ok":true,"first_time":false}"#)
        runner.reply("arm", #"{"ok":false,"armed":[],"error":"session 5 is not a running workbench agent session"}"#,
                     exitCode: 1)
        let center = await center(runner)
        await center.handTo(.session(5), workbench: "acme-api")

        let notice = Copy.armFailed("session 5 is not a running workbench agent session")
        XCTAssertEqual(center.armNotices[.session(5)], notice)
        XCTAssertEqual(WatchmanArmControl.arming(.session(5), in: center.lastStatus), .unarmed)
        XCTAssertTrue(center.armingHere.isEmpty)

        let control = WatchmanArmControl(center: center, scope: .session(5), workbench: "acme-api", style: .strip)
        XCTAssertNoThrow(try control.inspect().find(text: notice))
        XCTAssertNoThrow(try control.inspect().find(button: Copy.handTo))
        XCTAssertThrowsError(try control.inspect().find(button: Copy.takeBack))

        // A check that fails says so too, and opens no sheet.
        runner.reply("check", "", exitCode: 1, stderr: "error: opening database: locked")
        await center.handTo(.session(5), workbench: "acme-api")
        XCTAssertEqual(center.armNotices[.session(5)], Copy.armFailed("error: opening database: locked"))
        XCTAssertNil(center.sheet)
    }

    /// The tray's first arm: `arm --all-running --check`, the same sheet
    /// (the tray then opens the main window), arm only on confirm; with
    /// nothing to show it arms at once.
    func testTrayHandAllRunningChecksThenOpensTheSheet() async throws {
        let runner = ArmingRunner(status: Self.unarmed)
        runner.reply("check", Self.firstTimeCheck)
        runner.reply("arm", #"""
            {"ok":true,"armed":[],"first_time":true,"analytics_turned_on":true,"learning_started":true,
             "protection_warning":"","hooks_warning":"","sidecar_error":"","error":""}
            """#)
        let center = await center(runner)
        let opened = await center.handAllRunning()
        XCTAssertTrue(opened, "the tray brings the main window up for the sheet")
        XCTAssertEqual(runner.verbs, [["watchman", "arm", "--all-running", "--check", "--json"]])
        let sheet = try XCTUnwrap(center.sheet)
        XCTAssertEqual(sheet.scope, .allRunning)
        XCTAssertEqual(sheet.content.title, Copy.sheetTitleAllRunning)
        XCTAssertTrue(sheet.content.lines.map(\.text).contains(Copy.analyticsLine))

        await center.confirmSheet()
        XCTAssertEqual(runner.verbs.last, ["watchman", "arm", "--all-running", "--json"])
        XCTAssertEqual(runner.verbs.count, 2)
        XCTAssertEqual(center.armNotices[.allRunning], Copy.analyticsLine)

        // Learned, no warning: no sheet, armed at once.
        runner.reply("check", #"{"ok":true,"first_time":false}"#)
        let again = await center.handAllRunning()
        XCTAssertFalse(again)
        XCTAssertNil(center.sheet)
        XCTAssertEqual(Array(runner.verbs.suffix(2)), [
            ["watchman", "arm", "--all-running", "--check", "--json"],
            ["watchman", "arm", "--all-running", "--json"]
        ])

        var fired = false
        let tray = TrayMenuContent(
            isRunning: true, syncProgress: nil, daemonError: nil, cliStoreError: nil, voicesPendingCount: 0,
            updateVersion: nil, updateAction: {}, syncNowAction: {},
            watchman: TrayWatchmanSection(statusLine: "Watchman · Off", notes: [Copy.analyticsLine], busy: false) {
                fired = true
            },
            quickCaptureAction: {}, voicesAction: {}, reviewVoicesAction: {}, trainVoicesAction: {}, openAction: {},
            settingsAction: {})
        try tray.inspect().find(button: Copy.trayHandAll).tap()
        XCTAssertTrue(fired)
        XCTAssertNoThrow(try tray.inspect().find(text: "Watchman · Off"))
        XCTAssertNoThrow(try tray.inspect().find(text: Copy.analyticsLine))
        // D47: no Going to sleep item in phase 2.
        XCTAssertThrowsError(try tray.inspect().find(button: "Going to sleep"))
    }

    /// The real reply's warnings and sidecar note stay under any control;
    /// Take back says when its sidecar was not rewritten.
    func testArmReplyWarningsShowUnderEveryScope() async throws {
        let runner = ArmingRunner(status: Self.unarmed)
        runner.reply("arm", #"""
            {"ok":true,"armed":[],"first_time":false,"protection_warning":"",
             "hooks_warning":"guard cannot be installed in /tmp/acme","sidecar_error":"disk full","error":""}
            """#)
        let center = await center(runner)
        await center.arm(.session(5))
        let notice = ["guard cannot be installed in /tmp/acme", Copy.sidecarNote].joined(separator: "\n")
        XCTAssertEqual(center.armNotices[.session(5)], notice)
        await center.arm(.target(4))
        XCTAssertEqual(center.armNotices[.target(4)], notice)

        runner.reply("disarm", #"{"ok":true,"armed":[],"error":"","sidecar_error":"disk full"}"#)
        await center.disarm(.session(5))
        XCTAssertEqual(center.armNotices[.session(5)], Copy.takeBackSidecarNote)
        runner.reply("disarm", #"{"ok":true,"armed":[],"error":"","sidecar_error":""}"#)
        await center.disarm(.target(4))
        XCTAssertNil(center.armNotices[.target(4)])
    }

    /// Handed over while the daemon is stopped: the armed chip and card say
    /// nothing decides; an unarmed control does not.
    func testDaemonStoppedShowsUnderArmedControls() async throws {
        let stopped = Self.sessionArmed.replacingOccurrences(of: #""daemon_running":true"#, with: #""daemon_running":false"#)
            .replacingOccurrences(of: #""armed":[{"scope":"session","id":5,"#,
                                  with: #""armed":[{"scope":"target","id":4,"armed_at":"2026-11-17T01:40:00Z"},"#
                                      + #"{"scope":"session","id":5,"#)
        let center = await center(ArmingRunner(status: stopped))
        XCTAssertEqual(center.daemon, .stopped)
        typealias Control = WatchmanArmControl
        for scope in [WatchmanArmScope.session(5), .target(4)] {
            let arming = Control.arming(scope, in: center.lastStatus)
            XCTAssertNotEqual(arming, .unarmed)
            XCTAssertEqual(Control.noticeLines(arming: arming, daemon: center.daemon, notice: nil), [Copy.daemonStopped])
        }
        XCTAssertEqual(Control.noticeLines(arming: .unarmed, daemon: .stopped, notice: nil), [])
        XCTAssertEqual(Control.noticeLines(arming: .viaTarget, daemon: .stopped, notice: "x"), [Copy.daemonStopped, "x"])
        XCTAssertEqual(Control.noticeLines(arming: .armed, daemon: .running, notice: nil), [])
    }

    /// A failed first read does not latch: the control shows it with Retry,
    /// and the next read shows the right state.
    func testFailedFirstReadRetriesToTheRightState() async throws {
        let runner = ArmingRunner(status: Self.sessionArmed)
        runner.failStatus(CLIRunnerError.nonZeroExit(code: 1, stderr: "database is locked"))
        let center = WatchmanCenter(runner: runner)
        await center.reread()
        XCTAssertEqual(center.armingReadError, "database is locked")
        let control = WatchmanArmControl(center: center, scope: .session(5), workbench: "acme-api", style: .strip)
        XCTAssertNoThrow(try control.inspect().find(text: Copy.statusReadFailed("database is locked")))
        XCTAssertNoThrow(try control.inspect().find(button: Copy.retry))

        runner.setStatus(Self.sessionArmed)
        await center.reread()
        XCTAssertNil(center.armingReadError)
        XCTAssertEqual(WatchmanArmControl.arming(.session(5), in: center.lastStatus), .armed)
        XCTAssertThrowsError(try control.inspect().find(button: Copy.retry))
    }

    /// An arm made elsewhere (the CLI, another control) shows the next time
    /// a control appears: every appearance rereads, nothing latches.
    func testArmMadeElsewhereShowsAfterTheNextAppear() async {
        let runner = ArmingRunner(status: Self.unarmed)
        let center = WatchmanCenter(runner: runner)
        await center.reread()
        XCTAssertEqual(WatchmanArmControl.arming(.session(5), in: center.lastStatus), .unarmed)
        runner.setStatus(Self.sessionArmed)
        await center.reread()
        XCTAssertEqual(WatchmanArmControl.arming(.session(5), in: center.lastStatus), .armed)
        XCTAssertEqual(runner.invocations.count, 2)
    }

    /// A session under an armed target is the target's, even with its own
    /// row: no Take back (it would not return it).
    func testSessionWithDirectRowUnderArmedTargetIsViaTarget() async throws {
        let both = #"""
            {"ok":true,"workbenches":[],"mode":"sleep","mode_since":"2026-11-17T01:40:00Z",
             "armed":[{"scope":"target","id":4,"armed_at":"2026-11-17T01:40:00Z"},
                      {"scope":"session","id":9,"armed_at":"2026-11-17T02:10:00Z"}],
             "armed_sessions":[{"id":9,"target":4,"armed_at":"2026-11-17T01:40:00Z"}],"daemon_running":true}
            """#
        let center = await center(ArmingRunner(status: both))
        XCTAssertEqual(WatchmanArmControl.arming(.session(9), in: center.lastStatus), .viaTarget)
        let control = WatchmanArmControl(center: center, scope: .session(9), workbench: "acme-api", style: .strip)
        XCTAssertThrowsError(try control.inspect().find(button: Copy.takeBack))
    }

    /// "Sleep since" is the session's own arming time when the status
    /// carries it, else `mode_since`.
    func testSinceIsTheSessionsOwnArmingTime() throws {
        let status = try WatchmanStatusFixtures.decode(#"""
            {"ok":true,"workbenches":[],"mode":"sleep","mode_since":"2026-11-17T01:40:00Z",
             "armed":[{"scope":"session","id":3,"armed_at":"2026-11-17T01:40:00Z"},
                      {"scope":"session","id":5,"armed_at":"2026-11-17T02:10:00Z"}],
             "armed_sessions":[{"id":3,"target":0,"armed_at":"2026-11-17T01:40:00Z"},
                               {"id":5,"target":0,"armed_at":"2026-11-17T02:10:00Z"},{"id":7,"target":0}]}
            """#)
        XCTAssertEqual(WatchmanArmControl.since(.session(5), in: status), AutomationDates.parse("2026-11-17T02:10:00Z"))
        XCTAssertEqual(WatchmanArmControl.since(.session(7), in: status), AutomationDates.parse("2026-11-17T01:40:00Z"))
    }

    /// `arm` exited 0 but its reply could not be read: say the state is
    /// being reread (not that it failed), and reread it.
    func testUnreadableArmReplyRereads() async {
        let runner = ArmingRunner(status: Self.unarmed)
        runner.reply("arm", "not json")
        let center = await center(runner)
        runner.setStatus(Self.sessionArmed)
        await center.arm(.session(5))
        XCTAssertEqual(center.armNotices[.session(5)], Copy.rereading)
        XCTAssertEqual(runner.invocations.last, ["watchman", "status", "--json"])
        XCTAssertEqual(WatchmanArmControl.arming(.session(5), in: center.lastStatus), .armed)

        runner.reply("check", "not json")
        await center.handTo(.session(6), workbench: "acme-api")
        XCTAssertEqual(center.armNotices[.session(6)], Copy.armFailed(Copy.replyUnreadable))
    }
}

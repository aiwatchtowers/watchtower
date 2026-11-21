import DesignKit
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
    /// When set, the next `--check` waits on it; `checkEntered` opens once
    /// that check is under way.
    private var checkGate: AsyncGate?
    let checkEntered = AsyncGate()
    /// The same for the next arm (not a check).
    private var armGate: AsyncGate?
    let armEntered = AsyncGate()

    init(status: String) { statusJSON = status }

    var invocations: [[String]] { lock.withLock { calls } }
    /// The arm/disarm calls only, without the status reads.
    var verbs: [[String]] { invocations.filter { $0.dropFirst().first != "status" } }
    func setStatus(_ json: String) { lock.withLock { statusJSON = json; statusError = nil } }
    func failStatus(_ error: Error) { lock.withLock { statusError = error } }
    func holdNextCheck(_ gate: AsyncGate) { lock.withLock { checkGate = gate } }
    func holdNextArm(_ gate: AsyncGate) { lock.withLock { armGate = gate } }

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

    /// Each stdin a verb read (`--instructions-file -`, `--text-file -`),
    /// with the call it went with.
    private var stdins: [(args: [String], text: String)] = []
    var stdinCalls: [(args: [String], text: String)] { lock.withLock { stdins } }

    func capture(args: [String], stdin: Data, timeout: TimeInterval) async throws -> CLICapturedResult {
        lock.withLock { stdins.append((args, String(bytes: stdin, encoding: .utf8) ?? "<not UTF-8>")) }
        return try await capture(args: args, timeout: timeout)
    }

    func capture(args: [String], timeout: TimeInterval) async throws -> CLICapturedResult {
        if args.contains("--check"), let gate = lock.withLock({ () -> AsyncGate? in
            defer { checkGate = nil }
            return checkGate
        }) {
            checkEntered.release()
            await gate.wait()
        }
        if args.dropFirst().first == "arm", !args.contains("--check"), let gate = lock.withLock({ () -> AsyncGate? in
            defer { armGate = nil }
            return armGate
        }) {
            armEntered.release()
            await gate.wait()
        }
        return lock.withLock {
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
         "estimate":{"decisions":1850,"need_labels":1200,"tokens":1600000},"sessions":[5],"protection_warning":"","hooks_warning":"",
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
        XCTAssertEqual(sheet.content.mode, .firstTime)
        let lines = sheet.content.lines.map(\.text)
        XCTAssertTrue(lines.contains(Copy.analyticsLine))
        XCTAssertTrue(lines.contains("Learning from your history: ~1 850 decisions, est. 1.6 M tokens"))
        XCTAssertTrue(lines.contains("Watchman learns this workbench first (about 1 850 decisions). Questions asked "
            + "meanwhile wait and are decided once it finishes — or answer them yourself."))
        XCTAssertEqual(sheet.content.confirm, "Hand over")

        runner.setStatus(Self.sessionArmed)
        await center.confirmShown()
        XCTAssertNil(center.sheet)
        // An untouched empty field: no instruction flag.
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
        await center.handTo(.session(5), workbench: "acme-api", title: "Ship task 3")
        // A learned workbench without warnings: the short sheet, for the instruction.
        let sheet = try XCTUnwrap(center.sheet)
        XCTAssertEqual(sheet.content.mode, .short)
        XCTAssertEqual(sheet.content.title, "Hand to Watchman")
        XCTAssertEqual(sheet.content.subject, "#5 Ship task 3")
        XCTAssertEqual(sheet.content.lines, [])
        XCTAssertEqual([sheet.content.cancel, sheet.content.confirm], ["Cancel", "Hand over"])
        await center.confirmShown()
        XCTAssertNil(center.sheet)
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

    /// A covered session without the Watchman guard hook (final review
    /// A-I1): the check's `hooks_warning` line alone opens the sheet, which
    /// shows it, and the arm's notice keeps it under the control.
    func testMissingGuardHookLineOpensTheSheetAndStaysAsNotice() async throws {
        let line = "/tmp/acme: the Watchman guard hook is not installed — Repair the workbench, then restart the session"
        let runner = ArmingRunner(status: Self.unarmed)
        runner.reply("check", #"{"ok":true,"armed":[],"first_time":false,"protection_warning":"","hooks_warning":"\#(line)"}"#)
        runner.reply("arm", #"{"ok":true,"armed":[],"first_time":false,"protection_warning":"","hooks_warning":"\#(line)"}"#)
        let center = await center(runner)
        await center.handTo(.session(5), workbench: "acme-api")
        let sheet = try XCTUnwrap(center.sheet)
        XCTAssertEqual(sheet.content.warnings, [line])
        center.sheet = nil
        await center.arm(.session(5))
        XCTAssertEqual(center.armNotices[.session(5)], line)
    }

    /// A second arm of a scope while its first runs is ignored (final
    /// review D-3), as a second Take back is.
    func testArmInFlightIgnoresASecondPress() async {
        let runner = ArmingRunner(status: Self.unarmed)
        let center = await center(runner)
        let gate = AsyncGate()
        runner.holdNextArm(gate)
        let first = Task { await center.arm(.session(5)) }
        await runner.armEntered.wait()
        XCTAssertTrue(center.armingHere.contains(.session(5)))
        let second = await center.arm(.session(5))
        XCTAssertNil(second, "the second press arms nothing")
        gate.release()
        _ = await first.value
        XCTAssertEqual(runner.verbs, [["watchman", "arm", "--session", "5", "--json"]])
        XCTAssertFalse(center.armingHere.contains(.session(5)))
    }

    /// A CLI error: the control shows it and the strip stays unarmed.
    func testArmFailureShowsErrorAndKeepsControl() async throws {
        let runner = ArmingRunner(status: Self.unarmed)
        runner.reply("check", #"{"ok":true,"first_time":false}"#)
        runner.reply("arm", #"{"ok":false,"armed":[],"error":"session 5 is not a running workbench agent session"}"#,
                     exitCode: 1)
        let center = await center(runner)
        await center.arm(.session(5))

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
        XCTAssertEqual(sheet.content.mode, .tray)
        XCTAssertEqual(sheet.content.title, Copy.shortTitle)
        XCTAssertTrue(sheet.content.lines.map(\.text).contains(Copy.analyticsLine), "a first time shows what turns on")

        XCTAssertEqual(sheet.content.sessions, ["Session 5"], "no title known: the id")
        await center.confirmShown()
        XCTAssertEqual(runner.verbs.last, ["watchman", "arm", "--all-running", "--only", "5", "--json"])
        XCTAssertEqual(runner.verbs.count, 3, "check, the check again on confirm, arm")
        XCTAssertEqual(center.armNotices[.allRunning], Copy.analyticsLine)

        // Learned, no warning: still the sheet (for the instruction), without the lines.
        runner.reply("check", #"{"ok":true,"first_time":false,"sessions":[5]}"#)
        let again = await center.handAllRunning()
        XCTAssertTrue(again)
        XCTAssertEqual(center.sheet?.content.mode, .tray)
        XCTAssertEqual(center.sheet?.content.lines, [])
        await center.confirmShown()
        XCTAssertNil(center.sheet)
        XCTAssertEqual(Array(runner.verbs.suffix(3)), [
            ["watchman", "arm", "--all-running", "--check", "--json"],
            ["watchman", "arm", "--all-running", "--check", "--json"],
            ["watchman", "arm", "--all-running", "--only", "5", "--json"]
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
    /// row; its Take back removes only that row (round 3).
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
        XCTAssertNoThrow(try control.inspect().find(button: Copy.takeBack))
        // Its own instruction is edited here too: the button and the edit sheet.
        XCTAssertNoThrow(try control.inspect().find(button: Copy.instructionButton))
        await center.editInstruction(.session(9))
        XCTAssertEqual(center.sheet?.content.mode, .edit)
        XCTAssertEqual(center.sheet?.scope, .session(9))
        // Its chip's tooltip leads with its own instruction.
        XCTAssertEqual(WatchmanArmControl.chipHelp(viaTarget: "Handed over through #4", instruction: "Ship task 3"),
                       "Ship task 3\nHanded over through #4")
        XCTAssertEqual(WatchmanArmControl.chipHelp(viaTarget: "Handed over through #4", instruction: nil),
                       "Handed over through #4")
    }

    /// "since" is the session's own arming time when the status
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

    /// A session starting while the tray's sheet is open is never armed
    /// unseen: confirm checks again, shows the new set, and arms only the
    /// set confirmed.
    func testTraySheetRefreshesWhenTheRunningSetChanges() async throws {
        let runner = ArmingRunner(status: Self.unarmed)
        runner.reply("check", #"{"ok":true,"first_time":true,"sessions":[5],"estimate":null}"#)
        let center = await center(runner)
        _ = await center.handAllRunning()
        XCTAssertEqual(center.sheet?.sessions, [5])

        // Session 6 started meanwhile.
        runner.reply("check", #"{"ok":true,"first_time":true,"sessions":[5,6],"estimate":null}"#)
        await center.confirmShown("finish the plan")
        let refreshed = try XCTUnwrap(center.sheet, "the sheet asks again")
        XCTAssertEqual(refreshed.sessions, [5, 6])
        XCTAssertEqual(refreshed.content.notice, Copy.sessionsChanged)
        XCTAssertEqual(refreshed.instruction, "finish the plan", "the typed text survives the new set")
        XCTAssertFalse(runner.verbs.contains { !$0.contains("--check") }, "nothing armed yet")

        // Confirmed as shown: exactly that set.
        await center.confirmShown()
        XCTAssertNil(center.sheet)
        XCTAssertEqual(runner.verbs.last, ["watchman", "arm", "--all-running", "--only", "5,6", "--json"])
    }

    /// The via-target tooltip names every source that keeps the session.
    func testViaTargetHelpNamesEverySource() throws {
        let status = try WatchmanStatusFixtures.decode(#"""
            {"ok":true,"workbenches":[],"mode":"sleep",
             "armed":[{"scope":"target","id":4},{"scope":"session","id":9}],
             "armed_sessions":[{"id":9,"target":4},{"id":8,"target":4}]}
            """#)
        XCTAssertEqual(WatchmanArmControl.viaTargetHelp(.session(9), in: status), Copy.viaTargetHelp(target: 4, direct: true))
        XCTAssertEqual(WatchmanArmControl.viaTargetHelp(.session(8), in: status), Copy.viaTargetHelp(target: 4, direct: false))
    }

    /// Every running session is armed only as an explicit set: an empty
    /// list says there is nothing to hand over, a CLI without the list is
    /// refused, and `arm(.allRunning)` with no set never runs.
    func testAllRunningNeverArmsUnrestricted() async {
        let runner = ArmingRunner(status: Self.unarmed)
        let center = await center(runner)
        runner.reply("check", #"{"ok":true,"first_time":false,"sessions":[]}"#)
        _ = await center.handAllRunning()
        XCTAssertEqual(center.armNotices[.allRunning], Copy.nothingToHandOver)
        runner.reply("check", #"{"ok":true,"first_time":true}"#)
        let opened = await center.handAllRunning()
        XCTAssertFalse(opened)
        XCTAssertNil(center.sheet)
        XCTAssertEqual(center.armNotices[.allRunning], Copy.updateCLI)
        await center.arm(.allRunning)
        XCTAssertEqual(center.armNotices[.allRunning], Copy.nothingToHandOver)
        XCTAssertFalse(runner.verbs.contains { !$0.contains("--check") }, "never an unrestricted arm")
    }

    /// One confirm at a time (the button waits), and a sheet dismissed while
    /// its confirm checks again arms nothing.
    func testConfirmIsSingleAndADismissCancels() async throws {
        let runner = ArmingRunner(status: Self.unarmed)
        runner.reply("check", #"{"ok":true,"first_time":true,"sessions":[5]}"#)
        let center = await center(runner)
        _ = await center.handAllRunning()
        XCTAssertNotNil(center.sheet)

        let gate = AsyncGate()
        runner.holdNextCheck(gate)
        let confirm = Task { await center.confirmShown() }
        await runner.checkEntered.wait()
        XCTAssertTrue(center.confirming)
        await center.confirmShown() // a second press while checking: ignored
        center.sheet = nil          // Not now meanwhile
        gate.release()
        await confirm.value
        XCTAssertFalse(center.confirming)
        XCTAssertEqual(runner.verbs.filter { $0.contains("--check") }.count, 2, "the first check and one recheck")
        XCTAssertFalse(runner.verbs.contains { !$0.contains("--check") }, "nothing armed")
    }

    /// The sheet lists the sessions it hands over by title (ids without one),
    /// and an `--only` id no longer running shows as a warning.
    func testSheetListsSessionsAndDroppedIdsWarn() async throws {
        let runner = ArmingRunner(status: Self.unarmed)
        runner.reply("check", #"{"ok":true,"first_time":true,"sessions":[5,6]}"#)
        let center = await center(runner)
        center.sessionTitle = { $0 == 5 ? "Fix the login redirect" : nil }
        _ = await center.handAllRunning()
        let sheet = try XCTUnwrap(center.sheet)
        XCTAssertEqual(sheet.content.sessions, ["#5 Fix the login redirect", "Session 6"])
        XCTAssertEqual(Copy.sessionsHeader(2), "Hands over 2 sessions:")

        runner.reply("arm", #"{"ok":true,"sessions":[5],"dropped":[6]}"#)
        await center.confirmShown()
        XCTAssertEqual(center.armNotices[.allRunning], Copy.droppedLine([6]))
        XCTAssertEqual(Copy.droppedLine([6, 7]), "Not handed over (no longer running): #6, #7")
    }

    /// A session handed over itself and through its target keeps Take back,
    /// which removes the direct row only; the tooltip says so.
    func testDirectRowUnderTargetKeepsTakeBack() throws {
        let status = try WatchmanStatusFixtures.decode(#"""
            {"ok":true,"workbenches":[],"mode":"sleep",
             "armed":[{"scope":"target","id":4},{"scope":"session","id":9}],
             "armed_sessions":[{"id":9,"target":4},{"id":8,"target":4}]}
            """#)
        XCTAssertEqual(WatchmanArmControl.directUnderTarget(.session(9), in: status), 4)
        XCTAssertNil(WatchmanArmControl.directUnderTarget(.session(8), in: status))
        XCTAssertFalse(Copy.viaTargetHelp(target: 4, direct: true).contains("this session here"))
        XCTAssertTrue(Copy.viaTargetHelp(target: 4, direct: true).contains("Take back here removes the direct hand-over"))
        XCTAssertEqual(Copy.takeBackDirectHelp(target: 4),
                       "Takes back only this session's own hand-over; #4 still hands it to Watchman")
    }

    /// The CLI's real `arm --session N --check --json` reply
    /// (`cmd/testdata/watchman_arm_check_session.golden.json`, written by
    /// `TestWatchmanArm_CheckFixture`).
    private static func goCheckReply() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("cmd/testdata/watchman_arm_check_session.golden.json")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The strip and the panel never pass `--only` (the CLI refuses it with
    /// --session or --target), though a real check reply lists `sessions`.
    func testStripAndPanelArmWithoutOnly() async throws {
        let real = try Self.goCheckReply()
        let runner = ArmingRunner(status: Self.unarmed)
        runner.reply("check", real)
        let center = await center(runner)

        // First time with a warning: the sheet, then the arm on confirm.
        await center.handTo(.session(1), workbench: "acme")
        XCTAssertEqual(center.sheet?.sessions, [1])
        await center.confirmShown()
        XCTAssertEqual(runner.verbs.last, ["watchman", "arm", "--session", "1", "--json"])

        // Learned, no warning: the short sheet, still without --only.
        let learned = real.replacingOccurrences(of: #""first_time": true"#, with: #""first_time": false"#)
            .replacingOccurrences(of: "Could not read main's protection on GitHub — treat it as unprotected", with: "")
        XCTAssertNotEqual(learned, real)
        runner.reply("check", learned)
        await center.handTo(.session(1), workbench: "acme")
        XCTAssertEqual(center.sheet?.content.mode, .short)
        await center.confirmShown()
        XCTAssertNil(center.sheet)
        XCTAssertEqual(runner.verbs.last, ["watchman", "arm", "--session", "1", "--json"])
        await center.handTo(.target(4), workbench: "acme")
        await center.confirmShown()
        XCTAssertEqual(runner.verbs.last, ["watchman", "arm", "--target", "4", "--json"])
        XCTAssertFalse(runner.verbs.contains { $0.contains("--only") })
    }

    /// A confirm acts only on the sheet it was pressed on: a newer sheet for
    /// the same scope (same sessions) is not armed by the older press.
    func testConfirmActsOnlyOnItsOwnSheet() async throws {
        let runner = ArmingRunner(status: Self.unarmed)
        runner.reply("check", #"{"ok":true,"first_time":true,"sessions":[5]}"#)
        let center = await center(runner)
        _ = await center.handAllRunning()
        let first = try XCTUnwrap(center.sheet)

        let gate = AsyncGate()
        runner.holdNextCheck(gate)
        let confirm = Task { await center.confirmShown() }
        await runner.checkEntered.wait()
        center.sheet = nil                 // Not now
        _ = await center.handAllRunning()  // the tray again: a new sheet, same set
        let second = try XCTUnwrap(center.sheet)
        XCTAssertNotEqual(first.token, second.token)
        gate.release()
        await confirm.value
        XCTAssertEqual(center.sheet?.token, second.token, "the new sheet stays")
        XCTAssertFalse(runner.verbs.contains { !$0.contains("--check") }, "nothing armed by the old press")
    }

    /// The sheet's session list shows at most six rows; more scroll.
    func testSessionListIsBounded() {
        XCTAssertEqual(WatchmanArmSheet.listHeight(rows: 3), 3 * ListLayout.lineMinHeight)
        XCTAssertEqual(WatchmanArmSheet.listHeight(rows: 40), 6 * ListLayout.lineMinHeight)
    }

    // MARK: - Instructions (tuning spec §2)

    /// `status` with session `id` armed by its own row and its instruction.
    private static func armedWith(_ id: Int64, instructions: String) -> String {
        #"""
        {"ok":true,"workbenches":[],"mode":"sleep","mode_since":"2026-11-17T01:40:00Z",
         "armed":[{"scope":"session","id":\#(id),"armed_at":"2026-11-17T01:40:00Z"}],
         "armed_sessions":[{"id":\#(id),"target":0,"armed_at":"2026-11-17T01:40:00Z","instructions":"\#(instructions)"}],
         "daemon_running":true}
        """#
    }

    private static let learnedCheck = #"{"ok":true,"first_time":false,"sessions":[5]}"#

    /// Hand over with text: `arm --session N --instructions-file -`, the
    /// text on stdin; the next sheet pre-fills it.
    func testHandOverWithTextGoesOnStdin() async throws {
        let runner = ArmingRunner(status: Self.unarmed)
        runner.reply("check", Self.learnedCheck)
        let center = await center(runner)
        await center.handTo(.session(5), workbench: "acme-api")
        XCTAssertEqual(center.sheet?.instruction, "", "nothing stored: an empty field")
        runner.setStatus(Self.armedWith(5, instructions: "ship task 3 only"))
        await center.confirmShown("ship task 3 only")
        XCTAssertNil(center.sheet)
        XCTAssertEqual(runner.verbs.last, ["watchman", "arm", "--session", "5", "--instructions-file", "-", "--json"])
        XCTAssertEqual(runner.stdinCalls.map(\.text), ["ship task 3 only"])
        XCTAssertEqual(center.instructions[.session(5)], "ship task 3 only")

        // Taken back, handed over again: the stored text pre-fills (D7).
        runner.setStatus(Self.unarmed)
        await center.disarm(.session(5))
        await center.handTo(.session(5), workbench: "acme-api")
        XCTAssertEqual(center.sheet?.instruction, "ship task 3 only")
    }

    /// A single scope's empty field passes the flag only when the owner
    /// emptied a stored text; an untouched empty field passes none.
    func testEmptyFieldClearsOnlyAStoredText() async throws {
        let runner = ArmingRunner(status: Self.armedWith(5, instructions: "ship task 3 only"))
        runner.reply("check", Self.learnedCheck)
        let center = await center(runner)
        await center.handTo(.session(5), workbench: "acme-api")
        XCTAssertEqual(center.sheet?.instruction, "ship task 3 only")
        await center.confirmShown("  \n")
        XCTAssertEqual(runner.verbs.last, ["watchman", "arm", "--session", "5", "--instructions-file", "-", "--json"])
        XCTAssertEqual(runner.stdinCalls.last?.text, "", "an empty file clears it")

        await center.handTo(.session(6), workbench: "acme-api")
        XCTAssertEqual(center.sheet?.instruction, "")
        await center.confirmShown("")
        XCTAssertEqual(runner.verbs.last, ["watchman", "arm", "--session", "6", "--json"])
        XCTAssertEqual(runner.stdinCalls.count, 1)

        typealias Center = WatchmanCenter
        XCTAssertEqual(Center.instructionFlag("x", stored: "", tray: false), "x")
        XCTAssertNil(Center.instructionFlag(" ", stored: "", tray: false))
        XCTAssertEqual(Center.instructionFlag("", stored: "old", tray: false), "")
        XCTAssertNil(Center.instructionFlag("", stored: "old", tray: true))
        XCTAssertEqual(Center.instructionFlag("x", stored: "", tray: true), "x")
        XCTAssertNil(Center.instructionFlag("", stored: nil, tray: false), "an unknown stored text is never cleared")
        XCTAssertEqual(Center.instructionFlag("x", stored: nil, tray: false), "x")
    }

    /// After a restart the app has seen nothing: the sheets pre-fill from
    /// the database (D7).
    func testPrefillReadsTheDatabaseAfterARestart() async throws {
        let runner = ArmingRunner(status: Self.unarmed)
        runner.reply("check", #"{"ok":true,"first_time":false,"sessions":[]}"#)
        let center = await center(runner)
        XCTAssertNil(center.instructions[.target(4)])
        center.readInstruction = { scope in scope == .target(4) ? "keep the public API" : "" }
        await center.handTo(.target(4), workbench: "acme-api")
        XCTAssertEqual(center.sheet?.instruction, "keep the public API")
        XCTAssertEqual(center.sheet?.stored, "keep the public API")
        // Emptied by the owner: the stored text is cleared, knowingly.
        await center.confirmShown("")
        XCTAssertEqual(runner.verbs.last, ["watchman", "arm", "--target", "4", "--instructions-file", "-", "--json"])
        XCTAssertEqual(runner.stdinCalls.last?.text, "")

        await center.editInstruction(.target(4))
        XCTAssertEqual(center.sheet?.instruction, "keep the public API", "read again, not the cleared memory")
    }

    /// The read fails and the app saw nothing: the field opens empty, and
    /// neither an untouched hand-over nor an empty Save clears the text.
    func testUnreadStoredTextIsNeverCleared() async throws {
        struct Locked: Error {}
        let runner = ArmingRunner(status: Self.unarmed)
        runner.reply("check", Self.learnedCheck)
        let center = await center(runner)
        center.readInstruction = { _ in throw Locked() }
        await center.handTo(.session(5), workbench: "acme-api")
        XCTAssertEqual(center.sheet?.instruction, "")
        XCTAssertNil(center.sheet?.stored)
        await center.confirmShown("")
        XCTAssertEqual(runner.verbs.last, ["watchman", "arm", "--session", "5", "--json"], "no flag: nothing cleared")

        await center.editInstruction(.target(4))
        XCTAssertNil(center.sheet?.stored)
        await center.confirmShown(" ")
        XCTAssertFalse(runner.verbs.contains { $0.dropFirst().first == "instruct" }, "no empty file sent")
        XCTAssertNotNil(center.sheet, "the sheet stays")
        XCTAssertEqual(center.sheetError, Copy.instructionUnread)

        // A failed read falls back to what the app saw.
        runner.reply("instruct", #"{"ok":true,"scope":"target","ref_id":4,"instructions":"keep the API","error":""}"#)
        await center.confirmShown("keep the API")
        XCTAssertEqual(runner.verbs.last, ["watchman", "instruct", "--target", "4", "--text-file", "-", "--json"])
        await center.editInstruction(.target(4))
        XCTAssertEqual(center.sheet?.stored, "keep the API")
        XCTAssertEqual(center.sheet?.instruction, "keep the API")
    }

    /// The tray's confirm re-check failing, or finding nothing running,
    /// keeps the sheet and its text with the line.
    func testTrayRecheckFailureKeepsTheSheet() async throws {
        let runner = ArmingRunner(status: Self.unarmed)
        runner.reply("check", #"{"ok":true,"first_time":false,"sessions":[5]}"#)
        let center = await center(runner)
        _ = await center.handAllRunning()
        let token = try XCTUnwrap(center.sheet?.token)
        runner.reply("check", "", exitCode: 1, stderr: "database is locked")
        await center.confirmShown("finish the plan")
        XCTAssertEqual(center.sheet?.token, token)
        XCTAssertEqual(center.sheetError, Copy.saveFailed("database is locked"))

        runner.reply("check", #"{"ok":true,"first_time":false,"sessions":[]}"#)
        await center.confirmShown("finish the plan")
        XCTAssertEqual(center.sheet?.token, token, "the draft stays")
        XCTAssertEqual(center.sheetError, Copy.nothingToHandOver)
        XCTAssertFalse(runner.verbs.contains { !$0.contains("--check") }, "nothing armed")
    }

    /// A confirm while the scope's own arm runs sends nothing and says so.
    func testConfirmDuringARunningArmSaysSo() async throws {
        let runner = ArmingRunner(status: Self.unarmed)
        runner.reply("check", Self.learnedCheck)
        let center = await center(runner)
        await center.handTo(.session(5), workbench: "acme-api")
        let gate = AsyncGate()
        runner.holdNextArm(gate)
        let running = Task { await center.arm(.session(5)) }
        await runner.armEntered.wait()
        await center.confirmShown("x")
        XCTAssertNotNil(center.sheet)
        XCTAssertEqual(center.sheetError, Copy.armInProgress)
        gate.release()
        _ = await running.value
        XCTAssertEqual(runner.stdinCalls.count, 0)
    }

    /// The tray's empty field keeps each session's text (no flag); a text
    /// is set on every confirmed session.
    func testTrayEmptyFieldPassesNoFlag() async throws {
        let runner = ArmingRunner(status: Self.unarmed)
        runner.reply("check", #"{"ok":true,"first_time":false,"sessions":[5,6]}"#)
        let center = await center(runner)
        _ = await center.handAllRunning()
        XCTAssertEqual(center.sheet?.instruction, "", "the tray's field starts empty")
        await center.confirmShown("")
        XCTAssertEqual(runner.verbs.last, ["watchman", "arm", "--all-running", "--only", "5,6", "--json"])
        XCTAssertEqual(runner.stdinCalls.count, 0)

        _ = await center.handAllRunning()
        // Session 6 stopped before the arm: the CLI drops it, and it keeps its own text.
        runner.reply("arm", #"{"ok":true,"sessions":[5],"dropped":[6]}"#)
        await center.confirmShown("finish the plan")
        XCTAssertEqual(runner.verbs.last,
                       ["watchman", "arm", "--all-running", "--only", "5,6", "--instructions-file", "-", "--json"])
        XCTAssertEqual(runner.stdinCalls.map(\.text), ["finish the plan"])
        XCTAssertEqual(center.instructions[.session(5)], "finish the plan")
        XCTAssertNil(center.instructions[.session(6)])
    }

    /// A failed hand-over keeps the sheet (and so its text) with `Could not
    /// save: …`; Retry runs it again.
    func testSaveFailureKeepsTheSheetAndRetryReruns() async throws {
        let runner = ArmingRunner(status: Self.unarmed)
        runner.reply("check", Self.learnedCheck)
        runner.reply("arm", #"{"ok":false,"armed":[],"error":"database is locked"}"#, exitCode: 1)
        let center = await center(runner)
        await center.handTo(.session(5), workbench: "acme-api")
        let token = try XCTUnwrap(center.sheet?.token)
        await center.confirmShown("ship task 3 only")
        XCTAssertEqual(center.sheet?.token, token, "the sheet stays")
        XCTAssertEqual(center.sheetError, Copy.saveFailed("database is locked"))
        XCTAssertEqual(center.sheetError, "Could not save: database is locked")
        XCTAssertNil(center.armNotices[.session(5)], "the line is in the sheet, not under the control")
        XCTAssertFalse(center.confirming)

        // The sheet's Retry confirms again with the text it kept.
        var retried: String?
        let view = WatchmanArmSheet(content: try XCTUnwrap(center.sheet?.content), instruction: "ship task 3 only",
                                    error: center.sheetError, onCancel: {}, onConfirm: { retried = $0 })
        XCTAssertNoThrow(try view.inspect().find(text: "Could not save: database is locked"))
        try view.inspect().find(button: Copy.retry).tap()
        XCTAssertEqual(retried, "ship task 3 only")

        runner.reply("arm", #"{"ok":true,"armed":[],"error":""}"#)
        await center.confirmShown("ship task 3 only")
        XCTAssertNil(center.sheet)
        XCTAssertNil(center.sheetError)
        XCTAssertEqual(runner.stdinCalls.map(\.text), ["ship task 3 only", "ship task 3 only"])
    }

    /// While a confirm runs the sheet's buttons wait and the confirm shows
    /// a spinner; the counter shows past 1800 characters.
    func testSheetBusyAndCounter() throws {
        let content = WatchmanArmSheetContent.edit(subject: "#41 Ship task 3")
        let busy = WatchmanArmSheet(content: content, instruction: "x", busy: true, onCancel: {}, onConfirm: { _ in })
        XCTAssertTrue(try busy.inspect().find(button: Copy.save).isDisabled())
        XCTAssertTrue(try busy.inspect().find(button: Copy.cancel).isDisabled())
        XCTAssertNoThrow(try busy.inspect().find(ViewType.ProgressView.self))
        let idle = WatchmanArmSheet(content: content, instruction: String(repeating: "a", count: 1801),
                                    onCancel: {}, onConfirm: { _ in })
        XCTAssertNoThrow(try idle.inspect().find(text: "1801 / 2000"))
        XCTAssertThrowsError(try idle.inspect().find(ViewType.ProgressView.self))
    }

    /// Instruction… on the armed chip opens the edit sheet pre-filled from
    /// the status; Save runs `watchman instruct`; a target remembers the
    /// stored text for its next sheet.
    func testEditRunsInstruct() async throws {
        let runner = ArmingRunner(status: Self.armedWith(5, instructions: "ship task 3 only"))
        let center = await center(runner)
        await center.editInstruction(.session(5))
        let sheet = try XCTUnwrap(center.sheet)
        XCTAssertEqual(sheet.content.mode, .edit)
        XCTAssertEqual(sheet.content.title, "Instruction for Watchman")
        XCTAssertEqual(sheet.content.confirm, "Save")
        XCTAssertEqual(sheet.content.subject, "Session 5")
        XCTAssertEqual(sheet.instruction, "ship task 3 only")

        runner.reply("instruct", #"{"ok":true,"scope":"session","ref_id":5,"instructions":"ship task 4","error":""}"#)
        runner.setStatus(Self.armedWith(5, instructions: "ship task 4"))
        await center.confirmShown("ship task 4\n")
        XCTAssertNil(center.sheet)
        XCTAssertEqual(runner.verbs.last, ["watchman", "instruct", "--session", "5", "--text-file", "-", "--json"])
        XCTAssertEqual(runner.stdinCalls.last?.text, "ship task 4\n")
        XCTAssertEqual(center.instructions[.session(5)], "ship task 4")

        // A target: no read verb, the reply's text is remembered.
        runner.reply("instruct", #"{"ok":true,"scope":"target","ref_id":4,"instructions":"keep the API","error":""}"#)
        await center.editInstruction(.target(4), title: "Billing plan")
        XCTAssertEqual(center.sheet?.content.subject, "#4 Billing plan")
        XCTAssertEqual(center.sheet?.instruction, "")
        await center.confirmShown("keep the API")
        XCTAssertEqual(runner.verbs.last, ["watchman", "instruct", "--target", "4", "--text-file", "-", "--json"])
        XCTAssertEqual(center.instructions[.target(4)], "keep the API")
        runner.reply("check", #"{"ok":true,"first_time":false,"sessions":[]}"#)
        await center.handTo(.target(4), workbench: "acme-api")
        XCTAssertEqual(center.sheet?.instruction, "keep the API")
        center.sheet = nil

        // A refused save keeps the sheet with its line.
        runner.reply("instruct", #"{"ok":false,"scope":"target","ref_id":4,"instructions":"","error":"there is no target 4"}"#,
                     exitCode: 1)
        await center.editInstruction(.target(4))
        await center.confirmShown("x")
        XCTAssertNotNil(center.sheet)
        XCTAssertEqual(center.sheetError, Copy.saveFailed("there is no target 4"))
        center.sheet = nil
        XCTAssertNil(center.sheetError, "closing the sheet drops its line")
    }

    /// The armed chip's tooltip is the instruction's first line.
    func testInstructionHelpIsTheFirstLine() {
        XCTAssertEqual(Copy.instructionHelp("\n  Ship task 3 only, then finish.\nAsk me first."),
                       "Ship task 3 only, then finish.")
        XCTAssertNil(Copy.instructionHelp(" \n "))
    }

    /// The button passes the token of the sheet it shows: a sheet replaced
    /// before the confirm runs is not confirmed.
    func testConfirmTokenOfAReplacedSheetDoesNothing() async throws {
        let runner = ArmingRunner(status: Self.unarmed)
        runner.reply("check", #"{"ok":true,"first_time":true,"sessions":[5]}"#)
        let center = await center(runner)
        _ = await center.handAllRunning()
        let pressed = try XCTUnwrap(center.sheet).token
        _ = await center.handAllRunning() // replaced before the press runs
        XCTAssertNotEqual(center.sheet?.token, pressed)
        let checks = runner.verbs.count
        await center.confirmSheet(token: pressed, instruction: "")
        XCTAssertEqual(runner.verbs.count, checks, "no recheck, no arm")
        XCTAssertNotNil(center.sheet)
    }
}

private extension WatchmanCenter {
    /// Hand over (or Save) on the sheet on screen now, with `instruction`
    /// in its field.
    func confirmShown(_ instruction: String = "") async {
        guard let token = sheet?.token else { return }
        await confirmSheet(token: token, instruction: instruction)
    }
}

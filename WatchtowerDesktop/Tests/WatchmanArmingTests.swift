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

    init(status: String) { statusJSON = status }

    var invocations: [[String]] { lock.withLock { calls } }
    /// The arm/disarm calls only, without the status reads.
    var verbs: [[String]] { invocations.filter { $0.dropFirst().first != "status" } }
    func setStatus(_ json: String) { lock.withLock { statusJSON = json } }

    /// `key`: "check", "arm" or "disarm".
    func reply(_ key: String, _ json: String, exitCode: Int32 = 0, stderr: String = "") {
        lock.withLock { replies[key] = CLICapturedResult(stdout: Data(json.utf8), exitCode: exitCode, stderr: stderr) }
    }

    func run(args: [String]) async throws -> Data {
        lock.withLock {
            calls.append(args)
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
         "armed":[{"scope":"session","id":5,"armed_at":"2026-11-17T01:40:00Z"}],"armed_sessions":[5],"daemon_running":true}
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
        XCTAssertNil(center.armNotices[.session(5)])
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

    func testTrayHandAllRunningCallsAllRunning() async throws {
        let runner = ArmingRunner(status: Self.unarmed)
        runner.reply("arm", #"""
            {"ok":true,"armed":[],"first_time":true,"analytics_turned_on":true,"learning_started":true,
             "protection_warning":"main is not protected on GitHub — an agent's gh pr merge cannot be stopped here",
             "hooks_warning":"","sidecar_error":"","error":""}
            """#)
        let center = await center(runner)
        await center.handAllRunning()
        XCTAssertEqual(runner.verbs, [["watchman", "arm", "--all-running", "--json"]])
        // No sheet from a menu: what it would say stays as the tray's lines.
        XCTAssertNil(center.sheet)
        XCTAssertEqual(center.armNotices[.allRunning], [Copy.analyticsLine, Copy.protectionWarning].joined(separator: "\n"))

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

    /// Strips that appear together share one first status read.
    func testControlsShareTheFirstRead() async {
        let runner = ArmingRunner(status: Self.unarmed)
        let center = WatchmanCenter(runner: runner)
        await center.loadIfNeeded(for: .session(5))
        await center.loadIfNeeded(for: .session(6))
        await center.loadIfNeeded(for: .target(4))
        XCTAssertEqual(runner.invocations, [["watchman", "status", "--json"]])
        XCTAssertEqual(center.lastStatus?.mode, .off)
    }

    /// A session started under an armed target after the last read: the
    /// strip rereads the status once for it.
    func testSessionUnderArmedTargetRereadsOnce() async throws {
        let targetArmed = #"""
            {"ok":true,"workbenches":[],"mode":"sleep","mode_since":"2026-11-17T01:40:00Z",
             "armed":[{"scope":"target","id":4,"armed_at":"2026-11-17T01:40:00Z"}],"armed_sessions":[],"daemon_running":true}
            """#
        let runner = ArmingRunner(status: targetArmed)
        let center = await center(runner)
        runner.setStatus(targetArmed.replacingOccurrences(of: #""armed_sessions":[]"#, with: #""armed_sessions":[9]"#))
        await center.loadIfNeeded(for: .session(9))
        XCTAssertEqual(WatchmanArmControl.arming(.session(9), in: center.lastStatus), .viaTarget)
        await center.loadIfNeeded(for: .session(9))
        await center.loadIfNeeded(for: .target(4))
        XCTAssertEqual(runner.invocations.count, 2, "one initial read, one reread for session 9")
    }
}

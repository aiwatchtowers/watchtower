import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Board #1352: **Session Target ▸** runs `workbench session-target` through
/// the CLI; a refusal shows as the menu's failure line, success clears it.
@MainActor
final class WorkbenchesViewModelSessionTargetTests: XCTestCase {
    private final class Runner: CLIRunnerProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[String]] = []
        private var failure: String?

        var invocations: [[String]] { lock.withLock { calls } }
        func fail(_ stderr: String?) { lock.withLock { failure = stderr } }

        func run(args: [String]) async throws -> Data {
            let stderr = lock.withLock { () -> String? in
                calls.append(args)
                return failure
            }
            if let stderr { throw CLIRunnerError.nonZeroExit(code: 1, stderr: stderr) }
            return Data(#"{"session_id":1,"target_id":7,"stamped":3}"#.utf8)
        }
    }

    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var session: TerminalSession!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchesViewModelSessionTargetTests-\(UUID().uuidString)"))
        session = try pool.write { db in
            let pid = try TestDatabase.insertWorkbench(db, name: "acme", folder: "/tmp/acme")
            return try TerminalSessionQueries.create(db, .init(
                projectID: pid, kind: .claude, title: "s", folderPath: "/tmp/acme",
                claudeSessionID: UUID().uuidString.lowercased()
            ))
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeVM(_ runner: Runner) -> WorkbenchesViewModel {
        WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
    }

    func testABindRunsTheCLIAndClearsTheError() async {
        let runner = Runner()
        let vm = makeVM(runner)
        vm.sessionTargetError = "old"
        await vm.setSessionTarget(session, targetID: 7)
        XCTAssertEqual(runner.invocations, [[
            "workbench", "session-target", "--session", String(session.id), "--target", "7", "--json"
        ]])
        XCTAssertNil(vm.sessionTargetError)
    }

    func testNoneRunsClear() async {
        let runner = Runner()
        let vm = makeVM(runner)
        await vm.setSessionTarget(session, targetID: nil)
        XCTAssertEqual(runner.invocations, [[
            "workbench", "session-target", "--session", String(session.id), "--clear", "--json"
        ]])
    }

    func testAFailureShowsTheFailureLine() async {
        let runner = Runner()
        runner.fail("target 7 is not on this board\n")
        let vm = makeVM(runner)
        await vm.setSessionTarget(session, targetID: 7)
        XCTAssertEqual(vm.sessionTargetError, SessionTargetMenu.failureLine("target 7 is not on this board"))
    }
}

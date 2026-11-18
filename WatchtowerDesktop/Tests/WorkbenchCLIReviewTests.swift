import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Records the argv of each call and answers a fixed output. No process is
/// spawned. Refuses a model command on the generic entries as
/// `ProcessCLIRunner` does (#1886), and records each call's origin.
private final class RecordingCLIRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var last: [String] = []
    private var lastLimit: TimeInterval?
    private var calls: [(args: [String], origin: CLIOrigin?)] = []
    private let output: String

    init(output: String) { self.output = output }

    var lastArgs: [String] { lock.withLock { last } }
    /// The timeout of the last call; nil when it had none.
    var lastTimeout: TimeInterval? { lock.withLock { lastLimit } }
    /// Every call, with the `runModel` origin (nil for a generic call).
    var recorded: [(args: [String], origin: CLIOrigin?)] { lock.withLock { calls } }

    func run(args: [String], timeout: TimeInterval) async throws -> Data {
        try record(args, timeout: timeout, origin: nil)
    }

    func run(args: [String]) async throws -> Data {
        try record(args, timeout: nil, origin: nil)
    }

    func runModel(args: [String], origin: CLIOrigin, timeout: TimeInterval?, stdin _: Data?) async throws -> Data {
        try record(args, timeout: timeout, origin: origin)
    }

    private func record(_ args: [String], timeout: TimeInterval?, origin: CLIOrigin?) throws -> Data {
        if origin == nil { try CLIRunnerError.refuseModelCommand(args) }
        lock.withLock {
            last = args
            lastLimit = timeout
            calls.append((args, origin))
        }
        return Data(output.utf8)
    }
}

final class WorkbenchCLIReviewTests: XCTestCase {
    func testStartBuildsArgsAndDecodes() async throws {
        let runner = RecordingCLIRunner(output: """
        {"ok":true,"round":{"id":7,"status":"open","mode":"quick","folder_root":"/r","base_sha":"b","base_label":"main",
         "tree_sha":"t","prev_round_id":0,"prev_tree_sha":"","prev_tree_lost":false}}
        """)
        let env = try await WorkbenchCLI(runner: runner).reviewStart(projectID: 1, sessionID: 4, refresh: true)
        XCTAssertEqual(runner.lastArgs, ["workbench", "review", "start", "--workbench", "1", "--session", "4", "--refresh", "--json"])
        XCTAssertEqual(env.round?.id, 7)
        XCTAssertEqual(env.round?.baseLabel, "main")
    }

    func testDiffDecodesHunks() async throws {
        let runner = RecordingCLIRunner(output: """
        {"ok":true,"diff":{"files":[{"path":"a.go","status":"modified","additions":1,"deletions":1,"binary":false,
         "new_blob":"blob","new_mode":"100644",
         "hunks":[{"hunk_id":"h","header":"@@ -1 +1 @@","old_start":1,"old_lines":1,"new_start":1,"new_lines":1,"lines":["-a","+b"]}]}],
         "truncated":false},"from":"b","to":"t"}
        """)
        let env = try await WorkbenchCLI(runner: runner).reviewDiff(projectID: 1, roundID: 7, since: true)
        XCTAssertEqual(runner.lastArgs.suffix(3), ["7", "--since", "--json"])
        XCTAssertEqual(env.diff?.files.first?.hunks.first?.hunkId, "h")
        XCTAssertEqual(env.diff?.files.first?.newBlob, "blob")
    }

    func testFileSendApproveAndContextBuildArgs() async throws {
        let runner = RecordingCLIRunner(output: #"{"ok":true}"#)
        let cli = WorkbenchCLI(runner: runner)
        _ = try await cli.reviewFile(projectID: 1, roundID: 7, path: "a b.go", oldPath: nil, since: false)
        XCTAssertEqual(runner.lastArgs, ["workbench", "review", "file", "--workbench", "1", "--round", "7", "--path", "a b.go", "--json"])
        _ = try await cli.reviewFile(projectID: 1, roundID: 7, path: "new.go", oldPath: "old.go", since: true)
        XCTAssertEqual(runner.lastArgs, ["workbench", "review", "file", "--workbench", "1", "--round", "7", "--path", "new.go",
                                         "--old-path", "old.go", "--since", "--json"])
        _ = try await cli.reviewSend(projectID: 1, roundID: 7)
        XCTAssertEqual(runner.lastArgs, ["workbench", "review", "send", "--workbench", "1", "--round", "7", "--json"])
        _ = try await cli.reviewApprove(projectID: 1, roundID: 7, resolveOpen: false)
        XCTAssertEqual(runner.lastArgs, ["workbench", "review", "approve", "--workbench", "1", "--round", "7", "--json"])
        _ = try await cli.reviewApprove(projectID: 1, roundID: 7, resolveOpen: true)
        XCTAssertEqual(runner.lastArgs, ["workbench", "review", "approve", "--workbench", "1", "--round", "7", "--resolve-open", "--json"])
        _ = try await cli.reviewContext(projectID: 1, sessionID: 4)
        XCTAssertEqual(runner.lastArgs, ["workbench", "review", "context", "--workbench", "1", "--session", "4", "--json"])
    }

    func testRefusalEnvelopeIsNotAThrow() async throws {
        let runner = RecordingCLIRunner(output: #"{"ok":false,"error":"the folder is not a git work tree"}"#)
        let env = try await WorkbenchCLI(runner: runner).reviewStart(projectID: 1, sessionID: 4, refresh: false)
        XCTAssertFalse(env.ok)
        XCTAssertEqual(env.error, "the folder is not a git work tree")
    }

    func testAICallsRunWithTheLongTimeout() async throws {
        let runner = RecordingCLIRunner(output: #"{"ok":true}"#)
        let cli = WorkbenchCLI(runner: runner)
        _ = try await cli.reviewOverview(projectID: 1, roundID: 7)
        XCTAssertEqual(runner.lastArgs, ["workbench", "review", "overview", "--workbench", "1", "--round", "7", "--json"])
        XCTAssertEqual(runner.lastTimeout, 330)
        _ = try await cli.reviewOverview(projectID: 1, roundID: 7, cachedOnly: true)
        XCTAssertEqual(runner.lastArgs, ["workbench", "review", "overview", "--workbench", "1", "--round", "7", "--cached-only", "--json"])
        XCTAssertNil(runner.lastTimeout, "a cache read calls no model")
        _ = try await cli.reviewLessons(projectID: 1, action: .propose)
        XCTAssertEqual(runner.lastArgs, ["workbench", "review", "lessons", "propose", "--workbench", "1", "--json"])
        XCTAssertEqual(runner.lastTimeout, 330)
        XCTAssertEqual(runner.recorded.map(\.origin), [.owner, .owner, .owner], "overview (both forms) and propose name the owner")
    }

    /// Every argv the review family builds, fed through `ModelCommands.match`:
    /// the model ones (and only those) go through `runModel` (#1886 Task 18).
    func testEveryModelArgvOfTheReviewFamilyGoesThroughRunModel() async throws {
        let runner = RecordingCLIRunner(output: #"{"ok":true}"#)
        let cli = WorkbenchCLI(runner: runner)
        _ = try await cli.reviewStart(projectID: 1, sessionID: 4, refresh: true)
        _ = try await cli.reviewDiff(projectID: 1, roundID: 7, since: true)
        _ = try await cli.reviewFile(projectID: 1, roundID: 7, path: "a.go", oldPath: "b.go", since: true)
        _ = try await cli.reviewSend(projectID: 1, roundID: 7)
        _ = try await cli.reviewApprove(projectID: 1, roundID: 7, resolveOpen: true)
        _ = try await cli.reviewContext(projectID: 1, sessionID: 4)
        _ = try await cli.reviewMap(projectID: 1, roundID: 7)
        _ = try await cli.reviewOverview(projectID: 1, roundID: 7)
        _ = try await cli.reviewOverview(projectID: 1, roundID: 7, cachedOnly: true)
        _ = try await cli.reviewRevertHunk(projectID: 1, roundID: 7, hunkID: "h", since: false)
        for action: WorkbenchCLI.LessonAction in [.propose, .accept(5), .dismiss(5)] {
            _ = try await cli.reviewLessons(projectID: 1, action: action)
        }
        XCTAssertEqual(runner.recorded.count, 13)
        var models = 0
        for call in runner.recorded {
            let isModel = ModelCommands.match(call.args) != nil
            if isModel { models += 1 }
            XCTAssertEqual(call.origin != nil, isModel, "\(call.args): a model command needs runModel, no other does")
        }
        XCTAssertEqual(models, 3)
    }

    func testRevertAndLessonDecisionsBuildArgsWithoutATimeout() async throws {
        let runner = RecordingCLIRunner(output: #"{"ok":true}"#)
        let cli = WorkbenchCLI(runner: runner)
        _ = try await cli.reviewRevertHunk(projectID: 1, roundID: 7, hunkID: "0123456789abcdef", since: false)
        XCTAssertEqual(runner.lastArgs, ["workbench", "review", "revert-hunk", "--workbench", "1", "--round", "7",
                                         "--hunk", "0123456789abcdef", "--json"])
        XCTAssertNil(runner.lastTimeout)
        _ = try await cli.reviewRevertHunk(projectID: 1, roundID: 7, hunkID: "0123456789abcdef", since: true)
        XCTAssertEqual(runner.lastArgs.suffix(2), ["--since", "--json"])
        _ = try await cli.reviewLessons(projectID: 1, action: .accept(5))
        XCTAssertEqual(runner.lastArgs, ["workbench", "review", "lessons", "accept", "--workbench", "1", "--lesson", "5", "--json"])
        XCTAssertNil(runner.lastTimeout)
        _ = try await cli.reviewLessons(projectID: 1, action: .dismiss(5))
        XCTAssertEqual(runner.lastArgs, ["workbench", "review", "lessons", "dismiss", "--workbench", "1", "--lesson", "5", "--json"])
        XCTAssertNil(runner.lastTimeout)
    }

    /// Ending the iteration of a streamed overview terminates the child's
    /// whole process group (its own children too) and reaps it.
    func testStoppingTheOverviewStreamKillsTheProcessGroup() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wt-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("watchtower")
        let pids = dir.appendingPathComponent("pids")
        try """
        #!/bin/sh
        sleep 30 &
        echo "$$ $!" > "\(pids.path)"
        echo '{"event":"waiting","by":"agent"}'
        wait
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let cli = WorkbenchCLI(runner: ProcessCLIRunner(binaryPath: script.path))

        var first: ReviewStreamEvent?
        for try await event in cli.reviewOverviewStream(projectID: 1, roundID: 7) {
            first = event
            break
        }
        guard case .waiting(let by) = first else { return XCTFail("first event \(String(describing: first))") }
        XCTAssertEqual(by, "agent")
        let ids = try String(contentsOf: pids, encoding: .utf8).split(separator: " ")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        XCTAssertEqual(ids.count, 2)
        defer { ids.forEach { _ = kill($0, SIGKILL) } }
        func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }
        for _ in 0..<300 where ids.contains(where: alive) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(ids.contains(where: alive), "the leader and its child are gone")
    }

    /// `spec-review question` prints one id: anything else says so, not
    /// "not UTF-8".
    func testSpecReviewQuestionNeedsAnID() async throws {
        let ok = WorkbenchCLI(runner: FakeCLIRunner(stdout: Data("42\n".utf8)))
        let id = try await ok.specReviewQuestion(askID: 1, itemKey: "ag:1", question: "why?")
        XCTAssertEqual(id, 42)
        let odd = WorkbenchCLI(runner: FakeCLIRunner(stdout: Data("question filed\n".utf8)))
        do {
            _ = try await odd.specReviewQuestion(askID: 1, itemKey: "ag:1", question: "why?")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? WorkbenchCLIError, .unexpectedOutput(command: "workbench spec-review question"))
            XCTAssertEqual(error.localizedDescription, "`watchtower workbench spec-review question` did not print an id")
        }
    }
}

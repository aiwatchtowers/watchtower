import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Records the argv of each call and answers a fixed output. No process is spawned.
private final class RecordingCLIRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var last: [String] = []
    private var lastLimit: TimeInterval?
    private let output: String

    init(output: String) { self.output = output }

    var lastArgs: [String] { lock.withLock { last } }
    /// The timeout of the last call; nil when it had none.
    var lastTimeout: TimeInterval? { lock.withLock { lastLimit } }

    func run(args: [String], timeout: TimeInterval) async throws -> Data {
        lock.withLock { last = args; lastLimit = timeout }
        return Data(output.utf8)
    }

    func run(args: [String]) async throws -> Data {
        lock.withLock { last = args; lastLimit = nil }
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

    func testFileSendAndContextBuildArgs() async throws {
        let runner = RecordingCLIRunner(output: #"{"ok":true}"#)
        let cli = WorkbenchCLI(runner: runner)
        _ = try await cli.reviewFile(projectID: 1, roundID: 7, path: "a b.go", oldPath: nil, since: false)
        XCTAssertEqual(runner.lastArgs, ["workbench", "review", "file", "--workbench", "1", "--round", "7", "--path", "a b.go", "--json"])
        _ = try await cli.reviewFile(projectID: 1, roundID: 7, path: "new.go", oldPath: "old.go", since: true)
        XCTAssertEqual(runner.lastArgs, ["workbench", "review", "file", "--workbench", "1", "--round", "7", "--path", "new.go",
                                         "--old-path", "old.go", "--since", "--json"])
        _ = try await cli.reviewSend(projectID: 1, roundID: 7)
        XCTAssertEqual(runner.lastArgs, ["workbench", "review", "send", "--workbench", "1", "--round", "7", "--json"])
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
        _ = try await cli.reviewLessons(projectID: 1, action: .propose)
        XCTAssertEqual(runner.lastArgs, ["workbench", "review", "lessons", "propose", "--workbench", "1", "--json"])
        XCTAssertEqual(runner.lastTimeout, 330)
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
}

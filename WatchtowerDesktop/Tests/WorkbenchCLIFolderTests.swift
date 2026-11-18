import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The folder verbs' argv and JSON (#2003, Go `cmd/workbench_folder.go`),
/// the start's folder and parent flags and refusals, and Re-run Setup's
/// other folders. The Desktop writes the new tables only through these.
final class WorkbenchCLIFolderTests: XCTestCase {
    private static let hubJSON = #"{"id":5,"path":"/tmp/hub","name":"hub","position":1,"home":false,"installed":true,"removed":false}"#

    func testFolderResultDecodesEveryCode() throws {
        let codes = ["already_here", "other_bench", "nested", "not_found", "not_installed", "folder_missing", "folder_removed",
                     "sessions_running", "last_folder", "limit", "too_long", "not_running", "not_same_workbench", "self",
                     "declined", "not_allowed", "bad_args"]
        XCTAssertEqual(Set(WorkbenchRefusalCode.allCases.map(\.rawValue)), Set(codes))
        for code in codes {
            let json = #"{"ok":false,"error_code":"\#(code)","error":"\#(code): no"}"#
            let result = try JSONDecoder().decode(FolderResult.self, from: Data(json.utf8))
            XCTAssertFalse(result.ok)
            XCTAssertEqual(result.code?.rawValue, code)
            XCTAssertEqual(result.error, "\(code): no")
            XCTAssertNil(result.folder)
        }
        let newer = try JSONDecoder().decode(FolderResult.self, from: Data(#"{"ok":false,"error_code":"later","error":"later: x"}"#.utf8))
        XCTAssertNil(newer.code, "a code this build does not know stays raw")
        XCTAssertEqual(newer.errorCode, "later")
    }

    func testFolderResultCarriesTheFolderTheOtherBenchAndTheInstall() throws {
        let other = #"{"ok":false,"error_code":"other_bench","error":"other_bench: on web","other_bench":{"id":9,"name":"web"}}"#
        let refused = try JSONDecoder().decode(FolderResult.self, from: Data(other.utf8))
        XCTAssertEqual(refused.otherBench, FolderResult.OtherBench(id: 9, name: "web"))
        XCTAssertEqual(refused.code, .otherBench)

        let added = #"{"ok":true,"error_code":"","error":"","folder":\#(Self.hubJSON),"install":{"ok":false,"error":"denied"}}"#
        let result = try JSONDecoder().decode(FolderResult.self, from: Data(added.utf8))
        XCTAssertTrue(result.ok)
        XCTAssertNil(result.code)
        XCTAssertEqual(result.folder, FolderInfo(id: 5, path: "/tmp/hub", name: "hub", position: 1, home: false,
                                                 installed: true, removed: false))
        XCTAssertEqual(result.install, FolderResult.Step(ok: false, error: "denied"), "a failed install keeps the folder (§7 row 2)")
    }

    func testFolderVerbsArgv() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"error_code":"","error":"","folder":\#(Self.hubJSON)}"#.utf8))
        let cli = WorkbenchCLI(runner: runner)
        _ = try await cli.folderAdd(workbenchID: 7, path: "/tmp/hub dir")
        _ = try await cli.folderAdd(workbenchID: 7, path: "/tmp/hub", addedBy: .agentSuggestion)
        _ = try await cli.folderRemove(workbenchID: 7, folderID: 5)
        _ = try await cli.folderLocate(workbenchID: 7, folderID: 5, to: "/tmp/moved hub")
        XCTAssertEqual(runner.invocations, [
            ["workbench", "folder", "add", "--workbench", "7", "--folder", "/tmp/hub dir", "--added-by", "owner", "--json"],
            ["workbench", "folder", "add", "--workbench", "7", "--folder", "/tmp/hub", "--added-by", "agent_suggestion", "--json"],
            ["workbench", "folder", "remove", "--workbench", "7", "--folder", "5", "--json"],
            ["workbench", "folder", "locate", "--workbench", "7", "--folder", "5", "--to", "/tmp/moved hub", "--json"]
        ])
    }

    func testFolderListAndItsEmptyState() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"folders":[\#(Self.hubJSON)]}"#.utf8))
        let listed = try await WorkbenchCLI(runner: runner).folderList(workbenchID: 7, withRemoved: true)
        XCTAssertEqual(listed.map(\.name), ["hub"])
        XCTAssertEqual(runner.invocations, [["workbench", "folder", "list", "--workbench", "7", "--with-removed", "--json"]])

        let empty = FakeCLIRunner(stdout: Data(#"{"folders":[]}"#.utf8))
        let none = try await WorkbenchCLI(runner: empty).folderList(workbenchID: 7)
        XCTAssertEqual(none, [])
        XCTAssertEqual(empty.invocations, [["workbench", "folder", "list", "--workbench", "7", "--json"]])
    }

    /// Not Now, Never for This Folder and the prompt-flag Dismiss go through
    /// the CLI: the Desktop never writes those tables itself.
    func testQuietDeclineAndDismissGoThroughTheCLI() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true}"#.utf8))
        let cli = WorkbenchCLI(runner: runner)
        let quiet = try await cli.folderQuiet(sessionID: 12, root: "/tmp/hub")
        _ = try await cli.folderDecline(workbenchID: 7, path: "/tmp/hub")
        _ = try await cli.messageDismiss(id: 31)
        XCTAssertTrue(quiet.ok)
        XCTAssertEqual(runner.invocations, [
            ["workbench", "folder", "quiet", "--session", "12", "--root", "/tmp/hub", "--json"],
            ["workbench", "folder", "decline", "--workbench", "7", "--folder", "/tmp/hub", "--json"],
            ["workbench", "message", "dismiss", "--id", "31", "--json"]
        ])
        let refused = try JSONDecoder().decode(WorkbenchCLIAck.self,
                                               from: Data(#"{"ok":false,"error_code":"not_found","error":"not_found: no #31"}"#.utf8))
        XCTAssertEqual(refused.code, .notFound)
        XCTAssertEqual(refused.error, "not_found: no #31")
    }

    // MARK: Session start

    func testStartPassesTheFolderAndTheParent() {
        var request = SessionStartRequest(workbenchID: 7, agent: .claude, place: .auto)
        XCTAssertFalse(request.args.contains("--folder"), "the home folder sends no flag")
        XCTAssertFalse(request.args.contains("--parent"))
        request.folderID = 5
        request.parentSessionID = 12
        XCTAssertEqual(request.args, ["workbench", "session", "start", "--workbench", "7", "--folder", "5", "--parent", "12",
                                      "--agent", "claude", "--place", "auto", "--json"])
    }

    func testAStartRefusalCarriesItsCode() async throws {
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "not_installed: Install Watchtower in hub first\n"))
        do {
            _ = try await WorkbenchCLI(runner: runner).sessionStart(SessionStartRequest(workbenchID: 7, agent: .claude, place: .auto))
            XCTFail("a refused start throws")
        } catch let WorkbenchCLIError.startRefused(code, message) {
            XCTAssertEqual(code, .notInstalled)
            XCTAssertEqual(message, "not_installed: Install Watchtower in hub first")
        }

        let other = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "database is locked"))
        do {
            _ = try await WorkbenchCLI(runner: other).sessionStart(SessionStartRequest(workbenchID: 7, agent: .claude, place: .auto))
            XCTFail("a failed start throws")
        } catch CLIRunnerError.nonZeroExit(code: 1, let stderr) {
            XCTAssertEqual(stderr, "database is locked", "any other failure stays the runner's")
        }
    }

    // MARK: Re-run Setup over every folder

    private func resynced(_ tail: String) throws -> WorkbenchResynced {
        let json = #"{"integration_ok":true,"integration_error":"","skill":"unchanged","hooks_added":false,"excluded":[],"#
            + #""mcp_registered":true,"mcp_command":"","suggestions":[],"suggestions_error":""\#(tail)}"#
        return try JSONDecoder().decode(WorkbenchResynced.self, from: Data(json.utf8))
    }

    func testResyncFoldsAnotherFoldersFailureIntoTheSummary() throws {
        let older = try resynced("")
        XCTAssertEqual(older.folders, [], "an older CLI sends no folders")
        XCTAssertEqual(older.summaryLines.map(\.text), ["Everything was already up to date."])

        let fine = try resynced(#","folders":[{"id":5,"name":"hub","path":"/tmp/hub","ok":true,"error":""}],"folders_error":"""#)
        XCTAssertEqual(fine.summaryLines.map(\.text), ["Everything was already up to date."])

        let empty = try resynced(#","folders":[],"folders_error":"""#)
        XCTAssertEqual(empty.folders, [])

        let failed = try resynced(#","folders":[{"id":5,"name":"hub","path":"/tmp/hub","ok":false,"error":"permission denied"}],"#
            + #""folders_error":"""#)
        XCTAssertEqual(failed.summaryLines, [.init(text: "Setting up hub failed: permission denied", problem: true)])
        XCTAssertTrue(failed.integrationOK, "the home folder's install did not fail")

        let unread = try resynced(#","folders":[],"folders_error":"database is locked""#)
        XCTAssertEqual(unread.summaryLines, [.init(text: "The other folders were not set up: database is locked", problem: true)])
    }
}

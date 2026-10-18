import XCTest
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Task 9: `WorkbenchCLI` instructions calls keep owner text off argv and
/// surface Go's refusal text as it is.
final class WorkbenchCLIInstructionsTests: XCTestCase {
    private static let ok = Data(
        #"{"ok":true,"limit":1000,"global":{"session":"","procedure":""},"workbench":null,"suggestions":[]}"#.utf8
    )

    func testSetInstructionSendsTheBodyOnStdinOnly() async throws {
        let runner = FakeCLIRunner(stdout: Self.ok)
        _ = try await WorkbenchCLI(runner: runner).setInstruction(field: .procedure, workbenchID: 7, body: "секрет text")
        let args = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(args, ["instructions", "set", "--field", "procedure", "--stdin", "--workbench", "7", "--json"])
        XCTAssertFalse(args.contains { $0.contains("секрет") })
        XCTAssertEqual(runner.stdinInputs, [Data("секрет text".utf8)])
    }

    func testDecideSuggestionPassesNoWorkbench() async throws {
        let runner = FakeCLIRunner(stdout: Self.ok)
        _ = try await WorkbenchCLI(runner: runner).decideSuggestion(id: 3, add: true)
        _ = try await WorkbenchCLI(runner: runner).decideSuggestion(id: 4, add: false)
        XCTAssertEqual(runner.invocations, [
            ["instructions", "suggestion", "add", "3", "--json"],
            ["instructions", "suggestion", "dismiss", "4", "--json"]
        ])
    }

    func testRefusalThrowsGoTextTrimmed() async {
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(
            code: 1, stderr: "session instructions: over the 1000 character limit\n"))
        do {
            _ = try await WorkbenchCLI(runner: runner).setInstruction(field: .session, workbenchID: nil, body: "x")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual((error as? OwnerInstructionsError)?.message, "session instructions: over the 1000 character limit")
        }
    }
}

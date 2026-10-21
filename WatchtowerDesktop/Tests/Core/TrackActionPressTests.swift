import XCTest
import WatchtowerCore
import WatchtowerTestSupport

final class TrackActionPressTests: XCTestCase {
    func testArgumentsAreTheCLIContract() {
        XCTAssertEqual(TrackActionPress.arguments(eventID: 7), [
            "actions", "propose", "--tool", "apply_track_action", "--surface", "inbox",
            "--context-type", "track_event", "--context-id", "7",
            "--args", "{\"event_id\":7}", "--approve", "--json"
        ])
    }

    func testSuccessRunsTheContractCommandOnce() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"applied_ok":true,"error":""}"#.utf8))
        try await TrackActionPress(runner: runner).press(eventID: 7)
        XCTAssertEqual(runner.invocations, [TrackActionPress.arguments(eventID: 7)])
    }

    private func message(_ runner: FakeCLIRunner) async -> String? {
        do { try await TrackActionPress(runner: runner).press(eventID: 7); return nil } catch { return error.localizedDescription }
    }

    func testNonZeroExitShowsTheStderrText() async {
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "This change was already applied.\n"))
        let text = await message(runner)
        XCTAssertEqual(text, "This change was already applied.")
    }

    func testRefusalSurfacesTheCLIText() async {
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":false,"error":"This change was already applied."}"#.utf8))
        let text = await message(runner)
        XCTAssertEqual(text, "This change was already applied.")
    }

    func testAppliedFalseShowsTheEnvelopeError() async {
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"applied_ok":false,"error":"The task is gone."}"#.utf8))
        let text = await message(runner)
        XCTAssertEqual(text, "The task is gone.")
    }

    func testAppliedFalseWithoutTextStillFails() async {
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"applied_ok":false}"#.utf8))
        let text = await message(runner)
        XCTAssertNotNil(text)
    }

    func testUnreadableAnswerFails() async {
        let text = await message(FakeCLIRunner(stdout: Data("not json".utf8)))
        XCTAssertNotNil(text)
    }
}

import XCTest
@testable import WatchtowerDesktop

@MainActor
final class TargetExtractCenterTests: XCTestCase {

    func testStartOnSuccessSetsPendingResultAndClearsRunning() async {
        let center = TargetExtractCenter()
        let json = """
        {
          "extracted": [
            {
              "text": "Ship feature",
              "intent": "",
              "level": "day",
              "custom_label": "",
              "period_start": "2026-07-09",
              "period_end": "2026-07-09",
              "priority": "medium",
              "due_date": "",
              "parent_id": null,
              "ai_level_confidence": null,
              "secondary_links": []
            }
          ],
          "omitted_count": 0,
          "notes": ""
        }
        """
        let runner = FakeCLIRunner(stdout: Data(json.utf8))

        await center.start(text: "ship feature", runner: runner)

        XCTAssertFalse(center.isRunning)
        XCTAssertEqual(center.pendingResult?.extracted.count, 1)
        XCTAssertEqual(center.pendingResult?.extracted.first?.text, "Ship feature")
        XCTAssertNil(center.pendingError)
    }

    func testStartWithEmptyExtractionSetsPendingError() async {
        let center = TargetExtractCenter()
        let runner = FakeCLIRunner(stdout: Data("{\"extracted\": [], \"omitted_count\": 0, \"notes\": \"\"}".utf8))

        await center.start(text: "nothing here", runner: runner)

        XCTAssertFalse(center.isRunning)
        XCTAssertNil(center.pendingResult)
        XCTAssertEqual(center.pendingError, "AI returned no extracted targets")
    }

    func testStartOnCLIErrorSetsPendingError() async {
        let center = TargetExtractCenter()
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "boom"))

        await center.start(text: "sample", runner: runner)

        XCTAssertFalse(center.isRunning)
        XCTAssertNil(center.pendingResult)
        XCTAssertTrue(center.pendingError?.hasPrefix("Extract failed:") ?? false)
    }

    func testStartWhileRunningIsANoOp() async {
        let center = TargetExtractCenter()
        center.isRunning = true
        center.draftText = "original draft"

        let runner = FakeCLIRunner(stdout: Data("{\"extracted\": [], \"omitted_count\": 0, \"notes\": \"\"}".utf8))
        await center.start(text: "second draft", runner: runner)

        XCTAssertTrue(center.isRunning, "the guard must leave the in-flight flag untouched")
        XCTAssertEqual(center.draftText, "original draft", "a blocked start must not overwrite the in-flight draft")
        XCTAssertEqual(runner.invocations.count, 0, "the CLI runner must never be invoked while blocked")
    }

    func testClearPendingClearsBothResultAndError() {
        let center = TargetExtractCenter()
        center.pendingResult = TargetExtractResult(extracted: [], omittedCount: 0, notes: "")
        center.pendingError = "some error"

        center.clearPending()

        XCTAssertNil(center.pendingResult)
        XCTAssertNil(center.pendingError)
    }
}

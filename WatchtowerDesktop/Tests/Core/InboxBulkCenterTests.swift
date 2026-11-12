import XCTest
@testable import WatchtowerCore

/// Mark All Done… on a Mail waiting sender row and on Waiting for me's
/// Older row: one press model per key, a dry run first, then exactly the
/// planned ids, and the strip's refresh after every result.
@MainActor
final class InboxBulkCenterTests: XCTestCase {
    /// Answers each `capture` with the next scripted stdout / exit code.
    private final class ScriptedRunner: CLIRunnerProtocol, @unchecked Sendable {
        var answers: [(stdout: String, exitCode: Int32)]
        private(set) var calls: [[String]] = []

        init(_ answers: [(stdout: String, exitCode: Int32)]) {
            self.answers = answers
        }

        func run(args: [String]) async throws -> Data {
            XCTFail("bulk calls go through capture")
            return Data()
        }

        func capture(args: [String], timeout: TimeInterval) async throws -> CLICapturedResult {
            calls.append(args)
            guard !answers.isEmpty else {
                XCTFail("unexpected call \(args)")
                return CLICapturedResult(stdout: Data(), exitCode: 1, stderr: "no answer")
            }
            let answer = answers.removeFirst()
            return CLICapturedResult(stdout: Data(answer.stdout.utf8), exitCode: answer.exitCode, stderr: "")
        }
    }

    private var refreshes = 0

    private func center(_ runner: ScriptedRunner) -> InboxBulkCenter {
        InboxBulkCenter(cli: { InboxBulkCLI(runner: runner) }, onFinished: { [weak self] in self?.refreshes += 1 })
    }

    private func waitUntil(_ model: InboxBulkPressModel, _ done: (InboxBulkPressModel.State) -> Bool) async {
        let deadline = Date().addingTimeInterval(10)
        while !done(model.state) {
            guard Date() < deadline else { return XCTFail("still \(model.state)") }
            await Task.yield()
        }
    }

    private func isConfirming(_ state: InboxBulkPressModel.State) -> Bool {
        if case .confirming = state { return true }
        return false
    }

    private func isFinished(_ state: InboxBulkPressModel.State) -> Bool {
        if case .finished = state { return true }
        return false
    }

    func testSenderPressPlansThenResolvesExactlyThePlannedIDs() async {
        let runner = ScriptedRunner([
            (#"{"count":2,"ids":["12","5"]}"#, 0),
            (#"{"resolved":2,"skipped":0,"ids":["12","5"]}"#, 0)
        ])
        let center = center(runner)
        let key = InboxBulkKey.sender(" Colleague-A@Example.com")
        let model = center.model(for: key)

        center.begin(key)
        await waitUntil(model, isConfirming)
        XCTAssertEqual(model.state, .confirming(InboxBulkPlan(ids: ["12", "5"], count: 2)))
        XCTAssertEqual(refreshes, 0, "a plan changes nothing")

        model.confirm()
        await waitUntil(model, isFinished)

        XCTAssertEqual(model.state, .finished(.done(count: 2, skipped: 0)))
        XCTAssertEqual(runner.calls, [
            InboxBulkCLI.args(.planSender("colleague-a@example.com")),
            InboxBulkCLI.args(.resolve(ids: ["12", "5"]))
        ], "the sender's one spelling; only the planned ids")
        XCTAssertEqual(refreshes, 1)
    }

    func testOlderPeoplePlansSevenDays() async {
        let runner = ScriptedRunner([(#"{"count":1,"ids":["3"]}"#, 0)])
        let center = center(runner)
        let model = center.model(for: .olderPeople)

        center.begin(.olderPeople)
        await waitUntil(model, isConfirming)

        XCTAssertEqual(runner.calls, [InboxBulkCLI.args(.planOlderPeople(days: 7))])
        model.cancel()
        XCTAssertEqual(model.state, .idle)
    }

    func testStateSurvivesAReadOfTheModelAgain() async {
        let runner = ScriptedRunner([(#"{"count":1,"ids":["3"]}"#, 0)])
        let center = center(runner)
        let first = center.model(for: .sender("a@example.com"))

        center.begin(.sender("a@example.com"))
        await waitUntil(first, isConfirming)

        XCTAssertTrue(center.model(for: .sender("a@example.com")) === first)
        XCTAssertTrue(center.model(for: .sender(" A@EXAMPLE.com ")) === first, "one sender, many spellings")
        XCTAssertFalse(center.model(for: .sender("b@example.com")) === first)
        XCTAssertFalse(center.model(for: .olderPeople) === first)
        XCTAssertTrue(isConfirming(center.model(for: .sender("a@example.com")).state))
    }

    func testRefreshAfterEveryResult() async {
        let answers: [(stdout: String, exitCode: Int32, result: InboxBulkResult)] = [
            (#"{"resolved":2,"skipped":0,"ids":["1","2"]}"#, 0, .done(count: 2, skipped: 0)),
            (#"{"resolved":1,"of":2,"error":"database is locked"}"#, 1,
             .partial(done: 1, of: 2, error: "database is locked")),
            (#"{"resolved":0,"of":2,"error":"database is locked"}"#, 1, .failed("database is locked"))
        ]
        for (index, answer) in answers.enumerated() {
            refreshes = 0
            let runner = ScriptedRunner([(#"{"count":2,"ids":["1","2"]}"#, 0), (answer.stdout, answer.exitCode)])
            let center = center(runner)
            let model = center.model(for: .olderPeople)
            center.begin(.olderPeople)
            await waitUntil(model, isConfirming)
            model.confirm()
            await waitUntil(model, isFinished)
            XCTAssertEqual(model.state, .finished(answer.result), "case \(index)")
            XCTAssertEqual(refreshes, 1, "case \(index)")
        }
    }

    func testEmptyPlanRefreshesTheStaleRow() async {
        let runner = ScriptedRunner([(#"{"count":0,"ids":[]}"#, 0)])
        let center = center(runner)
        let model = center.model(for: .sender("a@example.com"))

        center.begin(.sender("a@example.com"))
        await waitUntil(model, isFinished)

        XCTAssertEqual(model.state, .finished(.done(count: 0, skipped: 0)))
        XCTAssertEqual(refreshes, 1, "the row the owner pressed was stale")
    }

    func testFailedDryRunRefreshesToo() async {
        let runner = ScriptedRunner([(#"{"resolved":0,"of":0,"error":"refused under an agent"}"#, 1)])
        let center = center(runner)
        let model = center.model(for: .olderPeople)

        center.begin(.olderPeople)
        await waitUntil(model, isFinished)

        XCTAssertEqual(model.state, .finished(.failed("refused under an agent")))
        XCTAssertEqual(refreshes, 1, "the row redraws with the result line")
    }

    func testTryAgainRunsTheDryRunAgain() async {
        let runner = ScriptedRunner([
            (#"{"count":3,"ids":["1","2","3"]}"#, 0),
            (#"{"resolved":1,"of":3,"error":"database is locked"}"#, 1),
            (#"{"count":2,"ids":["2","3"]}"#, 0)
        ])
        let center = center(runner)
        let model = center.model(for: .sender("a@example.com"))
        center.begin(.sender("a@example.com"))
        await waitUntil(model, isConfirming)
        model.confirm()
        await waitUntil(model, isFinished)

        // Try Again is the button's `model.begin()`: the stored plan, a new dry run.
        model.begin()
        await waitUntil(model, isConfirming)

        XCTAssertEqual(model.state, .confirming(InboxBulkPlan(ids: ["2", "3"], count: 2)))
        XCTAssertEqual(runner.calls.last, InboxBulkCLI.args(.planSender("a@example.com")))
        XCTAssertEqual(runner.calls.count, 3)
    }
}

import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// Answers each `automations <verb>` with its scripted stdout or error.
private final class VerbRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: Result<Data, Error>]
    private var recorded: [[String]] = []

    init(_ answers: [String: Result<Data, Error>]) {
        self.answers = answers
    }

    var invocations: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func set(_ verb: String, _ answer: Result<Data, Error>) {
        lock.lock()
        defer { lock.unlock() }
        answers[verb] = answer
    }

    func run(args: [String]) async throws -> Data {
        lock.lock()
        recorded.append(args)
        let answer = args.count > 1 ? answers[args[1]] : nil
        lock.unlock()
        guard let answer else { throw CLIRunnerError.nonZeroExit(code: 1, stderr: "unscripted \(args)") }
        return try answer.get()
    }

    func run(args: [String], timeout: TimeInterval) async throws -> Data { try await run(args: args) }
    func run(args: [String], stdin: Data) async throws -> Data { try await run(args: args) }
}

@MainActor
final class BuiltinAutomationCardModelTests: XCTestCase {
    private static let ownCopy = "---\nname: Morning brief\n---\nMy own words.\n"

    /// `show --json` for built-in 3 with the golden block, `builtin` fields
    /// replaced by `overrides`.
    private static func show(needsConfirmation: Bool = false, _ overrides: [String: Any] = [:]) throws -> Data {
        var block = try XCTUnwrap(
            JSONSerialization.jsonObject(with: BuiltinAutomationDetailDecodingTests.golden()) as? [String: Any])
        block.merge(overrides) { _, new in new }
        let detail: [String: Any] = [
            "id": 3, "slug": "morning-brief", "scope": "personal", "path": "builtin:morning-brief",
            "name": "Morning brief", "enabled": true, "runnable": !needsConfirmation,
            "needs_confirmation": needsConfirmation, "builtin": block
        ]
        return try JSONSerialization.data(withJSONObject: detail)
    }

    private func model(_ runner: VerbRunner, overridden: Bool = false) -> BuiltinAutomationCardModel {
        let automation = Automation(
            id: 3, slug: "morning-brief", path: "builtin:morning-brief", name: "Morning brief",
            triggerKind: "sync", triggerSpecJSON: #"{"sync":"morning_brief"}"#, recipeText: Self.ownCopy,
            approvalHash: "h", confirmedHash: "h", enabled: true, origin: .builtin, builtinID: "morning-brief",
            overridden: overridden)
        return BuiltinAutomationCardModel(automation: automation, cli: AutomationsCLI(runner: runner))
    }

    func testCardStateForShippedCopyAndUnconfirmed() async throws {
        let runner = VerbRunner(["show": .success(try Self.show())])
        let card = model(runner)
        await card.load()
        XCTAssertEqual(card.cardState, .shipped)

        runner.set("show", .success(try Self.show(["overridden": true])))
        await card.load()
        XCTAssertEqual(card.cardState, .ownCopyConfirmed)

        runner.set("show", .success(try Self.show(needsConfirmation: true, ["overridden": true])))
        await card.load()
        XCTAssertEqual(card.cardState, .ownCopyUnconfirmed)

        runner.set("show", .success(try Self.show(["overridden": true, "copy_error": "not a regular file"])))
        await card.load()
        XCTAssertEqual(card.cardState, .copyError("not a regular file"))
        XCTAssertNil(card.loadError)
    }

    func testUpdateBannerOnlyWhenOverriddenAndUpdated() async throws {
        let runner = VerbRunner(["show": .success(try Self.show(["update_available": true]))])
        let card = model(runner)
        XCTAssertFalse(card.updateBanner, "nothing loaded")
        await card.load()
        XCTAssertFalse(card.updateBanner, "not overridden")
        runner.set("show", .success(try Self.show(["overridden": true, "update_available": false])))
        await card.load()
        XCTAssertFalse(card.updateBanner, "no update")
        runner.set("show", .success(try Self.show(["overridden": true, "update_available": true])))
        await card.load()
        XCTAssertTrue(card.updateBanner)
    }

    func testCostsLineCases() async throws {
        let runner = VerbRunner(["show": .success(try Self.show())])
        let card = model(runner)
        XCTAssertEqual(card.costsLine, "Cost not reported", "nothing loaded")
        await card.load()
        XCTAssertEqual(card.costsLine, "Cost not reported")
        runner.set("show", .success(try Self.show(["costs": ["usd": 0, "days": 7, "reported": true]])))
        await card.load()
        XCTAssertEqual(card.costsLine, "No AI cost in the last 7 days")
        runner.set("show", .success(try Self.show(["costs": ["usd": 1.234, "days": 7, "reported": true]])))
        await card.load()
        XCTAssertEqual(card.costsLine, "About $1.23 in the last 7 days")
    }

    func testResetKeepsConfirmRowOnFailure() async throws {
        let runner = VerbRunner([
            "show": .success(try Self.show(["overridden": true])),
            "reset": .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "reset refused\n"))
        ])
        let card = model(runner, overridden: true)
        await card.load()
        card.beginReset()
        await card.confirmReset()
        XCTAssertTrue(card.resetConfirming)
        XCTAssertEqual(card.loadError, "reset refused")
        XCTAssertFalse(card.isWorking)
        XCTAssertEqual(card.cardState, .ownCopyConfirmed)
        card.cancelReset()
        XCTAssertFalse(card.resetConfirming)
    }

    func testResetClearsOnSuccess() async throws {
        let runner = VerbRunner([
            "show": .success(try Self.show(["overridden": true])),
            "reset": .success(Data(#"{"automation_id":3,"overridden":false,"approval_hash":"h2"}"#.utf8))
        ])
        let card = model(runner, overridden: true)
        await card.load()
        card.beginReset()
        card.showingChanges = true
        runner.set("show", .success(try Self.show()))
        await card.confirmReset()
        XCTAssertFalse(card.resetConfirming)
        XCTAssertFalse(card.showingChanges)
        XCTAssertNil(card.loadError)
        XCTAssertEqual(card.cardState, .shipped, "reloaded after the reset")
        XCTAssertEqual(runner.invocations.map { $0[1] }, ["show", "reset", "show"])
        XCTAssertEqual(runner.invocations[1], ["automations", "reset", "3", "--json"])
    }

    func testShowChangesDiffsCopyAgainstShipped() async throws {
        let runner = VerbRunner(["show": .success(try Self.show(["overridden": true]))])
        let card = model(runner, overridden: true)
        await card.load()
        XCTAssertNil(card.changes, "only while Show changes is on")
        card.showingChanges = true
        let diff = try XCTUnwrap(card.changes)
        let shipped = try XCTUnwrap(card.detail?.shippedText)
        XCTAssertEqual(diff, OwnerAskSnapshotDiff(previous: shipped, current: Self.ownCopy))
        XCTAssertTrue(diff.lines.contains(.added("My own words.")))
    }

    func testRunNowQueuesAManualRun() async throws {
        let runner = VerbRunner([
            "run": .success(Data(#"{"run_id":9,"coalesced":false,"daemon_running":true}"#.utf8))
        ])
        let card = model(runner)
        await card.runNow()
        XCTAssertEqual(runner.invocations, [["automations", "run", "3", "--json"]])
        XCTAssertNil(card.loadError)
        XCTAssertFalse(card.isWorking)
    }

    func testLoadFailureIsKept() async {
        let runner = VerbRunner([:])
        let card = model(runner)
        await card.load()
        XCTAssertNotNil(card.loadError)
        XCTAssertNil(card.detail)
        XCTAssertEqual(card.cardState, .shipped, "the row's state until a show succeeds")
    }
}

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
    private static func show(
        needsConfirmation: Bool = false, recipeText: String = ownCopy, _ overrides: [String: Any] = [:]
    ) throws -> Data {
        var block = try XCTUnwrap(
            JSONSerialization.jsonObject(with: BuiltinAutomationDetailDecodingTests.golden()) as? [String: Any])
        block.merge(overrides) { _, new in new }
        let detail: [String: Any] = [
            "id": 3, "slug": "morning-brief", "scope": "personal", "path": "builtin:morning-brief",
            "name": "Morning brief", "enabled": true, "runnable": !needsConfirmation,
            "needs_confirmation": needsConfirmation, "recipe_text": recipeText, "builtin": block
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
        runner.set("show", .success(try Self.show(["costs": ["usd": 0, "days": 7, "reported": false, "tokens": 12345]])))
        await card.load()
        XCTAssertEqual(card.costsLine, "12,345 tokens in the last 7 days (cost not reported)")
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

    func testShowChangesUsesTheFreshestRecipeText() async throws {
        let fresh = "---\nname: Morning brief\n---\nEdited since.\n"
        let runner = VerbRunner(["show": .success(try Self.show(recipeText: fresh, ["overridden": true]))])
        let card = model(runner, overridden: true)
        await card.load()
        card.showingChanges = true
        let diff = try XCTUnwrap(card.changes)
        XCTAssertTrue(diff.lines.contains(.added("Edited since.")), "the show's text, not the init row's")
        XCTAssertFalse(diff.lines.contains(.added("My own words.")))
    }

    func testRunNowKeepsAShowError() async throws {
        let runner = VerbRunner([
            "show": .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "show failed")),
            "run": .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "run failed"))
        ])
        let card = model(runner)
        await card.load()
        XCTAssertEqual(card.loadError, "show failed")
        runner.set("run", .success(Data(#"{"run_id":9,"coalesced":false,"daemon_running":true}"#.utf8)))
        await card.runNow()
        XCTAssertEqual(card.loadError, "show failed", "a Run Now success clears only its own error")

        runner.set("run", .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "run failed")))
        await card.runNow()
        XCTAssertEqual(card.loadError, "run failed")
        runner.set("run", .success(Data(#"{"run_id":10,"coalesced":false,"daemon_running":true}"#.utf8)))
        await card.runNow()
        XCTAssertNil(card.loadError)
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
        XCTAssertTrue(card.runQueued, "the card says it runs at the next sync")

        runner.set("run", .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "run failed")))
        await card.runNow()
        XCTAssertFalse(card.runQueued, "a refused press queued nothing")
    }

    private func item(_ automation: Automation, lastRunID: Int64?) -> AutomationListItem {
        let run = lastRunID.map { AutomationRun(id: $0, automationID: automation.id, status: .succeeded) }
        return AutomationListItem(automation: automation, lastRun: run, activeRun: nil, tokens7d: 0, badges: [],
                                  triggerText: "")
    }

    /// "Runs at the next sync" lasts until the row shows the queued run finished.
    func testRunQueuedClearsOnceTheQueuedRunFinished() async throws {
        let runner = VerbRunner([
            "run": .success(Data(#"{"run_id":9,"coalesced":false,"daemon_running":true}"#.utf8))
        ])
        let card = model(runner)
        await card.runNow()
        card.observe(item(card.automation, lastRunID: 8))
        XCTAssertTrue(card.runQueued, "an older finished run is not the queued one")
        card.observe(item(card.automation, lastRunID: nil))
        XCTAssertTrue(card.runQueued)
        card.observe(item(card.automation, lastRunID: 9))
        XCTAssertFalse(card.runQueued)
    }

    // MARK: - When fields and on/off (C2 Task 10)

    func testWhenFieldValidation() async throws {
        let card = model(VerbRunner(["show": .success(try Self.show())]))
        await card.load()
        XCTAssertFalse(card.parametersChanged)
        card.parameterEdits = ["briefing.hour": "8"]
        XCTAssertFalse(card.parametersChanged, "the value it had")
        card.parameterEdits = ["briefing.hour": "9", "day_plan.working_hours_start": "08:30"]
        XCTAssertTrue(card.parametersChanged)
        XCTAssertNil(card.invalidParameter)
        card.parameterEdits = ["day_plan.working_hours_end": "7pm"]
        XCTAssertEqual(card.invalidParameter, "to: use HH:MM, for example 09:00")
        for bad in ["9:00", "24:00", "09:60", "0900", ""] {
            XCTAssertFalse(BuiltinAutomationCardModel.isClock(bad), bad)
        }
        XCTAssertTrue(BuiltinAutomationCardModel.isClock("23:59"))
    }

    /// The counts: whole numbers from 0, and the backlog's at-least never
    /// above its at-most (edited or as shown); no save while it is.
    func testCountFieldsAndBacklogOrder() async throws {
        let card = model(VerbRunner(["show": .success(try Self.show())]))
        await card.load()
        card.parameterEdits = ["day_plan.max_timeblocks": "-1"]
        XCTAssertEqual(card.invalidParameter, "Time blocks at most: use a whole number, 0 or more")
        card.parameterEdits = ["day_plan.max_timeblocks": "0", "day_plan.min_backlog": "8"]
        XCTAssertNil(card.invalidParameter, "8 ≤ the shown 8")
        card.parameterEdits = ["day_plan.min_backlog": "9"]
        XCTAssertEqual(card.invalidParameter, "Backlog items at least can't be more than backlog items at most")
        card.parameterEdits = ["day_plan.max_backlog": "2"]
        XCTAssertNotNil(card.invalidParameter, "the shown at-least 3 > the edited at-most 2")
        var wrote = false
        await card.saveParameters { _ in
            wrote = true
            return nil
        }
        XCTAssertFalse(wrote, "an invalid edit is never saved")
    }

    /// An interval is whole hours from 1; a dictionary is never a field value.
    func testIntervalAndDictionaryFields() async throws {
        let parameters: [[String: String]] = [
            ["key": "ideas.mine_interval_hours", "kind": "interval", "label": "Every", "value": "6"],
            ["key": "reaction_command_map", "kind": "dictionary", "label": "Reactions", "value": "[]"]
        ]
        let card = model(VerbRunner(["show": .success(try Self.show(["parameters": parameters]))]))
        await card.load()
        for bad in ["0", "-1", "x", ""] {
            card.parameterEdits = ["ideas.mine_interval_hours": bad]
            XCTAssertEqual(card.invalidParameter, "Every: use a whole number of hours, 1 or more", bad)
        }
        card.parameterEdits = ["ideas.mine_interval_hours": "12", "reaction_command_map": "anything"]
        XCTAssertNil(card.invalidParameter)
    }

    func testSaveParametersWritesTheEditsOnceAndKeepsThemOnFailure() async throws {
        let card = model(VerbRunner(["show": .success(try Self.show())]))
        await card.load()
        card.parameterEdits = ["briefing.hour": "9"]
        var writes: [[String: String]] = []
        await card.saveParameters { values in
            writes.append(values)
            return "config locked"
        }
        XCTAssertEqual(card.actionError, "config locked")
        XCTAssertEqual(card.parameterEdits, ["briefing.hour": "9"], "a failed save keeps the edits")

        await card.saveParameters { values in
            writes.append(values)
            return nil
        }
        XCTAssertEqual(writes, [["briefing.hour": "9"], ["briefing.hour": "9"]])
        XCTAssertNil(card.actionError)
        XCTAssertEqual(card.parameterEdits, [:])
        XCTAssertFalse(card.isWorking)
    }

    /// Turn On/Off and Save and Turn On: the feature ids `show` names, one
    /// write per press; a press while one runs is ignored.
    func testSetEnabledSendsTheFeatureIDsAndIgnoresADoublePress() async throws {
        let card = model(VerbRunner(["show": .success(try Self.show())]))
        var calls: [([String], Bool)] = []
        var gate: CheckedContinuation<Void, Never>?
        let first = Task {
            await card.setEnabled(false) { ids, on in
                calls.append((ids, on))
                await withCheckedContinuation { gate = $0 }
                return nil
            }
        }
        while gate == nil { await Task.yield() }
        XCTAssertTrue(card.isWorking)
        await card.setEnabled(false) { ids, on in
            calls.append((ids, on))
            return nil
        }
        gate?.resume()
        await first.value
        XCTAssertEqual(calls.count, 1, "the second press is ignored, not refused with a message")
        XCTAssertEqual(calls.first?.0, ["briefing", "day-plan"], "read from show before the write")
        XCTAssertEqual(calls.first?.1, false)
        XCTAssertNil(card.actionError)

        await card.setEnabled(true) { _, _ in "busy elsewhere" }
        XCTAssertEqual(card.actionError, "busy elsewhere")
    }

    func testSetEnabledWithoutAShowWritesNothing() async {
        let card = model(VerbRunner([:]))
        var called = false
        await card.setEnabled(true) { _, _ in
            called = true
            return nil
        }
        XCTAssertFalse(called)
        XCTAssertNotNil(card.actionError)
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

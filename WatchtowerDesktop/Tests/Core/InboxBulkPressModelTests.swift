import Combine
import XCTest
@testable import WatchtowerCore

/// The Inbox's bulk press (Approve All, Close All…): plan, confirm, apply,
/// one result line, and Try Again only when the owner presses it.
@MainActor
final class InboxBulkPressModelTests: XCTestCase {
    private struct Boom: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let plan = InboxBulkPlan(ids: ["a", "b", "c"], count: 3)

    /// Waits (yielding, no sleeps) until the model reaches a state `done`
    /// accepts, failing after 10 s.
    private func waitUntil(_ model: InboxBulkPressModel, _ done: (InboxBulkPressModel.State) -> Bool) async {
        let deadline = Date().addingTimeInterval(10)
        while !done(model.state) {
            guard Date() < deadline else { return XCTFail("still \(model.state)") }
            await Task.yield()
        }
    }

    private func isFinished(_ state: InboxBulkPressModel.State) -> Bool {
        if case .finished = state { return true }
        return false
    }

    private func isConfirming(_ state: InboxBulkPressModel.State) -> Bool {
        if case .confirming = state { return true }
        return false
    }

    func testBeginPlansThenConfirms() async {
        let model = InboxBulkPressModel()
        var states: [InboxBulkPressModel.State] = []
        let watch = model.$state.sink { states.append($0) }
        defer { watch.cancel() }
        var applied: [[String]] = []

        model.begin { Self.plan }
        await waitUntil(model, isConfirming)
        XCTAssertEqual(model.state, .confirming(Self.plan))

        model.confirm { ids in
            applied.append(ids)
            return .done(count: ids.count, skipped: 0)
        }
        await waitUntil(model, isFinished)

        XCTAssertEqual(states, [
            .idle, .planning, .confirming(Self.plan), .running, .finished(.done(count: 3, skipped: 0))
        ])
        XCTAssertEqual(applied, [["a", "b", "c"]])
    }

    func testEmptyPlanFinishesWithoutConfirming() async {
        let model = InboxBulkPressModel()
        var states: [InboxBulkPressModel.State] = []
        let watch = model.$state.sink { states.append($0) }
        defer { watch.cancel() }

        model.begin { InboxBulkPlan(ids: [], count: 0) }
        await waitUntil(model, isFinished)

        XCTAssertEqual(states, [.idle, .planning, .finished(.done(count: 0, skipped: 0))])
    }

    func testPlanErrorFinishesFailed() async {
        let model = InboxBulkPressModel()
        model.begin { throw Boom(message: "database is locked") }
        await waitUntil(model, isFinished)
        XCTAssertEqual(model.state, .finished(.failed("database is locked")))
    }

    func testApplyErrorFinishesFailed() async {
        let model = InboxBulkPressModel()
        model.begin { Self.plan }
        await waitUntil(model, isConfirming)
        model.confirm { _ in throw Boom(message: "watchtower exited with code 1") }
        await waitUntil(model, isFinished)
        XCTAssertEqual(model.state, .finished(.failed("watchtower exited with code 1")))
    }

    func testPartialResultIsKept() async {
        let model = InboxBulkPressModel()
        model.begin { Self.plan }
        await waitUntil(model, isConfirming)
        model.confirm { _ in .partial(done: 2, of: 3, error: "card 3 is gone") }
        await waitUntil(model, isFinished)
        XCTAssertEqual(model.state, .finished(.partial(done: 2, of: 3, error: "card 3 is gone")))
    }

    /// A second press while the apply runs is ignored: the plan is not asked
    /// again and the state stays `running`.
    func testBeginIgnoredWhileRunning() async {
        var planCalls = 0
        var gate: CheckedContinuation<Void, Never>?
        let model = InboxBulkPressModel(
            plan: {
                planCalls += 1
                return Self.plan
            },
            apply: { ids in
                await withCheckedContinuation { gate = $0 }
                return .done(count: ids.count, skipped: 0)
            }
        )

        model.begin()
        await waitUntil(model, isConfirming)
        model.confirm()
        let deadline = Date().addingTimeInterval(10)
        while gate == nil {
            guard Date() < deadline else { return XCTFail("the apply never started") }
            await Task.yield()
        }
        XCTAssertEqual(model.state, .running)

        model.begin()
        model.begin { throw Boom(message: "not this one") }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(planCalls, 1)
        XCTAssertEqual(model.state, .running)

        gate?.resume()
        await waitUntil(model, isFinished)
        XCTAssertEqual(model.state, .finished(.done(count: 3, skipped: 0)))
        XCTAssertEqual(planCalls, 1)
    }

    func testCancelReturnsToIdle() async {
        var applyCalls = 0
        let model = InboxBulkPressModel(plan: { Self.plan }, apply: { _ in
            applyCalls += 1
            return .done(count: 3, skipped: 0)
        })
        model.begin()
        await waitUntil(model, isConfirming)

        model.cancel()
        XCTAssertEqual(model.state, .idle)
        model.confirm()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(applyCalls, 0, "a confirm after Cancel applies nothing")
        XCTAssertEqual(model.state, .idle)
    }

    /// Try Again is `begin()` after a failure: the stored plan runs again.
    /// Nothing re-runs it by itself.
    func testTryAgainReRunsThePlan() async {
        var planCalls = 0
        let model = InboxBulkPressModel()
        model.begin {
            planCalls += 1
            if planCalls == 1 { throw Boom(message: "database is locked") }
            return Self.plan
        }
        await waitUntil(model, isFinished)
        XCTAssertEqual(model.state, .finished(.failed("database is locked")))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(planCalls, 1, "no retry by itself")

        model.begin()
        await waitUntil(model, isConfirming)
        XCTAssertEqual(planCalls, 2)
        XCTAssertEqual(model.state, .confirming(Self.plan))
    }

    func testConfirmOutsideConfirmingIsIgnored() async {
        var applyCalls = 0
        let apply: ([String]) async throws -> InboxBulkResult = { ids in
            applyCalls += 1
            return .done(count: ids.count, skipped: 0)
        }
        let model = InboxBulkPressModel(apply: apply)

        model.confirm()
        model.confirm(apply: apply)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(model.state, .idle)

        model.begin { InboxBulkPlan(ids: [], count: 0) }
        await waitUntil(model, isFinished)
        model.confirm()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(applyCalls, 0)
        XCTAssertEqual(model.state, .finished(.done(count: 0, skipped: 0)))

        // The stored plan is unset, so a bare begin() is a no-op too.
        let fresh = InboxBulkPressModel()
        fresh.begin()
        XCTAssertEqual(fresh.state, .idle)
    }
}

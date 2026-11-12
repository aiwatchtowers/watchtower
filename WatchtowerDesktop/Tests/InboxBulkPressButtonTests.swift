import SwiftUI
import ViewInspector
import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop

/// The bulk press button's line under it and its Try Again.
@MainActor
final class InboxBulkPressButtonTests: XCTestCase {
    private struct Boom: LocalizedError {
        var errorDescription: String? { "database is locked" }
    }

    func testResultLines() {
        XCTAssertNil(InboxBulkPressButton.resultLine(.done(count: 4, skipped: 0)))
        XCTAssertEqual(InboxBulkPressButton.resultLine(.done(count: 0, skipped: 0)), "Nothing left to do.")
        XCTAssertEqual(
            InboxBulkPressButton.resultLine(.done(count: 4, skipped: 2)), "Done: 4. 2 were already closed."
        )
        XCTAssertEqual(
            InboxBulkPressButton.resultLine(.partial(done: 2, of: 5, error: "card 3 is gone")),
            "Closed 2 of 5. card 3 is gone"
        )
        XCTAssertEqual(InboxBulkPressButton.resultLine(.failed("database is locked")), "database is locked")
    }

    func testTryAgainOnlyAfterPartialOrFailed() async throws {
        let cases: [(InboxBulkResult?, Bool)] = [
            (nil, false),
            (.done(count: 3, skipped: 0), false),
            (.done(count: 0, skipped: 0), false),
            (.done(count: 3, skipped: 1), false),
            (.partial(done: 1, of: 3, error: "card 2 is gone"), true),
            (.failed("database is locked"), true)
        ]
        for (result, offered) in cases {
            let model = await finishedModel(result)
            let view = InboxBulkPressButton(title: "Approve All", confirmTitle: { "Approve \($0)" }, model: model)
            XCTAssertNoThrow(try view.inspect().find(button: "Approve All"))
            if offered {
                XCTAssertNoThrow(try view.inspect().find(button: "Try Again"), "\(String(describing: result))")
            } else {
                XCTAssertThrowsError(try view.inspect().find(button: "Try Again"), "\(String(describing: result))")
            }
            if let result, let line = InboxBulkPressButton.resultLine(result) {
                XCTAssertNoThrow(try view.inspect().find(text: line))
            }
        }
    }

    /// A group that no longer offers Approve All (its rows went) keeps the
    /// last press's result line and Try Again under its header; the button
    /// itself is gone, and an idle press draws nothing.
    func testResultLineOutlivesTheButton() async throws {
        let partial = InboxBulkResult.partial(done: 1, of: 3, error: "card 2 is gone")
        let finished = await finishedModel(partial)
        let header = NeedsApprovalGroupHeader(title: "Tasks", count: 2, approveAll: (nil, finished))
        XCTAssertThrowsError(try header.inspect().find(button: "Approve All 2…"))
        XCTAssertNoThrow(try header.inspect().find(text: try XCTUnwrap(InboxBulkPressButton.resultLine(partial))))
        XCTAssertNoThrow(try header.inspect().find(button: "Try Again"))

        let offered = NeedsApprovalGroupHeader(title: "Tasks", count: 2, approveAll: (2, finished))
        XCTAssertNoThrow(try offered.inspect().find(button: "Approve All 2…"))

        let idle = InboxBulkPressButton(title: nil, confirmTitle: { "Approve \($0)" }, model: InboxBulkPressModel())
        XCTAssertThrowsError(try idle.inspect().find(ViewType.Button.self))
        XCTAssertThrowsError(try idle.inspect().find(ViewType.Text.self))
    }

    func testTryAgainCallsTheStoredPlan() async throws {
        var planCalls = 0
        let model = InboxBulkPressModel()
        model.begin {
            planCalls += 1
            throw Boom()
        }
        await waitFinished(model)
        let view = InboxBulkPressButton(title: "Approve All", confirmTitle: { "Approve \($0)" }, model: model)

        try view.inspect().find(button: "Try Again").tap()
        XCTAssertEqual(model.state, .planning)
        await waitFinished(model)
        XCTAssertEqual(planCalls, 2)
    }

    /// A model idle (nil) or finished with `result`, reached through its own
    /// plan and apply.
    private func finishedModel(_ result: InboxBulkResult?) async -> InboxBulkPressModel {
        let model = InboxBulkPressModel()
        guard let result else { return model }
        switch result {
        case .failed:
            model.begin { throw Boom() }
        case .done(0, 0):
            model.begin { InboxBulkPlan(ids: [], count: 0) }
        default:
            model.begin { InboxBulkPlan(ids: ["a", "b", "c"], count: 3) }
            let deadline = Date().addingTimeInterval(10)
            while model.state == .planning {
                guard Date() < deadline else {
                    XCTFail("still planning")
                    return model
                }
                await Task.yield()
            }
            model.confirm { _ in result }
        }
        await waitFinished(model)
        return model
    }

    /// Yields until `model` finishes, failing after 10 s.
    private func waitFinished(_ model: InboxBulkPressModel) async {
        let deadline = Date().addingTimeInterval(10)
        while true {
            if case .finished = model.state { return }
            guard Date() < deadline else { return XCTFail("still \(model.state)") }
            await Task.yield()
        }
    }
}

import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// U2 (plan Task G7, S5): the Workchat says before Send that a line waits
/// for the turn's end, only for an agent without mid-turn input and only
/// while it works.
@MainActor
final class WorkchatComposerTests: XCTestCase {
    func testCaptionWhenNoMidturnInput() throws {
        XCTAssertEqual(
            WorkchatComposer.holdCaption(agentName: "Codex"), "Codex takes your message when this turn ends."
        )
        XCTAssertEqual(
            WorkchatComposer.holdCaption(agentName: nil), "The agent takes your message when this turn ends."
        )

        XCTAssertNil(WorkchatComposer.holdCaption(agent: .codex, holdsUntilIdle: false, working: true))
        XCTAssertNil(WorkchatComposer.holdCaption(agent: .codex, holdsUntilIdle: true, working: false))
        XCTAssertEqual(
            WorkchatComposer.holdCaption(agent: .codex, holdsUntilIdle: true, working: true),
            "Codex takes your message when this turn ends."
        )
    }
}

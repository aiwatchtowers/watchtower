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
            WorkchatComposer.holdCaption(agent: nil, holdsUntilIdle: true, working: true),
            "The agent takes your message when this turn ends."
        )

        XCTAssertNil(WorkchatComposer.holdCaption(agent: .codex, holdsUntilIdle: false, working: true))
        XCTAssertNil(WorkchatComposer.holdCaption(agent: .codex, holdsUntilIdle: true, working: false))
        XCTAssertEqual(
            WorkchatComposer.holdCaption(agent: .codex, holdsUntilIdle: true, working: true),
            "Codex takes your message when this turn ends."
        )
    }

    /// C2: Esc in an empty field while the agent works stops it, once; with text in the field it does not.
    func testEscapeInEmptyFieldWhileWorkingStops() {
        var stops = 0
        WorkchatComposer.escape(working: true, draft: "") { stops += 1 }
        XCTAssertEqual(stops, 1)
        WorkchatComposer.escape(working: true, draft: "wait") { stops += 1 }
        WorkchatComposer.escape(working: false, draft: "") { stops += 1 }
        XCTAssertEqual(stops, 1)
    }

    /// Esc stops only when the round button shows Stop (#2065): a field holding only an attachment, or a paste
    /// token, shows Send, so Esc leaves the agent alone; a whitespace-only field shows Stop, so Esc stops.
    func testEscWithOnlyAttachmentDoesNotStop() {
        var stops = 0
        WorkchatComposer.escape(working: true, draft: "", hasAttachments: true) { stops += 1 }
        WorkchatComposer.escape(working: true, draft: "[Image #1]") { stops += 1 }
        XCTAssertEqual(stops, 0)
        WorkchatComposer.escape(working: true, draft: " \n\t") { stops += 1 }
        XCTAssertEqual(stops, 1)
    }
}

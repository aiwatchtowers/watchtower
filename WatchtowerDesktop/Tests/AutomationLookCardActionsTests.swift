import DesignKit
import XCTest
@testable import WatchtowerCore
@testable import WatchtowerDesktop

/// The Look pane draws a dry-run card's own buttons as the Inbox does: the
/// `actions` of a preview result reach `ArtifactCardBody` decoded by the
/// Kit, not dropped (Inbox builder A, Task 11).
@MainActor
final class AutomationLookCardActionsTests: XCTestCase {
    func testPreviewCardButtonsDecodeForTheRenderer() throws {
        let result = #"{"ok":true,"errors":[],"manifest":{"name":"N","slug":"","trigger_kind":"manual","#
            + #""trigger":"manual","permissions":[],"outputs":["inbox"],"budget_tokens":1,"budget_minutes":1},"#
            + #""dry_run":{"steps":[],"outputs":[{"kind":"inbox","title":"A","body":"colleague A asked","#
            + #""priority":"normal","blocks":null,"key":"","content_hash":"h","#
            + #""actions":[{"label":"Ask","kind":"chat","chat":"why?","primary":true}]}],"#
            + #""tokens":5,"status":"succeeded","error":""}}"#
        let decoded = try JSONDecoder().decode(AutomationDraftEntry.Result.self, from: Data(result.utf8))
        let run = AutomationLookPreviewModel.Run(text: "R", at: Date(), outcome: .result(decoded))
        let content = AutomationLookPreviewModel.state(text: "R", outputs: ["inbox"], chatEntry: nil,
                                                       ownerResult: run, running: false)
        guard case let .preview(shown, _, _) = content else { return XCTFail("preview, got \(content)") }

        let card = AutomationLookDecodedCards.card(blocksJSON: shown.cards[0].blocksJSON,
                                                   actionsJSON: shown.cards[0].actionsJSON)
        XCTAssertEqual(card.result, .none, "a markdown card: its body is drawn")
        XCTAssertEqual(card.cardActions.map(\.label), ["Ask"])
        XCTAssertEqual(card.cardActions.first?.kind, .chat)
    }
}

import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Regression guard for the pre-tool-preamble fix's lifecycle safety.
///
/// `ChatViewModel.applyStreamEvent` is a pure static fold over the turn's LOCAL
/// state (`fullText`/`sawTurnComplete`/`newSessionID`), returning the UI-facing
/// side effects separately. That separation is load-bearing: a view model
/// deallocated mid-stream must not truncate the reply — the loop keeps draining
/// and the static persist tail still saves the whole thing (the
/// surviving-navigation contract). An earlier refactor gated the whole loop on
/// `guard let self else { break }`, which broke exactly that; these assertions
/// pin that the fold never touches `self`.
final class ChatViewModelStreamFoldTests: XCTestCase {
    func testApplyStreamEventFoldsStateWithoutSelf() {
        var full = ""
        var sawTC = false
        var sid: String?
        func fold(_ event: StreamEvent) -> ChatViewModel.StreamEffect {
            ChatViewModel.applyStreamEvent(
                event, fullText: &full, sawTurnComplete: &sawTC, newSessionID: &sid
            )
        }

        XCTAssertEqual(fold(.text("Part one. ")).visibleText, "Part one. ")
        _ = fold(.text("Part two."))
        XCTAssertEqual(full, "Part one. Part two.", "text deltas accumulate")

        let sidEffect = fold(.sessionID("sess-x"))
        XCTAssertEqual(sid, "sess-x", "the session id is captured in local state")
        XCTAssertEqual(sidEffect.sessionID, "sess-x")
        XCTAssertNil(sidEffect.visibleText, "a session id carries no UI text effect")

        XCTAssertEqual(fold(.reset).visibleText, "")
        XCTAssertEqual(full, "", "reset drops the pre-tool preamble")

        _ = fold(.turnComplete("Final."))
        XCTAssertEqual(full, "Final.")
        _ = fold(.text("X"))
        XCTAssertEqual(full, "X", "a delta after turnComplete replaces, not appends")
    }
}

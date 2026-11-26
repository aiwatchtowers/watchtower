import SwiftUI
import XCTest
@testable import WatchtowerDesktop

/// Spec 2026-11-26 chat text highlights, Task 1: the finished-agent row's title colours its refs — `#N`, `PR #N` and
/// `ask #N` — in `SyntaxTint.ref` as before (C8); a date stays plain.
final class AgentFinishedRowTitleTests: XCTestCase {
    func testTitleColoursRefsAndPrefixedRefsOnly() throws {
        let text = AgentFinishedRow.title("Fixed #12, see PR #1124 and ask #990 on 2026-11-16")
        let tinted = text.runs.filter { $0.foregroundColor == SyntaxTint.ref }
            .map { String(text[$0.range].characters) }
        XCTAssertEqual(tinted, ["#12", "PR #1124", "ask #990"])
        let date = try XCTUnwrap(text.range(of: "2026-11-16"))
        XCTAssertTrue(text[date].runs.allSatisfy { $0.foregroundColor == nil })
    }
}

import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore

@MainActor
final class QuoteBatchViewTests: XCTestCase {
    func testShowsEveryQuoteAndRemoveReportsItsID() throws {
        let quotes = [ChatQuoteDraft(quote: "retry budget", comment: "Why?"), ChatQuoteDraft(quote: "Ship on Friday", comment: "")]
        var removed: [UUID] = []
        let view = QuoteBatchView(quotes: quotes, onEditComment: { _, _ in }, onRemove: { removed.append($0) })
        XCTAssertNoThrow(try view.inspect().find(text: "\u{201C}retry budget\u{201D}"))
        XCTAssertNoThrow(try view.inspect().find(text: "\u{201C}Ship on Friday\u{201D}"))
        let buttons = try view.inspect().findAll(ViewType.Button.self) { try $0.accessibilityLabel().string() == "Remove quote" }
        XCTAssertEqual(buttons.count, 2)
        try buttons[1].tap()
        XCTAssertEqual(removed, [quotes[1].id])
    }
}

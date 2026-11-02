import AppKit
import XCTest
@testable import WatchtowerDesktop

/// AGENT-07: Return denies in the confirm window even with its text focused.
@MainActor
final class OwnerConfirmWindowTests: XCTestCase {
    func testReturnInTheTextDenies() {
        var denied = 0
        let handler = OwnerConfirmReturnDenies { denied += 1 }
        let textView = NSTextView()
        XCTAssertTrue(handler.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(denied, 1)
    }

    func testOtherCommandsStayTheTextViews() {
        var denied = 0
        let handler = OwnerConfirmReturnDenies { denied += 1 }
        let textView = NSTextView()
        XCTAssertFalse(handler.textView(textView, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertFalse(handler.textView(textView, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(denied, 0)
    }
}

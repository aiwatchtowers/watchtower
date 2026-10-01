import XCTest
@testable import WatchtowerCore

final class CommentEditorKeysTests: XCTestCase {
    func testCommandOrControlReturnSends() {
        for key in [CommentEditorKeys.returnKeyCode, CommentEditorKeys.keypadEnterKeyCode] {
            XCTAssertTrue(CommentEditorKeys.submits(keyCode: key, command: true, control: false))
            XCTAssertTrue(CommentEditorKeys.submits(keyCode: key, command: false, control: true))
            XCTAssertTrue(CommentEditorKeys.submits(keyCode: key, command: true, control: true))
        }
    }

    func testPlainReturnIsANewLineAndOtherKeysNeverSend() {
        XCTAssertFalse(CommentEditorKeys.submits(keyCode: CommentEditorKeys.returnKeyCode, command: false, control: false))
        XCTAssertFalse(CommentEditorKeys.submits(keyCode: CommentEditorKeys.keypadEnterKeyCode, command: false, control: false))
        XCTAssertFalse(CommentEditorKeys.submits(keyCode: 1, command: true, control: true), "⌘S is not send")
    }
}

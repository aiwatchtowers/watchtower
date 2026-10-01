import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class ArtifactCommentsSendBarTests: XCTestCase {
    func testSendTapsTheCallbackWithUnsentCommentsAndNoStream() throws {
        var sent = 0
        let bar = ArtifactCommentsSendBar(count: 2, canSend: true) { sent += 1 }
        let button = try bar.inspect().find(button: "Send 2 comments")
        XCTAssertFalse(try button.isDisabled())
        try button.tap()
        XCTAssertEqual(sent, 1)
    }

    func testDisabledWithNothingUnsentOrWhileStreaming() throws {
        let noneUnsent = try ArtifactCommentsSendBar(count: 0, canSend: true) {}.inspect()
        XCTAssertTrue(try noneUnsent.find(button: "Send 0 comments").isDisabled())
        let whileStreaming = try ArtifactCommentsSendBar(count: 1, canSend: false) {}.inspect()
        XCTAssertTrue(try whileStreaming.find(button: "Send 1 comment").isDisabled())
    }
}

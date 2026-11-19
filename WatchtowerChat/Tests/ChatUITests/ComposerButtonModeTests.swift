import XCTest
@testable import ChatUI

/// The composer's round button (#2065 §5): with `sendWhileStreaming` it is Send whenever the field holds something
/// to send, Stop only with an empty field while the agent works; without it (the AI chat, the phone) Stop while
/// streaming, as before.
final class ComposerButtonModeTests: XCTestCase {
    func testSendWithTextInEveryStateWhenEnabled() {
        XCTAssertEqual(ComposerButtonMode.resolve(isStreaming: true, sendWhileStreaming: true, canSend: true, canStop: true),
                       .sendButton(active: true))
        XCTAssertEqual(ComposerButtonMode.resolve(isStreaming: true, sendWhileStreaming: true, canSend: false, canStop: true),
                       .stopButton(active: true))
        XCTAssertEqual(ComposerButtonMode.resolve(isStreaming: false, sendWhileStreaming: true, canSend: false, canStop: true),
                       .sendButton(active: false))
        XCTAssertEqual(ComposerButtonMode.resolve(isStreaming: false, sendWhileStreaming: true, canSend: true, canStop: true),
                       .sendButton(active: true))
        XCTAssertEqual(ComposerButtonMode.resolve(isStreaming: true, sendWhileStreaming: true, canSend: false, canStop: false),
                       .stopButton(active: false))
    }

    func testAIChatKeepsStopWhileStreaming() {
        XCTAssertEqual(ComposerButtonMode.resolve(isStreaming: true, sendWhileStreaming: false, canSend: true, canStop: true),
                       .stopButton(active: true))
        XCTAssertEqual(ComposerButtonMode.resolve(isStreaming: true, sendWhileStreaming: false, canSend: true, canStop: false),
                       .stopButton(active: false))
        XCTAssertEqual(ComposerButtonMode.resolve(isStreaming: false, sendWhileStreaming: false, canSend: true, canStop: true),
                       .sendButton(active: true))
        XCTAssertFalse(ChatComposerFieldConfig(placeholder: "").sendWhileStreaming)
    }
}

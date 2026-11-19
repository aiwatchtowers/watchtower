import XCTest
@testable import ChatUI

/// The composer's round button (#2065 §5): with `sendWhileStreaming` it is Send whenever the field holds something
/// to send, Stop only with an empty field while the agent works; without it (the AI chat, the phone) Stop while
/// streaming, as before.
final class ComposerButtonModeTests: XCTestCase {
    func testSendWithTextInEveryStateWhenEnabled() {
        XCTAssertEqual(ComposerButtonMode.resolve(isStreaming: true, sendWhileStreaming: true, canSend: true, canStop: true),
                       .send(active: true))
        XCTAssertEqual(ComposerButtonMode.resolve(isStreaming: true, sendWhileStreaming: true, canSend: false, canStop: true),
                       .stop(active: true))
        XCTAssertEqual(ComposerButtonMode.resolve(isStreaming: false, sendWhileStreaming: true, canSend: false, canStop: true),
                       .send(active: false))
        XCTAssertEqual(ComposerButtonMode.resolve(isStreaming: false, sendWhileStreaming: true, canSend: true, canStop: true),
                       .send(active: true))
        XCTAssertEqual(ComposerButtonMode.resolve(isStreaming: true, sendWhileStreaming: true, canSend: false, canStop: false),
                       .stop(active: false))
    }

    func testAIChatKeepsStopWhileStreaming() {
        XCTAssertEqual(ComposerButtonMode.resolve(isStreaming: true, sendWhileStreaming: false, canSend: true, canStop: true),
                       .stop(active: true))
        XCTAssertEqual(ComposerButtonMode.resolve(isStreaming: true, sendWhileStreaming: false, canSend: true, canStop: false),
                       .stop(active: false))
        XCTAssertEqual(ComposerButtonMode.resolve(isStreaming: false, sendWhileStreaming: false, canSend: true, canStop: true),
                       .send(active: true))
        XCTAssertFalse(ChatComposerFieldConfig(placeholder: "").sendWhileStreaming)
    }
}

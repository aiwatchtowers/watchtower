import XCTest
@testable import WatchtowerCore

final class ChatSurfaceSpecTests: XCTestCase {
    private let key = EmbeddedChatKey(contextType: "target", contextID: "7", conversationID: 42)

    func testDraftOnlyNeverBuildsAToolMode() {
        XCTAssertNil(ChatSurfaceSpec.ToolAccess.draftOnly.toolMode(key: key, turnID: "t1"))
    }

    func testActionsBuildTheSurfaceToolMode() {
        let mode = ChatSurfaceSpec.ToolAccess.actions(surface: "target").toolMode(key: key, turnID: "t1")
        XCTAssertEqual(mode, ChatToolMode(surface: "target", conversationID: 42, turnID: "t1",
                                          contextType: "target", contextID: "7"))
    }

    func testActionsWithoutAConversationBuildNothing() {
        let memoryKey = EmbeddedChatKey(contextType: "setup", contextID: "calendar", conversationID: nil)
        XCTAssertNil(ChatSurfaceSpec.ToolAccess.actions(surface: "target").toolMode(key: memoryKey, turnID: "t"))
    }

    func testIdentityPostTurnKeepsTheReply() {
        let result = ChatPostTurnResult.identity(ChatPostTurnInput(reply: "hi", turnID: "t", messageID: 1))
        XCTAssertEqual(result, ChatPostTurnResult(displayText: "hi"))
    }
}

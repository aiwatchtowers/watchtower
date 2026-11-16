import ChatWire
import XCTest
@testable import ChatUI

/// What the Mac's window adds over the shared models (unified chat T8): the ⌘/ panel's screen context, artifact
/// comments sent as the owner's message, Archive, and an owner message edited as its own words.
@MainActor
final class ChatMacShellModelTests: XCTestCase {
    private var client: FakeChatClient!
    private var conversation: ChatConversationModel!
    private var composer: ChatComposerModel!

    override func setUp() async throws {
        client = FakeChatClient()
        conversation = ChatConversationModel(client: client, conversationID: 7, clock: ManualClock())
        composer = ChatComposerModel(conversation: conversation)
        conversation.store.apply(.snapshot(ChatUIFixtures.feed(messages: [ChatUIFixtures.message(2, text: "Hi.")])))
    }

    private func turnRequest(_ op: ChatOperation?) -> ChatTurnRequest? {
        guard case .turn(let request)? = op else { return nil }
        return request
    }

    func testScreenContextRidesWithTheSendAndTheTextStaysTyped() async {
        composer.draft = "How do I add a source?"
        await composer.send(screenContext: "Screen: Connections")
        let request = turnRequest(client.ops.last)
        XCTAssertEqual(request?.text, "How do I add a source?", "the stored text is the typed text alone")
        XCTAssertEqual(request?.screenContext, "Screen: Connections")

        composer.draft = "And then?"
        await composer.send()
        XCTAssertNil(turnRequest(client.ops.last)?.screenContext, "the chat window's own send carries none")
    }

    /// CHAT-05: comments reach the assistant only as the owner's message — a `chat_turn` with their ids, which the
    /// engine composes and marks sent in the start transaction.
    func testArtifactCommentsGoAsTheOwnersTurn() async {
        let sent = await composer.sendArtifactComments([11, 12])
        XCTAssertTrue(sent)
        let request = turnRequest(client.ops.last)
        XCTAssertEqual(request?.artifactCommentIDs, [11, 12])
        XCTAssertEqual(request?.text, "")
        XCTAssertEqual(request?.mode, .send)

        client.respond { _ in .refused(code: "busy", message: "") }
        let refused = await composer.sendArtifactComments([13])
        XCTAssertFalse(refused)
        XCTAssertEqual(composer.line, ChatConversationModel.busyLine)
    }

    func testArchiveIsAManageOperation() async {
        let model = ChatListModel(client: client, clock: ManualClock())
        let archived = await model.archive(4)
        XCTAssertTrue(archived)
        XCTAssertEqual(client.ops.last, .manage(conversationID: 4, op: .archive, title: nil, projectID: nil))
        client.respond { _ in .refused(code: "not_found", message: "") }
        let gone = await model.archive(5)
        XCTAssertFalse(gone)
    }

    /// The stored owner text carries the skill and REFERENCED lines the engine composed; editing puts the owner's
    /// words alone in the field.
    func testEditingAnOwnerMessageTakesItsWordsOnly() {
        let stored = "Use skill triage: load it with load_skill first.\n\nlook at @PAY-1\n\nREFERENCED: jira:PAY-1 \"PAY-1\""
        composer.beginEditing(ChatUIFixtures.message(3, role: "user", text: stored))
        XCTAssertEqual(composer.draft, "look at @PAY-1")
        XCTAssertEqual(composer.editing, 3)
    }
}

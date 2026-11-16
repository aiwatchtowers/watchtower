import ChatWire
import WatchtowerChatText
import XCTest
@testable import ChatUI

/// What the phone had before it moved onto ChatUI (unified chat T9), now shared: the new chat's model and project
/// chips, the 32 000-character cap, a held composer, a chat created by its first turn, a search hit paged into view,
/// and the list's sections with the older fold and the title search.
@MainActor
final class ChatUIPhoneParityTests: XCTestCase {
    private let models = [
        ChatList.Model(provider: "claude", model: "", displayName: "Claude", images: true, pdf: true),
        ChatList.Model(provider: "claude", model: "opus", displayName: "Claude Opus", images: true, pdf: true)
    ]
    private let projects = [ChatList.Project(id: 7, name: "acme-platform")]

    private func composer(_ client: FakeChatClient = FakeChatClient(), conversationID: Int64? = nil) -> ChatComposerModel {
        let composer = ChatComposerModel(conversation: ChatConversationModel(client: client, conversationID: conversationID))
        composer.newChatChoices = ChatNewChatChoices(models: models, projects: projects)
        return composer
    }

    func testANewChatHasEditableChipsAndTheMessagePlaceholder() {
        let fresh = composer()
        XCTAssertEqual(fresh.placeholder, "Message")
        XCTAssertEqual(fresh.modelChip, ChatComposerChip(label: "Auto · Claude", editable: true))
        XCTAssertEqual(fresh.projectChip, ChatComposerChip(label: "No project", editable: true))
        XCTAssertFalse(fresh.canSend)
        fresh.routing = ChatRouting(mode: "pinned", provider: "claude", model: "opus")
        fresh.projectID = 7
        fresh.draft = "Hi"
        XCTAssertEqual(fresh.modelChip?.label, "Claude Opus")
        XCTAssertEqual(fresh.projectChip?.label, "acme-platform")
        XCTAssertTrue(fresh.canSend)
        XCTAssertEqual(ChatComposerModel.modelOptions(models).map(\.label), ["Auto", "Claude", "Claude Opus"])
        XCTAssertNil(ChatComposerModel(conversation: ChatConversationModel(client: FakeChatClient(), conversationID: nil)).modelChip,
                     "no chips without the choices (the Mac's composer as it was)")
    }

    func testChipsLockAfterTheFirstMessage() {
        let saved = composer(conversationID: 7)
        saved.conversation.store.apply(.snapshot(ChatUIFixtures.feed(messages: [ChatUIFixtures.message(1, text: "Hi")])))
        XCTAssertEqual(saved.placeholder, "Ask a follow-up")
        XCTAssertEqual(saved.modelChip, ChatComposerChip(label: "Auto · Claude", editable: false))
        XCTAssertEqual(saved.projectChip, ChatComposerChip(label: "No project", editable: false))
    }

    func testTheLengthCapCountsUnicodeScalars() {
        let model = composer(conversationID: 7)
        model.draft = String(repeating: "é", count: 32_001)
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(model.line, ChatComposerModel.overLimitLine)
        model.draft = String(repeating: "é", count: 32_000)
        XCTAssertTrue(model.canSend)
    }

    func testAHeldComposerSendsNothingAndSaysWhy() async {
        let client = FakeChatClient()
        let model = composer(client, conversationID: 7)
        model.draft = "Hello"
        model.hold = "Waiting for your Mac…"
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(model.line, "Waiting for your Mac…")
        await model.send()
        XCTAssertTrue(client.ops.isEmpty)
        XCTAssertEqual(model.draft, "Hello")
    }

    /// The phone's relay creates a chat with its first turn: no `chat_new` first, the turn carries conversation 0, the
    /// project, the routing and the draft behind it, and the screen follows the chat the turn made.
    func testAClientThatCreatesOnTurnSendsConversationZeroAndFollowsTheChat() async {
        let client = FakeChatClient()
        client.createsOnTurn = true
        client.respond { _ in .applied(.turn(ChatTurnStarted(userMessageID: 3, assistantMessageID: 4, turnID: "t", conversationID: 88))) }
        let model = composer(client)
        model.routing = ChatRouting(mode: "pinned", provider: "claude", model: "opus")
        model.projectID = 7
        model.addQuote("the SSO deadline")
        model.draft = "When?"
        await model.send()
        XCTAssertEqual(client.ops.count, 1, "no chat_new")
        guard case .turn(let request)? = client.ops.first else { return XCTFail("turn") }
        XCTAssertEqual(request.conversationID, 0)
        XCTAssertEqual(request.projectID, 7)
        XCTAssertEqual(request.routing, ChatRouting(mode: "pinned", provider: "claude", model: "opus"))
        XCTAssertEqual(request.draft, ChatTurnDraft(text: "When?", quotes: ["the SSO deadline"]))
        XCTAssertEqual(model.conversation.conversationID, 88)
        XCTAssertEqual(model.draft, "")
    }

    func testASearchHitPagesUntilItsMessageShows() async {
        let client = FakeChatClient()
        let conversation = ChatConversationModel(client: client, conversationID: 7)
        conversation.focusMessageID = 21
        var feed = ChatUIFixtures.feed(messages: [ChatUIFixtures.message(61, role: "user"), ChatUIFixtures.message(62)])
        feed = ChatFeed(conversation: feed.conversation, messages: feed.messages, hasMore: true)
        conversation.store.apply(.snapshot(feed))
        let second = ChatPage(messages: [ChatUIFixtures.message(40, role: "user"), ChatUIFixtures.message(41)], hasMore: true)
        let third = ChatPage(messages: [ChatUIFixtures.message(20, role: "user"), ChatUIFixtures.message(21)], hasMore: true)
        client.respond { _ in .applied(.page(second)) }
        client.respond { _ in .applied(.page(third)) }
        await conversation.followFocus()
        XCTAssertEqual(client.ops, [.page(conversationID: 7, beforeMessageID: 61), .page(conversationID: 7, beforeMessageID: 40)])
        XCTAssertTrue(conversation.messages.contains { $0.id == 21 })
        await conversation.followFocus()
        XCTAssertEqual(client.ops.count, 2, "the hit is loaded: no more pages")
    }

    // MARK: - The list's sections

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func conversation(
        _ id: Int64, _ title: String = "Chat", ago: TimeInterval = 60, pinned: Bool = false
    ) -> ChatList.Conversation {
        ChatList.Conversation(id: id, title: title, pinned: pinned, updatedAt: Self.now.addingTimeInterval(-ago), state: .read)
    }

    func testPinnedThenRecentThenOlderFolded() {
        let list = [
            conversation(1, "Release checklist", ago: 120, pinned: true),
            conversation(2, "Old but pinned", ago: 30 * 86_400, pinned: true),
            conversation(3, "Q3 roadmap summary", ago: 10),
            conversation(4, "Meeting prep", ago: 6.9 * 86_400),
            conversation(5, "Vendor contracts", ago: 7.1 * 86_400),
            conversation(6, "Budget", ago: 40 * 86_400)
        ]
        let model = ChatListSections(list, now: Self.now)
        XCTAssertEqual(model.sections.map(\.title), ["Pinned", "Recent"])
        XCTAssertEqual(model.sections[0].conversations.map(\.id), [1, 2], "pinned stays pinned whatever its age")
        XCTAssertEqual(model.sections[1].conversations.map(\.id), [3, 4], "the last 7 days")
        XCTAssertEqual(model.older.map(\.id), [5, 6])
        XCTAssertEqual(model.olderLabel, "2 older")
        XCTAssertEqual(model.count, 6)
    }

    func testEmptySectionsAreLeftOutAndNoFoldWithoutOlderChats() {
        let model = ChatListSections([conversation(1)], now: Self.now)
        XCTAssertEqual(model.sections.map(\.title), ["Recent"])
        XCTAssertNil(model.olderLabel)
    }

    func testTheTitleFilterKeepsMatchingTitlesUnderTitlesWithNothingFolded() {
        let list = [
            conversation(1, "Who owns the billing API?"),
            conversation(2, "Q3 roadmap"),
            conversation(3, "Billing v1 notes", ago: 60 * 86_400),
            conversation(4, "Pinned billing", pinned: true)
        ]
        let model = ChatListSections(list, now: Self.now, query: " BILLING ")
        XCTAssertEqual(model.sections.map(\.title), ["Titles"])
        XCTAssertEqual(model.sections[0].conversations.map(\.id), [1, 3, 4], "the held order, older ones included")
        XCTAssertTrue(model.older.isEmpty)
        XCTAssertTrue(ChatListSections(list, now: Self.now, query: "zzz").sections.isEmpty)
    }
}

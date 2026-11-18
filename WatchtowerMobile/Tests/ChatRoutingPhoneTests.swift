import ChatUI
import ChatWire
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The phone's routing pill (#1822 T17, ask #1418): its catalog follows the `chat_list` record, a saved chat's pick
/// goes with its next turn, and **Use preferred** is the hub's `chat_manage use_preferred`.
@MainActor
final class ChatRoutingPhoneTests: XCTestCase {
    private var sleeper: TickSleeper!
    private var recorder: RecordingChatSender!

    override func setUp() async throws {
        sleeper = TickSleeper()
        recorder = RecordingChatSender()
    }

    override func tearDown() async throws {
        sleeper.cancelAll()
    }

    private let models = [
        ChatList.Model(provider: "claude", model: "opus", displayName: "Claude", images: true, pdf: true),
        ChatList.Model(provider: "codex", model: "gpt-5.6-sol", displayName: "Codex", images: true, pdf: false)
    ]

    private func routing() throws -> ChatList.Routing {
        let status = try ChatRoutingStatus.parse(Data("""
            {"preferred_provider":"claude","enabled":true,"revision":"r","providers":[{"provider":"claude","state":"available"}]}
            """.utf8))
        return ChatList.Routing(providers: [
            .init(id: "claude", displayName: "Claude", reservePeer: "codex", images: true, pdfs: true, readFolder: true, claudeAITools: true),
            .init(id: "codex", displayName: "Codex", reservePeer: "claude", images: true, readFolder: true)
        ], status: status)
    }

    /// A saved chat on screen, its feed in (the reserve answers after a quota fallback), the hub answering.
    private func screen(_ center: ChatsCenter, _ id: Int64 = 7) -> (ChatComposerModel, ChatRoutingModel) {
        center.setGate(ChatsGateModel(ChatFixture.inputs()))
        let (conversation, composer) = center.conversation(ChatRoute(id: id))
        conversation.store.apply(.snapshot(ChatFeed(
            conversation: ChatFeed.Conversation(id: id, title: "Plan", actualProvider: "codex", actualModel: "gpt-5.6-sol",
                                                routingReason: "quota_exhausted"),
            messages: [ChatFixture.message(1, "user", "Hi")]
        )))
        return (composer, center.routing(composer))
    }

    func testCatalogFollowsListUpdates() throws {
        let center = ChatFixture.center(recorder, sleeper: sleeper)
        center.apply(ChatsSnapshot(list: ChatList(conversations: [], models: models)))
        let (_, pill) = screen(center)
        XCTAssertNil(pill.catalog?.status, "an older daemon's list: no status")
        XCTAssertNil(pill.presentation?.preview)
        var snapshot = center.snapshot
        snapshot.list = ChatList(conversations: [], models: models, routing: try routing())
        center.apply(snapshot)
        XCTAssertEqual(pill.catalog?.status?.preferredProvider, "claude", "the open screen's pill follows the list")
        XCTAssertEqual(pill.presentation?.preview?.state, .recovered)
    }

    func testSavedChatPillEditableBetweenTurns() async throws {
        let center = ChatFixture.center(recorder, sleeper: sleeper)
        center.apply(ChatsSnapshot(list: ChatList(conversations: [], models: models, routing: try routing())))
        let (composer, pill) = screen(center)
        pill.selectProvider("codex")
        pill.selectModel("gpt-5.6-sol")
        XCTAssertEqual(pill.label, "Only Codex · gpt-5.6-sol")
        composer.draft = "Go on"
        let send = Task { await composer.send() }
        try await poll({ (try? self.recorder.params(ChatTurnParams.self).count) == 1 }, "turn sent")
        XCTAssertEqual(try recorder.params(ChatTurnParams.self).first?.routing,
                       ChatRouting(mode: "pinned", provider: "codex", model: "gpt-5.6-sol"))
        send.cancel()
    }

    func testUsePreferredGoesThroughChatManage() async throws {
        let center = ChatFixture.center(recorder, sleeper: sleeper)
        center.apply(ChatsSnapshot(list: ChatList(conversations: [], models: models, routing: try routing())))
        let (_, pill) = screen(center)
        XCTAssertEqual(pill.presentation?.canUsePreferred, true)
        let use = Task { await pill.usePreferred() }
        try await poll({ (try? self.recorder.params(ChatManageParams.self).count) == 1 }, "chat_manage sent")
        let sent = try XCTUnwrap(recorder.sent.last)
        XCTAssertEqual(sent.kind, .chatManage)
        XCTAssertEqual(sent.params["op"], .string("use_preferred"))
        XCTAssertEqual(sent.params["conversation_id"], .integer(7))
        use.cancel()

        // The relay contract lists it among the chat_manage ops the hub takes from the phone.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repo.appendingPathComponent("internal/chatengine/testdata/relay_ops.json")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(json["chat_manage_ops"] as? [String]).contains(ChatManageOp.usePreferred.rawValue))
    }

    /// I1 on the phone: "Preferred + reserve · Auto model" on a chat stuck on the reserve clears it through the hub.
    func testAutoPickOnAStickyChatSendsUsePreferred() async throws {
        let center = ChatFixture.center(recorder, sleeper: sleeper)
        center.apply(ChatsSnapshot(list: ChatList(conversations: [], models: models, routing: try routing())))
        let (composer, pill) = screen(center)
        pill.pick(try XCTUnwrap(pill.menu.first?.items.first))
        try await poll({ (try? self.recorder.params(ChatManageParams.self).count) == 1 }, "chat_manage sent")
        XCTAssertEqual(try recorder.params(ChatManageParams.self).first?.op, .usePreferred)
        XCTAssertEqual(composer.routing, ChatRouting(mode: "auto"))
    }
}

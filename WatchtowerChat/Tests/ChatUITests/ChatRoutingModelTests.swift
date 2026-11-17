import ChatWire
import XCTest
@testable import ChatUI

/// The routing pill shared by the Mac and the phone (#1822 T17): its labels and menu are the Mac picker's, a pick only
/// sets the next turn's routing, a saved chat shows its own routing until a pick, and **Use preferred** is the one
/// write (`chat_manage use_preferred`).
@MainActor
final class ChatRoutingModelTests: XCTestCase {
    private static let status = """
        {"preferred_provider":"claude","enabled":true,"revision":"r",
         "providers":[{"provider":"claude","state":"available"}]}
        """

    private func catalog(status: String? = ChatRoutingModelTests.status, statusError: String? = nil) throws -> ChatRoutingCatalog {
        ChatRoutingCatalog(providers: [
            .init(id: "claude", displayName: "Claude", reservePeer: "codex", models: ["opus", "haiku"],
                  caps: ChatProviderCaps(images: true, pdfs: true, readFolder: true, claudeAITools: true)),
            .init(id: "codex", displayName: "Codex", reservePeer: "claude", models: ["gpt-5.6-sol"],
                  caps: ChatProviderCaps(images: true, readFolder: true))
        ], status: try status.map { try ChatRoutingStatus.parse(Data($0.utf8)) }, statusError: statusError)
    }

    private final class Rig {
        let client = FakeChatClient()
        var composer: ChatComposerModel
        let routing: ChatRoutingModel
        var refreshes = 0

        @MainActor
        init(conversationID: Int64? = nil, refresh: Bool = false) {
            let composer = ChatComposerModel(conversation: ChatConversationModel(client: client, conversationID: conversationID))
            self.composer = composer
            weak var box: Rig?
            routing = ChatRoutingModel(client: client, composer: { box?.composer ?? composer },
                                       onRefresh: refresh ? { box?.refreshes += 1 } : nil)
            box = self
        }

        /// Shows chat `id` with its saved routing, actual pair and reason.
        @MainActor
        func show(
            _ id: Int64,
            routing: ChatFeed.Routing = .init(mode: "auto"),
            actual: String = "",
            reason: String = "",
            running: Bool = false
        ) {
            composer = ChatComposerModel(conversation: ChatConversationModel(client: client, conversationID: id))
            composer.conversation.store.apply(.snapshot(ChatFeed(
                conversation: ChatFeed.Conversation(id: id, title: "Plan", routing: routing, actualProvider: actual,
                                                    actualModel: actual.isEmpty ? "" : "sample-model",
                                                    routingReason: reason,
                                                    lease: running ? ChatFeed.Lease(owner: "desktop", turnID: "T") : nil),
                messages: [ChatUIFixtures.message(1, role: "user", text: "Hi")]
            )))
        }
    }

    func testLabelsMatchTheMacPicker() throws {
        let rig = Rig()
        rig.routing.catalog = try catalog()
        XCTAssertEqual(rig.routing.label, "Preferred + reserve · Auto")
        rig.routing.selectProvider("codex")
        XCTAssertEqual(rig.routing.label, "Only Codex · Auto")
        rig.routing.selectModel("gpt-5.6-sol")
        XCTAssertEqual(rig.routing.label, "Only Codex · gpt-5.6-sol")
    }

    func testMenuEntriesMatchTheMacPicker() throws {
        let rig = Rig()
        rig.routing.catalog = try catalog()
        let labels = rig.routing.menu.map { [$0.title ?? "-"] + $0.items.map(\.label) }
        XCTAssertEqual(labels, [
            ["-", "Preferred + reserve · Auto model"],
            ["Provider", "Only Claude", "Only Codex"],
            ["Model", "Auto", "opus", "haiku"]
        ])
        rig.routing.pick(try XCTUnwrap(rig.routing.menu[1].items.last))
        XCTAssertEqual(rig.routing.menu[2].items.map(\.label), ["Auto", "gpt-5.6-sol"], "the provider's own models")
        let questions = ChatRoutingModel.menu(automatic: false, providers: [("claude", "Claude")], models: ["opus"])
        XCTAssertEqual(questions.map(\.title), ["Provider", "Model"], "the code questions have no automatic choice")
    }

    func testPickWritesComposerRoutingOnly() throws {
        let rig = Rig()
        rig.routing.catalog = try catalog()
        rig.routing.selectProvider("codex")
        XCTAssertEqual(rig.composer.routing, ChatRouting(mode: "pinned", provider: "codex", model: nil))
        rig.routing.selectModel("gpt-5.6-sol")
        XCTAssertEqual(rig.composer.routing, ChatRouting(mode: "pinned", provider: "codex", model: "gpt-5.6-sol"))
        rig.routing.selectProvider("claude")
        XCTAssertEqual(rig.composer.routing, ChatRouting(mode: "pinned", provider: "claude", model: nil), "a provider pick resets the model")
        rig.routing.selectAutomatic()
        XCTAssertEqual(rig.composer.routing, ChatRouting(mode: "auto"))
        XCTAssertTrue(rig.client.ops.isEmpty, "a pick writes nothing")
    }

    func testPillAndActionOffWhileBusy() throws {
        let rig = Rig()
        rig.show(7, actual: "codex", reason: "quota_exhausted", running: true)
        rig.routing.catalog = try catalog()
        XCTAssertTrue(rig.routing.isBusy)
        rig.routing.selectProvider("codex")
        rig.routing.selectModel("opus")
        XCTAssertEqual(rig.routing.label, "Preferred + reserve · Auto", "picks are ignored while a turn runs")
        XCTAssertNil(rig.composer.routing)
        XCTAssertEqual(rig.routing.presentation?.preview?.state, .recovered)
        XCTAssertEqual(rig.routing.presentation?.canUsePreferred, false)
    }

    func testSavedChatPillShowsItsRoutingUntilAPick() throws {
        let rig = Rig()
        rig.routing.catalog = try catalog()
        rig.show(7, routing: .init(mode: "pinned", provider: "codex", model: "gpt-5.6-sol"))
        XCTAssertEqual(rig.routing.label, "Only Codex · gpt-5.6-sol")
        rig.routing.selectAutomatic()
        XCTAssertEqual(rig.routing.label, "Preferred + reserve · Auto")
        rig.show(8, routing: .init(mode: "pinned", provider: "claude"))
        XCTAssertEqual(rig.routing.label, "Only Claude · Auto", "another chat shows its own routing")
        rig.show(7, routing: .init(mode: "pinned", provider: "codex", model: "gpt-5.6-sol"))
        XCTAssertEqual(rig.routing.label, "Only Codex · gpt-5.6-sol", "a pick lasts while its chat is shown")
    }

    func testUsePreferredSendsManageAndTurnsAutomatic() async throws {
        let rig = Rig()
        rig.routing.catalog = try catalog()
        rig.show(7, routing: .init(mode: "auto"), actual: "codex", reason: "quota_exhausted")
        XCTAssertEqual(rig.routing.presentation?.preview?.state, .recovered)
        rig.routing.selectProvider("codex")
        await rig.routing.usePreferred()
        XCTAssertEqual(rig.client.ops, [.manage(conversationID: 7, op: .usePreferred, title: nil, projectID: nil)])
        XCTAssertTrue(rig.routing.automatic)
        XCTAssertEqual(rig.composer.routing, ChatRouting(mode: "auto"))

        let landing = Rig()
        landing.routing.catalog = try catalog()
        landing.routing.selectProvider("codex")
        await landing.routing.usePreferred()
        XCTAssertTrue(landing.client.ops.isEmpty, "the landing has no chat to write")
        XCTAssertEqual(landing.composer.routing, ChatRouting(mode: "auto"))
    }

    func testUsePreferredRefusedKeepsSelectionAndShowsNotice() async throws {
        let rig = Rig()
        rig.routing.catalog = try catalog()
        rig.show(7, actual: "codex", reason: "quota_exhausted")
        rig.routing.selectProvider("codex")
        rig.client.respond { _ in .refused(code: "busy", message: "This chat is already answering.") }
        await rig.routing.usePreferred()
        XCTAssertEqual(rig.routing.label, "Only Codex · Auto", "the pick is unchanged")
        XCTAssertEqual(rig.routing.notice, "Couldn't change provider choice: This chat is already answering.")
        XCTAssertFalse(rig.composer.conversation.isGone)

        rig.client.respond { _ in throw FakeChatClient.Dropped() }
        await rig.routing.usePreferred()
        XCTAssertEqual(rig.routing.label, "Only Codex · Auto")
        XCTAssertTrue(rig.routing.notice?.hasPrefix("Couldn't change provider choice:") == true)

        rig.client.respond { _ in .refused(code: "not_found", message: "This chat no longer exists on your Mac") }
        await rig.routing.usePreferred()
        XCTAssertTrue(rig.composer.conversation.isGone, "gone: the conversation's gone state")
    }

    func testUsePreferredOffWhileUnreachable() async throws {
        for state in [ChatReachability.unavailable, .offline(reason: "No connection")] {
            let rig = Rig()
            rig.routing.catalog = try catalog()
            rig.show(7, actual: "codex", reason: "quota_exhausted")
            rig.composer.conversation.reachability = state
            XCTAssertEqual(rig.routing.presentation?.preview?.state, .recovered, "the card stays as last read")
            XCTAssertEqual(rig.routing.presentation?.canUsePreferred, false, "the card's action is off")
            rig.routing.selectProvider("codex")
            XCTAssertEqual(rig.composer.routing, ChatRouting(mode: "pinned", provider: "codex", model: nil), "a pick still goes")
            await rig.routing.usePreferred()
            XCTAssertTrue(rig.client.ops.isEmpty)
        }
    }

    func testCatalogWithoutStatusShowsChoiceOnly() throws {
        let rig = Rig()
        let list = ChatList(conversations: [], models: [
            ChatList.Model(provider: "claude", model: "opus", displayName: "Claude", images: true, pdf: true)
        ])
        rig.routing.catalog = ChatRoutingCatalog(list: list)
        rig.show(7, actual: "claude", reason: "required_capability_missing")
        XCTAssertEqual(rig.routing.label, "Preferred + reserve · Auto")
        XCTAssertEqual(rig.routing.menu.last?.items.map(\.label), ["Auto", "opus"])
        XCTAssertNil(rig.routing.presentation?.preview, "no pair, no card")
        XCTAssertNil(rig.routing.presentation?.missingCapabilities, "no capability line")
        XCTAssertNil(rig.routing.capabilities)
    }

    func testNoCatalogHidesPill() {
        let rig = Rig()
        rig.composer.draft = "kept"
        XCTAssertFalse(rig.routing.showsPill)
        XCTAssertNil(rig.routing.presentation)
        XCTAssertEqual(rig.composer.draft, "kept")
    }

    func testPinnedModelMissingFromCatalogKeepsLabel() throws {
        let rig = Rig()
        rig.routing.catalog = try catalog()
        rig.show(7, routing: .init(mode: "pinned", provider: "ollama", model: "llama-gone"))
        XCTAssertEqual(rig.routing.label, "Only ollama · llama-gone", "the label keeps the pin")
        XCTAssertEqual(rig.routing.menu[1].items.map(\.label), ["Only Claude", "Only Codex", "Only ollama"],
                       "the menu offers the current choices and the current provider")
    }

    /// The drawn warning line: Desktop `ChatRoutingAccessoryViewTests.testHealthErrorShowsLine`.
    func testHealthErrorKeepsThePillAndItsLines() throws {
        let rig = Rig()
        rig.routing.catalog = try catalog(status: nil, statusError: "Couldn't read provider availability")
        XCTAssertEqual(rig.routing.catalog?.statusError, "Couldn't read provider availability")
        XCTAssertNotNil(rig.routing.presentation, "the lines draw; the error is one warning caption among them")
        XCTAssertTrue(rig.routing.showsPill, "the providers are still offered")
    }

    /// The refresh hooks the accessory's triggers call (the triggers themselves: Desktop
    /// `ChatRoutingAccessoryViewTests.testRefreshOnChatChangeActivationAndTurnEnd`).
    func testRefreshHooksCallOnRefreshOnlyWhenSet() async {
        let rig = Rig(refresh: true)
        await rig.routing.conversationChanged()
        XCTAssertEqual(rig.refreshes, 1)
        await rig.routing.turnEnded()
        XCTAssertEqual(rig.refreshes, 2)
        await rig.routing.activated()
        XCTAssertEqual(rig.refreshes, 3)
        let quiet = Rig()
        await quiet.routing.conversationChanged()
        await quiet.routing.turnEnded()
        await quiet.routing.activated()
        XCTAssertEqual(quiet.refreshes, 0, "nothing without onRefresh (the phone: the list carries the status)")
    }

    func testProjectMenuOnlyWithProjectsOnANewChat() {
        let rig = Rig()
        XCTAssertNil(rig.composer.projectChip, "the Mac passes no projects: no menu")
        rig.composer.newChatChoices = ChatNewChatChoices(projects: [ChatList.Project(id: 7, name: "acme")])
        XCTAssertEqual(rig.composer.projectChip, ChatComposerChip(label: "No project", editable: true))
        rig.show(9)
        rig.composer.newChatChoices = ChatNewChatChoices(projects: [ChatList.Project(id: 7, name: "acme")])
        XCTAssertEqual(rig.composer.projectChip, ChatComposerChip(label: "No project", editable: false))
    }

    /// I1: the pill's automatic entry on a saved automatic chat stuck on the reserve clears the stickiness, as main's
    /// pill did (the card's same `use_preferred`); on a chat with no actual provider, or a pinned one, it only sets
    /// the next turn's routing.
    func testAutomaticPickOnAStickyChatClearsTheReserve() async throws {
        let rig = Rig()
        rig.routing.catalog = try catalog()
        rig.show(7, actual: "codex", reason: "quota_exhausted")
        rig.routing.pick(try XCTUnwrap(rig.routing.menu.first?.items.first))
        await rig.routing.writesSettled()
        XCTAssertEqual(rig.client.ops, [.manage(conversationID: 7, op: .usePreferred, title: nil, projectID: nil)])
        XCTAssertEqual(rig.composer.routing, ChatRouting(mode: "auto"))

        let fresh = Rig()
        fresh.routing.catalog = try catalog()
        fresh.show(8)
        fresh.routing.selectAutomatic()
        await fresh.routing.writesSettled()
        XCTAssertTrue(fresh.client.ops.isEmpty, "no actual provider: nothing to clear")

        let pinned = Rig()
        pinned.routing.catalog = try catalog()
        pinned.show(9, routing: .init(mode: "pinned", provider: "claude"), actual: "claude")
        pinned.routing.selectAutomatic()
        await pinned.routing.writesSettled()
        XCTAssertTrue(pinned.client.ops.isEmpty, "a pinned chat turns automatic with its next turn's routing")
        XCTAssertEqual(pinned.composer.routing, ChatRouting(mode: "auto"))
    }

    /// I2 (main's rule): the actual provider's row only while an automatic chat runs on the preferred provider's
    /// reserve; a pick moves the row at once.
    func testCapabilitiesFollowThePickUnlessAutomaticOnTheReserve() throws {
        let rig = Rig()
        rig.routing.catalog = try catalog()
        rig.show(7, actual: "codex", reason: "quota_exhausted")
        XCTAssertEqual(rig.routing.capabilities?.pdfs, false, "automatic on the reserve: the reserve's row")
        rig.routing.selectProvider("claude")
        XCTAssertEqual(rig.routing.capabilities?.pdfs, true, "Only Claude picked on an auto chat sitting on Codex")
        XCTAssertNil(rig.routing.presentation?.missingCapabilities)

        let pinned = Rig()
        pinned.routing.catalog = try catalog()
        pinned.show(8, routing: .init(mode: "pinned", provider: "claude"), actual: "claude")
        XCTAssertEqual(pinned.routing.capabilities?.pdfs, true)
        pinned.routing.selectProvider("codex")
        XCTAssertEqual(pinned.routing.capabilities?.pdfs, false, "Only Codex picked on a pinned-Claude chat")
        XCTAssertEqual(pinned.routing.capabilities?.pdfUnavailableReason, "PDFs need a provider that reads them.")

        let off = Rig()
        off.routing.catalog = try catalog(status: """
            {"preferred_provider":"claude","enabled":false,"revision":"r","providers":[]}
            """)
        off.show(9, actual: "codex", reason: "quota_exhausted")
        XCTAssertEqual(off.routing.capabilities?.pdfs, true, "fallback off: a historical reserve does not gate")
    }
}

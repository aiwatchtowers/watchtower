import ChatWire
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The Chats tab's gate (iPhone chat spec §6.1, mockups 1b–1h): every state in its order with its exact copy.
final class ChatsGateModelTests: XCTestCase {
    private typealias Fixture = ChatFixture

    private func gate(_ inputs: ChatsGateInputs) -> ChatsGateModel {
        ChatsGateModel(inputs)
    }

    func testAnOldHubNeedsAnUpdate() {
        // 1f: no capabilities.chat key, or chat off because the running Mac app knows no lease (D18).
        for heartbeat in [Fixture.heartbeat(chat: nil), Fixture.heartbeat(chat: "off", reason: .desktopTooOld)] {
            let model = gate(Fixture.inputs(heartbeat: heartbeat, route: .cloudKit(.private), grant: Fixture.grant(chat: false)))
            XCTAssertEqual(model.state, .needsUpdate, "needs update comes first")
            XCTAssertEqual(model.title, "Update Watchtower on your Mac")
            XCTAssertEqual(model.line, "This Mac's Watchtower is too old for chat on the phone.")
            XCTAssertNil(model.action)
            XCTAssertFalse(model.showsList)
            XCTAssertFalse(model.canCreate)
        }
    }

    func testTheOrganizationsPolicyTurnsChatOff() {
        let model = gate(Fixture.inputs(heartbeat: Fixture.heartbeat(chat: "off", reason: .policy), route: .cloudKit(.private)))
        XCTAssertEqual(model.state, .turnedOff)
        XCTAssertEqual(model.title, "Chat is turned off by your organization")
        XCTAssertEqual(model.line, "Your organization's policy keeps chat off this phone.")
        XCTAssertNil(model.action, "nothing the owner can do on the phone")
    }

    func testAHubOnICloudNeedsRelay() {
        // 1e: the route is CloudKit; the hub says off/not_relay.
        let model = gate(Fixture.inputs(
            heartbeat: Fixture.heartbeat(chat: "off", reason: .notRelay), route: .cloudKit(.private), grant: Fixture.grant(chat: false)
        ))
        XCTAssertEqual(model.state, .needsRelay, "needs Relay comes before not allowed")
        XCTAssertEqual(model.title, "Chat works over Relay")
        XCTAssertEqual(
            model.line, "This Mac talks to your phone through iCloud. Chat needs Relay, which streams the answer as it is written."
        )
        XCTAssertEqual(model.action, .switchToRelay)
        XCTAssertEqual(model.actionTitle, "Switch to Relay…")
    }

    func testAPhoneWithoutTheChatGrantIsNotAllowed() {
        // 1g, from the grant record.
        let byGrant = gate(Fixture.inputs(grant: Fixture.grant(chat: false)))
        XCTAssertEqual(byGrant.state, .notAllowed)
        XCTAssertEqual(byGrant.title, "Chat is off for this phone")
        XCTAssertEqual(byGrant.line, "On the Mac: Settings → Mobile → this phone → allow Chat.")
        XCTAssertNil(byGrant.action)
        // ... or from a refused chat action while the hub wrote no grant record yet.
        let byRefusal = gate(Fixture.inputs(grant: nil, refusal: "This phone may not use chat", list: nil))
        XCTAssertEqual(byRefusal.state, .notAllowed)
        XCTAssertEqual(byRefusal.line, "On the Mac: Settings → Mobile → this phone → allow Chat.")
    }

    func testAServerHubGivesTheAllowCommandInsteadOfTheSettingsLine() {
        let server = Fixture.heartbeat(kind: .server)
        let refusal = "This phone may not use chat. On your tower, run:\nwatchtower hub allow PHONE-9 chat"
        let fromRefusal = gate(Fixture.inputs(heartbeat: server, grant: nil, refusal: refusal))
        XCTAssertEqual(fromRefusal.state, .notAllowed)
        XCTAssertEqual(fromRefusal.line, "On your tower, run:\nwatchtower hub allow PHONE-9 chat")
        XCTAssertFalse(fromRefusal.line?.contains("Settings") ?? true)

        let fromGrant = gate(Fixture.inputs(heartbeat: server, grant: Fixture.grant(chat: false, device: "phone-1")))
        XCTAssertEqual(fromGrant.line, "On your tower, run:\nwatchtower hub allow PHONE-1 chat", "the phone's id as hub phones lists it")
        XCTAssertEqual(fromGrant.title, "Chat is off for this phone")
    }

    /// Review fix 1: the grant record decides once it exists; a refusal left in the outbox never outlives an allow.
    func testAnAllowingGrantOverridesAHeldRefusal() {
        let model = gate(Fixture.inputs(grant: Fixture.grant(chat: true), refusal: "This phone may not use chat"))
        XCTAssertEqual(model.state, .ready)
        XCTAssertFalse(ChatsGateModel.notAllowed(grant: Fixture.grant(chat: true), refusal: "refused"))
        XCTAssertTrue(ChatsGateModel.notAllowed(grant: Fixture.grant(chat: false), refusal: nil))
        XCTAssertTrue(ChatsGateModel.notAllowed(grant: nil, refusal: "refused"))
        XCTAssertFalse(ChatsGateModel.notAllowed(grant: nil, refusal: nil))
    }

    /// Review fix 2: row actions write to the hub, so only while it answers (D3: nothing is queued).
    func testRowActionsOnlyWhileTheHubAnswers() {
        XCTAssertTrue(gate(Fixture.inputs()).allowsRowActions)
        XCTAssertFalse(gate(Fixture.inputs(mac: .asleep(lastSeen: Fixture.now))).allowsRowActions)
        XCTAssertFalse(gate(Fixture.inputs(mac: .offline)).allowsRowActions)
        XCTAssertFalse(gate(Fixture.inputs(relayUnreachable: true)).allowsRowActions)
        XCTAssertFalse(gate(Fixture.inputs(list: nil)).allowsRowActions)
    }

    /// Review fix 5: away with no rows says why; away with no list is not an endless loading.
    func testAnAwayHubWithNothingHeldSaysItIsAway() {
        let empty = gate(Fixture.inputs(list: ChatList(conversations: []), mac: .asleep(lastSeen: Fixture.now)))
        XCTAssertEqual(empty.state, .empty)
        XCTAssertEqual(empty.title, "No chats yet")
        XCTAssertEqual(empty.line, "Your Mac is asleep. You can read chats; sending works when it wakes.")
        XCTAssertNil(empty.action, "no New chat while the Mac is away")

        let fresh = gate(Fixture.inputs(list: nil, mac: .asleep(lastSeen: Fixture.now)))
        XCTAssertEqual(fresh.state, .away)
        XCTAssertNil(fresh.title)
        XCTAssertEqual(fresh.line, "Your Mac is asleep. You can read chats; sending works when it wakes.")
        XCTAssertNil(fresh.banner)
        XCTAssertFalse(fresh.canCreate)
        XCTAssertTrue(fresh.showsNewChat)
        XCTAssertEqual(gate(Fixture.inputs(list: nil, mac: .offline)).line,
                       "Your Mac is offline. You can read chats; sending works when it is back.")
        XCTAssertEqual(gate(Fixture.inputs(heartbeat: nil, list: nil, mac: .offline)).state, .loading,
                       "before the first heartbeat the phone is still loading")
    }

    func testChatOffForAnotherReasonIsUnavailable() {
        for reason in [ChatOffReason.runnerDown, ChatOffReason(rawValue: "something_new")] {
            let model = gate(Fixture.inputs(heartbeat: Fixture.heartbeat(chat: "off", reason: reason)))
            XCTAssertEqual(model.state, .unavailable)
            XCTAssertEqual(model.title, "Chat isn't available right now")
            XCTAssertEqual(model.line, "Watchtower on your Mac could not start chat. Restart Watchtower there to try again.")
        }
    }

    func testNoListYetIsLoading() {
        // 1c, and before the first heartbeat too.
        for inputs in [Fixture.inputs(list: nil), Fixture.inputs(heartbeat: nil, list: nil)] {
            let model = gate(inputs)
            XCTAssertEqual(model.state, .loading)
            XCTAssertEqual(model.banner, "Getting your chats from the Mac…")
            XCTAssertNil(model.title)
            XCTAssertFalse(model.showsList)
        }
    }

    func testAReadErrorWithNoRowsOffersRetry() {
        let model = gate(Fixture.inputs(list: ChatList(conversations: [], error: "read_failed")))
        XCTAssertEqual(model.state, .error)
        XCTAssertEqual(model.title, "Couldn't load chats")
        XCTAssertEqual(model.line, "The Mac could not read its chats.")
        XCTAssertEqual(model.action, .retry)
        XCTAssertEqual(model.actionTitle, "Retry")
    }

    func testAReadErrorOverHeldRowsIsABanner() {
        let list = ChatList(conversations: [Fixture.conversation(1)], error: "read_failed")
        let model = gate(Fixture.inputs(list: list))
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.banner, "The Mac could not read its chats.")
    }

    func testNoChatsIsEmptyWithNewChat() {
        let model = gate(Fixture.inputs(list: ChatList(conversations: [])))
        XCTAssertEqual(model.state, .empty)
        XCTAssertEqual(model.title, "No chats yet")
        XCTAssertEqual(
            model.line,
            "Ask anything about your Slack, mail, Jira, meetings and work. Your Mac answers with everything it knows."
        )
        XCTAssertEqual(model.action, .newChat)
        XCTAssertEqual(model.actionTitle, "New chat")
        XCTAssertTrue(model.canCreate)
        XCTAssertFalse(gate(Fixture.inputs(list: ChatList(conversations: []), mac: .offline)).canCreate, "not while the Mac is away")
    }

    func testAnAwayMacIsReadOnly() {
        // 1d: the held list, a line over it, no new chat.
        let asleep = gate(Fixture.inputs(mac: .asleep(lastSeen: Fixture.now)))
        XCTAssertEqual(asleep.state, .offline)
        XCTAssertTrue(asleep.showsList)
        XCTAssertFalse(asleep.canCreate)
        XCTAssertFalse(asleep.online)
        XCTAssertEqual(asleep.banner, "Your Mac is asleep. You can read chats; sending works when it wakes.")

        let offline = gate(Fixture.inputs(mac: .offline))
        XCTAssertEqual(offline.state, .offline)
        XCTAssertEqual(offline.banner, "Your Mac is offline. You can read chats; sending works when it is back.")

        let unreachable = gate(Fixture.inputs(relayUnreachable: true))
        XCTAssertEqual(unreachable.state, .offline, "the relay not answering counts as away")
        XCTAssertEqual(unreachable.banner, "Relay isn't answering. You can read chats; sending works when it is back.")
    }

    func testNewChatIsOnTheBarOnlyWhereChatCanRun() {
        XCTAssertTrue(gate(Fixture.inputs()).showsNewChat)
        XCTAssertTrue(gate(Fixture.inputs(list: nil)).showsNewChat, "1c")
        XCTAssertTrue(gate(Fixture.inputs(mac: .offline)).showsNewChat, "1d, disabled")
        XCTAssertTrue(gate(Fixture.inputs(list: ChatList(conversations: []))).showsNewChat, "1b")
        XCTAssertFalse(gate(Fixture.inputs(route: .cloudKit(.private))).showsNewChat, "1e")
        XCTAssertFalse(gate(Fixture.inputs(heartbeat: Fixture.heartbeat(chat: nil))).showsNewChat, "1f")
        XCTAssertFalse(gate(Fixture.inputs(grant: Fixture.grant(chat: false))).showsNewChat, "1g")
        XCTAssertFalse(gate(Fixture.inputs(list: ChatList(conversations: [], error: "read_failed"))).showsNewChat, "1h")
    }

    func testReady() {
        let model = gate(Fixture.inputs())
        XCTAssertEqual(model.state, .ready)
        XCTAssertNil(model.banner)
        XCTAssertNil(model.title)
        XCTAssertTrue(model.showsList)
        XCTAssertTrue(model.canCreate)
        XCTAssertTrue(model.online)
    }

    func testAServerHubNamesTheTower() {
        let server = Fixture.heartbeat(chat: nil, kind: .server)
        let update = gate(Fixture.inputs(heartbeat: server))
        XCTAssertEqual(update.title, "Update Watchtower on your tower")
        let loading = gate(Fixture.inputs(heartbeat: Fixture.heartbeat(kind: .server), list: nil))
        XCTAssertEqual(loading.banner, "Getting your chats from your tower…")
    }
}

/// The Chats tab runs on one clock: the screen's `TimelineView` passes `now` to everything under it. In 0.29.0 the
/// hub switcher opened a second `TimelineView` inside a `List` row; the list re-laid itself out without end, the main
/// thread stalled for 30 s and the watchdog killed the app (0x8BADF00D). A layout loop cannot be timed in a test, so
/// the source is held to its one clock.
final class ChatsTabOneClockTests: XCTestCase {
    func testTheChatsTabHasOneTimelineView() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerMobile
            .appendingPathComponent("Sources/Features/Chats/ChatListView.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "TimelineView(").count - 1, 1)
        XCTAssertTrue(source.contains("HubSwitcherChip(now: now)"))
    }
}

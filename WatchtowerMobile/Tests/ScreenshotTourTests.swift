import ChatUI
import ChatWire
import CryptoKit
import SwiftUI
import UIKit
import WatchtowerChatText
import WatchtowerHostedRelay
import WatchtowerKit
@testable import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The design pass's screenshot tour (design pass spec §6.2): every screen
/// of the demo seed rendered to PNGs in light and dark mode, for a
/// before/after comparison by eye. Opt-in: `make mobile-shots` sets
/// WATCHTOWER_SHOTS_DIR, and every other run reports the tour skipped. It
/// asserts no pixels, only that every file was written.
@MainActor
final class ScreenshotTourTests: XCTestCase {
    /// One screen of the tour: its review number, a file-name slug, the
    /// source file, how it is reached, and whether it gets an end shot.
    struct Shot {
        enum Reached: String {
            case fullApp = "full app"
            case bareStack = "bare stack"
            case sheet
            case leaf = "leaf view"
        }

        let number: String
        let slug: String
        let source: String
        let reached: Reached
        var hasEnd = false
        let make: @MainActor (AppEnvironment) -> AnyView
    }

    /// `make mobile-shots SHOTS_ONLY=relay-phase4` runs `testTheRelayPhase4Shots` alone (a frame or two of a
    /// new screen in minutes, not the whole tour's half hour); the plain run is the whole tour, which covers them too.
    private static let onlyRelayPhase4 = ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_ONLY"] == "relay-phase4"
    /// `SHOTS_ONLY=relay-phase5` runs `testTheRelayPhase5Shots` alone, the same way.
    private static let onlyRelayPhase5 = ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_ONLY"] == "relay-phase5"
    /// `SHOTS_ONLY=chat` runs `testTheChatShots` alone: the Chats tab's states (iPhone chat mockups 1a–1j).
    private static let onlyChat = ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_ONLY"] == "chat"
    /// `SHOTS_ONLY=inbox` runs `testTheInboxShots` alone: the Inbox tab's frames (mobile Inbox mockups §§1–6).
    private static let onlyInbox = ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_ONLY"] == "inbox"

    func testTheRelayPhase4Shots() async throws {
        guard let path = ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_DIR"], Self.onlyRelayPhase4 else {
            throw XCTSkip("Only with make mobile-shots SHOTS_ONLY=relay-phase4")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (root, _) = try makeDemoRoot()
        let host = ScreenshotHost(directory: dir, env: root.env, linking: root.linking)
        let rows = try await captureRelayPhase4(host: host)
        let written = try FileManager.default.contentsOfDirectory(atPath: path)
            .filter { name in rows.contains { name.hasPrefix($0.number + "-") } && name.hasSuffix(".png") }
        XCTAssertEqual(written.count, 3 * rows.count)
    }

    func testTheRelayPhase5Shots() async throws {
        guard let path = ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_DIR"], Self.onlyRelayPhase5 else {
            throw XCTSkip("Only with make mobile-shots SHOTS_ONLY=relay-phase5")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (root, _) = try makeDemoRoot()
        var rows = try await captureParkedFeed(into: dir, linking: root.linking)
        rows += try await captureTerm(host: ScreenshotHost(directory: dir, env: root.env, linking: root.linking))
        let written = try FileManager.default.contentsOfDirectory(atPath: path)
            .filter { name in rows.contains { name.hasPrefix($0.number + "-") } && name.hasSuffix(".png") }
        XCTAssertEqual(written.count, 3 * rows.count)
    }

    func testTheChatShots() async throws {
        guard let path = ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_DIR"], Self.onlyChat else {
            throw XCTSkip("Only with make mobile-shots SHOTS_ONLY=chat")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (root, demo) = try makeDemoRoot()
        try await poll({ Self.isHydrated(root.env) }, "the demo seed hydrated")
        let rows = try await captureChats(demo: demo, host: ScreenshotHost(directory: dir, env: root.env, linking: root.linking))
        let written = try FileManager.default.contentsOfDirectory(atPath: path)
            .filter { name in rows.contains { name.hasPrefix($0.number + "-") } && name.hasSuffix(".png") }
        XCTAssertEqual(written.count, 3 * rows.count)
    }

    /// Every frame of mobile Inbox mockups §§1–6 as one named shot (`InboxTourFrames`), light and dark.
    func testTheInboxShots() async throws {
        guard let path = ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_DIR"], Self.onlyInbox else {
            throw XCTSkip("Only with make mobile-shots SHOTS_ONLY=inbox")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (root, demo) = try makeDemoRoot()
        try await poll({ Self.isHydrated(root.env) }, "the demo seed hydrated")
        let rows = try await captureInbox(host: ScreenshotHost(directory: dir, env: root.env, linking: root.linking)) {
            try await self.putDemoMacToSleep(demo, env: root.env)
        }
        XCTAssertEqual(rows.map(\.number), InboxTourFrames.all.map(\.slug))
        let written = try FileManager.default.contentsOfDirectory(atPath: path)
            .filter { name in rows.contains { name.hasPrefix($0.number + "-") } && name.hasSuffix(".png") }
        XCTAssertEqual(written.count, 2 * rows.count)
    }

    func testTheTour() async throws {
        guard let path = ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_DIR"], !Self.onlyRelayPhase4, !Self.onlyRelayPhase5,
              !Self.onlyChat, !Self.onlyInbox else {
            throw XCTSkip("Screenshot tour: run make mobile-shots")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try ScreenshotHost.clear(dir)
        let (root, demo) = try makeDemoRoot()
        try await poll({ Self.isHydrated(root.env) }, "the demo seed hydrated")
        let host = ScreenshotHost(directory: dir, env: root.env, linking: root.linking)
        let shots = Self.designSystemShots() + Self.workbenchShots() + Self.calendarShots() + Self.onboardingShots()
        for shot in shots {
            let end = shot.hasEnd ? "\(shot.number)e-\(shot.slug)" : nil
            try await host.capture("\(shot.number)-\(shot.slug)", shot.make(root.env), endName: end)
        }
        let meetingRows = try await captureMeetingSoon(host: host)
        // Before the Mac falls asleep for good: the chat frames' chip is online but in 1d.
        // Before the chats: their last frame, like the Inbox's, puts the demo Mac to sleep.
        let inboxRows = try await captureInbox(host: host) { try await self.putDemoMacToSleep(demo, env: root.env) }
        try await wakeDemoMac(demo, env: root.env)
        let chatRows = try await captureChats(demo: demo, host: host)
        let asleepRows = try await captureMacAsleep(root.env, demo: demo, host: host)
            + (try await captureSessionStates(root.env, demo: demo, host: host))
            + (try await captureAskSources(root.env, demo: demo, host: host))
        let recorderRows = try await captureRecorder(into: dir, linking: root.linking)
        let outboxRows = try await captureOutbox(into: dir, linking: root.linking)
        let relayRows = try await captureRelayLinking(host: host)
        let onRelayRows = try await captureHubOnRelay(into: dir, linking: root.linking)
        let phase4Rows = try await captureRelayPhase4(host: host)
        let phase5Rows = try await captureParkedFeed(into: dir, linking: root.linking)
        try ScreenshotHost.writeIndex(
            Self.indexRows(shots) + meetingRows + asleepRows + recorderRows + outboxRows + relayRows + onRelayRows + phase4Rows + phase5Rows
                + chatRows + inboxRows,
            to: dir)

        let pngs = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "png" }
        XCTAssertEqual(
            pngs.count,
            2 * (shots.count + shots.filter(\.hasEnd).count + meetingRows.count + asleepRows.count + recorderRows.count + outboxRows.count
                + inboxRows.count)
                + 3 * (relayRows.count + onRelayRows.count + phase4Rows.count + phase5Rows.count + chatRows.count)
        )
        for png in pngs {
            XCTAssertGreaterThan(try png.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 0, png.lastPathComponent)
        }
    }

    // MARK: - The demo

    /// The primary demo Mac's transport and the defaults holding its seq
    /// ceiling, for a later save in the hub's name.
    private struct DemoHub {
        let transport: InMemoryCloudTransport
        let defaults: UserDefaults
    }

    private func makeDemoRoot() throws -> (AppRoot, DemoHub) {
        let defaults = try makeDefaults()
        var primary: InMemoryCloudTransport?
        let env = AppEnvironment(backend: .inMemoryDemo, defaults: defaults)
        for hub in DemoSeed.hubs {
            // The demo Mac allows typing; the phone's own toggle is on, so the
            // workchat shows its composer.
            defaults.set(true, forKey: "hub.\(hub.hubID).device.typingRequested")
            let transport = InMemoryCloudTransport()
            if hub == DemoSeed.primary {
                primary = transport
            }
            let session = try HubSession(
                transport: transport,
                replicaPath: try makeReplicaPath(),
                backend: .inMemoryDemo,
                hubID: hub.hubID,
                defaults: defaults,
                recordingsDirectory: try makeRecordingsDirectory()
            )
            addTeardownBlock { @MainActor in session.stop() }
            env.add(session)
        }
        env.activate(DemoSeed.primary.hubID)
        let demo = DemoHub(transport: try XCTUnwrap(primary), defaults: defaults)
        return (try AppRoot.demo(env, defaults: defaults), demo)
    }

    /// C1a–C1k (iPhone chat mockups 1a–1j, spec §6.1–6.2): the Chats tab in the full app, light/dark/narrow. 1a is the
    /// demo hub's own chat_list through the replica; every other state feeds the tab its own center and gate inputs.
    /// 1d goes last: it makes the demo Mac asleep, so the chip agrees with the line.
    private func captureChats(demo: DemoHub, host: ScreenshotHost) async throws -> [ScreenshotHost.IndexRow] {
        let env = host.env
        let now = Date()
        var rows: [ScreenshotHost.IndexRow] = []
        func shot(_ number: String, _ slug: String, _ reached: String, _ chatsShot: ChatsShot?) async throws {
            env.navigation.tab = .chats
            env.navigation.chatsPath = []
            // 1.5 s for the tab bar's selection. In the dark frames that show the list, iOS 26 still draws the bar's lens
            // over Now (the same at 0.6, 1.5 and 3 s): a capture artifact of the glass tab bar, not a transition.
            try await host.captureThree("\(number)-\(slug)", RootTabView(chatsShot: chatsShot), settle: .milliseconds(1_500))
            rows.append(ScreenshotHost.IndexRow(
                number: number, view: "ChatsTabView", source: "Features/Chats/ChatListView.swift", reached: "full app, \(reached), light/dark/narrow"
            ))
        }
        // The undo bar stays up for the frame: its timer never ends here.
        let holds: @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(86_400)) }
        func center(_ list: ChatList?, searches: [String: ChatSearch] = [:]) -> ChatsCenter {
            Self.chatCenter(list, searches: searches)
        }
        func heartbeat(chat: String?, reason: ChatOffReason? = nil, kind: HubKind? = nil, at: Date = now) -> HeartbeatPayload {
            Self.chatHeartbeat(chat: chat, reason: reason, kind: kind, at: at)
        }
        let relay = HubRoute.hostedRelay(macDeviceID: DemoSeed.Relay.workMac)
        let on = heartbeat(chat: "on")
        let list = try DemoSeed.Chat.list(now: now)
        func grant(chat: Bool) -> DeviceGrant {
            DeviceGrant(
                deviceID: DemoSeed.device.deviceID, hubID: DemoSeed.hubID, name: DemoSeed.device.name, scope: .private, linked: true,
                typingAllowed: true, startSessionsAllowed: true, chatAllowed: chat
            )
        }

        try await shot("C1a", "chats-list", "the demo hub's chat_list", nil)
        try await shot("C1b", "chats-empty", "no chats", ChatsShot(center: center(ChatList(conversations: [])), heartbeat: on, route: relay))
        try await shot("C1c", "chats-loading", "no chat_list yet", ChatsShot(center: center(nil), heartbeat: on, route: relay))
        try await shot(
            "C1e", "chats-needs-relay", "hub on iCloud",
            ChatsShot(center: center(nil), heartbeat: heartbeat(chat: "off", reason: .notRelay), route: .cloudKit(.private))
        )
        try await shot(
            "C1f", "chats-needs-update", "no chat capability", ChatsShot(center: center(nil), heartbeat: heartbeat(chat: nil), route: relay)
        )
        try await shot(
            "C1g", "chats-not-allowed", "no chat grant", ChatsShot(center: center(nil), heartbeat: on, route: relay, grant: grant(chat: false))
        )
        try await shot(
            "C1g2", "chats-not-allowed-server", "no chat grant on a server hub",
            ChatsShot(center: center(nil), heartbeat: heartbeat(chat: "on", kind: .server), route: relay, grant: grant(chat: false))
        )
        try await shot(
            "C1h", "chats-error", "chat_list error, no rows",
            ChatsShot(center: center(ChatList(conversations: [], error: "read_failed")), heartbeat: on, route: relay)
        )
        let searching = center(list, searches: [DemoSeed.Chat.searchQuery: DemoSeed.Chat.search(now: now)])
        // The hits are in before the frame (the search answers from the record the center holds).
        searching.listQuery = DemoSeed.Chat.searchQuery
        await searching.listModel.search(DemoSeed.Chat.searchQuery)
        try await shot("C1i", "chats-search", "search \"billing\" with the Mac's hits", ChatsShot(center: searching, heartbeat: on, route: relay))
        let deleting = Self.chatCenter(list, sleep: holds)
        deleting.listModel.delete(5)
        try await shot("C1j", "chats-undo-delete", "a chat deleted, the Undo bar up", ChatsShot(center: deleting, heartbeat: on, route: relay))
        try await shot(
            "C1k", "chats-turned-off", "the organization's policy",
            ChatsShot(center: center(nil), heartbeat: heartbeat(chat: "off", reason: .policy), route: relay)
        )

        let approving = DeviceGrant(
            deviceID: DemoSeed.device.deviceID, hubID: DemoSeed.hubID, name: DemoSeed.device.name, scope: .private, linked: true,
            typingAllowed: true, startSessionsAllowed: true, permissionsAllowed: true, chatAllowed: true
        )
        rows += try await captureComposerFrames(host: host, list: list) + captureRoutingFrames(host: host, list: list)
        rows += try await captureConversations(host: host, list: list, heartbeat: on, relay: relay, grant: approving, now: now)
        rows += try await captureUnifiedChatMocks(host: host)

        // 1d: the Mac asleep (its heartbeat 40 min old), the last list the phone holds.
        let stale = now.addingTimeInterval(-2_400)
        try await putDemoMacToSleep(demo, env: env, at: stale)
        try await shot(
            "C1d", "chats-mac-asleep", "Mac asleep, the held list",
            ChatsShot(
                center: center(DemoSeed.Chat.asleepList(now: now)), heartbeat: heartbeat(chat: "on", at: stale), route: relay,
                mac: .asleep(lastSeen: stale)
            )
        )
        return rows
    }

    /// The demo Mac asleep: its heartbeat `at` (40 min ago by default), published and fetched, so every chip reads it.
    private func putDemoMacToSleep(_ demo: DemoHub, env: AppEnvironment, at stale: Date = Date().addingTimeInterval(-2_400)) async throws {
        let beat = try XCTUnwrap(DemoSeed.records(now: stale).first { $0.recordName == HeartbeatPayload.recordName })
        let sealing = DemoSeed.hubTransport(inner: demo.transport, seq: DemoSeed.hubSeq(defaults: demo.defaults, now: Date()))
        try await sealing.save([beat])
        _ = await env.refresh(.pull)
        try await poll({ env.macReachability(now: Date()) != .online }, "the demo Mac fell asleep")
    }

    /// The demo Mac awake again: a fresh heartbeat, published and fetched.
    private func wakeDemoMac(_ demo: DemoHub, env: AppEnvironment) async throws {
        let beat = try XCTUnwrap(DemoSeed.records(now: Date()).first { $0.recordName == HeartbeatPayload.recordName })
        let sealing = DemoSeed.hubTransport(inner: demo.transport, seq: DemoSeed.hubSeq(defaults: demo.defaults, now: Date()))
        try await sealing.save([beat])
        _ = await env.refresh(.pull)
        try await poll({ env.macReachability(now: Date()) == .online }, "the demo Mac woke")
    }

    /// The composer states the phone gains from the shared composer (#1822 T13): the quote batch with its comments,
    /// the picked mention and skill chips, and the draft's files as shared chips with their upload state. Before the
    /// conversation frames, on the composer alone over its page.
    private func captureComposerFrames(host: ScreenshotHost, list: ChatList) async throws -> [ScreenshotHost.IndexRow] {
        func composer(_ prepare: (ChatsCenter, ChatComposerModel) -> Void) -> AnyView {
            // A suspending sleep: a sleep that returns at once turns the client's feed loop into a busy loop.
            let center = Self.chatCenter(list)
            let route = ChatRoute(id: DemoSeed.Chat.Feeds.roadmap)
            let (conversation, model) = center.conversation(route)
            conversation.reachability = .connected
            prepare(center, model)
            let files = ChatConversationView.draftFiles(center.drafts.draft(route.id).attachments, center: center,
                                                        conversation: route.id)
            let routing = center.routing(model)
            return AnyView(VStack(spacing: 0) {
                Spacer()
                ChatComposerView(model: model, field: ChatComposerFieldConfig(placeholder: model.placeholder),
                                 onAttach: {}, routing: routing, shellFiles: files)
            }
            .background(PhoneSurface.page)
            .environment(\.chatUIStyle, PhoneChatStyle()))
        }
        let frames: [(String, AnyView)] = [
            ("iphone-chat-composer-quotes", composer { _, model in
                model.addQuote("The rollout starts with the internal group next Tuesday.")
                model.addQuote("The staging check was never run.")
                model.quotes[0].comment = "Which group exactly?"
            }),
            ("iphone-chat-composer-mentions", composer { _, model in
                model.skill = "release-notes"
                model.mentions = [ChatCompose.Mention(kind: "person", id: "1:U1", label: "Anna Lee"),
                                  ChatCompose.Mention(kind: "jira", id: "PAY-12", label: "PAY-12")]
                model.draft = "Ask @Anna Lee about @PAY-12"
            }),
            ("iphone-chat-composer-attachments", composer { center, model in
                let key = DemoSeed.Chat.Feeds.roadmap
                _ = center.attach(data: Data("notes".utf8), fileName: "meeting-notes.md", conversation: key)
                _ = center.attach(data: Data("log".utf8), fileName: "build.log", conversation: key)
                _ = center.attach(data: Data("plan".utf8), fileName: "q3-plan.txt", conversation: key)
                center.drafts.update(key) { draft in
                    draft.attachments[1].state = .uploading
                    draft.attachments[2].state = .failed("refused")
                }
                model.hasShellAttachments = true
                model.draft = "What do these say?"
            })
        ]
        var rows: [ScreenshotHost.IndexRow] = []
        for (name, frame) in frames {
            try await host.captureThree(name, frame)
            rows.append(ScreenshotHost.IndexRow(
                number: name, view: "ChatComposerView", source: "WatchtowerChat/Sources/ChatUI/Composer",
                reached: "ChatUI composer, phone style, light/dark/narrow"
            ))
        }
        return rows
    }

    /// The routing pill shared with the Mac (#1822 T17, ask #1418): its labels and menu are the Mac's, a saved chat's
    /// pill stays editable between turns, and the fallback card, the capability line and the routing error come from
    /// the list's `routing` (an older daemon's list has none: the model choice only). On the composer alone.
    private func captureRoutingFrames(host: ScreenshotHost, list: ChatList) async throws -> [ScreenshotHost.IndexRow] {
        func routingList(preferred state: String, error: String? = nil) throws -> ChatList {
            let status = error == nil ? try ChatRoutingStatus.parse(Data("""
                {"preferred_provider":"claude","enabled":true,"revision":"demo",
                 "providers":[{"provider":"claude","state":"\(state)","next_probe_at":"2026-01-02T14:30:00Z"}]}
                """.utf8)) : nil
            let routing = ChatList.Routing(providers: [
                .init(id: "claude", displayName: "Claude", reservePeer: "codex", images: true, pdfs: true, readFolder: true,
                      claudeAITools: true),
                .init(id: "codex", displayName: "Codex", reservePeer: "claude", images: true, readFolder: true)
            ], status: status, error: error)
            return ChatList(conversations: list.conversations, projects: list.projects, models: list.models, routing: routing)
        }
        func frame(
            _ list: ChatList,
            saved: Bool = true,
            actual: String = "",
            reason: String = "",
            reachability: ChatReachability = .connected,
            prepare: (ChatRoutingModel) -> Void = { _ in }
        ) -> AnyView {
            let center = Self.chatCenter(list)
            let route = saved ? ChatRoute(id: DemoSeed.Chat.Feeds.roadmap) : .new
            let (conversation, model) = center.conversation(route)
            if saved {
                conversation.store.apply(.snapshot(ChatFeed(
                    conversation: ChatFeed.Conversation(id: route.id, title: "Q3 roadmap", actualProvider: actual,
                                                        actualModel: actual.isEmpty ? "" : "gpt-5.6-sol", routingReason: reason),
                    messages: [ChatFeed.Message(id: 1, role: "user", text: "Summarise the Q3 roadmap", createdAt: Date())]
                )))
            }
            conversation.reachability = reachability
            let routing = center.routing(model)
            prepare(routing)
            return AnyView(VStack(spacing: 0) {
                Spacer()
                ChatComposerView(model: model, field: ChatComposerFieldConfig(placeholder: model.placeholder),
                                 onAttach: {}, routing: routing)
            }
            .background(PhoneSurface.page)
            .environment(\.chatUIStyle, PhoneChatStyle()))
        }
        let frames: [(String, AnyView)] = [
            ("iphone-chat-routing-new-chat", frame(try routingList(preferred: "available"), saved: false)),
            ("iphone-chat-routing-saved", frame(try routingList(preferred: "available")) { $0.selectModel("opus") }),
            ("iphone-chat-routing-fallback", frame(try routingList(preferred: "quota_wait"), actual: "codex", reason: "quota_exhausted")),
            ("iphone-chat-routing-recovered", frame(try routingList(preferred: "available"), actual: "codex", reason: "quota_exhausted")),
            ("iphone-chat-routing-unsupported", frame(try routingList(preferred: "available"), actual: "claude",
                                                      reason: "required_capability_missing")),
            ("iphone-chat-routing-missing-caps", frame(try routingList(preferred: "available")) { $0.selectProvider("codex") }),
            ("iphone-chat-routing-status-error", frame(try routingList(preferred: "available", error: "Couldn't read provider availability"))),
            ("iphone-chat-routing-offline", frame(try routingList(preferred: "available"), actual: "codex", reason: "quota_exhausted",
                                                  reachability: .unavailable)),
            ("iphone-chat-routing-no-catalog", frame(list, actual: "claude"))
        ]
        var rows: [ScreenshotHost.IndexRow] = []
        for (name, frame) in frames {
            try await host.captureThree(name, frame)
            rows.append(ScreenshotHost.IndexRow(
                number: name, view: "ChatRoutingAccessory", source: "WatchtowerChat/Sources/ChatUI/Composer/Routing",
                reached: "ChatUI routing pill, phone style, light/dark/narrow"
            ))
        }
        return rows
    }

    /// The unified chat's new parts (spec 2026-11-16 §10, #1822 T0): a question card, a Slack approval card and the
    /// fallback card, drawn by `ChatUI` in the phone's style (T9 replaced the T0 mocks under the same names). Named by
    /// shot, not by frame number.
    private func captureUnifiedChatMocks(host: ScreenshotHost) async throws -> [ScreenshotHost.IndexRow] {
        let frames: [(String, String, AnyView)] = [
            ("iphone-chat-question-card", "QuestionPartView", AnyView(UnifiedChatParts.questionCard)),
            ("iphone-chat-approval-slack", "ApprovalPartView", AnyView(UnifiedChatParts.slackApproval)),
            ("iphone-chat-approval-jira", "AgentActionCard", AnyView(UnifiedChatParts.jiraApproval)),
            ("iphone-chat-approval-confluence", "AgentActionCard", AnyView(UnifiedChatParts.confluenceApproval)),
            ("iphone-chat-approval-connector", "AgentActionCard", AnyView(UnifiedChatParts.connectorApproval)),
            ("iphone-chat-approval-settled", "AgentActionCard", AnyView(UnifiedChatParts.settledApproval)),
            ("iphone-chat-approval-no-permission", "AgentActionCard", AnyView(UnifiedChatParts.noPermissionApproval)),
            ("chat-part-fallback", "FallbackPartView", AnyView(UnifiedChatParts.fallback))
        ]
        var rows: [ScreenshotHost.IndexRow] = []
        for (name, view, frame) in frames {
            try await host.captureThree(name, frame)
            rows.append(ScreenshotHost.IndexRow(
                number: name, view: view, source: "WatchtowerChat/Sources/ChatUI/Parts", reached: "ChatUI part, phone style, light/dark/narrow"
            ))
        }
        return rows
    }

    /// C2a–C2i, C3a–C3c (iPhone chat mockups 2a–2i, 3a–3c): each conversation in the full app over its own center;
    /// the sheets on their own.
    private func captureConversations(
        host: ScreenshotHost, list: ChatList, heartbeat: HeartbeatPayload, relay: HubRoute, grant: DeviceGrant, now: Date
    ) async throws -> [ScreenshotHost.IndexRow] {
        typealias Feeds = DemoSeed.Chat.Feeds
        let env = host.env
        var rows: [ScreenshotHost.IndexRow] = []
        let holds: @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(86_400)) }
        func center(_ feed: ChatFeed?) -> ChatsCenter {
            let center = ChatsCenter(sender: ChatSender { _, _ in "" }, sleep: holds)
            var snapshot = ChatsSnapshot(list: list)
            if let feed { snapshot.feeds[feed.conversation.id] = ChatFeedEntry(feed: feed, payload: Data()) }
            center.apply(snapshot)
            return center
        }
        func shot(
            _ number: String, _ slug: String, _ reached: String, _ route: ChatRoute, _ center: ChatsCenter, mac: MacReachability = .online
        ) async throws {
            env.navigation.tab = .chats
            env.navigation.chatsPath = [route]
            let chats = ChatsShot(center: center, heartbeat: heartbeat, route: relay, grant: grant, mac: mac)
            try await host.captureThree("\(number)-\(slug)", RootTabView(chatsShot: chats))
            rows.append(ScreenshotHost.IndexRow(
                number: number, view: "ChatConversationView", source: "Features/Chats/ChatConversationView.swift",
                reached: "full app, \(reached), light/dark/narrow"
            ))
        }
        func sheet(_ number: String, _ slug: String, _ view: some View, _ source: String) async throws {
            try await host.captureThree("\(number)-\(slug)", view)
            rows.append(ScreenshotHost.IndexRow(number: number, view: source, source: "Features/Chats/\(source).swift", reached: "sheet alone"))
        }
        try await shot("C2a", "chat-done", "a finished turn", ChatRoute(id: Feeds.roadmap), center(Feeds.done(now: now)))
        try await shot("C2b", "chat-answering", "the hub answers", ChatRoute(id: Feeds.roadmap), center(Feeds.busy(now: now)))
        try await shot("C2c", "chat-approvals", "two actions wait", ChatRoute(id: Feeds.release), center(Feeds.waiting(now: now)))
        try await shot("C2d", "chat-artifact-error", "an artifact and a stopped answer", ChatRoute(id: Feeds.vendor),
                       center(Feeds.artifactAndError(now: now)))
        try await shot("C2e", "chat-mac-asleep", "the held copy, the Mac asleep", ChatRoute(id: Feeds.billing), center(Feeds.held(now: now)),
                       mac: .asleep(lastSeen: now.addingTimeInterval(-2_400)))
        try await shot("C2f", "chat-answering-on-mac", "the Mac runs the turn", ChatRoute(id: Feeds.roadmap), center(Feeds.elsewhere(now: now)))
        try await shot("C2g", "chat-loading", "no feed yet", ChatRoute(id: Feeds.meeting), center(nil))
        try await shot("C2h", "chat-new", "a new chat", .new, center(nil))
        let quoting = center(Feeds.quoting(now: now))
        quoting.keepDraft(Feeds.roadmap, text: "", quotes: [Feeds.quote])
        try await shot("C2i", "chat-quote", "a quote waits, older history above", ChatRoute(id: Feeds.roadmap), quoting)

        let menu = NavigationStack {
            Color.clear
                .navigationTitle(ChatConversationView.newChatTitle)
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) { ChatAttachmentMenu { _ in }.padding(.bottom, Spacing.wide).background(.regularMaterial) }
        }
        try await sheet("C3a", "chat-attach-menu", menu, "ChatAttachmentPicker")
        let vendor = Feeds.artifactAndError(now: now)
        let drafts = vendor.messages.flatMap { ArtifactParser.parse($0.text, final: true).artifacts }
        let draft = try XCTUnwrap(drafts.last { $0.key == "reply-to-vendor" })
        let email = ChatArtifactContent(draft: draft, stored: vendor.artifacts.first { $0.key == "reply-to-vendor" })
        let viewer = NavigationStack {
            ScrollView { ArtifactViewer(artifact: email, openURL: { _ in }, copy: { _ in }).padding(Spacing.large) }
                .navigationTitle(email.title)
                .navigationBarTitleDisplayMode(.inline)
        }
        .environment(\.chatUIStyle, PhoneChatStyle())
        try await sheet("C3b", "chat-artifact-email", viewer, "ChatConversationView")
        let sources = ChatSourcesList(sources: Feeds.roadmapSources.map(ChatSource.init(wire:))) { _ in }
        try await sheet("C3c", "chat-sources", sources, "ChatConversationView")
        env.navigation.chatsPath = []
        return rows
    }

    /// A chat center showing `list` and `searches`, its sends going nowhere.
    /// A center whose timers never fire during the tour. Its sleep must suspend: `RelayChatClient`'s feed repeat loop
    /// runs on the main actor, and a sleep that returns at once turns it into a busy loop that starves every later
    /// frame (the C2 conversations hung on it, #1822 T15).
    private static func chatCenter(
        _ list: ChatList?,
        searches: [String: ChatSearch] = [:],
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(86_400)) }
    ) -> ChatsCenter {
        let center = ChatsCenter(sender: ChatSender { _, _ in "" }, sleep: sleep)
        center.apply(ChatsSnapshot(list: list, searches: searches))
        return center
    }

    /// The demo Mac's heartbeat at `at` with the chat capability `chat` (nil: an older hub) and its off reason.
    private static func chatHeartbeat(chat: String?, reason: ChatOffReason?, kind: HubKind?, at: Date) -> HeartbeatPayload {
        HeartbeatPayload(
            updatedAt: at, appVersion: "demo", hubID: DemoSeed.hubID, macName: DemoSeed.macName, flavor: .default,
            lastPublishAt: at, lastRelayAt: at, relayBacklog: 0, accounts: [], enabledAt: at, ownerUser: DemoSeed.ownerUser,
            sharing: .none, hubKind: kind,
            capabilities: chat == nil && reason == nil ? nil : HeartbeatCapabilities(chat: chat, chatReason: reason?.rawValue)
        )
    }

    /// 01m, 01me (#1785): Now with its clock 20 min ahead, so the demo's next meeting starts in about 4 min and its
    /// card carries Record (shown only within 10 min of the start); the end frame shows the card and Ended above it.
    private func captureMeetingSoon(host: ScreenshotHost) async throws -> [ScreenshotHost.IndexRow] {
        try await host.capture("01m-now-meeting-soon", NowView(clockOffset: 20 * 60), endName: "01me-now-meeting-soon")
        return ["01m", "01me"].map {
            ScreenshotHost.IndexRow(
                number: $0, view: "NowView", source: "Features/Now/NowView.swift", reached: "leaf view, clock 20 min ahead")
        }
    }

    /// 01s, 09s (mockup 8): the primary Mac's heartbeat 40 min old, so the
    /// Mac is asleep: Now's chip and working times "as of", the workchat's
    /// banner and composer note. Last of the app shots: the Mac stays asleep.
    private func captureMacAsleep(_ env: AppEnvironment, demo: DemoHub, host: ScreenshotHost) async throws -> [ScreenshotHost.IndexRow] {
        let stale = Date().addingTimeInterval(-2_400)
        let beat = try XCTUnwrap(DemoSeed.records(now: stale).first { $0.recordName == HeartbeatPayload.recordName })
        let sealing = DemoSeed.hubTransport(inner: demo.transport, seq: DemoSeed.hubSeq(defaults: demo.defaults, now: Date()))
        try await sealing.save([beat])
        _ = await env.refresh(.pull)
        try await poll({ env.macReachability(now: Date()) != .online }, "the demo Mac fell asleep")
        try await host.capture("01s-now-mac-asleep", Self.app(.now)(env))
        try await host.capture("09s-session-10-mac-asleep", NavigationStack {
            WorkchatView(replica: env.workbenchReplica, sessionID: 10, store: env.store, requester: env.chatRequests)
        })
        // #1873: the stale line on the Workbench tab, then every state of the line side by side.
        try await host.capture("05s-workbenches-stale", Self.app(.workbench)(env))
        try await host.capture("06s-workbench-stale", NavigationStack {
            WorkbenchView(replica: env.workbenchReplica, writer: env.boardWriter, workbenchID: DemoSeed.acmeID, segment: .sessions)
        })
        try await host.capture("06f-freshness-states", Self.freshnessStates(now: Date()))
        let source = "Features/Workbench/ReplicaFreshness.swift"
        return [
            ScreenshotHost.IndexRow(number: "01s", view: "NowView", source: "Features/Now/NowView.swift", reached: "full app, Mac asleep"),
            ScreenshotHost.IndexRow(
                number: "09s", view: "WorkchatView", source: "Features/Workbench/WorkchatView.swift", reached: "bare stack, Mac asleep"
            ),
            ScreenshotHost.IndexRow(
                number: "05s", view: "WorkbenchListView", source: "Features/Workbench/WorkbenchListView.swift", reached: "full app, Mac asleep"
            ),
            ScreenshotHost.IndexRow(
                number: "06s", view: "WorkbenchView", source: "Features/Workbench/WorkbenchView.swift", reached: "bare stack, Mac asleep"
            ),
            ScreenshotHost.IndexRow(number: "06f", view: "ReplicaFreshnessText", source: source, reached: "leaf views, stuck/stale/offline")
        ]
    }

    /// The freshness line's three states (#1873), from heartbeats built for each.
    private static func freshnessStates(now: Date) -> some View {
        func beat(age: TimeInterval, stuck: TimeInterval?) -> HeartbeatPayload {
            HeartbeatPayload(
                updatedAt: now.addingTimeInterval(-age), appVersion: "1", hubID: "h", macName: "Acme Mac", flavor: .default,
                lastPublishAt: now.addingTimeInterval(-age), lastRelayAt: nil, relayBacklog: 0, accounts: [], enabledAt: now,
                ownerUser: "", sharing: .none, stuckSince: stuck.map { now.addingTimeInterval(-$0) })
        }
        let models = [
            ReplicaFreshness(heartbeat: beat(age: 60, stuck: 3_600), linked: true, relayUnansweredSince: nil, now: now),
            ReplicaFreshness(heartbeat: beat(age: 7_200, stuck: nil), linked: true, relayUnansweredSince: nil, now: now),
            ReplicaFreshness(heartbeat: beat(age: 60, stuck: nil), linked: true, relayUnansweredSince: now.addingTimeInterval(-120), now: now)
        ].compactMap(\.self)
        return VStack(alignment: .leading, spacing: Spacing.regular) {
            ForEach(models, id: \.text) { ReplicaFreshnessText(model: $0) }
        }
        .padding(Spacing.large)
    }

    /// 16a–16c (#1786), after the Mac fell asleep so the earlier shots keep the demo as it was: an external
    /// terminal's check on an archived task (only Task #417), an ask whose session and task were deleted (no
    /// links, the number as text), and a long agent message folded behind Show more.
    private func captureAskSources(_ env: AppEnvironment, demo: DemoHub, host: ScreenshotHost) async throws -> [ScreenshotHost.IndexRow] {
        let now = Date()
        let ago: (TimeInterval) -> Int = { DemoSeed.JSON.stamp(now.addingTimeInterval(-$0)) }
        let acme = DemoSeed.acmeID
        let asks: [[String: Any]] = [
            DemoSeed.JSON.ask(150, workbench: acme, [
                "target_id": 417, "kind": "check", "status": "answered", "title": "Check the archive view",
                "created_at": ago(50_000), "answered_at": ago(49_000)
            ]),
            DemoSeed.JSON.ask(151, workbench: acme, [
                "session_id": 99, "target_id": 999, "status": "answered", "title": "Keep the old lane names?",
                "created_at": ago(40_000), "answered_at": ago(39_000)
            ]),
            DemoSeed.JSON.ask(152, workbench: acme, [
                "session_id": 15, "target_id": 421, "status": "delivered", "title": "Which lanes count toward the total?",
                "created_at": ago(11_000), "answered_at": ago(10_900), "delivered_at": ago(10_890),
                "payload": ["questions": [[
                    "id": "lanes", "question": "Which lanes count?", "options": [["label": "Open lanes only"], ["label": "Every lane"]]
                ]]],
                "answer": [
                    "verdict": "", "answers": [["id": "lanes", "labels": ["Open lanes only"], "other": ""]],
                    "checklist": [Any](), "comments": [Any](), "note": ""
                ]
            ])
        ]
        let message = """
            The lane header now sums the estimates of its targets. Two readings of "total" fit the board: \
            the open targets only, which matches what the Done fold hides, or every target in the lane, \
            which matches the Mac's progress bar. The first keeps the number moving as work lands; the \
            second keeps it stable across a sprint.
            I checked the Desktop board: its progress bar counts every lane.
            Before I change the header I need one answer, so I'm asking.
            """
        let chat: [String: Any] = ["session_id": 15, "live": false, "entries_more": 0, "entries": [
            ["id": "l1", "kind": "owner", "at": ago(12_000), "text": "Add totals to the lane headers."],
            ["id": "l2", "kind": "agent", "at": ago(11_100), "text": message]
        ]]
        let records = try zip([Int64(150), 151, 152], asks).map { try DemoSeed.record(kind: .ownerAsk, id: $0, json: $1, modifiedAt: now) }
            + [try DemoSeed.record(kind: .sessionChat, id: 15, json: chat, modifiedAt: now)]
        let sealing = DemoSeed.hubTransport(inner: demo.transport, seq: DemoSeed.hubSeq(defaults: demo.defaults, now: now))
        try await sealing.save(records)
        _ = await env.refresh(.pull)
        try await poll({ env.workbenchReplica.snapshot.asks.contains { $0.id == 152 } }, "the source asks arrived")
        let shots: [(String, Int64, String)] = [
            ("16a", 150, "archived-task-no-session"), ("16b", 151, "session-and-task-gone"), ("16c", 152, "long-agent-message")
        ]
        for (number, id, slug) in shots {
            try await host.capture("\(number)-ask-\(id)-\(slug)", NavigationStack {
                AskView(replica: env.workbenchReplica, drafts: env.askDrafts, answerer: env.askAnswerer, askID: id)
            })
        }
        return shots.map { number, _, slug in
            ScreenshotHost.IndexRow(number: number, view: "AskView", source: "Features/Asks/AskView.swift", reached: "bare stack, \(slug)")
        }
    }

    /// 10o, 10p, 12l, 11s, 12s: the workchat's what-next card (#1784), with 01c and 05c (Now and the Sessions tab while
    /// the failed session waits to continue, #1785 follow-up), and the permission card the seed has no request
    /// for. Runs after the Mac-asleep shots: the Mac wakes, records saved in its name set each state, and at the end
    /// the Mac sleeps again and every record is put back, so the shots after it see what they saw before.
    private func captureSessionStates(_ env: AppEnvironment, demo: DemoHub, host: ScreenshotHost) async throws -> [ScreenshotHost.IndexRow] {
        let now = Date()
        let sealing = DemoSeed.hubTransport(inner: demo.transport, seq: DemoSeed.hubSeq(defaults: demo.defaults, now: now))
        let seed = try DemoSeed.records(now: now)
        func seeded(_ name: String) throws -> CloudRecord { try XCTUnwrap(seed.first { $0.recordName == name }, name) }
        func publish(_ records: [CloudRecord], _ what: String, until done: @escaping @MainActor () -> Bool) async throws {
            try await sealing.save(records)
            _ = await env.refresh(.pull)
            try await poll(done, what)
        }
        func workchat(_ name: String, _ id: Int64) async throws {
            try await host.capture(name, NavigationStack {
                WorkchatView(replica: env.workbenchReplica, sessionID: id, store: env.store, requester: env.chatRequests)
            })
        }
        func grant(permissions: Bool) -> DeviceGrant {
            DeviceGrant(
                deviceID: DemoSeed.device.deviceID, hubID: DemoSeed.primary.hubID, name: DemoSeed.device.name, scope: DemoSeed.device.scope,
                linked: true, linkedAt: now.addingTimeInterval(-3_600), typingAllowed: true, startSessionsAllowed: true,
                permissionsAllowed: permissions, decidedAt: now.addingTimeInterval(-3_600)
            )
        }
        let snapshot = { env.workbenchReplica.snapshot }
        let beat = try seeded(HeartbeatPayload.recordName)
        try await publish([beat], "the demo Mac woke") { env.macReachability(now: Date()) == .online }

        // A Bash request on "Board lanes": first with the phone's answering off (the seed's), then on.
        let request = try DemoSeed.record(
            kind: .permissionRequest, id: 7,
            json: permissionRequestJSON(7, session: 12, ["summary": "npm run build\nBuild the board before the lane test"]),
            modifiedAt: now
        )
        try await publish([request], "the demo request arrived") { snapshot().pendingPermission(for: 12) != nil }
        try await workchat("10o-session-12-approval-phone-off", 12)
        await env.deviceSettings.setPermissionsRequested(true)
        try await publish([try DemoSeed.keyboxRecord(for: grant(permissions: true), modifiedAt: now)], "the tower allowed answers") {
            snapshot().grant(for: DemoSeed.device.deviceID)?.permissionsAllowed == true && env.deviceSettings.permissionsRequested
        }
        try await workchat("10p-session-12-approval-card", 12)

        // "Undo archive" as a current Mac publishes a failed turn: still live, at its prompt.
        let failedLive = try DemoSeed.record(kind: .terminalSession, id: 16, json: DemoSeed.JSON.session(16, workbench: DemoSeed.acmeID, [
            "title": "Undo archive", "state_kind": "failed", "state_caption": "Error: rate limit", "state_tone": "red",
            "state_glyph": "exclamationmark", "agent_error": "rate_limit", "target_id": 416,
            "last_active_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-600)), "state_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-600))
        ]), modifiedAt: now)
        try await publish([failedLive], "the failed session runs") { snapshot().session(16)?.live == true }
        try await workchat("12l-session-16-failed-live", 16)
        // #1785 follow-up: the failed session this phone can continue waits on Now (and the tab badge) and the Sessions tab.
        try await host.capture("01c-now-failed-to-continue", Self.app(.now)(env))
        try await host.capture("05c-workbench-sessions-failed-to-continue", NavigationStack {
            WorkbenchView(replica: env.workbenchReplica, writer: env.boardWriter, workbenchID: DemoSeed.acmeID, segment: .sessions)
        })
        try await workchat("11s-session-15-not-running", 15)

        // The Mac asleep over the failed session: Continue queues for its wake.
        let stale = try XCTUnwrap(DemoSeed.records(now: now.addingTimeInterval(-2_400)).first { $0.recordName == HeartbeatPayload.recordName })
        try await publish([stale], "the demo Mac fell asleep again") { env.macReachability(now: Date()) != .online }
        try await workchat("12s-session-16-failed-mac-asleep", 16)

        let serverRows = try await captureServerTower(env, sealing: sealing, now: now, host: host)

        try await sealing.delete(recordNames: [request.recordName], in: request.zone)
        await env.deviceSettings.setPermissionsRequested(false)
        try await publish(
            [try seeded(failedLive.recordName), try DemoSeed.keyboxRecord(for: grant(permissions: false), modifiedAt: now),
             stale],
            "the seed is back"
        ) {
            snapshot().pendingPermission(for: 12) == nil && snapshot().session(16)?.live == false
                && snapshot().grant(for: DemoSeed.device.deviceID)?.permissionsAllowed != true
                && snapshot().heartbeat?.isMac == true
        }
        let workchat = "Features/Workbench/WorkchatView.swift"
        let waiting = [
            ScreenshotHost.IndexRow(number: "01c", view: "NowView", source: "Features/Now/NowView.swift",
                                    reached: "full app, a failed live session the phone can continue"),
            ScreenshotHost.IndexRow(number: "05c", view: "WorkbenchView", source: "Features/Workbench/WorkbenchView.swift",
                                    reached: "bare stack, a failed live session the phone can continue")
        ]
        return waiting + serverRows + [
            ("10o", "bare stack, a permission request with the phone's answering off"),
            ("10p", "bare stack, a permission request the phone may answer"),
            ("12l", "bare stack, a failed turn of a live session"),
            ("11s", "bare stack, a session whose run ended"),
            ("12s", "bare stack, a failed live session, Mac asleep")
        ].map { ScreenshotHost.IndexRow(number: $0.0, view: "WorkchatView", source: workchat, reached: $0.1) }
    }

    /// 10v, 18v (#1783): the primary hub as a server tower (heartbeat hub_kind "server") that has not allowed
    /// answers or starts: the hints name `watchtower hub allow` instead of the Mac app's Settings → Mobile. The
    /// caller puts the Mac heartbeat and grant back.
    private func captureServerTower(
        _ env: AppEnvironment, sealing: SecureTransport, now: Date, host: ScreenshotHost
    ) async throws -> [ScreenshotHost.IndexRow] {
        var server = DemoSeed.primary
        server.kind = .server
        let serverBeat = try XCTUnwrap(DemoSeed.records(now: Date(), hub: server).first { $0.recordName == HeartbeatPayload.recordName })
        let serverGrant = DeviceGrant(
            deviceID: DemoSeed.device.deviceID, hubID: DemoSeed.primary.hubID, name: DemoSeed.device.name, scope: DemoSeed.device.scope,
            linked: true, linkedAt: now.addingTimeInterval(-3_600), typingAllowed: true, startSessionsAllowed: false,
            permissionsAllowed: false, decidedAt: now.addingTimeInterval(-3_600)
        )
        try await sealing.save([serverBeat, try DemoSeed.keyboxRecord(for: serverGrant, modifiedAt: now)])
        _ = await env.refresh(.pull)
        try await poll({
            env.workbenchReplica.snapshot.heartbeat?.isMac == false
                && env.workbenchReplica.snapshot.grant(for: DemoSeed.device.deviceID)?.permissionsAllowed == false
                && env.macReachability(now: Date()) == .online
        }, "the server tower")
        try await host.capture("10v-session-12-approval-server-tower", NavigationStack {
            WorkchatView(replica: env.workbenchReplica, sessionID: 12, store: env.store, requester: env.chatRequests)
        })
        try await host.capture("18v-start-session-server-tower", StartSessionSheet(
            workbenchID: DemoSeed.acmeID, target: env.workbenchReplica.snapshot.targets.first { $0.id == 415 }, fixed: true
        ) { _ in })
        return [
            ScreenshotHost.IndexRow(number: "10v", view: "WorkchatView", source: "Features/Workbench/WorkchatView.swift",
                                    reached: "bare stack, a permission request on a server tower that has not allowed answers"),
            ScreenshotHost.IndexRow(number: "18v", view: "StartSessionSheet", source: "Features/Workbench/StartSessionSheet.swift",
                                    reached: "sheet, a server tower that has not allowed starting sessions")
        ]
    }

    // MARK: - Linking over Relay (relay client Phase 3 Task 10, mockup section 7)

    /// A link flow over a scripted relay account and a fake host holding the demo Macs plus "Work Mac" on Relay,
    /// with the demo's finishing link to "build-box" in `state` (nil: none).
    private func relayLinking(_ state: PromotedLink.State?, now: Date) throws -> (LinkingViewModel, FakeRelayOps, FakeLinkHost) {
        let clock = FakeLinkClock(now: now)
        let relay = FakeRelayOps(clock: clock)
        let host = FakeLinkHost(log: LinkEventLog())
        for hub in DemoSeed.hubs {
            host.seed(DemoSeed.link(for: hub, now: now))
        }
        host.seed(DemoSeed.Relay.workLink(now: now))
        host.noteHeartbeat(now, hubID: DemoSeed.Relay.workLink(now: now).hubID)
        let store = LinkStore(defaults: try makeDefaults())
        if let state {
            let link = DemoSeed.Relay.finishingLink(state, now: now)
            store.promoted = [link.hubID: link]
        }
        let device = DemoSeed.device
        let linking = LinkingViewModel(
            access: FakeLinkAccess(log: LinkEventLog()), store: store,
            identity: DeviceIdentity(deviceID: device.deviceID, name: device.name, model: device.model, appVersion: device.appVersion),
            keys: InMemoryPhoneKeyStore(), clock: clock, relay: relay
        )
        linking.host = host
        relay.slots = [DemoSeed.Relay.workMac, DemoSeed.Relay.unknownMac, DemoSeed.Relay.finishingMac]
        return (linking, relay, host)
    }

    /// R01–R21, each light, dark and narrow (iPhone SE, the largest Dynamic Type size).
    private func captureRelayLinking(host: ScreenshotHost) async throws -> [ScreenshotHost.IndexRow] {
        let now = Date()
        let onboarding = "Features/Onboarding/"
        var rows: [ScreenshotHost.IndexRow] = []
        func shot(
            _ number: String,
            _ slug: String,
            _ source: String,
            _ reached: String,
            _ view: some View,
            settle: Duration = .milliseconds(600),
            narrowScroll: CGFloat? = nil
        ) async throws {
            try await host.captureThree("\(number)-\(slug)", view, settle: settle, narrowScroll: narrowScroll)
            let name = URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent
            rows.append(ScreenshotHost.IndexRow(number: number, view: name, source: source, reached: "\(reached), light/dark/narrow"))
        }
        for (number, slug, failure) in [
            ("R01", "link-needs-relay", LinkFailure.needsRelay(macName: "build-box")),
            ("R02", "link-relay-unreachable", .relayUnreachable),
            ("R03", "link-mac-on-relay", .macOnRelay(macName: "Work Mac"))
        ] {
            try await shot(number, slug, onboarding + "LinkedView.swift", "leaf view", LinkFailureView(failure: failure))
        }
        for (number, slug, notice) in [
            ("R04", "link-finish-in-background", LinkNotice.finishingInBackground(macName: "build-box")),
            ("R05", "notice-mac-on-relay", .macOnRelay(macName: "Work Mac"))
        ] {
            host.env.navigation.tab = .now
            try await shot(number, slug, "App/AppRootView.swift", "full app with the notice", TabsWithNotice(notice: notice))
        }

        let slots = onboarding + "RelaySlotsView.swift"
        let (slotsLinking, slotsRelay, _) = try relayLinking(.needsOwner(.slotsFull), now: now)
        await slotsLinking.manageSlots(for: DemoSeed.Relay.finishingHubID)
        try await shot(
            "R06", "relay-slots-full", slots,
            "sheet with its own Cancel (no back chevron: the mockup's 7.3 frames draw it pushed)",
            RelaySlotsView {}.environment(slotsLinking)
        )
        let finishingRow = try XCTUnwrap(
            RelaySlotsModel(state: slotsLinking.relaySlots, links: slotsLinking.links, promoted: slotsLinking.promotedLinks)
                .rows.first { $0.id == DemoSeed.Relay.finishingMac }
        )
        try await shot(
            "R07", "relay-slots-finishing-mac", slots, "sheet, Remove on the finishing link. \(Self.alertGap)",
            RelaySlotsView(asking: RelaySlotsModel.ask(for: finishingRow)) {}.environment(slotsLinking), settle: .seconds(2)
        )
        slotsRelay.park("removeSlot")
        slotsRelay.fail("removeSlot", with: HostedRelayPairing.Refusal.unreachable)
        let removal = Task { await slotsLinking.removeFromSlots(DemoSeed.Relay.workMac) }
        try await poll({ slotsRelay.isParked("removeSlot") }, "the removal is running")
        try await shot("R08", "relay-slots-removing", slots, "sheet, a removal running", RelaySlotsView {}.environment(slotsLinking))
        slotsRelay.release("removeSlot")
        await removal.value
        try await shot("R09", "relay-slots-remove-error", slots, "sheet, the removal failed", RelaySlotsView {}.environment(slotsLinking))

        try await captureRelayMacs(now: now) { number, slug, reached, view, settle in
            // The finishing row comes after the linked Macs: the narrow frame scrolls to the end of the list, where it
            // is (at the largest Dynamic Type size it falls below the first screen).
            try await shot(
                number, slug, "Features/Settings/MacsView.swift", "\(reached), narrow scrolled to the finishing row", view,
                settle: settle, narrowScroll: Self.toTheEnd
            )
        }
        try await shot(
            "R21", "link-mac-not-on-relay", onboarding + "LinkedView.swift", "leaf view",
            LinkFailureView(failure: .macNotOnRelay(macName: "build-box"))
        )
        return rows
    }

    /// R10–R20: Settings → Macs with the demo's finishing link in each state.
    private func captureRelayMacs(
        now: Date, shot: (_ number: String, _ slug: String, _ reached: String, _ view: AnyView, _ settle: Duration) async throws -> Void
    ) async throws {
        let (busy, busyRelay, _) = try relayLinking(.confirmed, now: now)
        busyRelay.park("vouch")
        let attempt = Task { await busy.tryAgain(DemoSeed.Relay.finishingHubID) }
        try await poll({ busyRelay.isParked("vouch") }, "the attempt is running")
        try await shot(
            "R10", "macs-finishing-row", "bare stack, an attempt running",
            AnyView(NavigationStack { MacsView() }.environment(busy)), .milliseconds(600)
        )
        busyRelay.release("vouch")
        await attempt.value

        let (failed, _, failedHost) = try relayLinking(.promoted, now: now)
        failedHost.prepareError = CocoaError(.fileReadCorruptFile)
        await failed.resumePromotedLinks()
        try await shot(
            "R11", "macs-finishing-row-error", "bare stack, the last attempt failed",
            AnyView(NavigationStack { MacsView() }.environment(failed)), .milliseconds(600)
        )

        for (index, reason) in PromotedLink.Reason.allCases.enumerated() {
            let (linking, _, _) = try relayLinking(.needsOwner(reason), now: now)
            try await shot(
                String(format: "R%02d", 12 + index), "macs-needs-owner-\(reason.rawValue)", "bare stack",
                AnyView(NavigationStack { MacsView() }.environment(linking)), .milliseconds(600)
            )
        }
        let (cancel, _, _) = try relayLinking(.needsOwner(.slotExpired), now: now)
        let row = try XCTUnwrap(MacsModel.finishingRows(cancel.promotedLinks, running: [], failed: []).first)
        try await shot(
            "R20", "macs-finishing-cancel-confirm", "bare stack, Cancel pressed. \(Self.alertGap)",
            AnyView(NavigationStack { MacsView(cancelling: row) }.environment(cancel)), .seconds(2)
        )
    }

    // MARK: - Relay client Phase 4 (mockup section 8, S01 upward)

    /// A link flow whose Macs are `links` (the fake host's), for Settings → Macs.
    private func macsLinking(_ links: [LinkRecord], now: Date) throws -> LinkingViewModel {
        let clock = FakeLinkClock(now: now)
        let host = FakeLinkHost(log: LinkEventLog())
        for link in links {
            host.seed(link)
            host.noteHeartbeat(now, hubID: link.hubID)
        }
        let device = DemoSeed.device
        let linking = LinkingViewModel(
            access: FakeLinkAccess(log: LinkEventLog()), store: LinkStore(defaults: try makeDefaults()),
            identity: DeviceIdentity(deviceID: device.deviceID, name: device.name, model: device.model, appVersion: device.appVersion),
            keys: InMemoryPhoneKeyStore(), clock: clock, relay: FakeRelayOps(clock: clock)
        )
        linking.host = host
        return linking
    }

    /// S01–S07, S41, S55: Settings → Macs' Relay card in each state and the Macs' transport lines, each light, dark
    /// and narrow. The card is handed to the view (`MacsView(card:)`) over a never-started account center, which is
    /// what turns the rows' transport lines on; S07 alone runs over a center whose subscription ended.
    private func captureRelayPhase4(host: ScreenshotHost) async throws -> [ScreenshotHost.IndexRow] {
        let now = Date()
        let env = host.env
        let defaults = try makeDefaults()
        env.relayAccount = RelayAccountCenter(
            link: RelayAccountLink(hasIdentity: { false }, account: { nil }, events: { nil }),
            store: FakeSubscriptionStore(), defaults: defaults
        ) { [] }
        defer { env.relayAccount = nil }
        let source = "Features/Settings/MacsView.swift"
        var rows: [ScreenshotHost.IndexRow] = []
        func shot(_ number: String, _ slug: String, _ reached: String, _ view: some View) async throws {
            try await host.captureThree("\(number)-\(slug)", view, narrowScroll: Self.toTheEnd)
            rows.append(ScreenshotHost.IndexRow(number: number, view: "MacsView", source: source, reached: "\(reached), light/dark/narrow"))
        }
        func macLink(_ id: String, _ name: String, relay: Bool = false) -> LinkRecord {
            var record = LinkRecord(
                hubID: id, macName: name, scope: .private, ownerName: "", userRecordName: "", nonce: id,
                dataShareURL: nil, relayShareURL: nil, deviceID: DemoSeed.device.deviceID, linkedAt: now
            )
            if relay { record.setRelay(mac: DemoSeed.Relay.workMac) }
            return record
        }
        let origin = try RelayOrigin("https://relay.example.com")
        let twoMacs = try macsLinking([macLink("p4-work", "Work Mac"), macLink("p4-home", "Home Mac")], now: now)
        let cards: [(String, String, RelayAccountCenter.Phase, Bool)] = [
            ("S01", "relay-card-not-subscribed", .free(ended: false), false),
            ("S02", "relay-card-loading", .checking, false),
            ("S03", "relay-card-error", .unknown, false),
            ("S04", "relay-card-active", .paying(grace: false, macs: ["a", "b"]), false),
            ("S05", "relay-card-grace", .paying(grace: true, macs: ["a", "b"]), false),
            ("S06", "relay-card-ended", .free(ended: true), false),
            ("S41", "relay-card-moved", .moved, false),
            ("S55", "relay-card-purchase-not-confirmed", .free(ended: false), true)
        ]
        for (number, slug, phase, unconfirmed) in cards {
            let card = try XCTUnwrap(RelayCardModel(
                availability: .available(origin), phase: phase, unconfirmedPurchase: unconfirmed
            ))
            try await shot(number, slug, "bare stack, the Relay card", NavigationStack { MacsView(card: card) }.environment(twoMacs))
        }

        let home = macLink("p4-home", "Home Mac")
        var thisPhone = macLink("p4-this", "Work Mac", relay: true)
        thisPhone.switchedBy = DemoSeed.device.deviceID
        var another = macLink("p4-other", "Work Mac", relay: true)
        another.switchedBy = "another-phone"
        var ended = macLink("p4-ended", "build-box")
        ended.switchedBy = TransportFollowerPolicy.lapseReason
        var switching = macLink("p4-lab", "Lab Mac")
        switching.relayUpgrade = RelayUpgradeRecord(step: .vouching)
        let at = Calendar.current.startOfDay(for: now).addingTimeInterval(10 * 3_600 + 42 * 60)
        thisPhone.switchedAt = at
        another.switchedAt = at
        ended.switchedAt = at
        let lines = try macsLinking([home, thisPhone, another, ended, switching], now: now)
        // The lapse row says "your subscription ended" only on a phone whose own subscription ended (S06): a center
        // that read a revoked entitlement from the fake relay, in place of the never-started one for this frame.
        let bed = AccountBed()
        let token = try await bed.register()
        try await bed.fake.setEntitlement(accountID: token.uuidString.lowercased(), state: "revoked", for: .seconds(86_400))
        let endedCenter = bed.makeCenter()
        endedCenter.start()
        await endedCenter.foreground()?.value
        XCTAssertEqual(endedCenter.phase, .free(ended: true))
        let neverStarted = env.relayAccount
        env.relayAccount = endedCenter
        try await shot(
            "S07", "macs-transport-lines", "bare stack, iCloud / Relay / lapse / switching rows",
            NavigationStack { MacsView() }.environment(lines)
        )
        env.relayAccount = neverStarted // the frames after S07 run over the never-started center again

        rows += try await captureDiagnostics(host: host)
        rows += try await captureConnection(host: host, origin: origin, now: now) { macLink($0, $1, relay: $2) }
        rows += try await captureSubscription(host: host)
        rows += try await captureBanners(host: host, origin: origin, now: now)
        return rows
    }

    /// S30–S36, S34b, S34c, S36b, S41b, S41c, S47, S50, S51, S53: Now's Relay banner in each state of Task 1's table, each light, dark and narrow, handed to
    /// the view (`NowView(banner:)`). The outage frames sit on the outbox demo, for the Waiting to send row under them.
    private func captureBanners(host: ScreenshotHost, origin: RelayOrigin, now: Date) async throws -> [ScreenshotHost.IndexRow] {
        func banner(
            availability: RelayAvailability? = nil,
            phase: RelayAccountCenter.Phase = .paying(grace: false, macs: []),
            updateRequired: Bool = false,
            wasPaying: Bool = false,
            route: HubRoute? = .cloudKit(.private),
            relayOnly: Bool = false,
            hubOnRelay: Bool = false,
            outageMinutes: Double? = nil,
            request: TransportRequestRecord? = nil,
            macName: String = "Work Mac"
        ) throws -> RelayBannerModel {
            let lastUpdate = Calendar.current.startOfDay(for: now).addingTimeInterval(10 * 3_600 + 41 * 60)
            return try XCTUnwrap(RelayBannerModel.banner(
                availability: availability ?? .available(origin), phase: phase, unconfirmedPurchase: false, updateRequired: updateRequired,
                wasPaying: wasPaying, route: route, relayOnly: relayOnly, hubOnRelayAt: hubOnRelay ? now : nil,
                unansweredSince: outageMinutes.map { now.addingTimeInterval(-$0 * 60) }, request: request, pressRefusal: nil,
                lastUpdate: lastUpdate, macName: macName, now: now
            ))
        }
        let onRelay = HubRoute.hostedRelay(macDeviceID: DemoSeed.Relay.workMac)
        func request(lapse: Bool = false, refusal: TransportRequestRefusal? = nil) -> TransportRequestRecord {
            let reason = lapse ? TransportFollowerPolicy.lapseReason : nil
            return TransportRequestRecord(target: .cloudKit, controlID: "c", reason: reason, at: now, refusal: refusal)
        }
        let plain: [(String, String, RelayBannerModel)] = [
            ("S30", "banner-free-mac-on-relay", try banner(phase: .free(ended: false), hubOnRelay: true)),
            ("S51", "banner-mac-on-relay-no-relay", try banner(availability: .off(.notConfigured), hubOnRelay: true)),
            ("S47", "banner-relay-only-ended", try banner(phase: .free(ended: true), route: onRelay, relayOnly: true, macName: "build-box")),
            ("S53", "banner-relay-only-moved", try banner(phase: .moved, route: onRelay, relayOnly: true, macName: "build-box")),
            ("S33", "banner-moved", try banner(phase: .moved, wasPaying: true)),
            ("S34", "banner-ended", try banner(phase: .free(ended: true), wasPaying: true)),
            ("S34b", "banner-ended-mac-not-moved", try banner(
                phase: .free(ended: true), wasPaying: true, route: onRelay, request: request(lapse: true)
            )),
            ("S41b", "banner-moved-mac-not-moved", try banner(phase: .moved, wasPaying: true, route: onRelay, request: request(lapse: true))),
            ("S34c", "banner-ended-mac-refused", try banner(
                phase: .free(ended: true), wasPaying: true, route: onRelay, request: request(lapse: true, refusal: .unavailable)
            )),
            ("S41c", "banner-moved-mac-refused", try banner(
                phase: .moved, wasPaying: true, route: onRelay, request: request(lapse: true, refusal: .unavailable)
            )),
            ("S35", "banner-update-the-app", try banner(updateRequired: true, wasPaying: true)),
            ("S36b", "banner-switching-relay-answers", try banner(route: onRelay, request: request()))
        ]
        let waiting: [(String, String, RelayBannerModel)] = [
            ("S31", "banner-relay-unavailable", try banner(route: onRelay, outageMinutes: 3)),
            ("S32", "banner-relay-unavailable-offer", try banner(route: onRelay, outageMinutes: 12)),
            ("S36", "banner-switching", try banner(route: onRelay, outageMinutes: 12, request: request())),
            ("S50", "banner-refused", try banner(route: onRelay, outageMinutes: 12, request: request(refusal: .unavailable)))
        ]
        var rows: [ScreenshotHost.IndexRow] = []
        func shots(_ frames: [(String, String, RelayBannerModel)], on host: ScreenshotHost, reached: String) async throws {
            for (number, slug, model) in frames {
                // At the largest type a sentence fills the narrow screen: the frame scrolls to its second line and links.
                let hasMore = model.secondLine != nil || !model.actions.isEmpty
                let reach: CGFloat = model.text.count > 100 ? 620 : model.actions.count > 2 ? 520 : 340
                let scroll = hasMore ? reach : nil
                try await host.captureThree("\(number)-\(slug)", NowView(banner: model), narrowScroll: scroll)
                rows.append(ScreenshotHost.IndexRow(
                    number: number, view: "NowView", source: "Features/Now/NowView.swift", reached: "\(reached), light/dark/narrow"
                ))
            }
        }
        try await shots(plain, on: host, reached: "NowView, demo hub")
        let (env, _) = try await outboxDemoEnv()
        let outboxHost = ScreenshotHost(directory: host.directory, env: env, linking: host.linking)
        try await shots(waiting, on: outboxHost, reached: "NowView, outbox demo")
        return rows
    }

    /// S20–S29, S42–S46, S57: the subscription screen in each state of Task 1's table, each light, dark and narrow, handed to
    /// the view (`RelaySubscriptionView(model:)`).
    private func captureSubscription(host: ScreenshotHost) async throws -> [ScreenshotHost.IndexRow] {
        let product = RelayProduct(id: "relay", displayPrice: "$4.99")
        let config = RelayConfig(
            origin: nil, termsURL: URL(string: "https://example.com/terms"), privacyURL: URL(string: "https://example.com/privacy")
        )
        let frames: [(String, String, RelayAccountCenter.PurchaseState)] = [
            ("S20", "subscription-loaded", .ready(product)),
            ("S21", "subscription-loading", .loadingProduct),
            ("S22", "subscription-error", .productFailed),
            ("S23", "subscription-buying", .buying),
            ("S24", "subscription-confirming", .confirming),
            ("S44", "subscription-restoring", .restoring),
            ("S45", "subscription-none-found", .noSubscriptionFound),
            ("S46", "subscription-account-failed", .accountFailed),
            ("S46b", "subscription-restore-failed", .restoreFailed),
            ("S25", "subscription-pending", .pending),
            ("S26", "subscription-not-reached", .boughtNotConfirmed),
            ("S27", "subscription-refused", .refused),
            ("S28", "subscription-transfer-limit", .transferLimit),
            ("S42", "subscription-no-purchases", .notImplemented),
            ("S43", "subscription-app-too-old", .updateRequired),
            ("S29", "subscription-done", .done),
            ("S57", "subscription-store-failed", .storeFailed)
        ]
        // A Restore pressed before any load found a price.
        let noPrice: [(String, String, RelayAccountCenter.PurchaseState)] = [
            ("S45b", "subscription-none-found-no-price", .noSubscriptionFound),
            ("S57b", "subscription-store-failed-no-price", .storeFailed)
        ]
        var rows: [ScreenshotHost.IndexRow] = []
        for (number, slug, purchase, price) in frames.map({ ($0.0, $0.1, $0.2, Optional(product)) }) + noPrice.map({ ($0.0, $0.1, $0.2, nil) }) {
            let model = RelaySubscriptionModel(
                purchase: purchase, unconfirmed: nil, phase: .free(ended: false), config: config, product: price
            )
            try await host.captureThree(
                "\(number)-\(slug)", NavigationStack { RelaySubscriptionView(model: model) }, narrowScroll: Self.toTheEnd
            )
            rows.append(ScreenshotHost.IndexRow(
                number: number, view: "RelaySubscriptionView", source: "Features/Settings/RelaySubscriptionView.swift",
                reached: "bare stack, the subscription screen, light/dark/narrow"
            ))
        }
        return rows
    }

    /// S08–S19, S49, S52, S54, S56: a Mac's Connection section in each state of Task 1's table, each light, dark and narrow,
    /// handed to the view (`MacDetailView(model:)`).
    private func captureConnection(
        host: ScreenshotHost, origin: RelayOrigin, now: Date, makeLink: (String, String, Bool) -> LinkRecord
    ) async throws -> [ScreenshotHost.IndexRow] {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32)).publicKey.rawRepresentation
        let device = DemoSeed.device.deviceID
        func grant(ordered: Bool = true) -> DeviceGrant {
            DeviceGrant(
                deviceID: device, hubID: "p4-work", name: "iPhone", scope: .private, linked: true, typingAllowed: true,
                startSessionsAllowed: true, orderedActions: ordered ? 1 : nil, transports: ["cloudkit", "relay"],
                relayDeviceID: RelayIDs.deviceID(publicKey: key), relayAuthPub: WireBytes.base64URL(key)
            )
        }
        let at = Calendar.current.startOfDay(for: now).addingTimeInterval(10 * 3_600 + 42 * 60)
        var iCloud = makeLink("p4-work", "Work Mac", false)
        iCloud.switchedBy = device
        iCloud.switchedAt = at
        var onRelay = makeLink("p4-work", "Work Mac", true)
        onRelay.switchedBy = device
        onRelay.switchedAt = at
        let freshICloud = makeLink("p4-work", "Work Mac", false)
        var relayOnly = makeLink("p4-work", "build-box", true)
        relayOnly.hubTransports = ["relay"]
        let paying = RelayAccountCenter.Phase.paying(grace: false, macs: [])
        let free = RelayAccountCenter.Phase.free(ended: false)
        func request(_ refusal: TransportRequestRefusal? = nil) -> TransportRequestRecord {
            TransportRequestRecord(target: .cloudKit, controlID: "c", reason: nil, at: now, refusal: refusal)
        }
        func facts(
            step: RelayUpgradeStep? = nil, refusal: RelayUpgradeRefusal? = nil, request: TransportRequestRecord? = nil, reachable: Bool = true
        ) -> SessionTransportFacts {
            SessionTransportFacts(upgradeStep: step, upgradeRefusal: refusal, request: request, macReachable: reachable)
        }
        func model(
            _ link: LinkRecord,
            phase: RelayAccountCenter.Phase = paying,
            grant given: DeviceGrant? = nil,
            unconfirmed: Bool = false,
            _ session: SessionTransportFacts? = nil
        ) -> MacTransportModel {
            MacTransportModel(
                link: link, grant: given ?? grant(), phase: phase, unconfirmedPurchase: unconfirmed,
                availability: .available(origin), session: session ?? facts(), macName: link.macName, ownDeviceID: device, now: now
            )
        }
        let frames: [(String, String, MacTransportModel)] = [
            ("S08", "connection-relay-chosen", model(onRelay)),
            ("S09", "connection-icloud-chosen", model(iCloud)),
            ("S10", "connection-free-phone", model(freshICloud, phase: free)),
            ("S11", "connection-too-soon", model(freshICloud, facts(refusal: .tooSoon(retryAt: now.addingTimeInterval(240))))),
            ("S12", "connection-mac-needs-update", model(freshICloud, grant: grant(ordered: false))),
            ("S12b", "connection-relay-route-mac-needs-update", model(onRelay, grant: grant(ordered: false))),
            ("S13", "connection-relay-only", model(relayOnly)),
            ("S13b", "connection-relay-only-lapse", model(relayOnly, phase: free)),
            ("S54", "connection-relay-no-answer", model(freshICloud, phase: .unknown)),
            ("S56", "connection-purchase-not-confirmed", model(freshICloud, phase: free, unconfirmed: true)),
            ("S14", "connection-slots-full", model(freshICloud, phase: .paying(grace: false, macs: ["a", "b", "c"]))),
            ("S49", "connection-request-refused", model(onRelay, facts(request: request(.unavailable)))),
            ("S52", "connection-no-answer", model(onRelay, facts(request: request(.macNoAnswer)))),
            ("S52b", "connection-no-answer-lapse", model(onRelay, phase: free, facts(request: request(.lapseNoAnswer)))),
            ("S15", "connection-upgrade-running", model(freshICloud, facts(step: .vouching))),
            ("S16", "connection-waiting-closed-mac", model(freshICloud, facts(step: .requested, reachable: false))),
            ("S17", "connection-toward-icloud", model(onRelay, facts(request: request()))),
            ("S18", "connection-refusal", model(freshICloud, facts(refusal: .readerNotConfirmed))),
            ("S19", "connection-checking", model(freshICloud, phase: .checking)),
            ("S19b", "connection-checking-relay-route", model(onRelay, phase: .checking))
        ]
        let linking = try macsLinking([makeLink("p4-work", "Work Mac", false)], now: now)
        var rows: [ScreenshotHost.IndexRow] = []
        for (number, slug, frame) in frames {
            try await host.captureThree(
                "\(number)-\(slug)", NavigationStack { MacDetailView(hubID: "p4-work", model: frame) }.environment(linking),
                narrowScroll: Self.toTheEnd
            )
            rows.append(ScreenshotHost.IndexRow(
                number: number, view: "MacDetailView", source: "Features/Settings/MacDetailView.swift",
                reached: "bare stack, the Connection section, light/dark/narrow"
            ))
        }
        return rows
    }

    /// S37–S40, S37b, S48: Settings → Diagnostics, each state through a fixed reader, light, dark and narrow.
    private func captureDiagnostics(host: ScreenshotHost) async throws -> [ScreenshotHost.IndexRow] {
        var rows: [ScreenshotHost.IndexRow] = []
        let settings = SettingsViewModel()
        settings.refreshBattery()
        let diagnostics: [(String, String, LatencyDiagnosticsModel.State)] = [
            ("S37", "diagnostics-rows", .rows([
                .init(title: "Relay", count: "214 actions", result: "p50 0.31 s · p90 0.7 s", answer: "Tower's answer: p50 0.12 s · p90 0.3 s")
            ])),
            ("S37b", "diagnostics-rows-icloud", .rows([
                .init(title: "iCloud", count: "214 actions", result: "p50 0.31 s · p90 0.7 s", answer: "Tower's answer: p50 0.12 s · p90 0.3 s")
            ])),
            ("S38", "diagnostics-empty", .empty),
            ("S48", "diagnostics-needs-mac-update", .needsMacUpdate),
            ("S39", "diagnostics-loading", .loading),
            ("S40", "diagnostics-error", .failed)
        ]
        for (number, slug, state) in diagnostics {
            let view = NavigationStack { DiagnosticsView(settings: settings, reader: LatencyDiagnosticsReader(fixed: state)) }
            try await host.captureThree("\(number)-\(slug)", view)
            rows.append(ScreenshotHost.IndexRow(
                number: number, view: "DiagnosticsView", source: "Features/Settings/DiagnosticsView.swift",
                reached: "bare stack, a fixed reader, light/dark/narrow"))
        }
        return rows
    }

    /// A narrow scroll past any list's end: `captureThree` stops at the end.
    static let toTheEnd: CGFloat = 100_000

    /// R07/R20's INDEX note: the confirmation alert is presented but not in the PNG.
    static let alertGap = "The alert is not captured (iOS 26 draws it outside drawHierarchy); its copy is asserted in "
        + "RelaySlotsModelTests and MacsModelTests; the owner checks it on a device"

    private static func isHydrated(_ env: AppEnvironment) -> Bool {
        env.activeSession.isBootstrapped && !env.workbenchReplica.snapshot.workbenches.isEmpty
            && !env.calendarReplica.snapshot.events.isEmpty && !env.phoneRecordings.snapshot.recordings.isEmpty
    }

    /// 26b–26d: the recorder over a fake engine and clock, recording,
    /// paused and saved. The demo environment's recorder never starts (no
    /// microphone on the simulator), so it shows 26 (idle) only.
    private func captureRecorder(into dir: URL, linking: LinkingViewModel) async throws -> [ScreenshotHost.IndexRow] {
        let engine = FakeAudioEngine()
        let clock = FakeClock()
        let defaults = try makeDefaults()
        let session = try HubSession(
            transport: InMemoryCloudTransport(),
            replicaPath: try makeReplicaPath(),
            backend: .inMemoryDemo,
            defaults: defaults,
            recordingsDirectory: try makeRecordingsDirectory()
        ) { uploader in
            PhoneRecorderController(
                uploader: uploader, engine: engine, notificationCenter: NotificationCenter(),
                now: { clock.now }, tickInterval: nil
            )
        }
        addTeardownBlock { @MainActor in session.stop() }
        try await poll({ session.isBootstrapped }, "the recorder environment booted")
        let env = AppEnvironment.single(session, defaults: defaults)
        let host = ScreenshotHost(directory: dir, env: env, linking: linking)
        let recorder = env.recorder
        await recorder.recordVoiceNote()
        for step in 0..<48 {
            engine.levelValue = Float(step % 8) / 8
            clock.advance(1)
            await recorder.tick()
        }
        try await host.capture("26b-recorder-recording", RecordingView())
        recorder.pause()
        try await host.capture("26c-recorder-paused", RecordingView())
        recorder.resume()
        clock.advance(60)
        await recorder.stop()
        try await host.capture("26d-recorder-saved", RecordingView())
        return ["26b", "26c", "26d"].map {
            ScreenshotHost.IndexRow(
                number: $0, view: "RecordingView", source: "Features/Recording/RecordingView.swift",
                reached: "leaf view, fake audio engine"
            )
        }
    }

    /// 37–38r (relay client mockup 5a): the demo outbox state on its own demo session — three actions waiting to
    /// send behind a stopped flush, two Not delivered (one withdrawn after 24 h, one refused) — on Now, then the
    /// list, its Dismiss All confirmation, and a retry running under the last one's "Unlock your iPhone" error.
    /// A demo session with three actions waiting to send and two not delivered (mockup 5a).
    private func outboxDemoEnv() async throws -> (AppEnvironment, HubSession) {
        let clock = MutableClock()
        let transport = RefusingTransport()
        let (env, session) = try await bareOutboxEnv(transport: transport, clock: clock)
        let now = Date()
        try await DemoSeed.loadOutboxDemo(
            outbox: session.outbox, now: now,
            setClock: { clock.advance($0.timeIntervalSince(clock.now)) },
            refuse: { await transport.refuse($0) })
        try await poll({
            let backlog = session.outboxBacklog
            return backlog.queued == 3 && backlog.undelivered == 2 && backlog.lastFlushStopped
                && OutboxItem.rows(session.workbenchReplica.snapshot.pending, .undelivered).count == 2
        }, "the outbox demo state landed")
        return (env, session)
    }

    /// A booted demo session over `transport`, its outbox empty.
    private func bareOutboxEnv(transport: RefusingTransport, clock: MutableClock) async throws -> (AppEnvironment, HubSession) {
        let defaults = try makeDefaults()
        let session = try HubSession(
            transport: transport,
            replicaPath: try makeReplicaPath(),
            backend: .inMemoryDemo,
            keys: try DemoSeed.phoneKeys(),
            defaults: defaults,
            recordingsDirectory: try makeRecordingsDirectory(),
            now: { clock.now } // swiftlint:disable:this trailing_closure
        )
        addTeardownBlock { @MainActor in session.stop() }
        try await poll({ session.isBootstrapped && !session.workbenchReplica.snapshot.workbenches.isEmpty }, "the outbox demo booted")
        await session.outboxWork?.value
        return (AppEnvironment.single(session, defaults: defaults), session)
    }

    /// S58, S58a, S58b2, S58c (relay client Phase 5, Task 16): Now with the relay feed parked waiting for the Mac's new
    /// keys, with two, one and no sent actions, then with three waiting to send under it; each on its own demo session
    /// (named as its link names it, as the chip does), light, dark and narrow. The tour writes the parked mark, as the feed would after its hour.
    private func captureParkedFeed(into dir: URL, linking: LinkingViewModel) async throws -> [ScreenshotHost.IndexRow] {
        let frames: [(String, String, Int, Bool)] = [
            ("S58", "now-parked-two-sent", 2, false),
            ("S58a", "now-parked-one-sent", 1, false),
            ("S58b2", "now-parked-none-sent", 0, false),
            ("S58c", "now-parked-waiting-to-send", 2, true)
        ]
        var rows: [ScreenshotHost.IndexRow] = []
        for (number, slug, sent, waiting) in frames {
            let transport = RefusingTransport()
            let (env, session) = try await bareOutboxEnv(transport: transport, clock: MutableClock())
            try await DemoSeed.loadParkedDemo(outbox: session.outbox, sent: sent, waiting: waiting) { await transport.refuse($0) }
            try session.store.markRelayFeedParked(at: Date())
            try await poll({
                let backlog = session.outboxBacklog
                return backlog.parked?.sent == sent && backlog.queued == (waiting ? 3 : 0)
                    && backlog.lastFlushStopped == waiting
            }, "the parked demo state landed")
            let host = ScreenshotHost(directory: dir, env: env, linking: linking)
            try await host.captureThree("\(number)-\(slug)", NowView(), narrowScroll: nil)
            rows.append(ScreenshotHost.IndexRow(
                number: number, view: "NowView", source: "Features/Now/NowView.swift", reached: "NowView, parked demo, light/dark/narrow"
            ))
        }
        return rows
    }

    /// S59–S61 (relay client Phase 5, Task 17): the left-behind phone's banner, the link ended at its term (the notice
    /// over the app) and the term's warning on the banner, on Now's row for another Mac and on its Settings → Macs row;
    /// each light, dark and narrow. Banners and Now's rows are handed to the view; the Macs rows come from links whose
    /// term started two days ago (before the date) or thirty (past it), over centers holding nothing, a held purchase
    /// or a refused row.
    private func captureTerm(host: ScreenshotHost) async throws -> [ScreenshotHost.IndexRow] {
        let now = Date()
        let origin = try RelayOrigin("https://relay.example.com")
        let before = now.addingTimeInterval(-2 * 86_400)
        let past = now.addingTimeInterval(-30 * 86_400)
        func link(_ name: String, _ cause: RelayRefusal?, since: Date, moved: Bool = false) -> LinkRecord {
            var record = LinkRecord(
                hubID: "term-\(name)", macName: name, scope: .private, ownerName: "", userRecordName: "", nonce: name,
                dataShareURL: nil, relayShareURL: nil, deviceID: DemoSeed.device.deviceID, linkedAt: now,
                transport: .relay, relayMacDeviceID: DemoSeed.Relay.workMac, hubTransports: ["relay"])
            record.relayRefused = cause.map { RelayRefusedRecord(since: since, cause: $0) }
            record.macMoved = moved ? 2 : nil
            return record
        }
        func banner(
            _ link: LinkRecord,
            phase: RelayAccountCenter.Phase = .free(ended: true),
            hold: RelayTermHold = .none,
            unconfirmed: Bool = false,
            updateRequired: Bool = false
        ) throws -> RelayBannerModel {
            try XCTUnwrap(RelayBannerModel.banner(
                availability: .available(origin), phase: phase, unconfirmedPurchase: unconfirmed, updateRequired: updateRequired,
                wasPaying: true, route: .hostedRelay(macDeviceID: DemoSeed.Relay.workMac), relayOnly: true, hubOnRelayAt: nil,
                unansweredSince: nil, request: nil, pressRefusal: nil, lastUpdate: nil, macName: link.macName, now: now,
                link: link, termHold: hold))
        }
        func row(_ link: LinkRecord, hold: RelayTermHold = .none) throws -> NowTermRow {
            let line = try XCTUnwrap(RelayBannerModel.termLine(for: link, surface: .now, now: now, heldPurchase: hold))
            return NowTermRow(id: link.hubID, title: link.macName, line: line)
        }
        let work = "Work Mac"
        let home = "Home Mac"
        // Work Mac's own banner with no term: the frames are about Home Mac's row under it.
        let workEnded = try banner(link(work, nil, since: now))
        var rows: [ScreenshotHost.IndexRow] = []
        func nowShot(_ number: String, _ slug: String, _ view: NowView, _ reached: String) async throws {
            try await host.captureThree("\(number)-\(slug)", view, narrowScroll: 620)
            rows.append(ScreenshotHost.IndexRow(
                number: number, view: "NowView", source: "Features/Now/NowView.swift", reached: "\(reached), light/dark/narrow"))
        }
        let paying = RelayAccountCenter.Phase.paying(grace: false, macs: [])
        let nowFrames: [(String, String, NowView)] = [
            ("S59", "banner-link-gone", NowView(banner: try banner(link(work, nil, since: before, moved: true), phase: paying))),
            ("S59b", "banner-link-gone-before-date", NowView(banner: try banner(link(work, .slot, since: before), phase: paying))),
            ("S59c", "banner-link-gone-past-date", NowView(banner: try banner(link(work, .slot, since: past), phase: paying, hold: .held))),
            ("S59d", "banner-link-gone-moved-lapse", NowView(banner: try banner(link(work, .lapse, since: before, moved: true), hold: .held))),
            ("S61a", "banner-needs-relay-before-date", NowView(banner: try banner(link(work, .lapse, since: before)))),
            ("S61b", "banner-needs-relay-past-date", NowView(banner: try banner(link(work, .lapse, since: past)))),
            ("S61c", "banner-needs-relay-held-free", NowView(banner: try banner(link(work, .lapse, since: before), hold: .held))),
            ("S61c2", "banner-needs-relay-held-moved", NowView(banner: try banner(link(work, .lapse, since: before), phase: .moved, hold: .held))),
            ("S61d", "now-row-before-date", NowView(banner: workEnded, termRows: [try row(link(home, .lapse, since: before))])),
            ("S61e", "now-row-past-date", NowView(banner: workEnded, termRows: [try row(link(home, .lapse, since: past))])),
            ("S61f", "now-row-refused-row", NowView(banner: workEnded, termRows: [try row(link(home, .lapse, since: past), hold: .refusedRow)])),
            ("S61g", "now-row-held", NowView(banner: workEnded, termRows: [try row(link(home, .lapse, since: before), hold: .held)])),
            ("S61l", "banner-transfer-limit-past-date", NowView(
                banner: try banner(link(work, .lapse, since: past), hold: .refusedRow, unconfirmed: true))),
            ("S61n", "banner-update-row-refused", NowView(
                banner: try banner(link(work, .lapse, since: past), hold: .refusedRow, unconfirmed: true, updateRequired: true),
                termRows: [try row(link(work, .lapse, since: past), hold: .refusedRow)]))
        ]
        for (number, slug, view) in nowFrames {
            try await nowShot(number, slug, view, "NowView, handed the banner and rows")
        }

        let s60: [(String, String, LinkNotice)] = [
            ("S60", "notice-link-ended", .relayEnded(macName: work, notSent: 0)),
            ("S60b", "notice-link-ended-not-sent", .relayEnded(macName: work, notSent: 2)),
            ("S60c", "notice-two-ended-first", .relayEnded(macName: work, notSent: 0)),
            ("S60d", "notice-two-ended-second", .relayEnded(macName: home, notSent: 2))
        ]
        for (number, slug, notice) in s60 {
            host.env.navigation.tab = .now
            try await host.captureThree("\(number)-\(slug)", TabsWithNotice(notice: notice), narrowScroll: nil)
            rows.append(ScreenshotHost.IndexRow(
                number: number, view: "TabsWithNotice", source: "App/AppRootView.swift", reached: "full app with the notice, light/dark/narrow"))
        }

        rows += try await captureTermMacs(
            host: host, origin: origin, homeBefore: link(home, .lapse, since: before), homePast: link(home, .lapse, since: past))
        return rows
    }

    /// S61h–S61k: the Settings → Macs row's term line, over centers holding nothing, a held purchase (a moved-away claim
    /// with this phone's own purchase in StoreKit) or a refused row (a `transferLimit` answer).
    private func captureTermMacs(
        host: ScreenshotHost, origin: RelayOrigin, homeBefore: LinkRecord, homePast: LinkRecord
    ) async throws -> [ScreenshotHost.IndexRow] {
        let now = Date()
        let env = host.env
        let saved = env.relayAccount
        defer { env.relayAccount = saved }
        let movedCard = try XCTUnwrap(RelayCardModel(availability: .available(origin), phase: .moved, unconfirmedPurchase: false))
        var rows: [ScreenshotHost.IndexRow] = []
        func shot(_ number: String, _ slug: String, _ links: [LinkRecord], card: RelayCardModel?, center: RelayAccountCenter) async throws {
            env.relayAccount = center
            let view = NavigationStack { MacsView(card: card) }.environment(try macsLinking(links, now: now))
            try await host.captureThree("\(number)-\(slug)", view, narrowScroll: Self.toTheEnd)
            rows.append(ScreenshotHost.IndexRow(
                number: number, view: "MacsView", source: "Features/Settings/MacsView.swift", reached: "bare stack, light/dark/narrow"))
        }
        let plain = RelayAccountCenter(
            link: RelayAccountLink(hasIdentity: { false }, account: { nil }, events: { nil }), store: FakeSubscriptionStore(),
            defaults: try makeDefaults()
        ) { [] }
        try await shot("S61h", "macs-row-before-date", [homeBefore], card: nil, center: plain)
        try await shot("S61i", "macs-row-past-date", [homePast], card: nil, center: plain)

        let refusedBed = AccountBed()
        let refusedToken = try await refusedBed.register()
        refusedBed.defaults.set(true, forKey: RelayAccountCenter.holdsSubscriptionKey)
        refusedBed.store.unfinishedResult = [refusedBed.row(token: refusedToken)]
        refusedBed.fake.failNext("submitTransaction", with: .transferLimit)
        let refused = refusedBed.makeCenter()
        refused.start()
        await refused.foreground()?.value
        XCTAssertEqual(refused.termHold, .refusedRow)
        try await shot("S61j", "macs-row-refused-row", [homePast], card: movedCard, center: refused)

        let heldBed = AccountBed()
        let heldToken = try await heldBed.register()
        heldBed.defaults.set(false, forKey: RelayAccountCenter.holdsSubscriptionKey)
        heldBed.store.unfinishedResult = [heldBed.row(token: heldToken)]
        let held = heldBed.makeCenter()
        held.start()
        await held.foreground()?.value
        XCTAssertEqual(held.termHold, .held)
        try await shot("S61k", "macs-row-held", [homeBefore], card: movedCard, center: held)
        return rows
    }

    private func captureOutbox(into dir: URL, linking: LinkingViewModel) async throws -> [ScreenshotHost.IndexRow] {
        let (env, session) = try await outboxDemoEnv()
        let host = ScreenshotHost(directory: dir, env: env, linking: linking)
        let first = try XCTUnwrap(OutboxItem.rows(session.workbenchReplica.snapshot.pending, .undelivered).first).id

        try await host.capture("37-now-outbox", Self.app(.now)(env))
        try await host.capture("38-not-delivered-list", NavigationStack { NotDeliveredView() })
        try await host.capture("38c-not-delivered-dismiss-confirm", NavigationStack { NotDeliveredView(confirming: true) })
        try await host.capture("38r-not-delivered-retry-error", NavigationStack {
            NotDeliveredView(retrying: [first], errors: [first: NotDeliveredModel.lockedRetryError])
        })
        let source = "Features/Now/NotDeliveredView.swift"
        return [
            ScreenshotHost.IndexRow(number: "37", view: "NowView", source: "Features/Now/NowView.swift", reached: "full app, outbox demo"),
            ScreenshotHost.IndexRow(number: "38", view: "NotDeliveredView", source: source, reached: "bare stack, outbox demo"),
            ScreenshotHost.IndexRow(number: "38c", view: "NotDeliveredView", source: source, reached: "bare stack, Dismiss All confirmation"),
            ScreenshotHost.IndexRow(number: "38r", view: "NotDeliveredView", source: source, reached: "bare stack, a retry over a failed one")
        ]
    }

    /// R30 (relay client mockup 7.7, R32): Not delivered with a move the hub's switch to Relay left behind ("<Mac>
    /// runs over Relay now") above a Phase 1 row refused for good, on its own demo session, in light, dark and narrow.
    private func captureHubOnRelay(into dir: URL, linking: LinkingViewModel) async throws -> [ScreenshotHost.IndexRow] {
        let transport = RefusingTransport()
        let defaults = try makeDefaults()
        let session = try HubSession(
            transport: transport,
            replicaPath: try makeReplicaPath(),
            backend: .inMemoryDemo,
            keys: try DemoSeed.phoneKeys(),
            defaults: defaults,
            recordingsDirectory: try makeRecordingsDirectory()
        )
        addTeardownBlock { @MainActor in session.stop() }
        try await poll({ session.isBootstrapped && !session.workbenchReplica.snapshot.workbenches.isEmpty }, "the demo booted")
        await session.outboxWork?.value
        try await session.outbox.enableOrderedActions()
        await transport.refuse(.unreachable)
        let workbench = DemoSeed.acmeID
        _ = try await session.outbox.enqueue(
            kind: .boardTargetStatus, entityRecordName: SliceKind.workbenchTarget.recordName(id: "416"),
            params: try BoardTargetStatusParams(workbenchID: workbench, status: .done, fromStatus: .todo).wireParams())
        _ = try await session.outbox.flush()
        try await session.outbox.listUnechoedAsUndelivered(reason: .hubOnRelay)
        await transport.refuse(.permanent(code: "zone_gone"))
        _ = try await session.outbox.enqueue(
            kind: .askAnswer, entityRecordName: SliceKind.ownerAsk.recordName(id: "109"),
            params: try AskAnswerParams(
                workbenchID: workbench, answer: OwnerAskAnswer(answers: [.init(id: "q1", labels: ["Archive Now"])])
            ).wireParams())
        _ = try await session.outbox.flush()
        try await poll({ OutboxItem.rows(session.workbenchReplica.snapshot.pending, .undelivered).count == 2 }, "both listed")
        let env = AppEnvironment.single(session, defaults: defaults)
        let host = ScreenshotHost(directory: dir, env: env, linking: linking)
        // The narrow frame scrolls past the title and the footer to the two rows (mockup 7.7's SE frame shows them).
        try await host.captureThree("R30-not-delivered-hub-on-relay", NavigationStack { NotDeliveredView() }, narrowScroll: 480)
        return [
            ScreenshotHost.IndexRow(
                number: "R30", view: "NotDeliveredView", source: "Features/Now/NotDeliveredView.swift",
                reached: "bare stack, a hub-on-relay row over a refused one, light/dark/narrow")
        ]
    }

    private static func indexRows(_ shots: [Shot]) -> [ScreenshotHost.IndexRow] {
        shots.flatMap { shot in
            let view = URL(fileURLWithPath: shot.source).deletingPathExtension().lastPathComponent
            let row = ScreenshotHost.IndexRow(number: shot.number, view: view, source: shot.source, reached: shot.reached.rawValue)
            let end = ScreenshotHost.IndexRow(
                number: "\(shot.number)e", view: view, source: shot.source,
                reached: "\(shot.reached.rawValue), scrolled to the end"
            )
            return shot.hasEnd ? [row, end] : [row]
        }
    }

    // MARK: - How a screen is reached

    /// A tab of the full app, with the Calendar stack at `path`.
    private static func app(_ tab: RootTabView.Tab, path: [CalendarRoute] = []) -> @MainActor (AppEnvironment) -> AnyView {
        { env in
            env.navigation.tab = tab
            env.navigation.calendarPath = path
            return AnyView(RootTabView())
        }
    }

    /// A Workbench push (target, session, ask) or a pushed form, in a bare
    /// stack without the tab bar.
    private static func stack<Content: View>(
        _ content: @escaping @MainActor (AppEnvironment) -> Content
    ) -> @MainActor (AppEnvironment) -> AnyView {
        { env in AnyView(NavigationStack { content(env) }) }
    }

    /// The Acme board in a bare stack under `filter` and `query`, its folds
    /// reset first and then changed by `folds` (#1781).
    private static func board(
        _ filter: BoardFilter? = nil, query: String = "", folds: @escaping (inout BoardFolds) -> Void = { _ in }
    ) -> @MainActor (AppEnvironment) -> AnyView {
        stack { env in
            env.boardFolds.update(hubID: env.activeHubID, workbenchID: DemoSeed.acmeID) { stored in
                stored = BoardFolds()
                folds(&stored)
            }
            return BoardView(
                replica: env.workbenchReplica, writer: env.boardWriter, workbenchID: DemoSeed.acmeID, now: Date(),
                filter: filter, query: query
            )
        }
    }

    /// A sheet (which owns its stack) or an onboarding leaf view.
    private static func leaf<Content: View>(
        _ content: @escaping @MainActor (AppEnvironment) -> Content
    ) -> @MainActor (AppEnvironment) -> AnyView {
        { env in AnyView(content(env)) }
    }

    // MARK: - The tour table (the review's screen numbers)

    /// DS1–DS8: the design system's parts in the redesign mockups' states
    /// (`docs/design/mobile/mockups.html`, the screen number in each slug),
    /// for a side-by-side check against the mockups.
    static func designSystemShots() -> [Shot] {
        let gallery = "../Tests/Support/DesignSystemGallery.swift"
        let pages: [(String, String, @MainActor () -> AnyView)] = [
            ("DS1", "now-m1", { AnyView(DesignSystemGallery.nowPage) }),
            ("DS2", "workchat-working-m3", { AnyView(DesignSystemGallery.workchatWorkingPage) }),
            ("DS3", "workchat-waiting-m4", { AnyView(DesignSystemGallery.workchatWaitingPage) }),
            ("DS4", "board-m5", { AnyView(DesignSystemGallery.boardPage) }),
            ("DS5", "calendar-m7", { AnyView(DesignSystemGallery.calendarPage) }),
            ("DS6", "mac-asleep-m8", { AnyView(DesignSystemGallery.workchatAsleepPage) }),
            ("DS7", "parts-bars-m9-12", { AnyView(DesignSystemGallery.actionsPage) }),
            ("DS8", "settings-m16", { AnyView(DesignSystemGallery.settingsPage) })
        ]
        return pages.map { number, slug, page in
            Shot(number: number, slug: slug, source: gallery, reached: .leaf) { _ in page() }
        }
    }

    static func workbenchShots() -> [Shot] {
        let acme = DemoSeed.acmeID
        let source = "Features/Workbench/"
        return [
            Shot(number: "01", slug: "now", source: "Features/Now/NowView.swift", reached: .fullApp, hasEnd: true, make: app(.now)),
            Shot(number: "02", slug: "workbench-list", source: source + "WorkbenchListView.swift", reached: .fullApp, make: app(.workbench)),
            Shot(number: "03", slug: "calendar", source: "Features/Calendar/AgendaView.swift", reached: .fullApp, hasEnd: true, make: app(.calendar)),
            Shot(number: "05", slug: "workbench-sessions", source: source + "WorkbenchView.swift", reached: .bareStack, hasEnd: true, make: stack {
                WorkbenchView(replica: $0.workbenchReplica, writer: $0.boardWriter, workbenchID: acme, segment: .sessions)
            }),
            // #1788: a workbench with no sessions, no board counts on Sessions.
            Shot(number: "05n", slug: "workbench-sessions-empty", source: source + "WorkbenchView.swift", reached: .bareStack, make: stack {
                WorkbenchView(replica: $0.workbenchReplica, writer: $0.boardWriter, workbenchID: DemoSeed.notesID, segment: .sessions)
            }),
            Shot(number: "06", slug: "workbench-board", source: source + "BoardView.swift", reached: .bareStack, make: stack {
                WorkbenchView(replica: $0.workbenchReplica, writer: $0.boardWriter, workbenchID: acme, segment: .board)
            }),
            // #1781: All with its folds (default, then a group and Backlog
            // opened), a search with an archived match, no match, Archive.
            Shot(number: "06a", slug: "board-all", source: source + "BoardView.swift", reached: .bareStack, make: board(.all)),
            Shot(
                number: "06b", slug: "board-all-opened", source: source + "BoardView.swift", reached: .bareStack,
                make: board(.all) { folds in
                    folds.toggleGroup(400)
                    folds.toggleLane(BoardLane(title: "Backlog", nodes: [], kind: .open))
                }
            ),
            Shot(number: "06c", slug: "board-search", source: source + "BoardView.swift", reached: .bareStack, make: board(query: "archive")),
            Shot(number: "06d", slug: "board-search-empty", source: source + "BoardView.swift", reached: .bareStack, make: board(query: "zzz")),
            Shot(number: "06e", slug: "board-archive", source: source + "BoardView.swift", reached: .bareStack, make: board(.archive)),
            Shot(number: "07", slug: "target-415", source: source + "BoardTargetDetailView.swift", reached: .bareStack, hasEnd: true, make: stack {
                BoardTargetDetailView(replica: $0.workbenchReplica, writer: $0.boardWriter, targetID: 415)
            }),
            Shot(number: "08", slug: "target-400-group", source: source + "BoardTargetDetailView.swift", reached: .bareStack, make: stack {
                BoardTargetDetailView(replica: $0.workbenchReplica, writer: $0.boardWriter, targetID: 400)
            })
        ] + sessionShots() + askShots() + [
            Shot(number: "18", slug: "start-session", source: source + "StartSessionSheet.swift", reached: .sheet, make: leaf { _ in
                StartSessionSheet(workbenchID: acme, target: nil, fixed: false) { _ in }
            }),
            // #1790: "Work on it in a session" from target #415 — brief
            // prefilled, intent shown, Start on without typing.
            Shot(number: "18t", slug: "start-session-target", source: source + "StartSessionSheet.swift", reached: .sheet, make: leaf { env in
                StartSessionSheet(
                    workbenchID: acme, target: env.workbenchReplica.snapshot.targets.first { $0.id == 415 }, fixed: true
                ) { _ in }
            }),
            Shot(number: "19", slug: "new-target", source: source + "NewBoardTargetSheet.swift", reached: .sheet, make: leaf {
                NewBoardTargetSheet(replica: $0.workbenchReplica, writer: $0.boardWriter, workbenchID: acme)
            })
        ]
    }

    /// The workchat (mockups 3, 4, 8): 09 waiting (inline asks), 09w
    /// working (the timer, a sent line), 10 needs approval, 11 finished,
    /// 12 failed; 12r the report and timeline behind the actions menu.
    static func sessionShots() -> [Shot] {
        let workchat = "Features/Workbench/WorkchatView.swift"
        let shots = [("09", 11, "waiting"), ("09w", 10, "working"), ("10", 12, "needs-approval"), ("11", 13, "finished"), ("12", 16, "failed")]
            .map { number, id, slug in
                Shot(number: number, slug: "session-\(id)-\(slug)", source: workchat, reached: .bareStack, make: stack {
                    WorkchatView(replica: $0.workbenchReplica, sessionID: id, store: $0.store, requester: $0.chatRequests)
                })
            }
        return shots + [
            Shot(number: "12r", slug: "session-11-report", source: "Features/Workbench/SessionReportView.swift", reached: .bareStack, make: stack {
                SessionReportView(replica: $0.workbenchReplica, sessionID: 11, store: $0.store, requester: $0.reportRequests)
            })
        ]
    }

    /// 13 question, 14 review, 15 check, 16 answered, 17 withdrawn; #1787:
    /// 14b the review with a comment under its paragraph and a note (Request
    /// changes on), 15b the check with Works and Doesn't work marked (Send on).
    static func askShots() -> [Shot] {
        let plain = [("13", 109, "question"), ("14", 110, "review"), ("15", 111, "check"), ("16", 105, "answered"), ("17", 107, "withdrawn")]
            .map { number, id, slug in
                Shot(number: number, slug: "ask-\(id)-\(slug)", source: "Features/Asks/AskView.swift", reached: .bareStack, make: stack {
                    AskView(replica: $0.workbenchReplica, drafts: $0.askDrafts, answerer: $0.askAnswerer, askID: id)
                })
            }
        return plain + [
            Shot(number: "14b", slug: "ask-110-review-commented", source: "Features/Asks/ReviewAskView.swift", reached: .bareStack, make: stack {
                seedReviewDraft($0)
                return AskView(replica: $0.workbenchReplica, drafts: $0.askDrafts, answerer: $0.askAnswerer, askID: 110)
            }),
            Shot(number: "15b", slug: "ask-111-check-marked", source: "Features/Asks/CheckAskView.swift", reached: .bareStack, make: stack { env in
                env.askDrafts.update(111) { draft in
                    draft.checks = ["1": .ok, "2": .broken]
                    draft.checkNotes = ["2": "The menu item is greyed out"]
                }
                return AskView(replica: env.workbenchReplica, drafts: env.askDrafts, answerer: env.askAnswerer, askID: 111)
            })
        ]
    }

    /// A comment on the demo review's "Step 2" paragraph and a note.
    @MainActor
    private static func seedReviewDraft(_ env: AppEnvironment) {
        guard let markdown = env.workbenchReplica.snapshot.asks.first(where: { $0.id == 110 })?.docSnapshot else { return }
        let document = PlainTextRendering.render(markdown)
        guard let paragraph = ReviewParagraph.split(document).first(where: { $0.text.hasPrefix("Step 2") }),
              let anchor = CommentAnchorBuilder.anchor(selection: paragraph.range, in: document) else { return }
        env.askDrafts.update(110) { draft in
            draft.comments = [AskCommentDraft(anchor: anchor, body: "Ask before the hook blocks, not after.", location: paragraph.range.location)]
            draft.note = "Otherwise fine."
        }
    }

    static func calendarShots() -> [Shot] {
        let event = "Features/Calendar/EventDetailView.swift"
        return [
            Shot(number: "20", slug: "event-upcoming", source: event, reached: .fullApp, hasEnd: true,
                 make: app(.calendar, path: [.event("demo-evt-roadmap")])),
            Shot(number: "21", slug: "event-past-recap", source: event, reached: .fullApp, make: app(.calendar, path: [.event("demo-evt-standup")])),
            Shot(number: "22", slug: "event-phone-recording", source: event, reached: .fullApp,
                 make: app(.calendar, path: [.event(DemoSeed.recordedEventID)])),
            Shot(number: "23", slug: "recordings", source: "Features/Recordings/RecordingsListView.swift", reached: .fullApp,
                 make: app(.calendar, path: [.recordings])),
            Shot(number: "24", slug: "recap", source: "Features/Recordings/RecapView.swift", reached: .fullApp,
                 make: app(.calendar, path: [.recap(501)])),
            Shot(number: "25", slug: "transcript", source: "Features/Recordings/RecapView.swift", reached: .bareStack, make: stack { _ in
                RecapView(transcriptID: 501, initialTab: .transcript)
            }),
            Shot(number: "26", slug: "recorder-idle", source: "Features/Recording/RecordingView.swift", reached: .leaf,
                 make: leaf { _ in RecordingView() }),
            Shot(number: "27", slug: "settings", source: "Features/Settings/SettingsView.swift", reached: .bareStack,
                 make: stack { _ in SettingsView() })
        ]
    }

    static func onboardingShots() -> [Shot] {
        let source = "Features/Onboarding/"
        let mac = DemoSeed.macName
        return [
            Shot(number: "28", slug: "welcome", source: source + "WelcomeView.swift", reached: .leaf, make: leaf { _ in WelcomeView() }),
            Shot(number: "29", slug: "scan", source: source + "ScanView.swift", reached: .leaf, make: leaf { _ in
                ScanView(onCode: { _ in }, onCancel: {})
            }),
            Shot(number: "30", slug: "checking", source: source + "LinkSteps.swift", reached: .leaf, make: leaf { _ in
                LinkStepsView(model: LinkStepsModel(waitingFor: nil, startedAt: nil, now: Date()))
            }),
            Shot(number: "31", slug: "waiting", source: source + "LinkSteps.swift", reached: .leaf, make: leaf { _ in
                LinkStepsView(model: LinkStepsModel(waitingFor: mac, startedAt: Date(), now: Date()))
            }),
            Shot(number: "31b", slug: "waiting-hint", source: source + "LinkSteps.swift", reached: .leaf, make: leaf { _ in
                LinkStepsView(model: LinkStepsModel(waitingFor: mac, startedAt: Date().addingTimeInterval(-25), now: Date()))
            }),
            Shot(number: "32", slug: "too-many-macs", source: source + "LinkedView.swift", reached: .leaf, make: leaf { _ in
                LinkFailureView(failure: .tooManyMacs)
            }),
            Shot(number: "33", slug: "failure", source: source + "LinkedView.swift", reached: .leaf, make: leaf { _ in
                LinkFailureView(failure: .expired)
            }),
            Shot(number: "34", slug: "linked", source: source + "LinkedView.swift", reached: .leaf, make: leaf { _ in LinkedView(macName: mac) }),
            Shot(number: "36", slug: "mac-switcher", source: "Features/Hubs/HubListSheet.swift", reached: .sheet, make: leaf { _ in
                HubListSheet { _ in }
            }),
            Shot(number: "36a", slug: "hub-switcher-chips", source: "Features/Hubs/HubSwitcherChip.swift", reached: .leaf, make: leaf { _ in
                HubSwitcherTourPages.chips(now: Date())
            }),
            Shot(number: "36b", slug: "mac-switcher-states", source: "Features/Hubs/HubListSheet.swift", reached: .sheet, make: leaf { _ in
                HubListSheetContent(rows: HubSwitcherTourPages.rows(now: Date()), add: .atLimit) { _ in }
            }),
            Shot(number: "36c", slug: "mac-switcher-add", source: "Features/Hubs/HubListSheet.swift", reached: .sheet, make: leaf { _ in
                HubListSheetContent(rows: Array(HubSwitcherTourPages.rows(now: Date()).prefix(2)), add: .on) { _ in }
            }),
            Shot(number: "35", slug: "mac-not-showing", source: source + "MacNotShowingView.swift", reached: .bareStack, make: stack { _ in
                MacNotShowingView()
            })
        ]
    }

    /// Review focus 1: an end shot finds only a scroll view taller than its
    /// bounds; a screen that fits has none, and its end shot is the screen
    /// at rest.
    func testTheEndVariantFindsOnlyAScrollViewTallerThanItsBounds() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let fits = UIScrollView(frame: root.bounds)
        fits.contentSize = CGSize(width: 100, height: 80)
        root.addSubview(fits)
        XCTAssertNil(ScreenshotHost.tallScrollView(in: root), "content that fits has no end to scroll to")

        let tall = UIScrollView(frame: root.bounds)
        tall.contentSize = CGSize(width: 100, height: 300)
        fits.addSubview(tall)
        XCTAssertTrue(ScreenshotHost.tallScrollView(in: root) === tall)
        XCTAssertEqual(ScreenshotHost.endOffset(of: tall), 200)
    }

    /// Phases 1–2 review: a list under a navigation bar and a tab bar
    /// scrolls when its content plus its insets is taller than its bounds,
    /// even when the content alone fits.
    func testAnEndShotCountsTheScrollViewsInsets() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let inset = UIScrollView(frame: root.bounds)
        inset.contentSize = CGSize(width: 100, height: 80)
        inset.contentInset = UIEdgeInsets(top: 30, left: 0, bottom: 0, right: 0)
        root.addSubview(inset)
        XCTAssertTrue(ScreenshotHost.tallScrollView(in: root) === inset, "80 + 30 is taller than 100")
        XCTAssertEqual(ScreenshotHost.endOffset(of: inset), -20, "10 pt past the resting offset of -30")
    }
}

/// The outbox demo's transport: the in-memory one, whose conditional saves are refused while a refusal is set.
private actor RefusingTransport: ConditionalTransport {
    private let inner = InMemoryCloudTransport()
    private var refusal: TransportRefusal?

    func refuse(_ refusal: TransportRefusal?) {
        self.refusal = refusal
    }

    func save(_ records: [CloudRecord]) async throws {
        try await inner.save(records)
    }

    func delete(recordNames: [String], in zone: CloudZoneID) async throws {
        try await inner.delete(recordNames: recordNames, in: zone)
    }

    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        try await inner.changes(in: zone, since: token)
    }

    func save(_ items: [ConditionalSave]) async throws -> [SaveOutcome] {
        if let refusal {
            return items.map { _ in .refused(refusal) }
        }
        return try await inner.save(items)
    }

    func delete(_ items: [ConditionalDelete]) async throws -> [DeleteOutcome] {
        try await inner.delete(items)
    }
}

/// Static mocks of the unified chat's new phone parts (#1822 T0), from the tokens the chat cards use. The exact copy is
/// the plan's Global Constraints.
/// The unified chat's part frames: `ChatUI`'s real cards on a page, in the phone's style.
@MainActor
private enum UnifiedChatParts {
    static let fallbackText = "Send a Slack message to #general — waiting for your approval"
    static let openOnMac = "Open on the Mac"

    private static func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            content()
            Spacer(minLength: 0)
        }
        .padding(Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemBackground))
        .environment(\.chatUIStyle, PhoneChatStyle())
    }

    static var questionCard: some View {
        page {
            QuestionPartView(
                card: ChatQuestionCard(questions: [ChatQuestion(
                    id: "store", question: "Which session store should the redirect fix use?",
                    options: [
                        ChatQuestionOption(label: "Server table", description: "One row per session", recommended: true),
                        ChatQuestionOption(label: "Cookie", description: "No extra table")
                    ]
                )]),
                answerText: nil
            ) { _ in }
        }
    }

    static var slackApproval: some View {
        approval(ChatFeed.Action(
            id: 31, tool: "send_slack_message", title: "Send a Slack message to #general",
            argsDisplay: ##"{"target": {"account_id": 1, "label": "#general", "workspace": "acme"}, "text": "The release is out."}"##,
            argsSHA256: "abc123", status: "pending", external: true, argsComplete: true
        ), text: "I drafted the announcement.")
    }

    // The approval card's per-tool bodies on the phone (#1822 T15): the content the shared card gains, for T16's review.

    static var jiraApproval: some View {
        approval(ChatFeed.Action(
            id: 32, tool: "create_jira_issue", title: "Create a Jira issue",
            argsDisplay: #"{"project_key": "ACME", "issue_type": "Task", "summary": "Pin the rollout window", "labels": ["release"]}"#,
            argsSHA256: "b2", status: "pending", external: true, argsComplete: true
        ), text: "I drafted the follow-up issue.")
    }

    static var confluenceApproval: some View {
        approval(ChatFeed.Action(
            id: 33, tool: "edit_confluence_page", title: "Edit a Confluence page",
            argsDisplay: #"{"base_version": 7, "title": "Rollout plan", "url": "https://example.atlassian.net/wiki/x/98765", "#
                + #""changes": [{"kind": "replace_text", "locator": "text in Plan", "before": "Ships on Friday.", "#
                + #""after": "Ships on Monday.", "removed": []}]}"#,
            argsSHA256: "c3", status: "pending", external: true, argsComplete: true
        ), text: "I fixed the rollout day.")
    }

    static var connectorApproval: some View {
        approval(ChatFeed.Action(
            id: 34, tool: "claude_ai_connector_call", title: "Run a claude.ai connector",
            argsDisplay: #"{"server": "Linear", "tool": "create_issue", "input": {"team": "ACME", "title": "Pin the rollout window"}}"#,
            argsSHA256: "d4", status: "pending", external: true, argsComplete: true
        ), text: "I can file it in Linear.", holds: true)
    }

    static var settledApproval: some View {
        approval(ChatFeed.Action(
            id: 35, tool: "create_jira_issue", title: "Create a Jira issue",
            argsDisplay: #"{"project_key": "ACME", "issue_type": "Task", "summary": "Pin the rollout window"}"#,
            argsSHA256: "b2", status: "applied", external: true,
            result: ["url": "https://example.atlassian.net/browse/ACME-12", "key": "ACME-12"], argsComplete: true
        ), text: "Filed.")
    }

    static var noPermissionApproval: some View {
        approval(ChatFeed.Action(
            id: 36, tool: "create_jira_issue", title: "Create a Jira issue",
            argsDisplay: #"{"project_key": "ACME", "issue_type": "Task", "summary": "Pin the rollout window"}"#,
            argsSHA256: "b2", status: "pending", external: true, argsComplete: true
        ), text: "I drafted the follow-up issue.", state: ChatApprovalState(
            showsButtons: false, canAnswer: false, line: ChatText.approveElsewhere(.mac)
        ))
    }

    private static func approval(
        _ action: ChatFeed.Action, text: String, state: ChatApprovalState? = nil, holds: Bool = false
    ) -> some View {
        let message = ChatFeed.Message(id: 1, role: "assistant", text: text, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let actions = ChatPartActions(approvals: ChatApprovalServices(state: { _ in state }, sessionHoldsCall: { _ in holds }))
        return page {
            ChatFeedView(messages: [message], context: ChatFeedContext(actions: [action], partActions: actions))
        }
    }

    static var fallback: some View {
        page {
            FallbackPartView(
                fallback: ChatPartFallback(
                    text: fallbackText, actions: [.init(label: openOnMac, action: "open_url", url: "https://example.com/open")]
                ),
                actions: ChatPartActions()
            )
        }
    }
}

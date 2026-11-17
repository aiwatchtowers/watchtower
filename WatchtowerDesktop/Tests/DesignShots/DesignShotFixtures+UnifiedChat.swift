import AppKit
import ChatUI
import ChatWire
import DesignKit
import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The unified chat's new states (spec 2026-11-16 §10) — on the Mac's real
/// views since T8: the shared feed and the Mac composer over ChatUI's models,
/// with the state the client reports — and "before" baselines of the
/// embedded surfaces T12 replaces. Synthetic data only.
@MainActor
enum UnifiedChatShotFixtures {
    /// The exact UI copy of the plan's Global Constraints.
    enum Copy {
        static let starting = "Chat is starting…"
        static let unavailable = "Chat is unavailable — Watchtower's background service is not running"
        static let stopped = "Chat needs Watchtower's background service, which is stopped"
        static let fallback = "Send a Slack message to #general — waiting for your approval"
        static let openOnMac = "Open on the Mac"
        static let retry = "Retry"
        static let start = "Start"
    }

    private static var engines: [EmbeddedChatEngine] = []
    private static var poolPaths: [String] = []
    private static var chats: [ChatViewModel] = []

    static func cleanUp() {
        engines = []
        chats = []
        poolPaths.forEach(TestDatabase.cleanup(path:))
        poolPaths = []
    }

    static var shots: [DesignShot] {
        [
            DesignShot(name: "chat-daemon-starting", size: NSSize(width: 560, height: 360)) { unreachable(.starting) },
            DesignShot(name: "chat-daemon-unavailable", size: NSSize(width: 560, height: 360)) { unreachable(.unavailable) },
            DesignShot(name: "chat-daemon-stopped", size: NSSize(width: 560, height: 360)) { unreachable(.stoppedOnPurpose) },
            DesignShot(name: "chat-part-fallback", size: NSSize(width: 560, height: 200)) { fallbackCard() },
            DesignShot(name: "chat-remote-turn-live", size: NSSize(width: 560, height: 320)) { remoteTurnLive() },
            DesignShot(name: "embedded-chat-target", size: NSSize(width: 460, height: 460)) {
                embedded(contextType: "target", hint: "Ask about this task", rows: targetRows, footer: false)
            },
            DesignShot(name: "embedded-chat-meeting", size: NSSize(width: 460, height: 460)) {
                embedded(contextType: "meeting", hint: "Ask about this meeting", rows: meetingRows, footer: false)
            },
            DesignShot(name: "embedded-chat-setup", size: NSSize(width: 460, height: 460)) {
                embedded(contextType: "setup", hint: "Describe what you want to set up", rows: setupRows, footer: true)
            },
            DesignShot(name: "owner-ask-question-card", size: NSSize(width: 440, height: 520)) { ownerAskQuestion() }
        ]
    }

    // MARK: - The Mac's chat on ChatUI (§10)

    /// The open chat: the shared feed and the Mac composer over a shell whose client never answers (the shot shows
    /// the state it is given).
    private static func chat(
        messages: [ChatFeed.Message], lease: ChatFeed.Lease? = nil, reachability: ChatReachability, draft: String
    ) -> AnyView {
        do {
            let (pool, path) = try TestDatabase.createPool()
            poolPaths.append(path)
            let vm = ChatViewModel(client: ShotChatClient(), dbPool: pool)
            chats.append(vm)
            let feed = ChatFeed(
                conversation: ChatFeed.Conversation(id: 7, title: "Q3 roadmap summary", lease: lease),
                messages: messages
            )
            vm.select(conversationID: 7)
            vm.conversation.stop()
            vm.conversation.store.apply(.snapshot(feed))
            vm.conversation.reachability = reachability
            vm.composer.draft = draft
            return AnyView(VStack(alignment: .leading, spacing: Spacing.medium) {
                Text(feed.conversation.title).font(.headline)
                ChatUI.ChatFeedView(messages: vm.messages,
                                    context: vm.conversation.feedContext(composer: vm.composer, partActions: ChatPartActions()))
                ChatComposerView(chatVM: vm, modelSuggestions: [], maxHeight: 120)
            }
            .padding(Spacing.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .macChatStyle(hooks: ChatMacArtifactHooks())
            .detailBackground())
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    private static let question = ChatFeed.Message(id: 1, role: "user", text: "Summarise the Q3 roadmap threads",
                                                   createdAt: Date(timeIntervalSince1970: 1_794_000_000))

    /// "Mac, chat unreachable": the feed as last loaded, the state line (and its action) from the client's
    /// reachability, and the composer with the draft kept and Send off.
    private static func unreachable(_ state: ChatReachability) -> AnyView {
        chat(messages: [
            question,
            ChatFeed.Message(id: 2, role: "assistant",
                             text: "The roadmap has three threads: onboarding, the phone chat and the background service.",
                             createdAt: Date(timeIntervalSince1970: 1_794_000_000))
        ], reachability: state, draft: "Also compare it with the Q2 plan")
    }

    /// "Any client, unknown part kind": the shared fallback view and its one button.
    private static func fallbackCard() -> AnyView {
        let fallback = ChatPartFallback(text: Copy.fallback,
                                        actions: [ChatPartFallback.Action(label: Copy.openOnMac, action: "none")])
        return AnyView(FallbackPartView(fallback: fallback, actions: ChatPartActions())
            .padding(Spacing.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .macChatStyle(hooks: ChatMacArtifactHooks())
            .detailBackground())
    }

    /// "Mac, phone-started turn, live": the engine's turn streams like a Mac one, with the normal Stop.
    private static func remoteTurnLive() -> AnyView {
        chat(messages: [
            question,
            ChatFeed.Message(id: 2, role: "assistant", text: "The roadmap has three threads: onboarding, the phone chat",
                             status: "pending", createdAt: Date(timeIntervalSince1970: 1_794_000_000))
        ], lease: ChatFeed.Lease(owner: "hub", turnID: "hub-turn"), reachability: .connected, draft: "")
    }

    // MARK: - The embedded surfaces on ChatUI (T12; same names as the T0 baselines)

    private static let targetRows: [(String, String)] = [
        ("user", "What is blocking the login redirect fix?"),
        ("assistant", "Two things: the session store decision is open, and the staging check was never run."),
        ("user", "Draft a comment for the owner of the session store.")
    ]
    private static let meetingRows: [(String, String)] = [
        ("user", "What was decided about the rollout?"),
        ("assistant", "The rollout starts with the internal group next Tuesday; the wider group waits for the staging check.")
    ]
    private static let setupRows: [(String, String)] = [
        ("assistant", "Which tracker do you use for your day-to-day tasks?"),
        ("user", "Jira, one project called ACME.")
    ]

    /// An `EmbeddedChatView` over an in-memory conversation of fixture rows.
    private static func embedded(contextType: String, hint: String, rows: [(String, String)], footer: Bool) -> AnyView {
        let store = MemoryEmbeddedChatStore()
        let spec = ChatSurfaceSpec(
            key: EmbeddedChatKey(contextType: contextType, contextID: "shot", conversationID: nil),
            persistence: .memory, toolAccess: .draftOnly, ownerInstructions: false, systemPrompt: { "" }, emptyHint: hint)
        var done = false
        Task { @MainActor in
            for (role, text) in rows { try? await store.append(role: role, text: text) }
            done = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        let engine = EmbeddedChatEngine(spec: spec, store: store, aiService: ScriptedAIService(), gate: EmbeddedStreamGate())
        engines.append(engine)
        return AnyView(
            EmbeddedChatView(engine: engine, placeholder: "Ask…", accessory: { _ in EmptyView() }, footer: {
                if footer {
                    HStack {
                        Spacer()
                        Button("Skip") {}.buttonStyle(.kitQuiet)
                        Button("Continue") {}.buttonStyle(.kitPrimary)
                    }
                    .padding(Spacing.medium)
                }
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .detailBackground())
    }

    /// The ask drawer on an open question ask (the real `OwnerAskDrawer`).
    private static func ownerAskQuestion() -> AnyView {
        do {
            let (pool, path) = try TestDatabase.createPool()
            poolPaths.append(path)
            let (project, session) = try pool.write { db -> (Int64, TerminalSession) in
                let id = try TestDatabase.insertWorkbench(db, folder: "/tmp/acme")
                let session = try TerminalSessionQueries.create(
                    db, .init(projectID: id, kind: .shell, title: "Fix the login redirect after SSO", folderPath: "/tmp/acme"))
                return (id, session)
            }
            let defaults = try XCTUnwrap(UserDefaults(suiteName: DesignShotFixtures.defaultsSuite))
            let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
            vm.selectedWorkbenchID = project
            vm.terminalSessions[project] = [session]
            let payload = #"{"questions":[{"id":"a","question":"Which session store should the redirect fix use?","#
                + #""options":[{"label":"Server table","description":"One row per session","recommended":true},"#
                + #"{"label":"Cookie","description":"No extra table"}]}]}"#
            let ask = try OwnerAsk(row: Row([
                "id": 412, "project_id": project, "session_id": session.id, "level": "full", "origin": "agent",
                "kind": "question", "title": "Which session store should the redirect fix use?", "status": "open",
                "withdrawn_reason": "", "payload": payload, "answer": "",
                "created_at": ISO8601DateFormatter().string(from: Date())
            ]))
            vm.asks.openDrawer(ask)
            return AnyView(OwnerAskDrawer(vm: vm, ask: ask).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }
}

/// One stored row drawn by ChatUI's row, as the embedded chats draw it (the Mac's kit style, no artifact hooks).
@MainActor
enum ChatUIShotRow {
    static func row(
        _ item: ChatThreadItem,
        rowActions: ChatRowActions = ChatRowActions(),
        partActions: ChatPartActions = ChatPartActions()
    ) -> some View {
        message(EmbeddedChatFeedAdapter.messages(rows: [item], live: nil)[0], rowActions: rowActions,
                partActions: partActions)
    }

    static func message(
        _ message: ChatFeed.Message,
        rowActions: ChatRowActions = ChatRowActions(),
        partActions: ChatPartActions = ChatPartActions()
    ) -> some View {
        ChatUI.ChatMessageRow(message: message, parts: ChatMessageParts.parts(for: message),
                              context: ChatPartContext(message: message, actions: partActions), rowActions: rowActions,
                              isTurnRunning: message.status == EmbeddedChatFeedAdapter.pendingStatus)
            .macChatStyle(hooks: ChatMacArtifactHooks())
    }
}

/// A client that never answers: the shots set the conversation's state themselves.
private final class ShotChatClient: ChatClient, @unchecked Sendable {
    func send(_ op: ChatOperation) async throws -> ChatEcho { .applied(.none) }
    func feed(_ conversation: Int64) -> AsyncStream<ChatFeedUpdate> { AsyncStream { _ in } }
    func list() -> AsyncStream<ChatListUpdate> { AsyncStream { _ in } }
    var reachability: AsyncStream<ChatReachability> { AsyncStream { _ in } }
}

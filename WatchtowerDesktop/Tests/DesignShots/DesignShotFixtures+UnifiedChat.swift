import AppKit
import DesignKit
import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The unified chat's new states (spec 2026-11-16 §10) as static mocks, and
/// "before" baselines of the real views the later tasks replace. The mock
/// names are the ones T8, T9 and T12 switch to the real view; the baselines
/// are compared with the real views after T12. Synthetic data only.
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

    static func cleanUp() {
        engines = []
        poolPaths.forEach(TestDatabase.cleanup(path:))
        poolPaths = []
    }

    static var shots: [DesignShot] {
        [
            DesignShot(name: "chat-daemon-starting", size: NSSize(width: 560, height: 360)) {
                unreachable(line: Copy.starting, action: nil)
            },
            DesignShot(name: "chat-daemon-unavailable", size: NSSize(width: 560, height: 360)) {
                unreachable(line: Copy.unavailable, action: Copy.retry)
            },
            DesignShot(name: "chat-daemon-stopped", size: NSSize(width: 560, height: 360)) {
                unreachable(line: Copy.stopped, action: Copy.start)
            },
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

    // MARK: - Mocks (§10 sketches)

    /// "Mac, chat unreachable": the feed as last loaded, a state line (and its
    /// action), and the composer with the draft kept and Send off.
    private static func unreachable(line: String, action: String?) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: Spacing.medium) {
            Text("Q3 roadmap summary").font(.headline)
            UserMessageBubble(text: "Summarise the Q3 roadmap threads")
            Text("The roadmap has three threads: onboarding, the phone chat and the background service.")
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: Spacing.compact) {
                if action == nil { ProgressView().controlSize(.mini) }
                Text(line).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let action { Button(action) {}.buttonStyle(.kitSecondary) }
            }
            draftComposer
        }
        .padding(Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .detailBackground())
    }

    /// The composer while the chat cannot send: the draft stays, Send is off.
    private static var draftComposer: some View {
        HStack(alignment: .bottom, spacing: Spacing.medium) {
            Text("Also compare it with the Q2 plan")
                .padding(Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            Button("Send") {}.buttonStyle(.kitPrimary).disabled(true)
        }
    }

    /// "Any client, unknown part kind": the fallback text and its one button.
    private static func fallbackCard() -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: Spacing.medium) {
            Text(Copy.fallback)
            Button(Copy.openOnMac) {}.buttonStyle(.kitSecondary)
        }
        .padding(Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .padding(Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .detailBackground())
    }

    /// "Mac, phone-started turn, live": the owner's text, the streaming
    /// answer and the composer's line with Stop.
    private static func remoteTurnLive() -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: Spacing.medium) {
            Text("Q3 roadmap summary").font(.headline)
            UserMessageBubble(text: "Summarise the Q3 roadmap threads")
            Text("The roadmap has three threads: onboarding, the phone chat")
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            ChatComposerBar(
                status: .elsewhere(ChatForeignTurnModel.answeringFromPhone),
                input: ChatComposerField(text: .constant(""), isStreaming: true, onSend: {}, onStop: {})
            )
        }
        .padding(Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .detailBackground())
    }

    // MARK: - Baselines of today's real views

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

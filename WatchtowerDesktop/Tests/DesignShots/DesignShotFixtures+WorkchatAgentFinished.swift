import AppKit
import ChatUI
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// The quiet agent-finished row (spec 2026-11-24-workchat-polish §3, #2201 T4) as built, beside mockup 05:
/// `workchat-polish-real-05-agent-finished` is the mock's dialog on ChatUI's feed with `WorkchatFeed.context()` — a
/// finished agent collapsed and expanded, a failed one, a background command; `…-05b-agent-finished-details` the same
/// four rows alone with the expanded row's Details open.
@MainActor
enum WorkchatAgentFinishedShotFixtures {
    static let shots: [DesignShot] = [
        DesignShot(name: "workchat-polish-real-05-agent-finished", size: NSSize(width: 720, height: 560)) {
            AnyView(feed)
        },
        DesignShot(name: "workchat-polish-real-05b-agent-finished-details", size: NSSize(width: 720, height: 360)) {
            AnyView(rowsAlone)
        }
    ]

    static let verify = SessionFeedTask(
        taskID: "a1b2c3d4e5f60718", toolUseID: "toolu_01AbCdEfGhIjKl", status: "completed",
        summary: #"Agent "Claude verify review #2188" finished"#,
        result: "No blockers. One test gap: the hidden-window → `.gone` transition is not covered.",
        outputFile: "/tmp/claude-501/-p/s1/tasks/a1b2c3d4e5f60718.output",
        tokens: 43545, toolUses: 9, durationMS: 88925, kind: "agent")
    static let codex = SessionFeedTask(
        taskID: "b2c3d4e5f6071829", toolUseID: "toolu_01BcDeFgHiJk", status: "failed",
        summary: #"Agent "Codex verify round 3 #2188" failed"#, tokens: 1200, toolUses: 2, durationMS: 12000,
        kind: "agent")
    static let command = SessionFeedTask(
        taskID: "c3d4e5f6", status: "completed",
        summary: #"Background command "Run full Go test suite" completed (exit code 0)"#, durationMS: 214_000,
        kind: "command", exitCode: 0)

    static var entries: [SessionFeedEntry] {
        [
            SessionFeedEntry(id: "o1", kind: "owner", text: "Get both reviews on round 3 and tell me what they found."),
            SessionFeedEntry(id: "a1", kind: "agent",
                             text: "Two reviews are out: a Claude verify pass and a Codex round. I will fold them into one answer."),
            task("t1", verify),
            task("t2", verify),
            task("t3", codex),
            task("t4", command)
        ]
    }

    private static func task(_ id: String, _ task: SessionFeedTask) -> SessionFeedEntry {
        SessionFeedEntry(id: id, kind: "event", text: "<task-notification>…</task-notification>", title: task.summary,
                         eventType: "task", task: task)
    }

    private static var feed: some View {
        var workchatFeed = WorkchatFeed(entries: entries, markdown: SessionFeedMarkdownCache(), expandedEvents: ["t2"]) { _ in }
        workchatFeed.highlighting = .workchatShot
        var context = workchatFeed.context()
        var follow = ChatFeedFollow(conversationID: 1)
        follow.anchorsBottom = true
        context.follow = follow
        return ChatUI.ChatFeedView(messages: workchatFeed.messages, context: context)
            .macChatStyle(hooks: .app, look: .workchat)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .detailBackground()
    }

    private static var rowsAlone: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            row(verify, expanded: false)
            row(verify, expanded: true, details: true)
            row(codex, expanded: false)
            row(command, expanded: false)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .detailBackground()
    }

    private static func row(_ task: SessionFeedTask, expanded: Bool, details: Bool = false) -> some View {
        AgentFinishedRow(presentation: AgentFinishedPresentation(task: task, fallbackTitle: ""),
                         outputFile: task.outputFile, expanded: expanded, onOpenOutput: { _ in },
                         showsDetails: details)
    }
}

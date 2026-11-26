import AppKit
import ChatUI
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// Workchat agents and live steps (#2065), the built views: one shot per
/// mockup state (`WorkchatAgentsMockShotFixtures`, `workchat-agents-NN-…`),
/// drawn by the real `WorkchatLiveLine`, `WorkchatAgentsPopover`,
/// `WorkchatStepsList`, `WorkchatComposer` and ChatUI's feed over fixture
/// `SessionFeedLive` / `SessionFeedEntry` data equal to the mock's (same
/// agents, steps, lines and clock). The pane is laid out as
/// `SessionChatView` lays it out; the 👥 popover, an `NSPopover` that an
/// offscreen render cannot open, sits where the mock draws it.
@MainActor
enum WorkchatAgentsShotFixtures {
    static let shots: [DesignShot] = [
        shot("01-working-done-collapsed", .workingDoneCollapsed),
        shot("02-done-expanded", .doneExpanded, height: 600),
        shot("03-only-done", .onlyDone, height: 560),
        shot("04-none", .noAgents),
        shot("05-unknown", .unknown, height: 560),
        shot("06-loading", .listLoading),
        shot("07-error", .listError),
        shot("08-steps-open", .stepsOpenWide),
        shot("09-steps-narrow", .stepsOpenNarrow, width: 340),
        shot("10-feed-no-cards", .feedOnly),
        shot("11-idle", .idleDone),
        shot("12-ended", .endedDone),
        shot("13-send-while-working", .typingWhileWorking),
        shot("14-paste-tokens", .pasteTokens)
        // The pane's loading and error states are `workchat-polish-real-11-loading` / `-12-error` (#2201).
    ]

    private static func shot(_ name: String, _ mock: WorkchatAgentsMock, width: CGFloat = 720, height: CGFloat = 480) -> DesignShot {
        DesignShot(name: "workchat-agents-real-\(name)", size: NSSize(width: width, height: height)) {
            AnyView(WorkchatAgentsRealShot(mock: mock))
        }
    }

    /// The shots' clock: every timer reads from it.
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let paneKey = "session-1"
    static let draftPasteTokens = "fix this [Image #1] and look at [Pasted text #2 +42 lines]"

    /// The live snapshot behind a working mock: the open Bash step (with the mock's `· 7 more`), the two working
    /// agents, the turn's eight steps. An unknown badge reads an agents state the CLI could not tell.
    static func snapshot(_ mock: WorkchatAgentsMock) -> SessionFeedLive? {
        guard !mock.idle else { return nil }
        let steps = self.steps(mock.steps)
        let agents: [SessionLiveAgent]
        switch mock.badge {
        case .working: agents = mock.working.isEmpty ? WorkchatAgentsMock.workingAgents.map(agent) : mock.working.map(agent)
        default: agents = []
        }
        let unknown: Bool = if case .unknown = mock.badge { true } else { false }
        var current = steps.last
        current?.more = 7
        return SessionFeedLive(observedAt: now - 1, conversation: "conversation-1", turnAt: now - 72, current: current,
                               agents: agents, agentsState: unknown ? "unknown" : "known", steps: steps)
    }

    private static func agent(_ mock: WorkchatAgentsMock.Agent) -> SessionLiveAgent {
        SessionLiveAgent(ref: SessionFeedSubagent(toolUseID: mock.id, type: mock.type, description: mock.task, status: "running"),
                         startedAt: now - seconds(mock.elapsed), action: SessionLiveAction(tool: mock.tool, summary: mock.action),
                         canOpen: true)
    }

    /// The mock's steps with times that give its durations: each starts when the one before ended; the last runs.
    private static func steps(_ mock: [WorkchatAgentsMock.Step]) -> [SessionLiveAction] {
        var end = now
        var result: [SessionLiveAction] = []
        for step in mock.reversed() {
            let start = end - seconds(step.time)
            result.append(SessionLiveAction(id: "step-\(step.id)", tool: step.tool, summary: step.summary, startedAt: start,
                                            completedAt: step.running ? nil : end))
            end = start
        }
        return result.reversed()
    }

    /// The mock's Done rows as the feed's finished markers, newest first by `started_at`.
    static func done(_ mock: WorkchatAgentsMock) -> [SessionFeedSubagent] {
        mock.done.enumerated().map { index, agent in
            SessionFeedSubagent(toolUseID: agent.id, type: agent.type, description: agent.task, status: "finished",
                                startedAt: now - TimeInterval(600 + 60 * index))
        }
    }

    /// The mock's feed as transcript entries, with subagent markers among them: the feed draws none (#2065 §1).
    static func entries(_ mock: WorkchatAgentsMock) -> [SessionFeedEntry] {
        var entries: [SessionFeedEntry] = []
        for (index, message) in WorkchatAgentsMock.feed.enumerated() {
            let last = index == WorkchatAgentsMock.feed.count - 1
            let text = mock.idle && last ? WorkchatAgentsMock.idleReply : message.text
            entries.append(SessionFeedEntry(id: "e\(index)", kind: message.owner ? "owner" : "agent",
                                            at: now - TimeInterval(300 - 60 * index), text: text))
            if index == 1 {
                for agent in WorkchatAgentsMock.workingAgents {
                    entries.append(SessionFeedEntry(
                        id: "marker-\(agent.id)", kind: "subagent", at: now - 200,
                        subagent: SessionFeedSubagent(toolUseID: agent.id, type: agent.type, description: agent.task,
                                                      status: mock.idle ? "finished" : "running")))
                }
            }
        }
        return entries
    }

    private static func seconds(_ text: String) -> TimeInterval {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : 0
    }
}

/// A Workchat control that reads nothing and sends nothing.
private final class AgentsShotControl: WorkchatControl {
    func lineCheck(_ sessionID: Int64) -> SessionControl.LineCheck { .go }
    func workchatLineCheck(_ sessionID: Int64) -> SessionControl.LineCheck { .go }
    func isWorking(_ sessionID: Int64) -> Bool { false }
    func interrupt(_ sessionID: Int64) async throws -> SessionControl.InterruptResult { .notWorking }
    func pendingPermission(_ sessionID: Int64) async throws -> SessionControl.PermissionPrompt? { nil }
    func answerPermission(requestID: Int64, sessionID: Int64, allow: Bool, decidedBy: String) async throws
        -> SessionControl.PermissionAnswer { .notFound }
}

/// The Workchat pane on the real views, laid out as `SessionChatView` lays it
/// out: feed, live line (with the steps list over it), then a hairline and the
/// composer; an ended session draws its line and the live line instead.
@MainActor
struct WorkchatAgentsRealShot: View {
    let mock: WorkchatAgentsMock
    @State private var memory: WorkchatPaneMemory
    @State private var model: WorkchatModel

    init(mock: WorkchatAgentsMock) {
        self.mock = mock
        let memory = WorkchatPaneMemory()
        // The steps list is closed by default (#2201 §1); the mock's open frames are the owner's toggle.
        if mock.stepsOpen { memory.toggleSteps(WorkchatAgentsShotFixtures.paneKey) }
        // Done follows the production default (collapsed while agents work, open when none do or their status is
        // unknown); only frame 02 is the owner expanding it while agents work.
        if case .agents(doneOpen: true) = mock.list, !mock.working.isEmpty {
            memory.setDoneOpen(WorkchatAgentsShotFixtures.paneKey, true)
        }
        _memory = State(initialValue: memory)
        let model = WorkchatModel(sessionID: 1, control: AgentsShotControl(),
                                  lineDelivery: SessionLineDelivery(terminalCenter: nil),
                                  kind: { .claude }, now: { WorkchatAgentsShotFixtures.now })
        if let draft = mock.draft {
            model.draft = draft.contains { if case .text = $0 { false } else { true } }
                ? WorkchatAgentsShotFixtures.draftPasteTokens
                : draft.map { if case .text(let text) = $0 { text } else { "" } }.joined(separator: " ")
        }
        _model = State(initialValue: model)
    }

    private var now: Date { WorkchatAgentsShotFixtures.now }
    private var working: Bool { !mock.idle }
    private var snapshot: SessionFeedLive? { WorkchatAgentsShotFixtures.snapshot(mock) }
    private var done: [SessionFeedSubagent] { WorkchatAgentsShotFixtures.done(mock) }
    private var feedLoaded: Bool {
        switch mock.list {
        case .loading, .error: false
        default: true
        }
    }
    private var feedError: String? {
        if case .error = mock.list { return "session-feed: exit status 1" }
        return nil
    }
    private var listOpen: Bool {
        if case .closed = mock.list { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            feed
            if mock.ended {
                Divider()
                Text(SessionChatView.finishedLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.large)
                    .padding(.top, Spacing.cozy)
                    .padding(.bottom, done.isEmpty ? Spacing.cozy : .zero)
                liveLine.padding(.bottom, Spacing.small)
            } else {
                liveLine
                Divider()
                WorkchatComposer(model: model, working: working)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .detailBackground()
        .overlay(alignment: .bottomTrailing) {
            if listOpen {
                WorkchatAgentsPopover(
                    list: WorkchatLivePresentation.agentsList(snapshot: snapshot, error: nil, feedLoaded: feedLoaded,
                                                              feedError: feedError, done: done, idle: !working, now: now),
                    agentsMore: snapshot?.agentsMore ?? 0, paneKey: WorkchatAgentsShotFixtures.paneKey, memory: memory
                ) { _ in }
                    // The NSPopover's own window, which an offscreen render does not draw.
                    .background(Surface.window, in: RoundedRectangle(cornerRadius: Radius.container))
                    .overlay(RoundedRectangle(cornerRadius: Radius.container).strokeBorder(.quaternary, lineWidth: Stroke.hairline))
                    .padding(.trailing, Spacing.large)
                    .padding(.bottom, Spacing.hero * 2 + Spacing.small)
            }
        }
    }

    private var liveLine: some View {
        WorkchatLiveLine(snapshot: snapshot, error: nil, loaded: true, working: working, stateAt: now - 72, done: done,
                         paneKey: WorkchatAgentsShotFixtures.paneKey, memory: memory, feedLoaded: feedLoaded,
                         feedError: feedError, onRetry: {}, onOpenAgent: { _ in }, referenceDate: now)
    }

    private var feed: some View {
        let entries = WorkchatAgentsShotFixtures.entries(mock)
        var workchatFeed = WorkchatFeed(entries: entries, markdown: SessionFeedMarkdownCache(), expandedEvents: []) { _ in }
        workchatFeed.highlighting = .workchatShot
        var context = workchatFeed.context()
        var follow = ChatFeedFollow(conversationID: 1)
        follow.anchorsBottom = true
        context.follow = follow
        if let queued = mock.queuedLine {
            // Typed into Claude Code mid-turn: sent, and the caption says the agent reads it at its next step.
            let line = WorkchatOutgoing(id: UUID(), text: queued, sentAt: now, state: .sent, sentWhileBusy: true)
            context.footer = AnyView(WorkchatOutgoingBubble(line: line, working: working, onCancel: {}, onShowTerminal: {}))
        }
        return ChatUI.ChatFeedView(messages: workchatFeed.messages, context: context)
            .macChatStyle(hooks: .app, look: .workchat)
    }
}

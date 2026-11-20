import SwiftUI
import WatchtowerKit
import WatchtowerSync

/// A subagent's chat (board #486), pushed from its row in the workchat:
/// read-only, in the workchat's bubbles (mockup 3) — the lines the subagent
/// was given right, its text left, its own subagents in the agents sheet. Opens scrolled to the newest entry. The session's own chat is the workchat
/// (`WorkchatView`), the only one with a composer. While the subagent works,
/// its own live line sits at the foot (#2112 L8).
struct SessionChatView: View {
    static let screen = ChatScreen.subagent

    @Environment(AppEnvironment.self) private var env

    let replica: WorkbenchReplicaModel
    private let store: ReplicaStore
    private let requester: SessionChatRequester
    @State private var viewModel: SessionChatViewModel
    @State private var openSubagent: SessionChatRoute?
    @State private var showsAgents = false
    @State private var doneDisclosure = WorkchatAgents.DoneDisclosure.automatic

    init(replica: WorkbenchReplicaModel, route: SessionChatRoute, store: ReplicaStore, requester: SessionChatRequester) {
        self.replica = replica
        self.store = store
        self.requester = requester
        _viewModel = State(initialValue: SessionChatViewModel(
            sessionID: route.sessionID, agentID: route.agentID, toolUseID: route.toolUseID,
            store: store, requester: requester
        ))
    }

    var body: some View {
        Group {
            if let chat = viewModel.chat {
                feed(chat)
            } else {
                waiting
            }
        }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let session = replica.snapshot.session(viewModel.sessionID) {
                WorkchatLiveSection(route: route, inputs: { liveInputs(session, now: $0) }, steps: env.workchatSteps,
                                    onRetry: viewModel.retry)
                .background(PhoneSurface.page)
            }
        }
        .onChange(of: stepsWatch) { _, watch in
            if let watch { env.workchatSteps.note(route, watch) }
        }
        .navigationTitle("Subagent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let badge = agents?.badge {
                ToolbarItem(placement: .topBarTrailing) {
                    WorkchatAgentsButton(badge: badge) { showsAgents = true }
                }
            }
        }
        .sheet(isPresented: $showsAgents) {
            if let agents {
                WorkchatAgentsSheet(
                    agents: agents,
                    disclosure: $doneDisclosure,
                    onOpen: { route in
                        showsAgents = false
                        openSubagent = route
                    },
                    onClose: { showsAgents = false }
                )
            }
        }
        .navigationDestination(item: $openSubagent) { route in
            Self(replica: replica, route: route, store: store, requester: requester)
        }
        .onAppear { viewModel.appeared() }
        .onDisappear { viewModel.disappeared() }
    }

    private var route: SessionChatRoute {
        SessionChatRoute(sessionID: viewModel.sessionID, agentID: viewModel.agentID, toolUseID: viewModel.toolUseID)
    }

    private var stepsWatch: WorkchatLiveLine.StepsWatch? {
        replica.snapshot.session(viewModel.sessionID).map {
            WorkchatLiveLine.StepsWatch(
                chat: viewModel.chat,
                working: WorkchatLiveLine.working($0, subagent: viewModel.chat, staleSince: env.towerFreshness.staleSince(at: .now)),
                cardShown: false
            )
        }
    }

    /// The subagent's line at `now`: its own record's live block (the sidechain), no card on this screen.
    private func liveInputs(_ session: TerminalSessionState, now: Date) -> WorkchatLiveLine.Inputs {
        let staleSince = env.towerFreshness.staleSince(at: now)
        return WorkchatLiveLine.Inputs(
            chat: viewModel.chat, arrivedSinceOpen: viewModel.recordArrivedSinceOpen,
            working: WorkchatLiveLine.working(session, subagent: viewModel.chat, staleSince: staleSince), stateAt: session.stateAt,
            staleSince: staleSince, stepsOpen: env.workchatSteps.isOpen(route)
        )
    }

    /// The chat's subagents, built once per render for the button and the sheet.
    private var agents: WorkchatAgents? {
        viewModel.chat.map { WorkchatAgents(entries: $0.entries, sessionID: viewModel.sessionID) }
    }

    private var waiting: some View {
        VStack(spacing: Spacing.medium) {
            if viewModel.waitingForKeys {
                Text("Unlock this iPhone to see the chat.")
            } else if viewModel.waitingTooLong {
                Text(SessionChatText.tooLong).multilineTextAlignment(.center)
            } else {
                ProgressView()
                Text(SessionChatText.asking)
            }
        }
        .font(TypeScale.meta)
        .foregroundStyle(.secondary)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func feed(_ chat: SessionChat) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.medium) {
                if let earlier = viewModel.earlierText {
                    ChatBubble(role: .watchtower, text: earlier)
                }
                let entries = WorkchatAgents.dialog(chat.entries)
                if entries.isEmpty {
                    ChatBubble(role: .watchtower, text: "No messages yet")
                }
                ForEach(entries) { entry in
                    WorkchatEntryRow(entry: entry)
                }
            }
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.regular)
        }
        .defaultScrollAnchor(.bottom)
    }
}

/// The screen's fixed strings.
enum SessionChatText {
    static let asking = "Asking your tower…"
    static let tooLong = "Your tower has not sent this chat yet. Is it awake?"
}

/// The route of a subagent marker.
enum SessionChatEntryRow {
    /// nil for a marker without its agent id or tool_use id: nothing to open.
    static func route(for subagent: SessionChat.Entry.Subagent, sessionID: Int64) -> SessionChatRoute? {
        guard !subagent.agentID.isEmpty, !subagent.toolUseID.isEmpty else { return nil }
        return SessionChatRoute(sessionID: sessionID, agentID: subagent.agentID, toolUseID: subagent.toolUseID)
    }
}

/// Markdown text: fenced code blocks monospaced, the rest inline Markdown
/// with its line breaks kept.
struct ChatMarkdown: View {
    private enum Segment {
        case prose(AttributedString)
        case code(String)
    }

    private let segments: [Segment]

    init(text: String) {
        segments = Self.split(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case let .prose(text):
                    Text(text)
                case let .code(code):
                    Text(code)
                        .font(.system(.callout, design: .monospaced))
                        .padding(Spacing.regular)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                }
            }
        }
    }

    private static func split(_ text: String) -> [Segment] {
        var result: [Segment] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var inCode = false
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            prose = []
            guard !joined.isEmpty else { return }
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            result.append(.prose((try? AttributedString(markdown: joined, options: options)) ?? AttributedString(joined)))
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    result.append(.code(code.joined(separator: "\n")))
                    code = []
                } else {
                    flushProse()
                }
                inCode.toggle()
            } else if inCode {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if inCode { result.append(.code(code.joined(separator: "\n"))) } else { flushProse() }
        return result
    }
}

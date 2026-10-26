import SwiftUI
import WatchtowerKit
import WatchtowerSync

/// A subagent's chat (board #486), pushed from its row in the workchat:
/// read-only, in the workchat's bubbles (mockup 3) — the lines the subagent
/// was given right, its text left, its own subagents as rows that push
/// their chat. Opens scrolled to the newest entry. The session's own chat is the workchat
/// (`WorkchatView`), the only one with a composer.
struct SessionChatView: View {
    static let screen = ChatScreen.subagent

    let replica: WorkbenchReplicaModel
    private let store: ReplicaStore
    private let requester: SessionChatRequester
    @State private var viewModel: SessionChatViewModel
    @State private var openSubagent: SessionChatRoute?

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
        .navigationTitle("Subagent")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openSubagent) { route in
            Self(replica: replica, route: route, store: store, requester: requester)
        }
        .onAppear { viewModel.appeared() }
        .onDisappear { viewModel.disappeared() }
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
                if chat.entries.isEmpty {
                    ChatBubble(role: .watchtower, text: "No messages yet")
                }
                ForEach(chat.entries) { entry in
                    WorkchatEntryRow(entry: entry, sessionID: viewModel.sessionID) { openSubagent = $0 }
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
    static let asking = "Asking your Mac…"
    static let tooLong = "Your Mac has not sent this chat yet. Is it awake?"
}

/// The route of a subagent marker and its status word.
enum SessionChatEntryRow {
    /// nil for a marker without its agent id or tool_use id: nothing to open.
    static func route(for subagent: SessionChat.Entry.Subagent, sessionID: Int64) -> SessionChatRoute? {
        guard !subagent.agentID.isEmpty, !subagent.toolUseID.isEmpty else { return nil }
        return SessionChatRoute(sessionID: sessionID, agentID: subagent.agentID, toolUseID: subagent.toolUseID)
    }

    static func statusText(_ status: String) -> String {
        switch status {
        case "running": "Running"
        case "finished": "Finished"
        default: ""
        }
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

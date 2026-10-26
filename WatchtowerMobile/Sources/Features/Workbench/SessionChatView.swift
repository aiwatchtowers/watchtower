import SwiftUI
import WatchtowerKit
import WatchtowerSync

/// A subagent's chat (board #486), pushed from its row in the workchat:
/// read-only, after the Mac pane — the lines the subagent was given right,
/// its text left, its own subagents as rows that push their chat. Opens
/// scrolled to the newest entry. The session's own chat is the workchat
/// (`WorkchatView`), the only one with a composer.
struct SessionChatView: View {
    static let screen = ChatScreen.subagent

    let replica: WorkbenchReplicaModel
    @State private var viewModel: SessionChatViewModel

    init(replica: WorkbenchReplicaModel, route: SessionChatRoute, store: ReplicaStore, requester: SessionChatRequester) {
        self.replica = replica
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
        .onAppear { viewModel.appeared() }
        .onDisappear { viewModel.disappeared() }
    }

    private var waiting: some View {
        VStack(spacing: Spacing.medium) {
            if viewModel.waitingForKeys {
                Text("Unlock this iPhone to see the chat.").foregroundStyle(.secondary)
            } else if viewModel.waitingTooLong {
                Text(SessionChatText.tooLong).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                ProgressView()
                Text(SessionChatText.asking).foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func feed(_ chat: SessionChat) -> some View {
        ScrollView {
            LazyVStack(spacing: Spacing.cozy) {
                if let earlier = viewModel.earlierText {
                    Text(earlier).font(TypeScale.meta).foregroundStyle(.secondary)
                }
                if chat.entries.isEmpty {
                    Text("No messages yet").foregroundStyle(.secondary).padding(.top, Spacing.page)
                }
                ForEach(chat.entries) { entry in
                    SessionChatEntryRow(entry: entry, sessionID: viewModel.sessionID)
                }
            }
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.cozy)
        }
        .defaultScrollAnchor(.bottom)
    }
}

/// The screen's fixed strings.
enum SessionChatText {
    static let asking = "Asking your Mac…"
    static let tooLong = "Your Mac has not sent this chat yet. Is it awake?"
}

/// One entry of the chat.
struct SessionChatEntryRow: View {
    let entry: SessionChat.Entry
    let sessionID: Int64

    var body: some View {
        switch entry.kind {
        case .owner:
            ownerBubble(label: nil, caption: nil)
        case .askAnswer:
            ownerBubble(label: entry.askID.map { "Ask #\($0)" } ?? "Ask", caption: "via Watchtower")
        case .watchtower:
            ownerBubble(label: nil, caption: "via Watchtower")
        case .agent:
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    ChatMarkdown(text: entry.text)
                    time
                }
                Spacer(minLength: 40)
            }
        case .brief:
            DisclosureGroup {
                ChatMarkdown(text: entry.text).padding(.top, 4)
            } label: {
                Text("Watchtower: brief").font(TypeScale.meta).foregroundStyle(.secondary)
            }
        case .separator:
            HStack(spacing: 8) {
                Rectangle().fill(.quaternary).frame(height: 1)
                Text("New conversation").font(TypeScale.meta).foregroundStyle(.secondary)
                Rectangle().fill(.quaternary).frame(height: 1)
            }
        case .subagent:
            if let subagent = entry.subagent {
                subagentRow(subagent)
            }
        default:
            EmptyView()
        }
    }

    private func ownerBubble(label: String?, caption: String?) -> some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 3) {
                VStack(alignment: .leading, spacing: 4) {
                    if let label {
                        Text(label).font(TypeScale.kind).foregroundStyle(.secondary)
                    }
                    if let title = entry.title, !title.isEmpty {
                        Text(title).font(TypeScale.rowEmphasis)
                    }
                    ChatMarkdown(text: entry.text)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack(spacing: 6) {
                    if let caption { Text(caption) }
                    if let at = entry.at { Text(at, format: .dateTime.hour().minute()) }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var time: some View {
        if let at = entry.at {
            Text(at, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private func subagentRow(_ subagent: SessionChat.Entry.Subagent) -> some View {
        if let route = Self.route(for: subagent, sessionID: sessionID) {
            NavigationLink(value: route) { subagentLabel(subagent, chevron: true) }
                .buttonStyle(.plain)
                .accessibilityLabel("Subagent \(subagent.type) \(subagent.description)")
        } else {
            // A marker without its ids has no chat to open yet.
            subagentLabel(subagent, chevron: false)
                .accessibilityLabel("Subagent \(subagent.type) \(subagent.description)")
        }
    }

    private func subagentLabel(_ subagent: SessionChat.Entry.Subagent, chevron: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(subagent.type.isEmpty ? "Subagent" : subagent.type).font(TypeScale.rowEmphasis)
                if !subagent.description.isEmpty {
                    Text(subagent.description).font(TypeScale.meta).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Text(Self.statusText(subagent.status)).font(TypeScale.meta).foregroundStyle(.secondary)
            if chevron {
                Image(systemName: "chevron.right").font(TypeScale.meta).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(minHeight: 44)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }

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
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case let .prose(text):
                    Text(text)
                case let .code(code):
                    Text(code)
                        .font(.system(.callout, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
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

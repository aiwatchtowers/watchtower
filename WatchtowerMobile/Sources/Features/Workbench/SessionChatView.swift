import SwiftUI
import WatchtowerKit
import WatchtowerSync

/// A session's chat (board #486), after the Mac pane: the owner's lines
/// right in a tinted bubble, the agent's left, ask answers and Watchtower's
/// lines marked "via Watchtower", the brief as one collapsed line, subagents
/// as rows that push their own chat. Opens scrolled to the newest entry.
/// "Tell the session…" sits at the bottom of the main chat under the session
/// detail's rule (PROJ-16); a sent line shows as a pending bubble until the
/// Mac applied it.
struct SessionChatView: View {
    @Environment(AppEnvironment.self) private var env
    let replica: WorkbenchReplicaModel
    @State private var viewModel: SessionChatViewModel
    @State private var sendError: String?

    init(replica: WorkbenchReplicaModel, route: SessionChatRoute, store: ReplicaStore, requester: SessionChatRequester) {
        self.replica = replica
        _viewModel = State(initialValue: SessionChatViewModel(
            sessionID: route.sessionID, agentID: route.agentID, store: store, requester: requester
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
        .navigationTitle(viewModel.agentID == nil ? "Chat" : "Subagent")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The Tell bar writes to the session, so only the main chat has it.
            if viewModel.agentID == nil, let input = input(now: .now), input.showsBar {
                TellSessionBar(model: input, isSending: env.sessionInputs.inFlight.contains(
                    SessionInputSender.sendKey(viewModel.sessionID)
                )) { text in await send(text) }
            }
        }
        .alert("Couldn't send", isPresented: Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sendError ?? "")
        }
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
        let lines = viewModel.agentID == nil ? (input(now: .now)?.lines ?? []) : []
        return ScrollView {
            LazyVStack(spacing: 10) {
                if let earlier = viewModel.earlierText {
                    Text(earlier).font(TypeScale.meta).foregroundStyle(.secondary)
                }
                if chat.entries.isEmpty, lines.isEmpty {
                    Text("No messages yet").foregroundStyle(.secondary).padding(.top, Spacing.page)
                }
                ForEach(chat.entries) { entry in
                    SessionChatEntryRow(entry: entry, sessionID: viewModel.sessionID)
                }
                ForEach(lines) { PendingLineBubble(row: $0, onDismiss: dismissLine) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .defaultScrollAnchor(.bottom)
    }

    private func input(now: Date) -> SessionInputModel? {
        let permissions = PermissionAccess(
            grant: replica.snapshot.grant(for: env.linkedDevice?.deviceID),
            requested: env.deviceSettings.permissionsRequested,
            inFlight: env.sessionInputs.inFlight,
            sentRequestID: env.sessionInputs.answered[viewModel.sessionID]
        )
        return replica.snapshot.session(viewModel.sessionID).map {
            SessionInputModel(
                session: $0, snapshot: replica.snapshot,
                grant: replica.snapshot.grant(for: env.linkedDevice?.deviceID),
                typingRequested: env.deviceSettings.typingRequested,
                delivered: env.sessionInputs.delivered[$0.id], now: now,
                answersPermission: PermissionCardModel.answerable($0, in: replica.snapshot, access: permissions)
            )
        }
    }

    private func send(_ text: String) async -> Bool {
        do {
            return try await env.sessionInputs.send(sessionID: viewModel.sessionID, text: text)
        } catch {
            sendError = BoardWriteText.sendError(error)
            return false
        }
    }

    private func dismissLine(_ row: PendingAction) {
        do {
            try env.sessionInputs.dismiss(row)
        } catch {
            sendError = BoardWriteText.sendError(error)
        }
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

    private func subagentRow(_ subagent: SessionChat.Entry.Subagent) -> some View {
        NavigationLink(value: Self.route(for: subagent, sessionID: sessionID)) {
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
                Image(systemName: "chevron.right").font(TypeScale.meta).foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(minHeight: 44)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Subagent \(subagent.type) \(subagent.description)")
    }

    static func route(for subagent: SessionChat.Entry.Subagent, sessionID: Int64) -> SessionChatRoute {
        SessionChatRoute(sessionID: sessionID, agentID: subagent.agentID)
    }

    static func statusText(_ status: String) -> String {
        switch status {
        case "running": "Running"
        case "finished": "Finished"
        default: ""
        }
    }
}

/// A line the phone sent that is not in the feed yet: waiting, held
/// (Cancel is on the session detail) or refused (Dismiss).
private struct PendingLineBubble: View {
    let row: SessionInputModel.LineRow
    let onDismiss: (PendingAction) -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 3) {
                Text(row.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                switch row.state {
                case let .waiting(text), let .held(text):
                    Label(text, systemImage: "clock").font(.caption2).foregroundStyle(.secondary)
                case let .failed(text):
                    Text(text).font(.caption2).foregroundStyle(PhoneTone.red.color)
                    Button("Dismiss") { onDismiss(row.pending) }
                        .font(.caption)
                        .frame(minHeight: 44)
                }
            }
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

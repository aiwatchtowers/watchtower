import SwiftUI
import WatchtowerCore

/// The dialog of an agent session as a chat (`.sessionChat`): the owner
/// right in a tinted bubble, the agent left without one, Watchtower's own
/// lines marked "via Watchtower", subagents as cards opening a sheet.
struct SessionChatView: View {
    let vm: WorkbenchesViewModel
    let sessionID: Int64
    let projectID: Int64

    @StateObject private var store: SessionFeedStore
    @State private var poller: SessionFeedPoller
    @State private var openedSubagent: SessionFeedEntry?
    private let runnerMissing: Bool

    init(vm: WorkbenchesViewModel, sessionID: Int64, projectID: Int64) {
        self.vm = vm
        self.sessionID = sessionID
        self.projectID = projectID
        let runner = ProcessCLIRunner.makeDefault()
        runnerMissing = runner == nil
        let store = SessionFeedStore(sessionID: sessionID, runner: runner ?? UnavailableRunner())
        _store = StateObject(wrappedValue: store)
        _poller = State(initialValue: SessionFeedPoller { await store.refresh() })
    }

    /// The agent works or has background subagents running: poll every 3 s.
    private var isActive: Bool {
        guard let session = vm.session(sessionID, projectID: projectID) else { return false }
        let kind = vm.sessionState(session).kind
        return kind == .working || kind == .background
    }

    private var stateKind: SessionSwitcherPresentation.State.Kind? {
        vm.session(sessionID, projectID: projectID).map { vm.sessionState($0).kind }
    }

    var body: some View {
        VStack(spacing: 0) {
            if runnerMissing {
                errorBar(WorkbenchesViewModel.cliMissingMessage, retry: false)
            } else if let error = store.error {
                errorBar(error, retry: true)
            }
            if store.entries.isEmpty {
                emptyState
            } else {
                feed
            }
        }
        .task(id: stateKind) { await poll() }
        .sheet(item: $openedSubagent) { entry in
            SessionChatSubagentSheet(store: store, entry: entry)
        }
    }

    private var feed: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(store.entries) { entry in
                    SessionChatRow(entry: entry) { openedSubagent = entry }
                }
            }
            .padding(14)
        }
        .defaultScrollAnchor(.bottom)
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.error == nil && !runnerMissing {
            Text("No messages yet")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Spacer()
        }
    }

    private func errorBar(_ message: String, retry: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).lineLimit(3).textSelection(.enabled)
            Spacer(minLength: 4)
            if retry {
                Button("Retry") { Task { await poller.refresh() } }
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.1))
    }

    /// One read when the pane (or the session's state) changes; while the
    /// agent works, one more every 3 s. Cancelled with the pane.
    private func poll() async {
        guard !runnerMissing else { return }
        await poller.refresh()
        while isActive {
            try? await Task.sleep(for: .seconds(3))
            if Task.isCancelled { return }
            await poller.refresh()
        }
    }
}

/// Stand-in when the CLI binary is missing: the pane shows the error and
/// never polls, so this is never called.
private struct UnavailableRunner: CLIRunnerProtocol {
    func run(args: [String]) async throws -> Data { Data() }
}

/// One message of the chat, shared by the pane and the subagent sheet.
struct SessionChatRow: View {
    let entry: SessionFeedEntry
    var openSubagent: (() -> Void)?

    var body: some View {
        switch entry.kind {
        case "owner":
            ownerBubble(label: nil, title: nil, caption: nil)
        case "ask_answer":
            ownerBubble(label: entry.askID.map { "Ask #\($0)" } ?? "Ask", title: entry.title, caption: "via Watchtower")
        case "watchtower":
            ownerBubble(label: nil, title: nil, caption: "via Watchtower")
        case "agent":
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    SessionChatText(text: entry.text)
                    timeCaption
                }
                Spacer(minLength: 48)
            }
        case "brief":
            DisclosureGroup {
                SessionChatText(text: entry.text).padding(.top, 4)
            } label: {
                Text("Watchtower: brief").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity)
        case "separator":
            HStack(spacing: 8) {
                Rectangle().fill(.quaternary).frame(height: 1)
                Text("New conversation").font(.caption).foregroundStyle(.secondary)
                Rectangle().fill(.quaternary).frame(height: 1)
            }
        case "subagent":
            if let subagent = entry.subagent {
                subagentCard(subagent)
            }
        default:
            EmptyView()
        }
    }

    private func ownerBubble(label: String?, title: String?, caption: String?) -> some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 3) {
                VStack(alignment: .leading, spacing: 4) {
                    if let label {
                        Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    if let title, !title.isEmpty {
                        Text(title).font(.callout.weight(.semibold))
                    }
                    SessionChatText(text: entry.text)
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

    @ViewBuilder
    private var timeCaption: some View {
        if let at = entry.at {
            Text(at, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func subagentCard(_ subagent: SessionFeedSubagent) -> some View {
        Button {
            openSubagent?()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.2").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(subagent.type.isEmpty ? "Subagent" : subagent.type).font(.callout.weight(.semibold))
                    if !subagent.description.isEmpty {
                        Text(subagent.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                Text(subagent.status == "running" ? "Running" : subagent.status == "finished" ? "Finished" : "")
                    .font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 420, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Markdown text: fenced code blocks monospaced, the rest inline Markdown
/// with its line breaks kept. Parsed once per text, not per render.
struct SessionChatText: View {
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
                    Text(text).textSelection(.enabled)
                case let .code(code):
                    Text(code)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
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

import SwiftUI
import WatchtowerCore

/// Open Quickly's content (spec §8.1): the search field, the scope control
/// (All · Files · Symbols · Text), the results on the left with section
/// headers, the preview on the right and the key hints. Keys (↑↓ ↩ ⌥↩ ⌘↩
/// Esc Space) are the panel's (`OpenQuicklyPanelController`), so the field
/// keeps the focus. After ⌘↩ the answer card (spec §9.3) takes the panel.
struct OpenQuicklyView: View {
    let session: OpenQuicklySession
    let questions: CodeQuestionCenter?
    let onActivate: (_ option: Bool) -> Void
    /// A `path:line` link in the answer.
    let onAnswerLink: (URL) -> Void
    /// The card is on screen: its follow-up field takes the keyboard.
    let onAnswerShown: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if let conversationID = session.answerConversationID, let questions,
               let question = questions.questionRef(conversationID) {
                OpenQuicklyAnswerCard(questions: questions, question: question, onLink: onAnswerLink)
                    .onAppear(perform: onAnswerShown)
            } else {
                searchContent
            }
        }
        .frame(width: OpenQuicklyPanelController.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open Quickly")
    }

    private var searchContent: some View {
        let model = session.model
        let selectedID = model.selectedRow?.id
        return VStack(spacing: 0) {
            searchField
            Picker("Scope", selection: Binding(get: { session.model.scope }, set: { session.updateScope($0) })) {
                Text("All").tag(CodeSearchScope.all)
                Text("Files").tag(CodeSearchScope.files)
                Text("Symbols").tag(CodeSearchScope.symbols)
                Text("Text").tag(CodeSearchScope.text)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            Divider()
            HStack(spacing: 0) {
                results(model, selectedID: selectedID)
                    .frame(width: 300)
                Divider()
                OpenQuicklyPreviewPane(session: session, row: model.selectedRow)
            }
            .frame(height: 340)
            Divider()
            footer(model)
        }
        .onChange(of: session.index.files.count) { _, _ in session.refreshIndexResults() }
        .onChange(of: session.index.state) { _, _ in session.refreshIndexResults() }
        .onAppear { searchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Open Quickly", text: Binding(get: { session.model.query }, set: { session.updateQuery($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 22))
                .focused($searchFocused)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func results(_ model: OpenQuicklyModel, selectedID: String?) -> some View {
        let sections = model.sections
        if sections.isEmpty {
            Text(emptyText(model))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(sections) { section in
                            if let title = section.kind.title {
                                Text(title)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 6)
                                    .padding(.bottom, 2)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            ForEach(section.rows) { row in
                                OpenQuicklyRowView(
                                    row: row, isSelected: row.id == selectedID, query: model.query,
                                    folder: session.project.folderURL, gitStatuses: session.gitStatuses
                                )
                                .id(row.id)
                                .onTapGesture {
                                    session.select(row.id)
                                    onActivate(NSEvent.modifierFlags.contains(.option))
                                }
                                .onHover { if $0 { session.select(row.id) } }
                            }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func emptyText(_ model: OpenQuicklyModel) -> String {
        if model.trimmedQuery.isEmpty { return model.scope == .text ? "Type to search the text of every file." : "No files yet." }
        if model.scope == .text, model.textStatus == .searching { return "Searching…" }
        return "No matches."
    }

    private func footer(_ model: OpenQuicklyModel) -> some View {
        HStack(spacing: 8) {
            Text(model.askAIEnabled ? "↩ Open · ⌥↩ Open Beside · ⌘↩ Ask AI" : "↩ Open · ⌥↩ Open Beside")
            Spacer(minLength: 8)
            if let status = statusText(model) {
                Text(status)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(statusIsError(model) ? Color.red : .secondary)
                    .help(status)
                Spacer(minLength: 8)
            }
            Text("Space — Quick Look")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    /// The index's state (spec §7: its failure shows here) and the text
    /// search's.
    private func statusText(_ model: OpenQuicklyModel) -> String? {
        if let askError = session.askError { return askError }
        switch session.index.state {
        case let .failed(message): return "Index: \(message)"
        case let .indexing(done, total): return total > 0 ? "Indexing \(done) of \(total) files…" : "Indexing…"
        case .idle, .ready: break
        }
        guard model.scope == .all || model.scope == .text else { return nil }
        switch model.textStatus {
        case let .failed(message): return "Text search: \(message)"
        case .finished(truncated: true): return "Text: first \(OpenQuicklySession.textSearchMax) matches"
        case .searching, .finished, .idle: return nil
        }
    }

    private func statusIsError(_ model: OpenQuicklyModel) -> Bool {
        if session.askError != nil { return true }
        if case .failed = session.index.state { return true }
        if case .failed = model.textStatus { return true }
        return false
    }
}

/// The answer in Open Quickly (spec §9.3): "✦ AI answer" over the streamed
/// conversation (`EmbeddedChatView` `.compact`, whose field follows up on
/// ↩) and the key hint. A `path:line` link opens the file and closes the
/// panel.
struct OpenQuicklyAnswerCard: View {
    let questions: CodeQuestionCenter
    let question: CodeQuestionRef
    let onLink: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("✦ AI answer")
                    .font(.headline)
                Spacer(minLength: 8)
                Text(QuestionsView.originLabel(question.origin))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider()
            if let engine = questions.engine(for: question), let chats = questions.embeddedChats {
                EmbeddedChatView(engine: engine, density: .compact, placeholder: "Ask a follow-up…")
                    .embeddedChatVisibility(engine.spec.key, in: chats)
                    .frame(height: 380)
            } else {
                ContentUnavailableView("The answer can't be shown", systemImage: "exclamationmark.triangle")
                    .frame(height: 380)
            }
            Divider()
            HStack {
                Text("↩ Follow up · click a link to open the file")
                Spacer(minLength: 8)
                Text("esc to close")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .environment(\.dictationCenter, questions.dictation)
        .codeAnswerLinks(onLink)
    }
}

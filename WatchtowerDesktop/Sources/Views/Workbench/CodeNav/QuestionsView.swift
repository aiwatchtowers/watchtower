import SwiftUI
import WatchtowerCore

/// The inspector's Questions tab (spec §9.4): this workbench's code
/// conversations, newest first — the first question, the `path:line` it was
/// asked from and when. A click opens the conversation here; Delete removes
/// it with its messages.
struct QuestionsView: View {
    let questions: CodeQuestionCenter
    let project: Workbench

    var body: some View {
        VStack(spacing: 0) {
            if let error = questions.questionListErrors[project.id] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            if let conversationID = questions.inspectorQuestions[project.id],
               let question = questions.questionRef(conversationID) {
                QuestionConversationView(questions: questions, question: question)
                    .id(conversationID)
            } else {
                QuestionListView(questions: questions, project: project)
            }
        }
        .task(id: project.id) { questions.reloadQuestionList(workbenchID: project.id) }
    }

    /// "Sources/App.swift:12", or a note for a question asked with no file.
    static func originLabel(_ origin: CodeQuestionOrigin) -> String {
        origin.path.isEmpty ? "No file open" : "\(origin.path):\(origin.line)"
    }
}

private struct QuestionListView: View {
    let questions: CodeQuestionCenter
    let project: Workbench
    @State private var pendingDelete: CodeQuestionListItem?

    var body: some View {
        let items = questions.questionLists[project.id] ?? []
        if items.isEmpty {
            ContentUnavailableView(
                "No questions yet", systemImage: "bubble.left.and.text.bubble.right",
                description: Text("Ask AI about code with ⌘I in the editor or ⌘↩ in Open Quickly.")
            )
        } else {
            List(items) { item in
                Button {
                    questions.openQuestion(item, project: project)
                } label: {
                    QuestionRow(item: item)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Delete", role: .destructive) { pendingDelete = item }
                }
            }
            .listStyle(.plain)
            .confirmationDialog(
                "Delete this question?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                presenting: pendingDelete
            ) { item in
                Button("Delete", role: .destructive) {
                    questions.deleteQuestion(CodeQuestionRef(project: project, conversationID: item.conversationID,
                                                             origin: item.origin))
                }
            } message: { _ in
                Text("The conversation and its answers are removed.")
            }
        }
    }
}

private struct QuestionRow: View {
    let item: CodeQuestionListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.firstQuestion ?? "No question sent")
                .font(.callout)
                .foregroundStyle(item.firstQuestion == nil ? .secondary : .primary)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(QuestionsView.originLabel(item.origin))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(item.createdAt, format: .relative(presentation: .named))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One code conversation in the inspector (`EmbeddedChatView` `.compact`):
/// back to the list, where it was asked, the model picker, Delete.
private struct QuestionConversationView: View {
    let questions: CodeQuestionCenter
    let question: CodeQuestionRef
    @State private var confirmsDelete = false

    var body: some View {
        let engine = questions.engine(for: question)
        VStack(spacing: 0) {
            header(busy: engine?.isBusy ?? false)
            Divider()
            if let engine, let chats = questions.embeddedChats {
                EmbeddedChatView(engine: engine, density: .compact, placeholder: "Ask a follow-up…")
                    .embeddedChatVisibility(engine.spec.key, in: chats)
            } else {
                ContentUnavailableView("This question can't be opened", systemImage: "exclamationmark.triangle")
            }
        }
        .environment(\.dictationCenter, questions.dictation)
        .codeAnswerLinks { [questions, question] url in
            Task { await questions.openLink(url, project: question.project) }
        }
        .confirmationDialog("Delete this question?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) { questions.deleteQuestion(question) }
        } message: {
            Text("The conversation and its answers are removed.")
        }
    }

    private func header(busy: Bool) -> some View {
        let conversationID = question.conversationID
        let choice = questions.modelChoice(conversationID: conversationID)
        return HStack(spacing: 6) {
            Button {
                questions.closeInspectorQuestion(workbenchID: question.project.id)
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("All questions")
            .accessibilityLabel("All questions")
            Text(QuestionsView.originLabel(question.origin))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            ChatModelPicker(
                provider: choice.provider,
                model: choice.model,
                suggestions: questions.modelSuggestions(choice.provider),
                onSelectProvider: { questions.setModelChoice(choice.switching(to: $0), conversationID: conversationID) },
                onSelectModel: { questions.setModelChoice(.init(provider: choice.provider, model: $0), conversationID: conversationID) }
            )
            .disabled(busy)
            if CodeQuestionActionsFeature.handToClaudeCode {
                Button {
                    questions.handToClaude(question)
                } label: {
                    Image(systemName: "terminal")
                }
                .keyboardShortcut(.return, modifiers: [.command, .option])
                .disabled(busy)
                .help("Hand to Claude Code (⌥⌘↩)")
                .accessibilityLabel("Hand to Claude Code")
            }
            Button {
                confirmsDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete this question")
            .accessibilityLabel("Delete")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

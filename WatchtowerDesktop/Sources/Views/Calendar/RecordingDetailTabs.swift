import SwiftUI
import AppKit

// MARK: - Recap tab

/// Structured recap (summary / decisions / action items / open questions) —
/// same plain-Text rendering as MeetingNotesView.recapSection, duplicated
/// here because the prep pane keeps its own copy (both stay functional).
struct RecordingRecapTab: View {
    let transcript: MeetingTranscript
    let recapContent: MeetingRecap.Content?
    let onRetryRecap: () -> Void
    let isRetrying: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let content = recapContent {
                    if !content.summary.isEmpty {
                        Text(content.summary)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                    if !content.keyDecisions.isEmpty {
                        recapSubsection(title: "Decisions", items: content.keyDecisions)
                    }
                    if !content.actionItems.isEmpty {
                        recapSubsection(title: "Action items", items: content.actionItems)
                    }
                    if !content.openQuestions.isEmpty {
                        recapSubsection(title: "Open questions", items: content.openQuestions)
                    }
                } else {
                    VStack(spacing: 8) {
                        Text("No recap yet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                }

                Button {
                    onRetryRecap()
                } label: {
                    Label(recapContent == nil ? "Generate recap" : "Re-generate",
                          systemImage: isRetrying ? "hourglass" : "arrow.triangle.2.circlepath")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRetrying)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func recapSubsection(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
            ForEach(Array(items.enumerated()), id: \.offset) { _, text in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(.secondary)
                    Text(text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Notes tab

/// Publishable meeting notes: generate (AI, via TranscriptNotesCenter) →
/// edit in a TextEditor (debounced autosave) → Copy to clipboard.
struct RecordingNotesTab: View {
    let transcript: MeetingTranscript
    let notesMD: String?
    let onGenerate: () -> Void
    let isGenerating: Bool
    let generationError: String?
    let onSave: (String) -> Void

    @State private var draft: String = ""
    @State private var copied = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    onGenerate()
                } label: {
                    Label(notesMD == nil ? "Generate" : "Re-generate",
                          systemImage: "sparkles")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isGenerating)

                if isGenerating {
                    ProgressView().controlSize(.small)
                    Text("Generating notes…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !draft.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draft, forType: .string)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let error = generationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if notesMD == nil && draft.isEmpty && !isGenerating {
                Text("Generate publishable meeting notes from the transcript, edit them, then copy anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $draft)
                .font(.callout)
                // Editing is locked during generation so the finished AI output
                // can never clobber text typed mid-run (adoption guard below).
                .disabled(isGenerating)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(.textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: draft) { _, newValue in
                    scheduleSave(newValue)
                }
        }
        .padding(12)
        .onAppear { draft = notesMD ?? "" }
        .onChange(of: notesMD) { _, newValue in
            // Generation finished (or another window edited) — adopt the DB
            // value only when the local draft isn't ahead of it.
            if let newValue, draft != newValue, saveTask == nil {
                draft = newValue
            }
        }
        .onDisappear {
            saveTask?.cancel()
            saveTask = nil
            flushSave()
        }
    }

    private func scheduleSave(_ text: String) {
        guard text != (notesMD ?? "") else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            onSave(text)
            saveTask = nil
        }
    }

    private func flushSave() {
        if draft != (notesMD ?? "") {
            onSave(draft)
        }
    }
}

// MARK: - Transcript tab

/// Full transcript text — the ONLY place the heavy blob is rendered.
struct RecordingTranscriptTab: View {
    let transcriptText: String

    var body: some View {
        ScrollView {
            Text(transcriptText)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }
}

// MARK: - Chat tab

/// Secretary chat about this meeting. The ChatInput is docked BELOW the
/// ScrollView (nested-NSScrollView collapse — same constraint as
/// SituationDiscussInputBar).
struct RecordingChatTab: View {
    @Bindable var chatVM: MeetingChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chatVM.messages.isEmpty {
                        Text("Ask about this meeting — what was decided, who said what, or draft a follow-up.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    }
                    ForEach(chatVM.messages) { msg in
                        bubble(msg)
                    }
                }
                .padding(12)
            }

            Divider()

            if let err = chatVM.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }
            ChatInput(
                text: $chatVM.inputText,
                isStreaming: chatVM.isStreaming,
                onSend: { chatVM.send() },
                onStop: { chatVM.cancelStream() },
                placeholder: "Ask about this meeting…"
            )
        }
    }

    @ViewBuilder
    private func bubble(_ msg: ChatMessage) -> some View {
        switch msg.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(msg.text)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
            }
        case .assistant:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 9)
                Group {
                    if msg.text.isEmpty && msg.isStreaming {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Thinking…").foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    } else {
                        MarkdownText(text: msg.text)
                            .font(.subheadline)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            }
        case .system:
            Text(msg.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

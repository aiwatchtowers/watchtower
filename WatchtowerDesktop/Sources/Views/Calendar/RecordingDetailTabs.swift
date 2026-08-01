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

/// Full transcript — the ONLY place the heavy blob is rendered. Rows with
/// persisted segments get the utterance list (speaker + timecode header per
/// merged utterance, hover-revealed delete, undo toast); legacy rows (NULL
/// segments) keep the flat text view. Soft delete only: the utterance is
/// flagged `deleted` and hidden, never removed — `onSetUtteranceDeleted`
/// performs the transactional `segments_json` + `transcript_text` rewrite.
struct RecordingTranscriptTab: View {
    let transcriptText: String
    let utterances: [TranscriptUtterance]?
    /// Returns whether the transactional rewrite landed — the toast only
    /// shows (and the undo only clears) on success.
    let onSetUtteranceDeleted: (_ idx: Int, _ deleted: Bool) -> Bool

    @State private var hoveredIdx: Int?
    @State private var undoIdx: Int?
    @State private var undoDismissTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let utterances {
                utteranceList(utterances)
            } else {
                legacyFlatText
            }
        }
        .overlay(alignment: .bottom) { undoToast }
        .onDisappear { clearUndo() }
    }

    private var legacyFlatText: some View {
        ScrollView {
            Text(transcriptText)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }

    private func utteranceList(_ utterances: [TranscriptUtterance]) -> some View {
        let visible = utterances.filter { !$0.deleted }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if visible.isEmpty {
                    // Degenerate but valid: every utterance soft-deleted.
                    Text("All utterances deleted")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                }
                ForEach(visible) { utterance in
                    utteranceRow(utterance)
                }
            }
            .padding(12)
        }
    }

    private func utteranceRow(_ utterance: TranscriptUtterance) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(utterance.speaker)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(utterance.speaker == "Я" ? Color.accentColor : .secondary)
                Text(TranscriptFormatting.formatTimecode(utterance.startSec))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    deleteUtterance(utterance.idx)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hoveredIdx == utterance.idx ? 1 : 0)
                // Invisible must also mean untappable — an opacity-0 button
                // stays hit-testable otherwise.
                .allowsHitTesting(hoveredIdx == utterance.idx)
                .help("Delete utterance")
            }
            Text(utterance.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering in
            if hovering {
                hoveredIdx = utterance.idx
            } else if hoveredIdx == utterance.idx {
                hoveredIdx = nil
            }
        }
    }

    @ViewBuilder
    private var undoToast: some View {
        if let idx = undoIdx {
            HStack(spacing: 12) {
                Text("Utterance deleted")
                    .font(.callout)
                Button("Undo") {
                    // Keep the toast when the restore write failed, so the
                    // utterance stays recoverable without reopening the row.
                    if onSetUtteranceDeleted(idx, false) {
                        clearUndo()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 4)
            .padding(.bottom, 12)
        }
    }

    private func deleteUtterance(_ idx: Int) {
        // No toast when the write failed — the detail view surfaces the error
        // and the transcript is unchanged, so "Utterance deleted" would lie.
        guard onSetUtteranceDeleted(idx, true) else { return }
        undoDismissTask?.cancel()
        undoIdx = idx
        undoDismissTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            clearUndo()
        }
    }

    private func clearUndo() {
        undoDismissTask?.cancel()
        undoDismissTask = nil
        undoIdx = nil
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

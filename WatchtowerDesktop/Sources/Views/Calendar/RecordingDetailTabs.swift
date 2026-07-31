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
///
/// Speaker identity: tapping a non-«Я» speaker label opens the rename picker
/// (attendees first, free text after) — `onRenameSpeaker` performs the
/// transactional rewrite + voice-print upsert. "Suggest speaker names" runs
/// the LLM guess for unnamed clusters; suggestions render as confirm chips on
/// the cluster's first visible utterance and are NEVER auto-applied.
struct RecordingTranscriptTab: View {
    let transcriptText: String
    let utterances: [TranscriptUtterance]?
    let attendees: [EventAttendee]
    let suggestions: [SpeakerSuggestion]
    let isSuggesting: Bool
    let suggestError: String?
    /// Returns whether the transactional rewrite landed — the toast only
    /// shows (and the undo only clears) on success.
    let onSetUtteranceDeleted: (_ idx: Int, _ deleted: Bool) -> Bool
    let onSuggestNames: () -> Void
    let onRenameSpeaker: (_ from: String, _ to: String) -> Void
    let onDismissSuggestion: (_ speaker: String) -> Void

    @State private var hoveredIdx: Int?
    @State private var undoIdx: Int?
    @State private var undoDismissTask: Task<Void, Never>?
    @State private var renameTarget: SpeakerRenameTarget?

    var body: some View {
        Group {
            if let utterances {
                utteranceList(utterances)
            } else {
                legacyFlatText
            }
        }
        .overlay(alignment: .bottom) { undoToast }
        .sheet(item: $renameTarget) { target in
            SpeakerRenameSheet(speaker: target.speaker, attendees: attendees) { newName in
                onRenameSpeaker(target.speaker, newName)
            }
        }
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
        let hasUnnamed = visible.contains { SpeakerNaming.isUnnamed($0.speaker) }
        // Chip anchor: the cluster's first visible utterance.
        var chipAnchors: [Int: SpeakerSuggestion] = [:]
        for suggestion in suggestions {
            if let first = visible.first(where: { $0.speaker == suggestion.speaker }) {
                chipAnchors[first.idx] = suggestion
            }
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if hasUnnamed || isSuggesting || suggestError != nil {
                    suggestBar
                }
                if visible.isEmpty {
                    // Degenerate but valid: every utterance soft-deleted.
                    Text("All utterances deleted")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                }
                ForEach(visible) { utterance in
                    utteranceRow(utterance, suggestion: chipAnchors[utterance.idx])
                }
            }
            .padding(12)
        }
    }

    /// "Suggest speaker names" control (visible while any cluster is still an
    /// unnamed "Speaker N").
    private var suggestBar: some View {
        HStack(spacing: 8) {
            Button {
                onSuggestNames()
            } label: {
                Label("Suggest speaker names", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isSuggesting)

            if isSuggesting {
                ProgressView().controlSize(.small)
                Text("Analyzing transcript…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let suggestError {
                Label(suggestError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
        }
    }

    private func utteranceRow(_ utterance: TranscriptUtterance, suggestion: SpeakerSuggestion?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                speakerLabel(utterance.speaker)
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
            if let suggestion {
                suggestionChip(suggestion)
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

    /// «Я» stays a plain label (the owner's cluster is not renameable); every
    /// other speaker label opens the rename picker.
    @ViewBuilder
    private func speakerLabel(_ speaker: String) -> some View {
        if speaker == "Я" {
            Text(speaker)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color.accentColor)
        } else {
            Button {
                renameTarget = SpeakerRenameTarget(speaker: speaker)
            } label: {
                Text(speaker)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Rename this speaker")
        }
    }

    /// "Looks like X — confirm?" chip for an LLM suggestion. Confirm applies
    /// the manual-rename mechanics; ✕ dismisses the chip. Never auto-applied.
    private func suggestionChip(_ suggestion: SpeakerSuggestion) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
            Text("Looks like \(suggestion.candidate)")
                .font(.caption)
                .help(suggestion.evidence)
            Button("Confirm") {
                onRenameSpeaker(suggestion.speaker, suggestion.candidate)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            Button {
                onDismissSuggestion(suggestion.speaker)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss suggestion")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
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

/// Sheet-identity wrapper for the speaker label being renamed.
struct SpeakerRenameTarget: Identifiable {
    let speaker: String
    var id: String { speaker }
}

/// Rename picker: event attendees first (one tap), free-text entry after.
/// Confirm hands the chosen display name back to the caller, which runs the
/// transactional rename + voice-print upsert.
struct SpeakerRenameSheet: View {
    let speaker: String
    let attendees: [EventAttendee]
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var freeText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(speaker)")
                .font(.headline)

            if !attendees.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Attendees")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(attendees) { attendee in
                        Button {
                            confirm(attendee.displayName.isEmpty ? attendee.email : attendee.displayName)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "person.circle")
                                    .foregroundStyle(.secondary)
                                Text(attendee.displayName.isEmpty ? attendee.email : attendee.displayName)
                                if !attendee.displayName.isEmpty, !attendee.email.isEmpty {
                                    Text(attendee.email)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(attendees.isEmpty ? "Name" : "Or type a name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Speaker name", text: $freeText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { confirm(freeText) }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Rename") { confirm(freeText) }
                    .buttonStyle(.borderedProminent)
                    .disabled(freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 320)
    }

    private func confirm(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed)
        dismiss()
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

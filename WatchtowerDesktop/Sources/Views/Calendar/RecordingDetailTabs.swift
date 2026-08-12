import SwiftUI
import AppKit
import WatchtowerCore

// MARK: - Recap tab

/// Structured recap. With generated chapters: overall summary on top, then
/// chapters as disclosure groups (per-chapter decisions / action items / open
/// questions, Action item → Target conversion, follow-up drafts). Without:
/// the legacy flat recap rendering (same plain-Text rendering as
/// MeetingNotesView.recapSection — a deliberate copy, both stay functional)
/// plus a "Generate chapters" button when segments exist.
struct RecordingRecapTab: View {
    let transcript: MeetingTranscript
    let recapContent: MeetingRecap.Content?
    /// True when `recapContent` is the event's recap and it was generated
    /// from a different recording's transcript (or another source) than this
    /// one. Only the legacy flat-recap path renders the note — chapters are
    /// always generated from this transcript's own segments.
    let recapFromOtherSource: Bool
    let chapters: MeetingChapters?
    let hasSegments: Bool
    let onRetryRecap: () -> Void
    let isRetrying: Bool
    let onGenerateChapters: () -> Void
    let isGeneratingChapters: Bool
    let chaptersError: String?
    let onOpenChapter: (MeetingChapter) -> Void
    let onConvertActionItem: (_ chapterIdx: Int, _ itemIdx: Int) -> Void
    let onFollowup: (_ chapterIdx: Int?) -> Void

    @State private var showRegenerateConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let chapters {
                    chaptersView(chapters)
                } else {
                    legacyRecap
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Chapters rendering

    @ViewBuilder
    private func chaptersView(_ chapters: MeetingChapters) -> some View {
        if !chapters.overallSummary.isEmpty {
            Text(chapters.overallSummary)
                .font(.callout)
                .textSelection(.enabled)
        }
        followupButton(chapterIdx: nil, label: "Follow-up draft (whole meeting)")

        ForEach(Array(chapters.chapters.enumerated()), id: \.offset) { idx, chapter in
            chapterGroup(idx: idx, chapter: chapter)
        }

        chaptersFooter
    }

    private func chapterGroup(idx: Int, chapter: MeetingChapter) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if !chapter.summary.isEmpty {
                    Text(chapter.summary)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                if !chapter.decisions.isEmpty {
                    recapSubsection(title: "Decisions", items: chapter.decisions)
                }
                if !chapter.actionItems.isEmpty {
                    actionItemsSection(chapterIdx: idx, items: chapter.actionItems)
                }
                if !chapter.openQuestions.isEmpty {
                    recapSubsection(title: "Open questions", items: chapter.openQuestions)
                }
                followupButton(chapterIdx: idx, label: "Follow-up draft")
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Text(chapter.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                // Tapping the time range jumps to the chapter's first
                // utterance in the Transcript tab.
                Button {
                    onOpenChapter(chapter)
                } label: {
                    Text("\(TranscriptFormatting.formatTimecode(chapter.startSec))–\(TranscriptFormatting.formatTimecode(chapter.endSec))")
                        .font(.caption)
                        .monospacedDigit()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Show in transcript")
                if !chapter.participants.isEmpty {
                    Text(chapter.participants.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Action items with the per-item Target conversion. A converted item
    /// keeps its row (link, not delete — DASH-03 spirit) and shows the
    /// created Target instead of the button.
    private func actionItemsSection(chapterIdx: Int, items: [ChapterActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Action items")
                .font(.subheadline)
                .fontWeight(.medium)
            ForEach(Array(items.enumerated()), id: \.offset) { itemIdx, item in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(.secondary)
                    Text(item.text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let targetID = item.convertedTargetID {
                        Label("Target #\(targetID)", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Already converted to a Target")
                    } else {
                        Button("Target") {
                            onConvertActionItem(chapterIdx, itemIdx)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Create a Target from this action item")
                    }
                }
            }
        }
    }

    private func followupButton(chapterIdx: Int?, label: String) -> some View {
        Button {
            onFollowup(chapterIdx)
        } label: {
            Label(label, systemImage: "paperplane")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private var chaptersFooter: some View {
        if let error = chaptersError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
        HStack(spacing: 8) {
            // Destructive-ish: regeneration replaces the chapters wholesale.
            // Target links are re-keyed onto matching action items by the CLI
            // (CarryConvertedTargets), but items whose text changed lose the
            // link marker — hence the confirmation.
            Button {
                showRegenerateConfirm = true
            } label: {
                Label("Re-generate chapters",
                      systemImage: isGeneratingChapters ? "hourglass" : "arrow.triangle.2.circlepath")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isGeneratingChapters)
            .confirmationDialog(
                "Re-generate chapters?",
                isPresented: $showRegenerateConfirm,
                titleVisibility: .visible
            ) {
                Button("Re-generate", role: .destructive) { onGenerateChapters() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "The current chapters are replaced. Links to created Targets are kept for "
                        + "action items whose text is unchanged; the Targets themselves are never deleted."
                )
            }

            // Recap regeneration must stay reachable once chapters exist —
            // the chapters view replaces the flat recap (with its retry
            // button), and for ad-hoc recordings this is the only path.
            Button {
                onRetryRecap()
            } label: {
                Label(recapContent == nil ? "Generate recap" : "Re-generate recap",
                      systemImage: isRetrying ? "hourglass" : "arrow.triangle.2.circlepath")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isRetrying)
        }
    }

    // MARK: Legacy flat recap

    @ViewBuilder
    private var legacyRecap: some View {
        if let content = recapContent {
            if recapFromOtherSource {
                Label(
                    "Event recap — generated from a different recording or source of this meeting, not from this recording.",
                    systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

        HStack(spacing: 8) {
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

            // Chapters need per-utterance timecodes — the button only shows
            // when segments exist (legacy rows re-transcribe first).
            if hasSegments {
                Button {
                    onGenerateChapters()
                } label: {
                    Label("Generate chapters",
                          systemImage: isGeneratingChapters ? "hourglass" : "sparkles")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isGeneratingChapters)
            }
        }

        if let error = chaptersError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
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

// MARK: - Follow-up draft sheet

/// Copyable follow-up draft (per chapter or whole meeting). The draft is
/// ephemeral: nothing is persisted and nothing is ever auto-sent — the only
/// exit is Copy or Close.
struct FollowupDraftSheet: View {
    let chapterTitle: String?
    let isLoading: Bool
    let errorMessage: String?
    let draft: String
    let onClose: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(chapterTitle.map { "Follow-up: \($0)" } ?? "Follow-up: whole meeting")
                    .font(.headline)
                Spacer()
                Button("Close") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Drafting in your voice…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            } else {
                ScrollView {
                    Text(draft)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 120, maxHeight: 320)
                .background(Color(.textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))

                HStack {
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draft, forType: .string)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(draft.isEmpty)
                }
            }
        }
        .padding(16)
        .frame(width: 440)
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
    /// One-shot chapter → transcript jump: when set, the utterance list
    /// scrolls to this utterance idx and clears the binding (RecordingDetailView
    /// sets it before switching to this tab).
    @Binding var scrollTarget: Int?
    let attendees: [EventAttendee]
    let suggestions: [SpeakerSuggestion]
    let isSuggesting: Bool
    let suggestError: String?
    let suggestNotice: String?
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
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if hasUnnamed || isSuggesting || suggestError != nil || suggestNotice != nil {
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
                            .id(utterance.idx)
                    }
                }
                .padding(12)
            }
            .onAppear { consumeScrollTarget(proxy) }
            .onChange(of: scrollTarget) { _, _ in consumeScrollTarget(proxy) }
        }
    }

    private func consumeScrollTarget(_ proxy: ScrollViewProxy) {
        guard let target = scrollTarget else { return }
        proxy.scrollTo(target, anchor: .top)
        scrollTarget = nil
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
            } else if let suggestNotice {
                // A successful run with nothing to confirm is info, not
                // failure — no red triangle.
                Label(suggestNotice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        let label = Text(speaker)
            .font(.caption)
            .fontWeight(.semibold)
        if speaker == "Я" {
            label.foregroundStyle(Color.accentColor)
        } else {
            Button {
                renameTarget = SpeakerRenameTarget(speaker: speaker)
            } label: {
                label.foregroundStyle(.secondary)
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
                if freeTextIsReserved {
                    Text("«Я» and “Speaker N” are reserved labels")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Rename") { confirm(freeText) }
                    .buttonStyle(.borderedProminent)
                    .disabled(freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || freeTextIsReserved)
            }
        }
        .padding(16)
        .frame(minWidth: 320)
    }

    private var freeTextIsReserved: Bool {
        SpeakerNaming.isReserved(freeText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func confirm(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reserved labels («Я» / "Speaker N") never leave the sheet — a
        // rename to one would merge the cluster into the owner's identity
        // and poison the voice-print base (also guarded in
        // MeetingTranscriptQueries.renameSpeaker).
        guard !trimmed.isEmpty, !SpeakerNaming.isReserved(trimmed) else { return }
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

import SwiftUI
import WatchtowerCore

enum RecordingDetailTab: String, CaseIterable {
    case recap, notes, transcript, chat

    var title: String {
        switch self {
        case .recap: return "Recap"
        case .notes: return "Notes"
        case .transcript: return "Transcript"
        case .chat: return "Chat"
        }
    }
}

/// Single-view screen for one recording: header (title/date/duration/badges,
/// link-to-event, delete) + four tabs. The full transcript row is fetched
/// asynchronously on selection; the chat VM is created lazily on first
/// opening of the Chat tab (perf: opening a recording must not pay for the
/// heavy tabs).
struct RecordingDetailView: View {
    let transcriptID: Int64
    let onDeleted: () -> Void
    let onChanged: () -> Void
    /// Navigate to the Events tab with the given event expanded (linked-event
    /// header tap); the link carries the start time so the host can pin the
    /// event's day into the rendered window first. nil = no navigation
    /// affordance available from this host.
    var onOpenEvent: ((CalendarQueries.EventLink) -> Void)?
    /// Deselects the entry in the host list, dismissing this pane. nil when
    /// embedded under an event header that already carries the close button.
    var onClose: (() -> Void)?

    @Environment(AppState.self) private var appState
    @State private var transcript: MeetingTranscript?
    @State private var utterances: [TranscriptUtterance]?
    @State private var linkedEvent: CalendarQueries.EventLink?
    @State private var recapContent: MeetingRecap.Content?
    /// True when `recapContent` came from the event's `meeting_recaps` row and
    /// that row was generated from a different recording's transcript (or
    /// another source) than this one — the Recap tab needs a provenance note
    /// so it doesn't read like AI hallucination.
    @State private var recapFromOtherSource = false
    /// The `meeting_recaps` row on screen (only when it decoded — otherwise
    /// the tab shows the transcript's own `summary_json`, stamped by
    /// `summary_updated_at`) — feeds `showRecapRefreshHint`.
    @State private var shownRecap: RecordingRecap?
    @State private var chapters: MeetingChapters?
    @State private var tab: RecordingDetailTab = .recap
    @State private var chatVM: MeetingChatViewModel?
    @State private var isRetryingRecap = false
    @State private var showDeleteConfirm = false
    @State private var linkTarget: MeetingTranscript?
    @State private var errorMessage: String?
    @State private var transcriptScrollTarget: Int?
    @State private var followup: FollowupState?

    /// One in-flight follow-up draft request (sheet-scoped, ephemeral by
    /// design — the draft is never persisted; dismissing the sheet discards
    /// it, so no navigation-surviving center is needed).
    struct FollowupState: Identifiable {
        let id = UUID()
        let chapter: Int?
        let chapterTitle: String?
        var draft = ""
        var errorMessage: String?
        var isLoading = true
    }

    private var notesService: TranscriptSaveService? {
        guard let runner = ProcessCLIRunner.makeDefault() else { return nil }
        return TranscriptSaveService(runner: runner)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let transcript {
                header(transcript)
                Picker("", selection: $tab) {
                    ForEach(RecordingDetailTab.allCases, id: \.self) { t in
                        Text(t.title).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

                if let error = errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                }

                tabContent(transcript)
            } else if let error = errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: transcriptID) {
            tab = .recap
            chatVM = nil
            utterances = nil
            chapters = nil
            transcriptScrollTarget = nil
            followup = nil
            await load()
        }
        .sheet(isPresented: Binding(
            get: { followup != nil },
            set: { if !$0 { followup = nil } }
        )) {
            FollowupDraftSheet(
                chapterTitle: followup?.chapterTitle,
                isLoading: followup?.isLoading ?? true,
                errorMessage: followup?.errorMessage,
                draft: followup?.draft ?? ""
            ) { followup = nil }
        }
        .confirmationDialog(
            "Delete this recording?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete recording, notes and chat", role: .destructive) { deleteRecording() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The transcript, its meeting notes, chat and audio file will be removed. This cannot be undone.")
        }
        .sheet(item: $linkTarget) { t in
            LinkTranscriptSheet(transcript: t) {
                Task { await load() }
                onChanged()
            }
            .environment(appState)
        }
    }

    @ViewBuilder
    private func tabContent(_ transcript: MeetingTranscript) -> some View {
        let center = appState.transcriptNotesCenter
        let chaptersCenter = appState.transcriptChaptersCenter
        switch tab {
        case .recap:
            RecordingRecapTab(
                transcript: transcript,
                recapContent: recapContent,
                recapFromOtherSource: recapFromOtherSource,
                chapters: chapters,
                hasSegments: utterances != nil,
                onRetryRecap: retryRecap,
                isRetrying: isRetryingRecap,
                onGenerateChapters: generateChapters,
                isGeneratingChapters: chaptersCenter.generating.contains(transcriptID),
                chaptersError: chaptersCenter.lastError[transcriptID],
                onOpenChapter: openChapterInTranscript,
                onConvertActionItem: convertActionItem,
                onFollowup: generateFollowup)
        case .notes:
            RecordingNotesTab(
                transcript: transcript,
                notesMD: transcript.notesMD,
                onGenerate: generateNotes,
                isGenerating: center.generating.contains(transcriptID),
                generationError: center.lastError[transcriptID],
                onSave: saveNotes)
        case .transcript:
            RecordingTranscriptTab(
                transcriptText: transcript.transcriptText,
                utterances: utterances,
                scrollTarget: $transcriptScrollTarget,
                showRecapRefreshHint: showRecapRefreshHint,
                onSetUtteranceDeleted: setUtteranceDeleted,
                onListenToSamples: { speaker in
                    Task { await appState.voiceRegistryCenter.relabel(transcriptID: transcriptID, clusterLabel: speaker) }
                },
                onRegenerateRecap: retryRecap
            )
        case .chat:
            if let chatVM {
                RecordingChatTab(chatVM: chatVM)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { openChat(transcript) }
            }
        }
    }

    private func header(_ transcript: MeetingTranscript) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(transcript.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                Spacer()
                if transcript.eventID == nil {
                    Button {
                        linkTarget = transcript
                    } label: {
                        Label("Link to event…", systemImage: "link")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Delete recording with all its content")

                if let onClose {
                    // Close affordance for a detail pane — without it the pane
                    // can only be swapped, never dismissed.
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                }
            }
            HStack(spacing: 8) {
                Text(TranscriptFormatting.formattedDate(transcript.createdAt))
                Text(TranscriptFormatting.formatDuration(transcript.durationSec))
                TranscriptLangBadges(langStatsJSON: transcript.langStats)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Linked-event affordance: resolvable event → tappable deep link
            // into the Events tab; event row pruned by sync retention → plain
            // informational label (never an error, never navigation).
            if transcript.eventID != nil {
                LinkedEventHeader(linkedEvent: linkedEvent, onOpenEvent: onOpenEvent)
            }

            // Audio playback (single-slot app-wide center; hidden once the
            // retention phase has swept the file).
            TranscriptAudioControl(transcript: transcript, center: appState.audioPlaybackCenter)
        }
        .padding(12)
    }

    // MARK: - Data

    /// One detail load's off-main fetch result (row + everything derived from
    /// its event), decoded once here so `body` never touches heavy blobs.
    private struct LoadedDetail {
        var row: MeetingTranscript?
        var recap: RecordingRecap?
        var link: CalendarQueries.EventLink?
        var utterances: [TranscriptUtterance]?
        var chapters: MeetingChapters?
    }

    private func load() async {
        guard let db = appState.databaseManager else { return }
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { [transcriptID] in
                try db.dbPool.read { conn -> LoadedDetail in
                    let row = try MeetingTranscriptQueries.fetch(conn, id: transcriptID)
                    // Durable transcript_id link first (survives the event's
                    // deletion), then the event_id lookup, then (below) the
                    // transcript's summary_json.
                    let recap = try MeetingRecapQueries.fetchForRecording(
                        conn, transcriptID: transcriptID, eventID: row?.eventID)
                    var link: CalendarQueries.EventLink?
                    if let eventID = row?.eventID {
                        // Lightweight (title + start_time); nil when the event
                        // row is gone — the header degrades to a plain label.
                        link = try CalendarQueries.fetchEventLink(conn, id: eventID)
                    }
                    return LoadedDetail(row: row, recap: recap, link: link,
                                        utterances: row?.utterances, chapters: row?.parsedChapters)
                }
            }.value
            transcript = loaded.row
            linkedEvent = loaded.link
            // Segments and chapters decoded ONCE here (off-main, alongside
            // the fetch), never in body evaluations or row builders.
            utterances = loaded.utterances
            chapters = loaded.chapters
            // Event recap wins; ad-hoc (or collision-guarded) recap falls back
            // to the transcript's own summary_json. Decoded ONCE here, never
            // in row builders.
            let eventRecapContent = loaded.recap?.recap.parsed
            recapContent = eventRecapContent ?? loaded.row?.parsedSummary
            // An exact source-text match means the event recap WAS generated
            // from this recording's own transcript; anything else (including
            // no event recap at all, or a recap row whose recap_json failed
            // to decode so `parsed` is nil and the tab falls back to this
            // recording's own summary) is either this recording's own
            // summary or none, so no note is needed. Gating on `parsed` (not
            // just `recap != nil`) keeps the note tied to what is actually
            // displayed.
            //
            // Known limitation: this exact-match formula does not survive a
            // later utterance soft-delete, which rewrites `transcript_text`
            // (see `setUtteranceDeleted`) — a recording's own recap can then
            // read as "from a different source" even though nothing else
            // changed. The caption's "different recording or source" wording
            // keeps this only mildly over-cautious; a robust fix would need
            // the originating transcript id persisted on `meeting_recaps`
            // (out of scope here).
            recapFromOtherSource = eventRecapContent != nil
                && loaded.recap?.recap.sourceText != loaded.row?.transcriptText
            shownRecap = eventRecapContent != nil ? loaded.recap : nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Soft delete / undo for one utterance: the transactional
    /// `segments_json` + `transcript_text` rewrite (see
    /// `MeetingTranscriptQueries.setUtteranceDeleted`), then a reload so
    /// every tab sees the rebuilt text. Returns whether the write landed —
    /// the transcript tab gates its "deleted" toast on it.
    private func setUtteranceDeleted(idx: Int, deleted: Bool) -> Bool {
        guard let db = appState.databaseManager else { return false }
        do {
            try db.dbPool.write { conn in
                try MeetingTranscriptQueries.setUtteranceDeleted(
                    conn, id: transcriptID, idx: idx, deleted: deleted)
            }
            // The chat VM snapshots the transcript at init (its system-prompt
            // excerpt is built from that copy) — reset it so the next chat
            // turn is created over the edited text instead of still carrying
            // the deleted utterance. It is recreated lazily on the Chat tab
            // from the reloaded row; the persisted conversation survives.
            chatVM?.cancelStream()
            chatVM = nil
            onChanged()
            Task { await load() }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Whether speaker names changed after the recap on screen was generated
    /// (`MeetingTranscript.recapPredatesSpeakerNames`).
    private var showRecapRefreshHint: Bool {
        transcript?.recapPredatesSpeakerNames(shownRecap: shownRecap) ?? false
    }

    private func openChat(_ transcript: MeetingTranscript) {
        guard let db = appState.databaseManager else { return }
        chatVM = MeetingChatViewModel(
            transcript: transcript, recapContent: recapContent, dbManager: db)
    }

    private func retryRecap() {
        guard let service = notesService else {
            errorMessage = "watchtower CLI not found"
            return
        }
        isRetryingRecap = true
        Task {
            defer { isRetryingRecap = false }
            do {
                _ = try await service.retryRecap(transcriptID: transcriptID)
                await load()
                onChanged()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func generateChapters() {
        guard let service = notesService else {
            errorMessage = "watchtower CLI not found"
            return
        }
        appState.transcriptChaptersCenter.generate(
            transcriptID: transcriptID, service: service
        ) {
            Task { await load() }
            onChanged()
        }
    }

    /// Chapter → transcript jump: scroll target = the first non-deleted
    /// utterance at or after the chapter start, then switch tabs.
    private func openChapterInTranscript(_ chapter: MeetingChapter) {
        if let utterances {
            transcriptScrollTarget = MeetingChapters.firstUtteranceIdx(
                in: utterances, atOrAfter: chapter.startSec)
        }
        tab = .transcript
    }

    /// Action item → Target: one query-layer call
    /// (`MeetingTranscriptQueries.convertActionItemToTarget`) creates the
    /// Target and stamps converted_target_id inside chapters_json in ONE
    /// write transaction (link, not delete — DASH-03 spirit; any stamp
    /// failure rolls the Target insert back), then reloads so the recap tab
    /// shows the converted state.
    private func convertActionItem(chapterIdx: Int, itemIdx: Int) {
        guard let db = appState.databaseManager else { return }
        do {
            _ = try db.dbPool.write { conn in
                try MeetingTranscriptQueries.convertActionItemToTarget(
                    conn, transcriptID: transcriptID,
                    chapterIdx: chapterIdx, itemIdx: itemIdx)
            }
            onChanged()
            Task { await load() }
        } catch MeetingTranscriptQueries.ActionItemConversionError.alreadyConverted {
            // Benign double-click / stale view — reload to show the stamp.
            Task { await load() }
        } catch {
            errorMessage = error.localizedDescription
            Task { await load() }
        }
    }

    /// Follow-up draft (per chapter, or whole meeting when chapterIdx nil):
    /// opens the sheet in its loading state and fills it when the CLI
    /// returns. The draft is shown copyable only — never auto-sent.
    private func generateFollowup(chapterIdx: Int?) {
        guard let service = notesService else {
            errorMessage = "watchtower CLI not found"
            return
        }
        let title = chapterIdx.flatMap { idx in
            chapters.flatMap { $0.chapters.indices.contains(idx) ? $0.chapters[idx].title : nil }
        }
        let state = FollowupState(chapter: chapterIdx, chapterTitle: title)
        followup = state
        Task {
            do {
                let result = try await service.generateFollowup(
                    transcriptID: transcriptID, chapter: chapterIdx)
                guard followup?.id == state.id else { return } // sheet closed/replaced
                followup?.draft = result.draft
                followup?.isLoading = false
            } catch {
                guard followup?.id == state.id else { return }
                followup?.errorMessage = error.localizedDescription
                followup?.isLoading = false
            }
        }
    }

    private func generateNotes() {
        guard let service = notesService else {
            errorMessage = "watchtower CLI not found"
            return
        }
        appState.transcriptNotesCenter.generate(
            transcriptID: transcriptID, service: service
        ) {
            Task { await load() }
            onChanged()
        }
    }

    private func saveNotes(_ markdown: String) {
        guard let db = appState.databaseManager else { return }
        do {
            try db.dbPool.write { conn in
                try MeetingTranscriptQueries.saveNotes(conn, id: transcriptID, markdown: markdown)
            }
            onChanged()
        } catch {
            // The final flush runs as the pane goes away, with nobody left to
            // read `errorMessage`: keep a trace as well.
            NSLog("RecordingDetailView: could not save notes: %@", error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    private func deleteRecording() {
        guard let db = appState.databaseManager else { return }
        do {
            chatVM?.cancelStream()
            if appState.audioPlaybackCenter.activeTranscriptID == transcriptID {
                appState.audioPlaybackCenter.pause()
            }
            let audioPath = try db.dbPool.write { conn in
                try MeetingTranscriptQueries.delete(conn, id: transcriptID)
            }
            // Post-commit, best-effort: the daemon retention phase may have
            // already removed the file — a missing file is success.
            if let audioPath {
                try? FileManager.default.removeItem(atPath: audioPath)
            }
            onDeleted()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

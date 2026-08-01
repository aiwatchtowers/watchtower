import SwiftUI

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

    @Environment(AppState.self) private var appState
    @State private var transcript: MeetingTranscript?
    @State private var utterances: [TranscriptUtterance]?
    @State private var attendees: [EventAttendee] = []
    @State private var recapContent: MeetingRecap.Content?
    @State private var tab: RecordingDetailTab = .recap
    @State private var chatVM: MeetingChatViewModel?
    @State private var isRetryingRecap = false
    @State private var showDeleteConfirm = false
    @State private var linkTarget: MeetingTranscript?
    @State private var errorMessage: String?

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
            await load()
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
        switch tab {
        case .recap:
            RecordingRecapTab(
                transcript: transcript,
                recapContent: recapContent,
                onRetryRecap: retryRecap,
                isRetrying: isRetryingRecap)
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
                attendees: attendees,
                suggestions: appState.speakerGuessCenter.suggestions[transcriptID] ?? [],
                isSuggesting: appState.speakerGuessCenter.generating.contains(transcriptID),
                suggestError: appState.speakerGuessCenter.lastError[transcriptID],
                suggestNotice: appState.speakerGuessCenter.lastNotice[transcriptID],
                onSetUtteranceDeleted: setUtteranceDeleted,
                onSuggestNames: suggestSpeakerNames,
                onRenameSpeaker: renameSpeaker
            ) { speaker in
                appState.speakerGuessCenter.consumeSuggestion(
                    transcriptID: transcriptID, speaker: speaker)
            }
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
            }
            HStack(spacing: 8) {
                Text(TranscriptFormatting.formattedDate(transcript.createdAt))
                Text(TranscriptFormatting.formatDuration(transcript.durationSec))
                TranscriptLangBadges(langStatsJSON: transcript.langStats)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Audio playback (single-slot app-wide center; hidden once the
            // retention phase has swept the file).
            TranscriptAudioControl(transcript: transcript, center: appState.audioPlaybackCenter)
        }
        .padding(12)
    }

    // MARK: - Data

    private func load() async {
        guard let db = appState.databaseManager else { return }
        do {
            let (row, recap, decodedUtterances, eventAttendees) = try await Task.detached(priority: .userInitiated) { [transcriptID] in
                try db.dbPool.read { conn -> (MeetingTranscript?, MeetingRecap?, [TranscriptUtterance]?, [EventAttendee]) in
                    let row = try MeetingTranscriptQueries.fetch(conn, id: transcriptID)
                    var recap: MeetingRecap?
                    var eventAttendees: [EventAttendee] = []
                    if let eventID = row?.eventID {
                        recap = try MeetingRecapQueries.fetch(conn, eventID: eventID)
                        // Attendees feed the rename picker (attendees first,
                        // free text after); ad-hoc recordings have none.
                        eventAttendees = try CalendarQueries.fetchEvent(conn, id: eventID)?.parsedAttendees ?? []
                    }
                    return (row, recap, row?.utterances, eventAttendees)
                }
            }.value
            transcript = row
            // Segments decoded ONCE here (off-main, alongside the fetch),
            // never in body evaluations or row builders.
            utterances = decodedUtterances
            attendees = eventAttendees
            // Event recap wins; ad-hoc (or collision-guarded) recap falls back
            // to the transcript's own summary_json. Decoded ONCE here, never
            // in row builders.
            recapContent = recap?.parsed ?? row?.parsedSummary
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

    /// "Suggest speaker names" (LLM content hints for unnamed clusters) —
    /// runs through the app-wide SpeakerGuessCenter so the in-flight state
    /// and the returned chips survive navigation.
    private func suggestSpeakerNames() {
        guard let service = notesService else {
            errorMessage = "watchtower CLI not found"
            return
        }
        appState.speakerGuessCenter.suggest(transcriptID: transcriptID, service: service)
    }

    /// Manual rename / confirmed suggestion: the transactional
    /// `segments_json` + `transcript_text` + `speakers_json` rewrite plus the
    /// voice-print upsert (one write transaction, see
    /// `MeetingTranscriptQueries.renameSpeaker`), then a reload so every tab
    /// sees the new labels.
    private func renameSpeaker(from: String, to name: String) {
        guard let db = appState.databaseManager else {
            errorMessage = "Database not available"
            return
        }
        do {
            let personKey = SpeakerNaming.personKey(for: name, attendees: attendees)
            let applied = try db.dbPool.write { conn in
                try MeetingTranscriptQueries.renameSpeaker(
                    conn, id: transcriptID, from: from, to: name, personKey: personKey)
            }
            // A stale-state rename (label already gone, reserved name, …)
            // writes nothing — keep the suggestion chip and say so instead of
            // silently consuming it.
            guard applied else {
                errorMessage = "Could not rename \(from) — the transcript may have changed"
                return
            }
            appState.speakerGuessCenter.consumeSuggestion(transcriptID: transcriptID, speaker: from)
            onChanged()
            Task { await load() }
        } catch {
            errorMessage = error.localizedDescription
        }
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

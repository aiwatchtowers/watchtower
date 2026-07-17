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
            RecordingTranscriptTab(transcriptText: transcript.transcriptText)
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
            let (row, recap) = try await Task.detached(priority: .userInitiated) { [transcriptID] in
                try db.dbPool.read { conn -> (MeetingTranscript?, MeetingRecap?) in
                    let row = try MeetingTranscriptQueries.fetch(conn, id: transcriptID)
                    var recap: MeetingRecap?
                    if let eventID = row?.eventID {
                        recap = try MeetingRecapQueries.fetch(conn, eventID: eventID)
                    }
                    return (row, recap)
                }
            }.value
            transcript = row
            // Event recap wins; ad-hoc (or collision-guarded) recap falls back
            // to the transcript's own summary_json. Decoded ONCE here, never
            // in row builders.
            recapContent = recap?.parsed ?? row?.parsedSummary
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

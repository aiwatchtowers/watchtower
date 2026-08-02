import SwiftUI

/// Recordings attached to a calendar event, shown under the recap in
/// `MeetingNotesView`. Each transcript is a `DisclosureGroup` exposing duration,
/// date, per-language window counts, the selectable transcript text, and — when
/// applicable — retry-recap / re-transcribe actions.
struct TranscriptSectionView: View {
    let eventID: String
    /// Whether the event already has a recap; drives whether "Retry recap" shows.
    let hasRecap: Bool
    /// Called after an action changes the DB so the host can refresh its recap.
    let onChanged: () -> Void

    @Environment(AppState.self) private var appState
    @State private var transcripts: [MeetingTranscript] = []
    @State private var errorMessage: String?
    @State private var retryingRecapID: Int64?

    var body: some View {
        Group {
            if !transcripts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .foregroundStyle(.blue)
                        Text("Recordings")
                            .font(.headline)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    ForEach(transcripts, id: \.id) { transcript in
                        transcriptRow(transcript)
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: appState.meetingRecorderCenter.phase) { _, phase in
            // A just-finished transcription lands as a new row once idle — and
            // its save may have generated the event's recap, so the host must
            // refetch too (record → recap appears without reopening the event).
            if case .idle = phase {
                load()
                onChanged()
            }
        }
    }

    private func transcriptRow(_ transcript: MeetingTranscript) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                TranscriptLangBadges(langStatsJSON: transcript.langStats)

                // A transcript saved while the event already had a recap keeps
                // its own recap in summary_json (the Go guard never overwrites
                // the event's) — surface it so it isn't invisible.
                if let summary = transcript.parsedSummary?.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ScrollView {
                    Text(transcript.transcriptText)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)

                TranscriptAudioControl(transcript: transcript, center: appState.audioPlaybackCenter)

                HStack(spacing: 8) {
                    if !hasRecap {
                        Button {
                            retryRecap(transcript)
                        } label: {
                            Label("Retry recap", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(retryingRecapID == transcript.id)
                    }

                    if transcript.audioPath != nil {
                        Button {
                            reTranscribe(transcript)
                        } label: {
                            Label("Re-transcribe", systemImage: "waveform.badge.magnifyingglass")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(appState.meetingRecorderCenter.isBusy)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Text(TranscriptFormatting.formatDuration(transcript.durationSec))
                    .font(.callout)
                Text(TranscriptFormatting.formattedDate(transcript.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func retryRecap(_ transcript: MeetingTranscript) {
        guard let id = transcript.id, let runner = ProcessCLIRunner.makeDefault() else { return }
        retryingRecapID = id
        Task {
            defer { retryingRecapID = nil }
            do {
                _ = try await TranscriptSaveService(runner: runner).retryRecap(transcriptID: id)
                load()
                onChanged()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reTranscribe(_ transcript: MeetingTranscript) {
        guard let audioPath = transcript.audioPath else { return }
        let center = appState.meetingRecorderCenter
        center.prepareRetry(
            audioURL: URL(fileURLWithPath: audioPath),
            eventID: transcript.eventID,
            title: transcript.title
        )
        Task {
            await center.retryTranscription(config: .fromDefaults())
            load()
            onChanged()
        }
    }

    // MARK: - Data

    private func load() {
        guard let db = appState.databaseManager else { return }
        do {
            transcripts = try db.dbPool.read { conn in
                try MeetingTranscriptQueries.fetchForEvent(conn, eventID: eventID)
            }
        } catch {
            // Render-nothing on failure, but never silently: an empty section
            // and a failed read must be distinguishable in the logs.
            print("TranscriptSectionView load failed: \(error)")
        }
    }
}

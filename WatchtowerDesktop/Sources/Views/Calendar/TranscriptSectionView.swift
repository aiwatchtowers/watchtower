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
            // A just-finished transcription lands as a new row once idle.
            if case .idle = phase { load() }
        }
    }

    private func transcriptRow(_ transcript: MeetingTranscript) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                langBadges(transcript)

                ScrollView {
                    Text(transcript.transcriptText)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)

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
                Text(formatDuration(transcript.durationSec))
                    .font(.callout)
                Text(formattedDate(transcript.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func langBadges(_ transcript: MeetingTranscript) -> some View {
        HStack(spacing: 6) {
            ForEach(decodeLangStats(transcript.langStats), id: \.0) { lang, count in
                Text("\(lang.uppercased()) \(count)")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.1), in: Capsule())
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
            // Silent: table may not exist yet on older DB schema versions.
        }
    }

    private func decodeLangStats(_ json: String) -> [(String, Int)] {
        guard let data = json.data(using: .utf8),
              let stats = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return []
        }
        return stats.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return minutes > 0 ? "\(minutes)m \(secs)s" : "\(secs)s"
    }

    private func formattedDate(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) else { return iso }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

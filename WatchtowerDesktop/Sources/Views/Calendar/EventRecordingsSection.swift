import SwiftUI

/// "Recordings" block inside the expanded calendar-event row: loads the
/// event's linked transcripts and renders one compact row each (date,
/// duration, recap/notes badges). Hidden entirely when the event has no
/// recordings. Tapping a row jumps to the Recordings tab with that recording
/// selected (via `onOpen` — the host owns the mode/selection state).
struct EventRecordingsSection: View {
    let eventID: String
    let onOpen: (Int64) -> Void

    @Environment(AppState.self) private var appState
    @State private var transcripts: [MeetingTranscript] = []
    @State private var hasEventRecap = false

    var body: some View {
        EventRecordingRows(
            transcripts: transcripts, hasEventRecap: hasEventRecap, onOpen: onOpen
        )
        .onAppear(perform: load)
    }

    private func load() {
        guard let db = appState.databaseManager else { return }
        do {
            (transcripts, hasEventRecap) = try db.dbPool.read { conn in
                (try MeetingTranscriptQueries.fetchForEvent(conn, eventID: eventID),
                 try MeetingRecapQueries.fetch(conn, eventID: eventID) != nil)
            }
        } catch {
            // Silent: table may not exist yet on older DB schema versions.
        }
    }
}

/// Presentation-only rows, split from the loading container for testability
/// (mirrors the RecordingsListView pattern). Renders nothing at all when
/// `transcripts` is empty — the section must not leave a stray header.
struct EventRecordingRows: View {
    let transcripts: [MeetingTranscript]
    /// Whether the event has a `meeting_recaps` row — the recap badge shows on
    /// every row even when the transcript's own summary_json is empty (the
    /// recap collision guard can put the recap in either place).
    let hasEventRecap: Bool
    let onOpen: (Int64) -> Void

    var body: some View {
        if !transcripts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("Recordings", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(transcripts, id: \.id) { transcript in
                    row(transcript)
                }
            }
            .padding(.top, 2)
        }
    }

    private func row(_ transcript: MeetingTranscript) -> some View {
        Button {
            if let id = transcript.id { onOpen(id) }
        } label: {
            HStack(spacing: 8) {
                Text(TranscriptFormatting.formattedDate(transcript.createdAt))
                Text(TranscriptFormatting.formatDuration(transcript.durationSec))
                if transcript.notesMD != nil {
                    Image(systemName: "doc.text")
                        .help("Has meeting notes")
                }
                if hasEventRecap || transcript.summaryJSON != nil {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.purple)
                        .help("Has AI recap")
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open in Recordings")
    }
}

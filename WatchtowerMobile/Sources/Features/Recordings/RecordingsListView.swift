import SwiftUI

/// The Recordings list (spec §13 C3): "In progress" (sending, waiting for
/// the Mac to wake, transcribing on Mac) and "Earlier" (ready recaps,
/// newest first). A ready row opens its recap; a failed upload offers
/// Retry. The heartbeat goes stale with time alone, so the list re-renders
/// every 30 s.
struct RecordingsListView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(RecordingsListModel(
                recordings: env.phoneRecordings.snapshot,
                replica: env.calendarReplica.snapshot,
                seen: env.recordingsSeen.value,
                now: context.date,
                calendar: .current
            ))
        }
        .navigationTitle("Recordings")
        .refreshable { await env.refresh() }
    }

    private func content(_ model: RecordingsListModel) -> some View {
        List {
            if let empty = model.emptyText {
                Text(empty).foregroundStyle(.secondary)
            }
            if !model.inProgress.isEmpty {
                Section("In progress") {
                    ForEach(model.inProgress) { row($0) }
                }
            }
            if !model.earlier.isEmpty {
                Section("Earlier") {
                    ForEach(model.earlier) { row($0) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: RecordingEntry) -> some View {
        if let transcriptID = entry.transcriptID {
            NavigationLink(value: CalendarRoute.recap(transcriptID)) {
                RecordingRow(entry: entry)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(entry.accessibilityLabel)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                RecordingRow(entry: entry)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(entry.accessibilityLabel)
                if entry.offersRetry, let id = entry.phoneRecordingID {
                    Button("Retry") {
                        Task { await env.recorder.retry(id: id) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel("Retry sending \(entry.title)")
                }
            }
        }
    }
}

/// Icon, title, subtitle and the coloured state line.
private struct RecordingRow: View {
    let entry: RecordingEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(entry.tone.color)
                .frame(width: 40, height: 40)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title).font(.body.weight(.medium)).lineLimit(1)
                    if entry.isNew {
                        Circle().fill(PhoneTone.accent.color).frame(width: 7, height: 7)
                    }
                }
                Text(entry.subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                Text(entry.statusText).font(.footnote).foregroundStyle(entry.tone.color).lineLimit(2)
            }
        }
        .frame(minHeight: 44)
    }

    private var icon: String {
        switch entry.state {
        case .recordingOnPhone: "record.circle"
        case .sending: "arrow.up.circle"
        case .waitingForMac: "clock"
        case .sendFailed, .macFailed: "exclamationmark.triangle"
        case .onMac: "waveform"
        case .ready: "checkmark"
        }
    }
}

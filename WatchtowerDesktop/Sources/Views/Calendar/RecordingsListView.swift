import SwiftUI

/// Master list of all recordings (ad-hoc + event-linked), newest first.
/// Presentation-only: the parent owns loading and selection.
struct RecordingsListView: View {
    let items: [RecordingListItem]
    @Binding var selectedID: Int64?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.blue)
                    Text("Recordings")
                        .font(.title2)
                        .fontWeight(.bold)
                    Spacer()
                }

                if items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No recordings yet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("Record a meeting from the Events tab — it will appear here.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }

                ForEach(items) { item in
                    row(item)
                }
            }
            .padding()
        }
    }

    private func row(_ item: RecordingListItem) -> some View {
        let isSelected = selectedID == item.id
        return Button {
            selectedID = isSelected ? nil : item.id
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: item.eventID == nil ? "waveform" : "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.title)
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer()
                    if item.hasNotes {
                        Image(systemName: "doc.text")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Has meeting notes")
                    }
                    if item.hasRecap {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                            .help("Has AI recap")
                    }
                }
                HStack(spacing: 8) {
                    Text(TranscriptFormatting.formattedDate(item.createdAt))
                    Text(TranscriptFormatting.formatDuration(item.durationSec))
                    TranscriptLangBadges(langStatsJSON: item.langStats)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !item.snippet.isEmpty {
                    Text(item.snippet)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

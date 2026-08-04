import SwiftUI

/// List row for a standalone `.recording` entry in the unified Meetings list
/// (ad-hoc recording, or one whose linked event was pruned by sync
/// retention). Visual weight matches `CalendarEventRow`.
struct MeetingRecordingRow: View {
    let item: RecordingListItem
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "waveform")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.callout)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(TranscriptFormatting.formattedDate(item.createdAt))
                    Text(TranscriptFormatting.formatDuration(item.durationSec))
                    TranscriptLangBadges(langStatsJSON: item.langStats)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 4) {
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
        }
        .padding(8)
        .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 8))
    }

    private var backgroundStyle: Color {
        isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.04)
    }
}

import Foundation
import SwiftUI

/// Shared formatting for meeting-transcript rows, used by both
/// `TranscriptSectionView` (event-linked recordings) and `CalendarEventsView`
/// (ad-hoc recordings) so duration/date/language-badge rendering can't drift
/// between the two entry points.
enum TranscriptFormatting {
    static func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return minutes > 0 ? "\(minutes)m \(secs)s" : "\(secs)s"
    }

    static func formattedDate(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) else { return iso }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func decodeLangStats(_ json: String) -> [(String, Int)] {
        guard let data = json.data(using: .utf8),
              let stats = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return []
        }
        return stats.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }
}

/// Per-language window-count badges (e.g. "RU 4  EN 2") for a transcript's
/// `langStats` JSON blob.
struct TranscriptLangBadges: View {
    let langStatsJSON: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(TranscriptFormatting.decodeLangStats(langStatsJSON), id: \.0) { lang, count in
                Text("\(lang.uppercased()) \(count)")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.1), in: Capsule())
            }
        }
    }
}

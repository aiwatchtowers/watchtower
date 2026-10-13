import Foundation
import SwiftUI

/// Settings' one "Your Mac" row (design pass spec §3 bug 10): the Mac's
/// name, else "Mac", on the left; "Online", "Offline · seen 3 min. ago" or
/// "Not connected" with a dot in the tone on the right. Green only while
/// online, otherwise secondary; never orange.
struct MacStatusRow: Equatable {
    let label: String
    let value: String
    let tone: PhoneTone

    init(status: MacStatus, now: Date, locale: Locale = .current) {
        let name = status.macName ?? ""
        label = name.isEmpty ? "Mac" : name
        switch status {
        case .notConnected:
            value = "Not connected"
            tone = .secondary
        case .online:
            value = "Online"
            tone = .green
        case let .offline(_, lastSeen):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            formatter.dateTimeStyle = .named
            formatter.locale = locale
            value = "Offline · seen \(formatter.localizedString(for: lastSeen, relativeTo: now))"
            tone = .secondary
        }
    }

    var toneUse: ToneUse {
        ToneUse(element: "settings mac status", tone: tone, role: .mac)
    }
}

/// The Your Mac row (bug 10): the name on the left and the dot and state on
/// the right, on one line. A name too long for that gets the state on a
/// second line under it, instead of either truncating (Phases 1–2 review).
struct MacStatusRowView: View {
    let row: MacStatusRow

    var body: some View {
        ViewThatFits(in: .horizontal) {
            LabeledContent {
                status
            } label: {
                Text(row.label).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(row.label)
                status.foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var status: some View {
        HStack(spacing: Spacing.compact) {
            Circle().fill(row.tone.color).frame(width: 8, height: 8)
            Text(row.value).lineLimit(1)
        }
    }
}

/// Settings' Last sync value (design pass SET2): "3 min. ago", "Just now"
/// under a minute, or "Never".
/// Relative to the moment it is drawn; the row's 30 s TimelineView redraws
/// it.
enum LastSyncText {
    static func string(_ last: Date?, now: Date = Date(), locale: Locale = .current) -> String {
        guard let last else { return "Never" }
        if now.timeIntervalSince(last) < 60 { return "Just now" }
        // RelativeFormatStyle measures against the real clock (no anchor
        // before iOS 18), so shift `last` by how far `now` is from it.
        let shifted = last.addingTimeInterval(Date().timeIntervalSince(now))
        return shifted.formatted(Date.RelativeFormatStyle(presentation: .named, unitsStyle: .abbreviated, locale: locale))
    }
}

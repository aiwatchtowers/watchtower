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

/// The This Mac row (mockup 16): the Mac's name with the status dot in its
/// tone, the state trailing, on one `SettingsRow`.
struct MacStatusRowView: View {
    let row: MacStatusRow

    var body: some View {
        SettingsRow(title: row.label, leadingDot: row.tone) {
            Text(row.value)
        }
        .accessibilityValue(row.value)
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

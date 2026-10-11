import Foundation

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

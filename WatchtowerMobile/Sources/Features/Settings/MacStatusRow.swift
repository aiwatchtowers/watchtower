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

/// Where the Mac is, for the screens that act on it (spec §5.6): online
/// while its heartbeat is under 2100 s old (`MacStatus.isOnline`, the rule
/// Settings' row reads; one stamped ahead of the phone's clock is online),
/// asleep with an older heartbeat from a still-linked Mac, offline with no
/// heartbeat or no link.
enum MacReachability: Equatable {
    case online
    case asleep(lastSeen: Date)
    case offline

    static func of(heartbeat: Date?, linked: Bool, now: Date) -> Self {
        guard linked, let heartbeat else { return .offline }
        return MacStatus.isOnline(lastHeartbeat: heartbeat, now: now) ? .online : .asleep(lastSeen: heartbeat)
    }

    var isOnline: Bool { self == .online }

    /// The last contact a live state is "as of" while the Mac is asleep.
    var asOf: Date? {
        if case let .asleep(lastSeen) = self { return lastSeen }
        return nil
    }

    /// The Mac status chip's state; an unlinked phone has no Mac to name.
    func chipState(linked: Bool) -> MacChipState {
        switch self {
        case .online: .online
        case let .asleep(lastSeen): .asleep(lastSeen: lastSeen)
        case .offline: linked ? .offline(lastSeen: nil) : .notLinked
        }
    }
}

/// The workchat's banner while the Mac is not online (mockup 8): "**Your
/// Mac is asleep** · last seen 12 min ago. New lines go when it wakes."
struct MacAwayBanner: Equatable {
    let title: String
    let detail: String

    init?(_ mac: MacReachability, now: Date) {
        switch mac {
        case .online:
            return nil
        case let .asleep(lastSeen):
            title = "Your Mac is asleep"
            detail = " · last seen \(LastSeen.phrase(lastSeen, now: now)). New lines go when it wakes."
        case .offline:
            title = "Your Mac is offline"
            detail = ". New lines go when it is back."
        }
    }

    var text: String { title + detail }
}

extension AppEnvironment {
    /// The active Mac's reachability at `now`, from its heartbeat and link.
    func macReachability(now: Date) -> MacReachability {
        .of(heartbeat: workbenchReplica.snapshot.heartbeat?.updatedAt, linked: linkedDevice != nil, now: now)
    }

    /// The Mac status chip of Now and the Calendar (mockups 1, 7).
    func macChip(now: Date) -> MacStatusChipModel {
        let linked = linkedDevice != nil
        return MacStatusChipModel(
            macName: workbenchReplica.snapshot.heartbeat?.macName ?? "",
            state: macReachability(now: now).chipState(linked: linked),
            now: now
        )
    }
}

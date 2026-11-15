import Foundation

/// Every word the switcher puts on screen (#1782), built from one hub word so
/// the app-wide rename (#1783) changes this feature in one place.
enum HubSwitcherText {
    static let hubWord = TowerText.word
    static let hubWordPlural = TowerText.plural

    /// The list's title.
    static let sheetTitle = TowerText.pluralTitle
    /// The line above the rows: what a pick does.
    static let sheetNote = "Pick the \(hubWord) this iPhone shows. Every tab switches to it."
    /// The list's last row.
    static let addRow = "Add \(hubWord)"
    static func limitNote(_ limit: Int) -> String { "You can link up to \(limit) \(hubWordPlural)" }

    static let chipHint = "Shows your \(hubWordPlural) and switches between them"
    static let currentLabel = "Showing now"

    /// "1 question", "2 questions".
    static func questions(_ count: Int) -> String { count == 1 ? "1 question" : "\(count) questions" }

    /// The chip's line for the asks on the other hubs: "+1 question on Home
    /// Mac" when they all wait on one, "+3 questions on 2 other Macs" when
    /// they are spread.
    static func otherAsks(_ count: Int, hubs: [String]) -> String {
        hubs.count == 1
            ? "+\(questions(count)) on \(hubs[0])"
            : "+\(questions(count)) on \(hubs.count) other \(hubWordPlural)"
    }

    /// A list row's asks line: "2 questions waiting".
    static func waiting(_ count: Int) -> String { "\(questions(count)) waiting" }

    /// A list row's state, as the status chip says it: "online", "asleep ·
    /// 40 min ago", "offline" (never a heartbeat), "Removed this phone".
    static func status(_ item: HubListItem, now: Date) -> String {
        if item.removedByMac { return "Removed this phone" }
        if item.online { return "online" }
        guard let heartbeat = item.lastHeartbeat else { return "offline" }
        return "asleep · \(LastSeen.phrase(heartbeat, now: now))"
    }
}

/// The switcher chip under each tab's title (#1782): the status chip of the
/// hub on screen ("● Acme Mac · online"), a ▾ and a tap only when more than
/// one hub is linked, and the questions waiting on the other hubs in words.
struct HubSwitcherChipModel: Equatable {
    let status: MacStatusChipModel
    /// More than one hub is linked: the chip opens the list.
    let switches: Bool
    /// "+1 question on Home Mac"; nil when no other hub waits.
    let otherAsks: String?
    let accessibilityLabel: String

    /// `name` is the hub on screen's list name (with its duplicate suffix),
    /// else its heartbeat's; `items` are the switcher's rows.
    init(name: String, state: MacChipState, items: [HubListItem], now: Date) {
        status = MacStatusChipModel(macName: name, state: state, now: now)
        switches = items.count > 1
        let waiting = items.filter { !$0.isActive && $0.asksCount && $0.openAsks > 0 }
        let count = waiting.reduce(0) { $0 + $1.openAsks }
        otherAsks = count > 0 ? HubSwitcherText.otherAsks(count, hubs: waiting.map(\.name)) : nil
        accessibilityLabel = [status.text, otherAsks].compactMap(\.self).joined(separator: ". ")
    }

    var toneUses: [ToneUse] {
        [status.toneUse] + (otherAsks == nil ? [] : [
            ToneUse(element: "other hubs' questions", tone: .waitingForYou, role: .waiting)
        ])
    }
}

/// One row of the switcher's list (#1782).
struct HubSwitcherRowModel: Equatable, Identifiable {
    let id: String
    let name: String
    let status: String
    let dotTone: PhoneTone
    let flavor: String?
    /// "2 questions waiting"; nil with none, or on a hub whose asks don't
    /// count (`HubListItem.asksCount`).
    let waiting: String?
    let lines: [String]
    let isActive: Bool
    let isEnabled: Bool

    init(_ item: HubListItem, now: Date) {
        id = item.id
        name = item.name
        status = HubSwitcherText.status(item, now: now)
        dotTone = item.online ? .green : item.lastHeartbeat == nil || item.removedByMac ? .secondary : .gray
        flavor = item.flavor
        waiting = item.openAsks > 0 && item.asksCount ? HubSwitcherText.waiting(item.openAsks) : nil
        lines = [item.transportLine, item.termLine, item.problem].compactMap(\.self)
        isActive = item.isActive
        // A hub whose data could not be opened never goes on screen: Forget
        // it in Settings → Macs.
        isEnabled = !item.unopened
    }

    var toneUses: [ToneUse] {
        [ToneUse(element: "hub \(id) dot", tone: dotTone, role: .mac)] + (waiting == nil ? [] : [
            ToneUse(element: "hub \(id) questions", tone: .waitingForYou, role: .waiting)
        ])
    }
}

/// What the phone tells the owner about its link outside a scan (spec §9).
enum LinkNotice: Equatable {
    /// `TransportEvent.unlinked`: the Mac removed this phone.
    case removed
    /// The heartbeat's `hub_id` is another hub's.
    case moved(macName: String)
    /// No heartbeat for a day.
    case stale
    /// The unlink wiped outbox items and recordings the Mac never got.
    case notSent(Int)

    var message: String {
        switch self {
        case .removed: "This Mac removed this phone"
        case let .moved(macName): "Watchtower moved to \(macName) — scan the code on that Mac"
        case .stale: "Your Mac hasn't synced for a day — if it changed iCloud account, link again"
        case let .notSent(count):
            count == 1
                ? "Not sent: 1 item was still waiting for your Mac"
                : "Not sent: \(count) items were still waiting for your Mac"
        }
    }
}

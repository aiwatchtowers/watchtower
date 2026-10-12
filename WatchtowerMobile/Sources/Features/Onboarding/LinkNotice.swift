/// What the phone tells the owner about its link outside a scan (spec §9).
enum LinkNotice: Equatable {
    /// `TransportEvent.unlinked`: the Mac removed this phone.
    case removed
    /// The heartbeat's `hub_id` is another hub's.
    case moved(macName: String)
    /// No heartbeat for a day.
    case stale
    /// The unlink wiped outbox items (and recordings whose audio is gone)
    /// the Mac never got.
    case notSent(Int)
    /// The link ended during a capture: it was stopped and kept, and goes
    /// to the Mac after the next link. Carries the wipe's "Not sent" count.
    case recordingKept(notSent: Int)

    /// What a wipe reports, or nil when it lost nothing and stopped no
    /// capture.
    static func after(_ wipe: LocalWipe) -> Self? {
        if wipe.stoppedRecording { return .recordingKept(notSent: wipe.notSent) }
        return wipe.notSent > 0 ? .notSent(wipe.notSent) : nil
    }

    var message: String {
        switch self {
        case .removed: "This Mac removed this phone"
        case let .moved(macName): "Watchtower moved to \(macName) — scan the code on that Mac"
        case .stale: "Your Mac hasn't synced for a day — if it changed iCloud account, link again"
        case let .notSent(count):
            Self.notSentText(count)
        case let .recordingKept(notSent):
            "The link ended during a recording. It's saved on this iPhone and goes to your Mac after you link again"
                + (notSent > 0 ? ". \(Self.notSentText(notSent))" : "")
        }
    }

    private static func notSentText(_ count: Int) -> String {
        count == 1
            ? "Not sent: 1 item was still waiting for your Mac"
            : "Not sent: \(count) items were still waiting for your Mac"
    }
}

/// What the phone tells the owner about its link outside a scan (spec §9).
enum LinkNotice: Equatable {
    /// `TransportEvent.unlinked` or the Mac's deleted grant: the Mac
    /// removed this phone. `notSent`: the outbox items and recordings the
    /// wipe dropped before the Mac got them.
    case removed(notSent: Int = 0)
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

    /// Recordings could not be handed over or restored (`LocalWipe.problem`),
    /// with the wipe's "Not sent" count.
    case recordingsProblem(String, notSent: Int)

    /// What a wipe reports: a recording problem first, then a capture it
    /// stopped and kept, else `otherwise` (by default the "Not sent" count,
    /// or nil when nothing was lost).
    static func after(_ wipe: LocalWipe, otherwise: Self? = nil) -> Self? {
        if let problem = wipe.problem { return .recordingsProblem(problem, notSent: wipe.notSent) }
        if wipe.stoppedRecording { return .recordingKept(notSent: wipe.notSent) }
        if let otherwise { return otherwise }
        return wipe.notSent > 0 ? .notSent(wipe.notSent) : nil
    }

    var message: String {
        switch self {
        case let .removed(notSent):
            "This Mac removed this phone" + (notSent > 0 ? " — \(Self.notSentText(notSent))" : "")
        case let .moved(macName): "Watchtower moved to \(macName) — scan the code on that Mac"
        case .stale: "Your Mac hasn't synced for a day — if it changed iCloud account, link again"
        case let .notSent(count):
            Self.notSentText(count)
        case let .recordingKept(notSent):
            "The link ended during a recording. It's saved on this iPhone and goes to your Mac after you link it again"
                + (notSent > 0 ? ". \(Self.notSentText(notSent))" : "")
        case let .recordingsProblem(problem, notSent):
            problem + (notSent > 0 ? ". \(Self.notSentText(notSent))" : "")
        }
    }

    private static func notSentText(_ count: Int) -> String {
        count == 1
            ? "Not sent: 1 item was still waiting for your Mac"
            : "Not sent: \(count) items were still waiting for your Mac"
    }
}

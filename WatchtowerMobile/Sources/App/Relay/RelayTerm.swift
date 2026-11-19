import Foundation

/// The term on a relay-only link the relay refuses (relay client Phase 5, Task 17, asks #1082, #1093, #1098, #1100):
/// the link ends `length` after the first refusal (`RelayRefusedRecord.since`, fixed), once two answered account reads
/// at least `secondReadAfter` apart show the refusal standing, in the foreground only.
enum RelayTerm {
    /// About 21 days from the first refusal (ask #1082): the link's term, shown as a date from the first refusal (S61).
    static let length: TimeInterval = 21 * 86_400
    /// G2's `NoPayerPoll` (ask #1100): two reads of the same fact, apart.
    static let secondReadAfter: TimeInterval = 5 * 60

    /// The day the link ends if the refusal stands.
    static func date(of refused: RelayRefusedRecord) -> Date {
        refused.since.addingTimeInterval(length)
    }

    /// The term is due: a relay link the relay refuses, past its date. A link with only `macMoved` has no term
    /// (ask #1098: a paying phone holding the slot is refused nothing).
    static func isDue(_ link: LinkRecord, now: Date) -> Bool {
        guard link.transport == .relay, let refused = link.relayRefused else { return false }
        return now >= date(of: refused)
    }

    /// A held purchase or a refused row may hold this link's term only on a needs-Relay link: the cause `.lapse` with no
    /// known move. A purchase brings back neither a lost slot nor a moved Mac (ask #1100).
    static func purchaseHolds(_ link: LinkRecord) -> Bool {
        link.relayRefused?.cause == .lapse && link.macMoved == nil
    }
}

/// What may hold a refused link's term, as the account center knows it (`RelayAccountCenter.termHold`): nothing, a
/// purchase this phone paid that the relay has not seen (`held`), or one the relay refused for a reason not about the
/// payment (`refusedRow`: `transferLimit`, `notImplemented`, `updateRequired`).
enum RelayTermHold: Equatable {
    case none, held, refusedRow
}

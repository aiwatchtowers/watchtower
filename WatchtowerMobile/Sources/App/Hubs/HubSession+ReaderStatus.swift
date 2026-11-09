import Foundation
import os
import WatchtowerSync

// The relay reader status of a session (relay client Phase 5): the link's term, a lost slot, and the `hub_on_relay`
// sighting `runsOnRelay()` reads.

private let readerStatusLogger = Logger(subsystem: "WatchtowerMobile", category: "HubSession")

extension HubSession {
    /// The link's term in the foreground (relay client Phase 5, Task 17, S60): once due (`RelayTerm.isDue`) and with no
    /// recording held by this hub's recorder, `check` reads the account for this Mac (`RelayAccountCenter.termCheck`).
    /// A refusal that stands is written as the term's first read and ends nothing; a later one at least
    /// `RelayTerm.secondReadAfter` after it answers true: the caller ends the link. Anything else waits for a later
    /// foreground; the first read stays on the row across launches.
    func runTerm(
        now: @MainActor () -> Date,
        check: (_ mac: String, _ purchaseHolds: @escaping @MainActor () -> Bool) async -> RelayAccountCenter.TermAnswer
    ) async -> Bool {
        guard let link = linkOnRow?(), RelayTerm.isDue(link, now: now()), let mac = link.relayMacDeviceID else { return false }
        guard !recorder.holdsMicrophoneOrScreen else { return false }
        // Asked after the read, on the row as the read left it (review I1).
        let holds: @MainActor () -> Bool = { [weak self] in self?.linkOnRow?().map(RelayTerm.purchaseHolds) ?? false }
        guard await check(mac, holds) == .refusalStands else { return false }
        // Read again after the account call: the read may have cleared the mark or changed its cause.
        guard var fresh = linkOnRow?(), var refused = fresh.relayRefused else { return false }
        guard let first = refused.termReadAt else {
            refused.termReadAt = now()
            fresh.relayRefused = refused
            if writeLinkOnRow?(fresh) != true { readerStatusLogger.error("the term's first read was not saved") }
            return false
        }
        return now().timeIntervalSince(first) >= RelayTerm.secondReadAfter
    }

    /// The relay account answered with this hub's Mac in none of this phone's slots while it is on the relay (relay
    /// client Phase 5, `RelayAccountCenter`): `TransportFollowerPolicy.decide(.slotLost)` withdraws its unechoed
    /// actions and, with an iCloud route, moves there.
    func relaySlotLost() async {
        await transportRequester?.slotLost()
    }

    /// The Mac's relay device id while this session runs over the relay; nil on iCloud.
    var relayMacDeviceID: String? {
        if case .hostedRelay(let mac) = route { return mac }
        return nil
    }
}

/// Whether a `hub_on_relay` control was read, set from the relay feed's actor.
final class HubOnRelaySighting: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var seen: Bool { lock.withLock { value } }

    func note() {
        lock.withLock { value = true }
    }

    /// The hub moved on since: the sighting no longer holds (`HubSession.forgetHubOnRelay`).
    func forget() {
        lock.withLock { value = false }
    }
}

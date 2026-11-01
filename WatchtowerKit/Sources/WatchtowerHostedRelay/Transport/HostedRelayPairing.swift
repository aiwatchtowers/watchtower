import Foundation
import os
import WatchtowerRelayProto

/// The relay's own limits the phone checks before asking (relay spec §8).
public enum HostedRelayLimits {
    /// Macs one account holds in slots (Worker `limits.maxMacSlots`).
    public static let maxMacSlots = 3
}

/// The phone's account ops of linking over the relay (R3 of Phase 3; relay `proto/README.md`
/// "Slots", "Vouched hubs", Worker `do/account/pairing.ts` / `slots.ts`): `get_account_state`,
/// `open_pairing`, `vouch_hub`, `promote_pairing`, `close_pairing`, `remove_slot`. The hello and keybox themselves go through a
/// `HostedRelayTransport` in `.pairing(slot:)` mode. Every call is one HTTPS op on the session's
/// client (its login and `UNAVAILABLE` retry); no socket is opened.
///
/// The answers a linking screen acts on are thrown as `Refusal`; any other error is rethrown as
/// the client threw it (`NOT_FOUND` of a closed or replaced slot, `FORBIDDEN`, ...).
public struct HostedRelayPairing: Sendable {
    static let logger = Logger(subsystem: "WatchtowerKit", category: "HostedRelay")

    public enum Refusal: Error, Equatable, Sendable {
        /// `ENTITLEMENT_INACTIVE`: the account is neither active nor in grace.
        case notPaying
        /// The account holds `HostedRelayLimits.maxMacSlots` Macs (`SLOT_LIMIT`): these.
        case slotsFull(macs: [String])
        /// `SLOT_REPLACEMENT_LIMIT`: too many new Macs after removals in 30 days.
        case replacementLimit
        /// `PAIRING_EXPIRED`: the slot's 600 s ran out before promote.
        case pairingExpired
        /// No answer (or `UNAVAILABLE` past its retries, a 5xx).
        case unreachable
        /// `UNSUPPORTED_VERSION`, or App Attest asks for an app update.
        case updateRequired
        /// App Attest failed transiently: no relay call before `until`.
        case attestationBackoff(until: Date)
    }

    /// The answers of `vouch` a linking flow acts on (relay `proto/README.md` "Client rules (phone)").
    public enum VouchRefusal: Error, Equatable, Sendable {
        /// `ENTITLEMENT_INACTIVE`: the subscription screen (Phase 4); the link waits.
        case notPaying
        /// `ATTESTATION_REQUIRED`, `ATTESTATION_FAILED` after the retries, `UNSUPPORTED_VERSION`.
        case updateRequired
        /// `NOT_FOUND`: the hub has not registered on the relay (keep it open and retry).
        case hubNotOnRelay
        /// `SLOT_LIMIT`: the account holds 3 other Macs.
        case slotsFull
        /// `FORBIDDEN`: cannot happen for a phone session; logged.
        case notConfirmed
        /// No answer, `UNAVAILABLE` past its retries, a 5xx.
        case unreachable
        /// App Attest failed transiently: no relay call before `until`.
        case attestationBackoff(until: Date)
    }

    let session: HostedRelaySession

    public init(session: HostedRelaySession) {
        self.session = session
    }

    private var client: HostedRelayClient {
        session.client
    }

    /// `get_account_state`: paying (active or grace), the Macs in slots.
    public func accountState() async throws -> (paying: Bool, macs: [String]) {
        let state = try await refusing("getAccountState") { try await client.accountState() }
        let paying = state.entitlement.state == .active || state.entitlement.state == .grace
        return (paying, state.macDeviceIds)
    }

    /// Refuses `.slotsFull` before any request when 3 Macs hold slots and `mac` is not one of them;
    /// else `open_pairing`. A second open for the same Mac replaces its open slot (Worker
    /// `pairing.ts`): the old slot's promote answers `NOT_FOUND`.
    public func open(mac: String) async throws -> (slot: String, expiresAt: Date) {
        let macs = try await accountState().macs
        if macs.count >= HostedRelayLimits.maxMacSlots, !macs.contains(mac) {
            Self.logger.info("relay open_pairing: slots full, not asked")
            throw Refusal.slotsFull(macs: macs)
        }
        var request = Relay_V1_OpenPairingSlot()
        request.macDeviceID = mac
        let slot = try await refusing("openPairing") { try await client.openPairing(request) }
        return (slot.slotID, Date(timeIntervalSince1970: TimeInterval(slot.expiresAtMs) / 1000))
    }

    /// `promote_pairing`: the slot's Mac goes into the account's slots and the slot closes.
    public func promote(slot: String) async throws {
        var request = Relay_V1_PromotePairing()
        request.slotID = slot
        try await refusing("promotePairing") { try await client.promotePairing(request) }
    }

    /// `close_pairing`: best effort (the slot expires by itself); a failure is only logged.
    public func close(slot: String) async {
        var request = Relay_V1_ClosePairingSlot()
        request.slotID = slot
        do {
            try await client.closePairing(request)
        } catch {
            Self.logger.info("relay close_pairing failed: \(Self.code(error), privacy: .public)")
        }
    }

    /// `remove_slot` with Phase 2's `UNAVAILABLE` retry (the client's); `NOT_FOUND` counts as done (R14).
    public func removeSlot(mac: String) async throws {
        var request = Relay_V1_RemoveMacSlot()
        request.phoneDeviceID = client.deviceID
        request.macDeviceID = mac
        try await refusing("removeSlot") {
            do {
                try await client.removeSlot(request)
            } catch HostedRelayError.server(code: .notFound, _) {
                Self.logger.info("relay remove_slot: not in the slots, done")
            }
        }
    }

    /// `vouch_hub` (relay `proto/README.md` "Vouched hubs"): after the owner confirmed the code and
    /// before `promote_pairing` / `add_slot`, which must follow within the vouch's 10 minutes (a
    /// `HUB_NOT_VOUCHED` from them is the caller's: vouch again, then repeat once).
    /// GetChallenge{VOUCH} → assertion over the vouch hash → `vouch_hub`; every attempt takes a new
    /// nonce and a new assertion (`HostedRelayClient.vouchHub`). `ATTESTATION_FAILED` is retried
    /// once, then once more after the lost-key path (a login with a fresh attestation), then it is
    /// `.updateRequired`. The other answers throw `VouchRefusal` at once; an error none of them
    /// covers is rethrown as the client threw it.
    public func vouch(hubDeviceID: String, authPub: Data) async throws {
        var request = Relay_V1_VouchHub()
        request.hubDeviceID = hubDeviceID
        request.authPub = authPub
        var refusals = 0
        while true {
            do {
                try await client.vouchHub(request)
                return
            } catch HostedRelayError.server(code: .attestationFailed, _) {
                refusals += 1
                Self.logger.error("relay vouchHub: attestation_failed, refusal \(refusals)")
                if refusals == 2 { try await takeLostKeyPath() }
                if refusals > 2 { throw VouchRefusal.updateRequired }
            } catch {
                Self.logger.error("relay vouchHub failed: \(Self.code(error), privacy: .public)")
                throw vouchRefusal(for: error) ?? error
            }
        }
    }

    /// The vouch's lost-key step: forget the App Attest key and log in with a fresh attestation.
    /// `.updateRequired` when the attestor already took that step since the last good login.
    private func takeLostKeyPath() async throws {
        guard await client.attestor.serverRefusedAssertion() else { throw VouchRefusal.updateRequired }
        do {
            try await client.login()
        } catch {
            Self.logger.error("relay vouchHub: lost-key login failed: \(Self.code(error), privacy: .public)")
            throw vouchRefusal(for: error) ?? error
        }
    }

    // MARK: - Refusals

    /// Runs one op, mapping the answers a linking screen acts on to `Refusal`.
    private func refusing<T>(_ op: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            Self.logger.error("relay \(op, privacy: .public) failed: \(Self.code(error), privacy: .public)")
            throw await refusal(for: error) ?? error
        }
    }

    private func refusal(for error: any Error) async -> Refusal? {
        guard let error = error as? HostedRelayError else { return nil }
        switch error {
        case .server(let code, _):
            switch code {
            // The client's one lost-key login already ran where it applies.
            case .attestationRequired, .attestationFailed: return .updateRequired
            case .entitlementInactive: return .notPaying
            case .slotLimit: return .slotsFull(macs: await slottedMacs())
            case .slotReplacementLimit: return .replacementLimit
            case .pairingExpired: return .pairingExpired
            case .unavailable: return .unreachable
            case .unsupportedVersion: return .updateRequired
            default: return nil
            }
        case .unreachable:
            return .unreachable
        case .undecodable(let status):
            return (500..<600).contains(status) ? .unreachable : nil
        case .unsupportedVersion, .attestation(.updateRequired):
            return .updateRequired
        case .attestation(.retryLater(let after)):
            return .attestationBackoff(until: backoffEnd(after))
        case .attestation(.notSupported):
            return nil
        }
    }

    /// `vouch`'s answers as `VouchRefusal` (`ATTESTATION_FAILED` reaches here only from the lost-key login).
    private func vouchRefusal(for error: any Error) -> VouchRefusal? {
        guard let error = error as? HostedRelayError else { return nil }
        switch error {
        case .server(let code, _):
            switch code {
            case .forbidden: return .notConfirmed
            case .entitlementInactive: return .notPaying
            case .attestationRequired, .attestationFailed, .unsupportedVersion: return .updateRequired
            case .notFound: return .hubNotOnRelay
            case .slotLimit: return .slotsFull
            case .unavailable: return .unreachable
            default: return nil
            }
        case .unreachable:
            return .unreachable
        case .undecodable(let status):
            return (500..<600).contains(status) ? .unreachable : nil
        case .unsupportedVersion, .attestation(.updateRequired):
            return .updateRequired
        case .attestation(.retryLater(let after)):
            return .attestationBackoff(until: backoffEnd(after))
        case .attestation(.notSupported):
            return nil
        }
    }

    private func backoffEnd(_ after: Duration) -> Date {
        let parts = after.components
        return client.clock.now().addingTimeInterval(TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18)
    }

    /// The Macs in slots for a `SLOT_LIMIT` answer; empty when the account state cannot be read.
    private func slottedMacs() async -> [String] {
        (try? await client.accountState().macDeviceIds) ?? []
    }

    /// An error's code for logs: the relay code or the case, never a message.
    private static func code(_ error: any Error) -> String {
        guard let error = error as? HostedRelayError else { return String(describing: type(of: error)) }
        if case .server(let code, _) = error { return String(describing: code) }
        return String(describing: error)
    }
}

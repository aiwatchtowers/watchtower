import Foundation
import Observation
import os
import WatchtowerHostedRelay
import WatchtowerSync

/// Finishes the Relay links the owner confirmed (relay client Phase 3 Task 10, point 9): one attempt per
/// `LinkStore.promoted` entry at every launch, on every foreground and on the owner's Try Again, with a growing
/// pause between failed automatic attempts. Per state:
/// - `.confirmed` → vouch, then `.promoteSent`, then promote;
/// - `.promoteSent` → the account state first: the Mac in slots → `.promoted` (no promote); the slot still open →
///   promote again (vouching first when the vouch is 10 minutes old); the slot expired → `.needsOwner(.slotExpired)`;
/// - `.promoted` → `finish` (prepare and linked) only;
/// - `.needsOwner` → nothing automatic. The owner's Try Again asks the account state the same way, opens a new slot
///   where one is needed (never a hello: the keys are held) and vouches and promotes.
/// A definite refusal moves the link to `.needsOwner(reason)` with its keys kept; a transient answer changes nothing.
/// Never a second hello, never a promote of a slot the account already shows granted, never a key deletion.
@MainActor
@Observable
final class PromotedLinkResumer {
    enum Outcome: Equatable {
        /// The link completed: its row is saved and the promoted entry gone.
        case linked
        /// It waits for the owner.
        case needsOwner(PromotedLink.Reason)
        /// Not finished yet: the next launch, foreground or Try Again goes on.
        case waiting
        /// No such promoted link (cancelled meanwhile), or an attempt is already running.
        case none
    }

    /// `promote_pairing` must follow a vouch within this (relay `proto/README.md` "Vouched hubs").
    static let vouchLifetime: TimeInterval = 600
    /// The first pause after a failed automatic attempt; it doubles per failure up to `maxPause`.
    static let firstPause: TimeInterval = 30
    static let maxPause: TimeInterval = 1_800

    /// The hubs whose attempt is running ("Finishing the link…" with no actions).
    private(set) var running: Set<String> = []
    /// The hubs whose last attempt failed without a definite answer ("Couldn't finish the link.").
    private(set) var failed: Set<String> = []

    @ObservationIgnored private let store: LinkStore
    @ObservationIgnored private let relay: any RelayLinkOps
    @ObservationIgnored private let clock: any LinkClock
    @ObservationIgnored private var failures: [String: Int] = [:]
    @ObservationIgnored private var notBefore: [String: Date] = [:]
    /// Completes a `.promoted` link (`prepare`, then `linked`): true once its row is saved.
    @ObservationIgnored var finish: @MainActor (PromotedLink) async -> Bool = { _ in false }
    /// The store changed (a state written or the entry gone).
    @ObservationIgnored var changed: @MainActor () -> Void = {}
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "Linking")

    init(store: LinkStore, relay: any RelayLinkOps, clock: any LinkClock) {
        self.store = store
        self.relay = relay
        self.clock = clock
    }

    /// One automatic attempt for every promoted link that is not waiting for the owner, outside its pause.
    func resumeAll() async {
        for link in store.promoted.values.sorted(by: { $0.since < $1.since }) {
            if case .needsOwner = link.state { continue }
            if let pause = notBefore[link.hubID], clock.now() < pause { continue }
            _ = await run(link.hubID, ownerAsked: false)
        }
    }

    /// One attempt for `hubID`. `ownerAsked`: the owner's Try Again (a `.needsOwner` link goes on).
    func run(_ hubID: String, ownerAsked: Bool) async -> Outcome {
        guard !running.contains(hubID), let link = store.promoted[hubID] else { return .none }
        running.insert(hubID)
        failed.remove(hubID)
        let outcome = await step(link, ownerAsked: ownerAsked)
        running.remove(hubID)
        switch outcome {
        case .waiting:
            failed.insert(hubID)
            let count = (failures[hubID] ?? 0) + 1
            failures[hubID] = count
            notBefore[hubID] = clock.now().addingTimeInterval(min(Self.firstPause * pow(2, Double(count - 1)), Self.maxPause))
        case .linked, .needsOwner, .none:
            failures[hubID] = nil
            notBefore[hubID] = nil
        }
        changed()
        return outcome
    }

    /// Forgets a cancelled link's attempt state.
    func forget(_ hubID: String) {
        failed.remove(hubID)
        failures[hubID] = nil
        notBefore[hubID] = nil
    }

    // MARK: - Per state

    private func step(_ link: PromotedLink, ownerAsked: Bool) async -> Outcome {
        switch link.state {
        case .promoted:
            return await complete(link)
        case .confirmed:
            return await vouchAndPromote(link)
        case .promoteSent:
            guard let macs = await slottedMacs() else { return .waiting }
            if macs.contains(link.macDeviceID) { return await promoted(link) }
            guard clock.now() < link.slotExpiresAt else { return needsOwner(link, .slotExpired) }
            return await promote(link, vouchFirstIfStale: true, vouchedAgain: false)
        case let .needsOwner(reason):
            guard ownerAsked else { return .needsOwner(reason) }
            return await tryAgain(link, reason: reason)
        }
    }

    /// The owner's Try Again: the Mac already in slots is promoted; else a new slot where one is needed, then vouch
    /// and promote.
    private func tryAgain(_ link: PromotedLink, reason: PromotedLink.Reason) async -> Outcome {
        guard let macs = await slottedMacs() else { return .waiting }
        if macs.contains(link.macDeviceID) { return await promoted(link) }
        var link = link
        if reason.needsNewSlot || clock.now() >= link.slotExpiresAt {
            do {
                let slot = try await relay.open(mac: link.macDeviceID)
                link.slot = slot.slot
                link.slotExpiresAt = slot.expiresAt
                link.vouchedAt = nil
                store.update(link)
            } catch {
                guard let refused = Self.reason(forOpen: error) else { return .waiting }
                return needsOwner(link, refused)
            }
        }
        return await vouchAndPromote(link)
    }

    private func vouchAndPromote(_ link: PromotedLink) async -> Outcome {
        var link = link
        if let outcome = await vouch(&link) { return outcome }
        link.state = .promoteSent
        store.update(link)
        return await promote(link, vouchFirstIfStale: false, vouchedAgain: false)
    }

    /// `vouch_hub`: nil once vouched (`vouchedAt` stamped), else the attempt's outcome.
    private func vouch(_ link: inout PromotedLink) async -> Outcome? {
        guard let authPub = link.link.relayAuthPub.flatMap(WireBytes.fromBase64URL) else {
            Self.logger.error("promoted link without the Mac's relay key")
            return needsOwner(link, .notConfirmed)
        }
        do {
            try await relay.vouch(hubDeviceID: link.macDeviceID, authPub: authPub)
        } catch let refusal as HostedRelayPairing.VouchRefusal {
            switch refusal {
            case .notPaying: return needsOwner(link, .notPaying)
            case .updateRequired: return needsOwner(link, .updateApp)
            case .hubNotOnRelay: return needsOwner(link, .hubNotOnRelay)
            case .slotsFull: return needsOwner(link, .slotsFull)
            case .notConfirmed:
                Self.logger.error("relay vouch: forbidden for a phone session")
                return needsOwner(link, .notConfirmed)
            case .unreachable, .attestationBackoff: return .waiting
            }
        } catch {
            return .waiting
        }
        link.vouchedAt = clock.now()
        store.update(link)
        return nil
    }

    private func promote(_ link: PromotedLink, vouchFirstIfStale: Bool, vouchedAgain: Bool) async -> Outcome {
        var link = link
        if vouchFirstIfStale, link.vouchedAt.map({ clock.now().timeIntervalSince($0) >= Self.vouchLifetime }) ?? true {
            if let outcome = await vouch(&link) { return outcome }
        }
        do {
            try await relay.promote(slot: link.slot)
        } catch HostedRelayError.server(code: .hubNotVouched, _) {
            guard !vouchedAgain else { return needsOwner(link, .notConfirmed) }
            Self.logger.notice("relay promote: hub not vouched, vouching again")
            if let outcome = await vouch(&link) { return outcome }
            return await promote(link, vouchFirstIfStale: false, vouchedAgain: true)
        } catch HostedRelayError.server(code: .notFound, _) {
            // The slot is closed or replaced: granted already, or not confirmed.
            guard let macs = await slottedMacs() else { return .waiting }
            return macs.contains(link.macDeviceID) ? await promoted(link) : needsOwner(link, .notConfirmed)
        } catch HostedRelayError.server(code: .forbidden, _) {
            Self.logger.error("relay promote: forbidden for a phone session")
            return needsOwner(link, .notConfirmed)
        } catch {
            guard let refused = Self.reason(forPromote: error) else { return .waiting }
            return needsOwner(link, refused)
        }
        return await promoted(link)
    }

    private func promoted(_ link: PromotedLink) async -> Outcome {
        var link = link
        link.state = .promoted
        store.update(link)
        return await complete(link)
    }

    private func complete(_ link: PromotedLink) async -> Outcome {
        await finish(link) ? .linked : .waiting
    }

    private func needsOwner(_ link: PromotedLink, _ reason: PromotedLink.Reason) -> Outcome {
        var link = link
        link.state = .needsOwner(reason)
        store.update(link)
        Self.logger.notice("promoted link waits for the owner: \(reason.rawValue, privacy: .public)")
        return .needsOwner(reason)
    }

    /// The Macs in this account's slots; nil when the account state cannot be read (transient, whatever the error).
    private func slottedMacs() async -> [String]? {
        do {
            return try await relay.accountState().macs
        } catch {
            Self.logger.notice("relay account state unread: the promoted link waits")
            return nil
        }
    }

    /// A definite refusal of `promote_pairing` as the owner's reason; nil for a transient answer.
    static func reason(forPromote error: any Error) -> PromotedLink.Reason? {
        switch error as? HostedRelayPairing.Refusal {
        case .pairingExpired: .slotExpired
        case .slotsFull: .slotsFull
        case .replacementLimit: .replacementLimit
        case .notPaying: .notPaying
        case .updateRequired: .updateApp
        case .unreachable, .attestationBackoff, nil: nil
        }
    }

    /// A definite refusal of a new slot (`open_pairing`) as the owner's reason; nil for a transient answer.
    static func reason(forOpen error: any Error) -> PromotedLink.Reason? {
        reason(forPromote: error)
    }
}

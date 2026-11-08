import CryptoKit
import Foundation

// MARK: - Own rows across a keybox merge (relay client Phase 5, Task 8 fix round 1b)
//
// A link write can drop epochs (`saveHubLink` and `updateHubLink` keep `retained(now:)`): a phone back after weeks
// jumps many epochs in one merge, and a write that is no merge (`withOffer`) drops a previous epoch 7 days after it was
// superseded. This phone's own `pending_actions` rows sealed in a dropped epoch would never open again, and a Not
// delivered row would leave the list while it still counts. So at every merge, before the save, every own row sealed
// in an epoch below the merged newest is resealed under the newest, with the keys the phone holds before the merge;
// the newest epoch is never trimmed.
//
// Crash-safe order, on the outbox chain:
// 1. promote what an earlier, interrupted run staged (its epoch is held now);
// 2. stage the new envelopes in `pending_reseal` (rows and keys untouched: a kill here changes nothing a reader sees,
//    and the re-run stages again);
// 3. save the merged link (`updateHubLink`, the one writer of `hub.<id>` here);
// 4. promote: each row still holding its old envelope takes the new one in one transaction; a `queued` or `sent` row
//    whose old epoch's key is gone after the save is listed Not delivered (F7: it is never sent). A kill between 3 and
//    4 leaves the stage, and step 1 of the next merge (they run after every fetch) applies it.
extension ActionOutbox {
    /// Merges `keybox` into the link of `hubID` in `keys` (as `HubLinkKeys.merging` does) and keeps this phone's own
    /// rows readable across it. Returns the merge, nil when the link is gone (nothing written). A locked keychain
    /// throws `keysUnavailable` with nothing written; a refused merge (`KeyboxKeysError`) throws with nothing written.
    @discardableResult
    public func mergeKeybox(
        _ keybox: KeyboxKeys, into keys: any PhoneKeyStore, hubID: String, now: Date
    ) async throws -> KeyboxMerge? {
        try await onChain { try await self.performMerge(keybox, into: keys, hubID: hubID, now: now) }.value
    }

    private func performMerge(
        _ keybox: KeyboxKeys, into keys: any PhoneKeyStore, hubID: String, now: Date
    ) async throws -> KeyboxMerge? {
        guard let device = deviceID.flatMap(UUID.init(uuidString:)) else { throw ActionOutboxError.notLinked }
        let hub = try WireBytes.hubUUID(hubID)
        do {
            guard let link = try keys.hubLink(hubID) else { return nil }
            let identity = try keys.identity()
            try promoteStagedReseals(link: link, identity: identity, hub: hub, device: device)
            let merge = try link.merging(keybox, identity: identity, hubID: hub, deviceID: device, now: now)
            try await stageOwnReseals(from: link, to: merge.keys, identity: identity, hub: hub, device: device)
            var saved: KeyboxMerge?
            guard let stored = try keys.updateHubLink(hubID, { current in
                let merged = try current.merging(keybox, identity: identity, hubID: hub, deviceID: device, now: now)
                saved = merged
                return merged.keys
            }) else { return nil }
            try promoteStagedReseals(link: stored, identity: identity, hub: hub, device: device)
            return saved
        } catch KeyStoreError.locked {
            throw SecureTransportError.keysUnavailable
        }
    }

    /// Step 2: every own row sealed in an epoch below `merged`'s newest, any state, is opened with the key `link`
    /// holds and sealed under `merged`'s newest epoch, with a fresh envelope seq; the new envelopes are staged. Every
    /// row then sits in the newest epoch, which no link write ever trims (retention also runs on writes that are no
    /// merge, `withOffer` say, and drops a previous epoch 7 days after it was superseded).
    func stageOwnReseals(
        from link: HubLinkKeys, to merged: HubLinkKeys, identity: DeviceIdentityKeys, hub: UUID, device: UUID
    ) async throws {
        guard let target = merged.epochs.last?.epoch,
              let targetKey = try merged.ownRelayKey(epoch: target, identity: identity, hub: hub, device: device)
        else { return }
        var staged: [StagedReseal] = []
        for row in try store.ownSealedRows() {
            guard let header = try? Envelope.parse(row.envelope).header, header.envelopeClass == .relayToHub,
                  header.senderID == device, header.epoch < target,
                  let oldKey = try link.ownRelayKey(epoch: header.epoch, identity: identity, hub: hub, device: device)
            else { continue }
            let context = EnvelopeContext(zone: .relay, wireName: row.wireName)
            guard let frame = try? EnvelopeSealer.openSymmetric(
                row.envelope, accepting: [.relayToHub], context: context, verifier: nil) { _ in oldKey }.frame
            else { continue }
            let envelope = try EnvelopeSealer.sealSymmetric(
                frame, envelopeClass: .relayToHub, key: targetKey, hubID: hub, senderID: device, epoch: target,
                seq: try transport.keys.nextSeq(), context: context, signer: nil)
            staged.append(StagedReseal(
                actionID: row.actionID, oldPayload: row.envelope, oldEpoch: header.epoch, payload: envelope, epoch: target))
        }
        try store.stageReseals(staged)
    }

    /// Steps 1 and 4: applies the staged reseals whose epoch `link` holds; a `queued` or `sent` row whose old epoch's
    /// key `link` no longer holds is listed Not delivered.
    func promoteStagedReseals(link: HubLinkKeys, identity: DeviceIdentityKeys, hub: UUID, device: UUID) throws {
        let held = Set(link.epochs.map(\.epoch))
        let ready = try store.stagedReseals().filter { held.contains($0.epoch) }
        guard !ready.isEmpty else { return }
        var undeliver: Set<String> = []
        for reseal in ready where try link.ownRelayKey(epoch: reseal.oldEpoch, identity: identity, hub: hub, device: device) == nil {
            undeliver.insert(reseal.actionID)
        }
        for id in undeliver { stampLatency { try self.store.latencyDrop(actionID: id) } }
        try store.promoteReseals(ready, undeliver: undeliver, message: Self.refusedMessage)
        logger.notice(
            "\(ready.count, privacy: .public) own rows resealed for a merge, \(undeliver.count, privacy: .public) past their key")
    }
}

extension HubLinkKeys {
    /// This phone's relay key for `epoch` by the link's rule: the stored pair, else the static key; nil when the
    /// epoch's keys are gone or not here yet (`storedRelayKeys` throws `epochKeysGone`/`epochKeysPending`).
    func ownRelayKey(
        _ direction: RelayDirection = .phoneToHub, epoch: UInt32, identity: DeviceIdentityKeys, hub: UUID, device: UUID
    ) throws -> SymmetricKey? {
        do {
            if let pair = try storedRelayKeys(epoch: epoch) { return SymmetricKey(data: pair.key(direction)) }
        } catch SecureTransportError.epochKeysGone, SecureTransportError.epochKeysPending {
            return nil
        }
        let hubPublic: Curve25519.KeyAgreement.PublicKey
        do { hubPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hubAgreementKey) } catch {
            throw KeyStoreError.corrupt("hub agreement key does not parse")
        }
        return try KeyDerivation.relayKey(
            agreementPrivate: identity.agreement, peerPublic: hubPublic, linkNonce: linkNonce, hubID: hub,
            deviceID: device, epoch: epoch, direction: direction)
    }
}

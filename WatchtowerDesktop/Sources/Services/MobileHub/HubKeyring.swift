import CryptoKit
import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

enum HubKeyringError: Error, Equatable {
    /// No `hub_epochs` row for the epoch (never created, or forgotten by `resetGroupKeys`).
    case unknownEpoch(UInt32)
    /// A sealed key in `hubstate.db` does not open under this identity's wrap key (the identity was recreated) or
    /// does not have the sealed shape. Names which one, never its bytes.
    case sealedKeyUnreadable(String)
    /// A relay key asked for a device with no relay material (not linked, removed, or a pre-E2E row).
    case unknownDevice
    /// `hub_meta.envelope_seq_ceiling` is not a number: never read as 0, which would reuse seqs.
    case corruptSeqCeiling
}

/// The hub's `SecureKeyProvider` and relay `RollbackGuard` (spec §2.2, D2/D3/D10, F3/F5).
///
/// - Identity: `hub_sig`, `hub_kx` and the 32-byte wrap key are Keychain items (`HubKeyStore`), loaded once here.
/// - Group keys: `K_meta` (`hub_meta.k_meta_sealed`) and each epoch's `K_data ‖ K_alert` (`hub_epochs.sealed_keys`)
///   are sealed with ChaChaPoly under the wrap key, the AAD binding hub id and epoch, so a rotation (new epoch and
///   hash wipe) is one SQLite transaction (`beginNextEpoch(alongside:)`).
/// - Seq: one `SeqAllocator` over `hub_meta.envelope_seq_ceiling`; one keyring per sidecar (two allocators over one
///   ceiling could hand out the same block).
/// - Relay keys: per linked phone, from `hub_kx` and the row's `agreement_key`/`link_nonce`, cached per
///   (device, epoch, direction) and re-derived only when the row's material changes (a re-link).
final class HubKeyring: SecureKeyProvider, RollbackGuard, @unchecked Sendable {
    static let metaKeySealedKey = "k_meta_sealed"
    static let seqCeilingKey = "envelope_seq_ceiling"
    /// D10: the previous epoch's relay envelopes are accepted this long after it was retired.
    static let previousEpochGrace: TimeInterval = 7 * 86_400
    /// Spec §2.2: rotate after 90 days or 2^28 messages.
    static let rotationAge: TimeInterval = 90 * 86_400
    static let rotationSeqCap: UInt64 = 1 << 28

    private static let logger = Logger(subsystem: Constants.bundleID, category: "HubKeys")

    let role: SecureRole
    /// True when the Keychain identity was created now while the sidecar already had linked phones or epochs:
    /// the old pairing is unusable, so the hub must delete its zones and forget phones (Task 15 acts on it).
    let identityWasRecreated: Bool

    private let hubUUID: UUID
    private let identity: HubIdentityKeys
    private let sidecar: HubSyncState
    private let now: @Sendable () -> Date
    private let seq: SeqAllocator
    private let lock = NSLock()
    private var relayMaterial: [UUID: RelayMaterial] = [:]

    /// One phone's relay inputs, checked once (the public key parses, ECDH succeeds, the nonce decodes), and the
    /// keys derived from them so far.
    private struct RelayMaterial {
        let agreementKey: Data
        let linkNonce: String
        let peer: Curve25519.KeyAgreement.PublicKey
        let nonceBytes: Data
        var keys: [String: SymmetricKey] = [:]
    }

    init(
        hubID: String, sidecar: HubSyncState, store: any HubKeyStore, now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        let hubUUID = try WireBytes.hubUUID(hubID)
        let hadPairing = try sidecar.hasPairingState()
        let loaded = try store.hubIdentity(hubID: hubID)
        self.hubUUID = hubUUID
        self.identity = loaded.keys
        self.sidecar = sidecar
        self.now = now
        self.role = .hub(hubID: hubUUID)
        self.identityWasRecreated = loaded.created && hadPairing
        self.seq = SeqAllocator(
            load: { [sidecar] in try Self.seqCeiling(sidecar.metaValue(forKey: Self.seqCeilingKey)) },
            store: { [sidecar] in try sidecar.setMetaValue(String($0), forKey: Self.seqCeilingKey) })
        if identityWasRecreated {
            Self.logger.error("hub identity was recreated while the sidecar held a pairing: phones must re-pair")
        }
    }

    var signingPublicKey: Curve25519.Signing.PublicKey { identity.signing.publicKey }
    var agreementPublicKey: Curve25519.KeyAgreement.PublicKey { identity.agreement.publicKey }

    // MARK: - Group keys

    /// Creates K_meta and epoch 1 when none exists (idempotent).
    func ensureGroupKeys() throws {
        try sidecar.writeKeys { db in
            if try HubSyncState.metaValue(Self.metaKeySealedKey, db) == nil {
                let sealed = try seal(Self.randomKey(), aad: metaAAD())
                try HubSyncState.setMetaValue(sealed.base64EncodedString(), Self.metaKeySealedKey, db)
            }
            if try HubSyncState.latestEpochs(db).isEmpty {
                _ = try insertEpoch(1, db)
            }
        }
    }

    /// Retires the current epoch and creates the next one, running `work` (Task 14: the slice hash wipe) in the same
    /// IMMEDIATE transaction, so the new epoch and its consequences commit together or not at all.
    @discardableResult
    func beginNextEpoch(alongside work: (Database) throws -> Void = { _ in }) throws -> EpochKeys {
        try sidecar.writeKeys { db in
            guard let current = try HubSyncState.latestEpochs(db).last else { throw SecureTransportError.keysUnavailable }
            let (next, overflow) = current.epoch.addingReportingOverflow(1)
            guard !overflow else { throw HubKeyringError.unknownEpoch(current.epoch) }
            try db.execute(
                sql: "UPDATE hub_epochs SET retired_at = ? WHERE epoch = ? AND retired_at IS NULL",
                arguments: [now().timeIntervalSince1970, Int64(current.epoch)])
            let keys = try insertEpoch(next, db)
            try work(db)
            return keys
        }
    }

    /// Clears K_meta and every epoch (hub turned off / zones deleted): the next pairing starts fresh. The seq
    /// ceiling stays, so seqs never repeat.
    func resetGroupKeys() throws {
        try sidecar.writeKeys { db in
            try db.execute(sql: "DELETE FROM hub_epochs")
            try db.execute(sql: "DELETE FROM hub_meta WHERE key = ?", arguments: [Self.metaKeySealedKey])
        }
    }

    func epochKeys(_ epoch: UInt32) throws -> EpochKeys {
        guard let stored = try sidecar.storedEpoch(epoch) else { throw HubKeyringError.unknownEpoch(epoch) }
        let plain = try open(stored.sealedKeys, aad: epochAAD(epoch), what: "epoch \(epoch)")
        guard plain.count == 64 else { throw HubKeyringError.sealedKeyUnreadable("epoch \(epoch)") }
        return EpochKeys(epoch: epoch, dataKey: Data(plain.prefix(32)), alertKey: Data(plain.suffix(32)))
    }

    /// Due when the current epoch is 90 days old or has used 2^28 seqs (spec §2.2). False before the first epoch.
    func rotationDue() throws -> Bool {
        guard let current = try sidecar.latestEpochs().last else { return false }
        if now().timeIntervalSince(current.createdAt) >= Self.rotationAge { return true }
        let ceiling = try Self.seqCeiling(sidecar.metaValue(forKey: Self.seqCeilingKey))
        return ceiling >= current.firstSeq && ceiling - current.firstSeq >= Self.rotationSeqCap
    }

    private func insertEpoch(_ epoch: UInt32, _ db: Database) throws -> EpochKeys {
        let keys = EpochKeys(epoch: epoch, dataKey: Self.randomKey(), alertKey: Self.randomKey())
        let sealed = try seal(keys.dataKey + keys.alertKey, aad: epochAAD(epoch))
        try HubSyncState.insertEpoch(.init(
            epoch: epoch, sealedKeys: sealed, createdAt: now(),
            firstSeq: try Self.seqCeiling(HubSyncState.metaValue(Self.seqCeilingKey, db)), retiredAt: nil), db)
        return keys
    }

    // MARK: - SecureKeyProvider

    func metaKey() throws -> SymmetricKey {
        guard let text = try sidecar.metaValue(forKey: Self.metaKeySealedKey) else { throw SecureTransportError.keysUnavailable }
        guard let sealed = Data(base64Encoded: text) else { throw HubKeyringError.sealedKeyUnreadable("k_meta") }
        let plain = try open(sealed, aad: metaAAD(), what: "k_meta")
        guard plain.count == 32 else { throw HubKeyringError.sealedKeyUnreadable("k_meta") }
        return SymmetricKey(data: plain)
    }

    /// The newest epoch; `keysUnavailable` before `ensureGroupKeys` (nothing can be sealed yet).
    func currentEpoch() throws -> UInt32 {
        guard let current = try sidecar.latestEpochs().last else { throw SecureTransportError.keysUnavailable }
        return current.epoch
    }

    func dataKey(epoch: UInt32) throws -> SymmetricKey { SymmetricKey(data: try epochKeys(epoch).dataKey) }
    func alertKey(epoch: UInt32) throws -> SymmetricKey { SymmetricKey(data: try epochKeys(epoch).alertKey) }

    /// Never throws for an id `relayDeviceIDs()` or `acceptsRelayEpoch` just vouched for: their material is cached
    /// and was checked when cached. A device without material is `unknownDevice`.
    func relayKey(_ direction: RelayDirection, deviceID: UUID, epoch: UInt32) throws -> SymmetricKey {
        let cached = lock.withLock { relayMaterial[deviceID] }
        guard var material = try cached ?? refreshMaterial(deviceID) else { throw HubKeyringError.unknownDevice }
        let slot = "\(direction.rawValue)/\(epoch)"
        if let key = material.keys[slot] { return key }
        let key = try KeyDerivation.relayKey(
            agreementPrivate: identity.agreement, peerPublic: material.peer, linkNonce: material.nonceBytes,
            hubID: hubUUID, deviceID: deviceID, epoch: epoch, direction: direction)
        material.keys[slot] = key
        lock.withLock {
            // Keep the derived key only if the material it came from is still the cached one.
            if let current = relayMaterial[deviceID], current.agreementKey == material.agreementKey,
               current.linkNonce == material.linkNonce {
                relayMaterial[deviceID]?.keys[slot] = key
            }
        }
        return key
    }

    /// D10: the current epoch, and the previous one until 7 days after it was retired. false for a device without
    /// relay material (unknown, removed, pre-E2E, or a row whose key does not parse); never throws for those.
    func acceptsRelayEpoch(_ epoch: UInt32, deviceID: UUID) throws -> Bool {
        guard try refreshMaterial(deviceID) != nil else { return false }
        let epochs = try sidecar.latestEpochs()
        guard let current = epochs.last else { return false }
        if epoch == current.epoch { return true }
        guard epochs.count == 2, epoch == epochs[0].epoch else { return false }
        let retiredAt = epochs[0].retiredAt ?? current.createdAt
        return now().timeIntervalSince(retiredAt) < Self.previousEpochGrace
    }

    /// Every linked phone with usable relay material; the cache is replaced by exactly these.
    func relayDeviceIDs() throws -> [UUID] {
        let rows = try sidecar.deviceKeyRows()
        var fresh: [UUID: RelayMaterial] = [:]
        var ids: [UUID] = []
        let cached = lock.withLock { relayMaterial }
        for row in rows {
            guard let id = UUID(uuidString: row.deviceID) else {
                Self.logger.error("linked device id is not a UUID: \(row.deviceID, privacy: .public)")
                continue
            }
            guard let material = Self.reuse(cached[id], for: row) ?? makeMaterial(row, deviceID: id) else { continue }
            fresh[id] = material
            ids.append(id)
        }
        lock.withLock { relayMaterial = fresh }
        return ids
    }

    func nextSeq() throws -> UInt64 { try seq.next() }

    func hubSigner() throws -> Curve25519.Signing.PrivateKey { identity.signing }
    func hubAgreement() throws -> Curve25519.KeyAgreement.PrivateKey { identity.agreement }

    /// A linked, pending, revoked or refused device's agreement key (F5); nil when none is stored or it does not
    /// parse (logged: the keybox is then `noKeyboxRecipient`).
    func keyboxRecipient(deviceID: UUID) throws -> Curve25519.KeyAgreement.PublicKey? {
        guard let raw = try sidecar.keyboxRecipientKey(deviceID.uuidString) else { return nil }
        do { return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) } catch {
            Self.logger.error("stored agreement key of \(deviceID.uuidString, privacy: .public) does not parse")
            return nil
        }
    }

    func deviceSigner() throws -> Curve25519.Signing.PrivateKey { throw SecureTransportError.wrongRole }
    func hubAgreementPublicKey() throws -> Curve25519.KeyAgreement.PublicKey { throw SecureTransportError.wrongRole }
    func linkNonce() throws -> Data { throw SecureTransportError.wrongRole }

    /// Drops a device's cached relay keys (Task 14 calls it on Remove; Task 13 on a re-link).
    func forgetRelayKeys(deviceID: UUID) {
        lock.withLock { relayMaterial[deviceID] = nil }
    }

    // MARK: - RollbackGuard (F3)

    func check(wireName: String, senderID: UUID, epoch: UInt32, seq: UInt64) throws -> RollbackVerdict {
        guard let stored = try sidecar.relaySeen(wireName: wireName, senderID: senderID.uuidString) else { return .newer }
        if (epoch, seq) == stored { return .same }
        return (epoch, seq) > stored ? .newer : .older
    }

    func record(wireName: String, senderID: UUID, epoch: UInt32, seq: UInt64) throws {
        try sidecar.recordRelaySeen(wireName: wireName, senderID: senderID.uuidString, epoch: epoch, seq: seq, at: now())
    }

    // MARK: - Helpers

    /// Re-reads the device's row and refreshes its cache entry: kept when the material is unchanged, replaced on a
    /// re-link, dropped when the row is gone or unusable.
    private func refreshMaterial(_ deviceID: UUID) throws -> RelayMaterial? {
        let material: RelayMaterial?
        if let row = try sidecar.deviceKeyRow(deviceID.uuidString) {
            let cached = lock.withLock { relayMaterial[deviceID] }
            material = Self.reuse(cached, for: row) ?? makeMaterial(row, deviceID: deviceID)
        } else {
            material = nil
        }
        lock.withLock { relayMaterial[deviceID] = material }
        return material
    }

    private static func reuse(_ cached: RelayMaterial?, for row: HubSyncState.DeviceKeyRow) -> RelayMaterial? {
        guard let cached, cached.agreementKey == row.agreementKey, cached.linkNonce == row.linkNonce else { return nil }
        return cached
    }

    /// nil (logged) when the stored key does not parse, ECDH with it fails, or the nonce is not base64url: such a
    /// row can never authenticate a record, so it is treated like an unknown device.
    private func makeMaterial(_ row: HubSyncState.DeviceKeyRow, deviceID: UUID) -> RelayMaterial? {
        guard let nonceBytes = WireBytes.fromBase64URL(row.linkNonce), !nonceBytes.isEmpty else {
            Self.logger.error("link nonce of \(deviceID.uuidString, privacy: .public) is not base64url")
            return nil
        }
        do {
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: row.agreementKey)
            // Probes the key once, so a cached device's relay keys always derive.
            _ = try identity.agreement.sharedSecretFromKeyAgreement(with: peer)
            return RelayMaterial(agreementKey: row.agreementKey, linkNonce: row.linkNonce, peer: peer, nonceBytes: nonceBytes)
        } catch {
            Self.logger.error("agreement key of \(deviceID.uuidString, privacy: .public) is unusable")
            return nil
        }
    }

    private func metaAAD() -> Data { Data("wt/hub-meta/v1".utf8) + WireBytes.bytes(of: hubUUID) }

    private func epochAAD(_ epoch: UInt32) -> Data {
        var aad = Data("wt/hub-epoch/v1".utf8) + WireBytes.bytes(of: hubUUID)
        WireBytes.append(epoch, to: &aad)
        return aad
    }

    private func seal(_ plain: Data, aad: Data) throws -> Data {
        try ChaChaPoly.seal(plain, using: identity.wrapKey, authenticating: aad).combined
    }

    private func open(_ sealed: Data, aad: Data, what: String) throws -> Data {
        do {
            return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: identity.wrapKey, authenticating: aad)
        } catch {
            throw HubKeyringError.sealedKeyUnreadable(what)
        }
    }

    private static func randomKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    private static func seqCeiling(_ text: String?) throws -> UInt64 {
        guard let text else { return 0 }
        guard let value = UInt64(text) else { throw HubKeyringError.corruptSeqCeiling }
        return value
    }
}

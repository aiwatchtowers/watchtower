import CryptoKit
import Foundation
import os

/// Seals what its role sends; opens what its role receives in RelayZone; DataZone reads pass through (the
/// replica opens on read). Record naming: `heartbeat` stays `heartbeat`; `device_grant-<id>` → `keybox-<id>`;
/// `hello-<id>` stays; signals keep their name; everything else → `KeyDerivation.recordName(K_meta, zone, kind, id)`
/// with `kind`/`id` the plain name split at its first `-` (`target-7` → `target`, `7`), so a plain name alone
/// (a delete) maps to the same wire name as the record it names.
///
/// Inner frame: `kind` = the plain `CloudRecord.kind`, `id` = the plain record name, plus the notify level and the
/// asset descriptor; the wire record keeps only `modifiedAt` and the asset file in the clear (F28: no notify level).
///
/// F1: also `CompactingTransport` and `SweepingTransport`, so the hydrator (`ReplicaHydrator`), `RelayFeed` and the
/// hub's `sweepBuffer` keep reaching the buffer through their casts.
///
/// Relay reads (`changes(in: .relay)`): the hub passes `.hello` through sealed (F4) with kind `hello`, opens
/// `.relayToHub` from a sender with an accepted epoch, and opens its own `.relayToPhone` echoes (F2); the phone opens
/// `.relayToPhone` under its own key and its own `.relayToHub` records. Everything else is dropped and reported
/// once per wire name through `onRejected`. Every opened record passes the rollback guard keyed by (wire name,
/// sender) (F3); signals (DataZone only) are refused here. A locked keychain makes `changes` throw
/// `SecureTransportError.keysUnavailable` so the consumer keeps its token and replays (Review Focus 1). `deletedRecordNames` are passed through as wire names.
public actor SecureTransport: CloudSyncTransport, CompactingTransport, SweepingTransport {
    private static let relayKinds: Set<String> = [
        RelayRecordKind.action.rawValue, RelayRecordKind.recordingUpload.rawValue, RelayRecordKind.device.rawValue
    ]
    private static let signalPrefix = "\(WireKind.signal)-"
    private static let keyboxPrefix = "keybox-"
    private static let grantPrefix = "\(SliceKind.deviceGrant.rawValue)-"
    private static let helloPrefix = "\(RelayRecordKind.hello.rawValue)-"
    private static let rolledBackReason = "rolledBack"

    private let inner: any CloudSyncTransport & Sendable
    private let keys: any SecureKeyProvider
    private let rollback: any RollbackGuard
    private let names: (any WireNameIndex)?
    private let onRejected: (@Sendable (_ wireName: String, _ reason: String) -> Void)?
    /// Wire → plain names this process sealed or opened.
    private var knownNames: [String: String] = [:]
    /// "<wire name>|<reason>" already reported: another phone's records come back on every full read.
    private var reported: Set<String> = []
    private let logger = Logger(subsystem: "WatchtowerKit", category: "SecureTransport")

    public init(
        inner: any CloudSyncTransport & Sendable,
        keys: any SecureKeyProvider,
        rollback: any RollbackGuard,
        names: (any WireNameIndex)? = nil,
        onRejected: (@Sendable (_ wireName: String, _ reason: String) -> Void)? = nil
    ) {
        self.inner = inner
        self.keys = keys
        self.rollback = rollback
        self.names = names
        self.onRejected = onRejected
    }

    // MARK: - Naming

    nonisolated public func wireName(for record: CloudRecord) throws -> String {
        record.kind == WireKind.signal ? record.recordName : try wireName(plain: record.recordName, zone: record.zone)
    }

    /// The epoch this side seals under now (the phone: its newest keybox's).
    nonisolated public func currentEpoch() throws -> UInt32 {
        try keys.currentEpoch()
    }

    nonisolated public func wireName(plain: String, zone: CloudZoneID) throws -> String {
        if plain.hasPrefix(Self.signalPrefix) { return plain }
        switch zone {
        case .data:
            if plain == HeartbeatPayload.recordName { return plain }
            if plain.hasPrefix(Self.grantPrefix) {
                return Keybox.recordName(deviceID: Self.canonicalDeviceID(String(plain.dropFirst(Self.grantPrefix.count))))
            }
        case .relay:
            if plain.hasPrefix(Self.helloPrefix) { return plain }
        }
        let parts = Self.namingParts(plain)
        return KeyDerivation.recordName(metaKey: try keys.metaKey(), zone: zone, kind: parts.kind, id: parts.id)
    }

    /// The plain name of a sealed record (the rejected-record callback, Task 11): `names` first (persisted, F19),
    /// then the key-free names, then the records sealed or opened in this process.
    public func plainName(forWire wireName: String) -> String? {
        if let persisted = names?.plainName(forWire: wireName) { return persisted }
        if wireName == HeartbeatPayload.recordName || wireName.hasPrefix(Self.signalPrefix)
            || wireName.hasPrefix(Self.helloPrefix) {
            return wireName
        }
        if wireName.hasPrefix(Self.keyboxPrefix) {
            return Self.grantPrefix + wireName.dropFirst(Self.keyboxPrefix.count)
        }
        return knownNames[wireName]
    }

    private static func namingParts(_ plain: String) -> (kind: String, id: String) {
        guard let dash = plain.firstIndex(of: "-") else { return (plain, "") }
        return (String(plain[..<dash]), String(plain[plain.index(after: dash)...]))
    }

    /// F30: a device id is emitted as `uuidString`; a non-UUID id is left as it is.
    private static func canonicalDeviceID(_ raw: String) -> String {
        UUID(uuidString: raw)?.uuidString ?? raw
    }

    // MARK: - Sealing

    /// Plain → sealed wire record (kind "wt", payload = envelope, asset descriptor inside the frame).
    public func seal(_ record: CloudRecord) throws -> CloudRecord {
        let wire = try wireName(for: record)
        let context = EnvelopeContext(zone: record.zone, wireName: wire)
        let frame = InnerFrame(
            kind: record.kind, id: record.recordName, notifyLevel: record.notifyLevel, asset: record.asset,
            payload: record.payload)
        let envelope: Data
        switch keys.role {
        case .hub(let hubID):
            envelope = try sealAsHub(record, frame: frame, context: context, hubID: hubID)
        case let .phone(hubID, deviceID):
            envelope = try sealAsPhone(record, frame: frame, context: context, hubID: hubID, deviceID: deviceID)
        }
        knownNames[wire] = record.recordName
        return CloudRecord(
            recordName: wire, zone: record.zone, kind: WireKind.envelope, modifiedAt: record.modifiedAt,
            payload: envelope, notifyLevel: nil, assetFileURL: record.assetFileURL)
    }

    private func sealAsHub(_ record: CloudRecord, frame: InnerFrame, context: EnvelopeContext, hubID: UUID) throws -> Data {
        let epoch = try keys.currentEpoch()
        switch record.zone {
        case .data:
            if record.kind == SliceKind.deviceGrant.rawValue {
                let rawID = String(record.recordName.dropFirst(Self.grantPrefix.count))
                guard record.recordName.hasPrefix(Self.grantPrefix), let deviceID = UUID(uuidString: rawID),
                      let recipient = try keys.keyboxRecipient(deviceID: deviceID)
                else { throw SecureTransportError.noKeyboxRecipient(record.recordName) }
                return try SealedBox.seal(
                    frame, envelopeClass: .keybox, to: recipient, info: SealedBox.keyboxInfo(hubID: hubID, deviceID: deviceID),
                    hubID: hubID, senderID: hubID, epoch: epoch, seq: try keys.nextSeq(), context: context,
                    signer: try keys.hubSigner())
            }
            guard SliceKind(rawValue: record.kind) != nil else { throw SecureTransportError.unknownKind(record.kind) }
            let isAlert = record.kind == SliceKind.askAlert.rawValue
            return try EnvelopeSealer.sealSymmetric(
                frame, envelopeClass: isAlert ? .alert : .data,
                key: try isAlert ? keys.alertKey(epoch: epoch) : keys.dataKey(epoch: epoch),
                hubID: hubID, senderID: hubID, epoch: epoch, seq: try keys.nextSeq(), context: context,
                signer: try keys.hubSigner())
        case .relay:
            guard Self.relayKinds.contains(record.kind) else { throw SecureTransportError.unknownKind(record.kind) }
            let recipient = try echoRecipient(record, hubID: hubID)
            return try EnvelopeSealer.sealSymmetric(
                frame, envelopeClass: .relayToPhone, key: try keys.relayKey(.hubToPhone, deviceID: recipient, epoch: epoch),
                hubID: hubID, senderID: hubID, epoch: epoch, seq: try keys.nextSeq(), context: context, signer: nil)
        }
    }

    /// F16: the authenticated sender of the record being answered; else the payload's `device_id`. The sealed info
    /// of the hub's own opened echo names the hub, so that one falls back to the payload too.
    private func echoRecipient(_ record: CloudRecord, hubID: UUID) throws -> UUID {
        if let sender = record.sealed?.senderID, sender != hubID { return sender }
        let object = try? JSONSerialization.jsonObject(with: record.payload) as? [String: Any]
        guard let raw = object?["device_id"] as? String, let deviceID = UUID(uuidString: raw) else {
            throw SecureTransportError.noRelayRecipient(record.recordName)
        }
        return deviceID
    }

    private func sealAsPhone(
        _ record: CloudRecord, frame: InnerFrame, context: EnvelopeContext, hubID: UUID, deviceID: UUID
    ) throws -> Data {
        guard record.zone == .relay else { throw SecureTransportError.wrongRole }
        let epoch = try keys.currentEpoch()
        if record.kind == RelayRecordKind.hello.rawValue {
            return try SealedBox.seal(
                frame, envelopeClass: .hello, to: try keys.hubAgreementPublicKey(),
                info: SealedBox.helloInfo(hubID: hubID, linkNonce: try keys.linkNonce()),
                hubID: hubID, senderID: deviceID, epoch: epoch, seq: try keys.nextSeq(), context: context,
                signer: try keys.deviceSigner())
        }
        guard Self.relayKinds.contains(record.kind) else { throw SecureTransportError.unknownKind(record.kind) }
        return try EnvelopeSealer.sealSymmetric(
            frame, envelopeClass: .relayToHub, key: try keys.relayKey(.phoneToHub, deviceID: deviceID, epoch: epoch),
            hubID: hubID, senderID: deviceID, epoch: epoch, seq: try keys.nextSeq(), context: context, signer: nil)
    }

    // MARK: - CloudSyncTransport

    /// Sends already-sealed wire records unchanged (stored envelopes: outbox rows, uploads; Review Focus 2).
    public func saveSealed(_ records: [CloudRecord]) async throws {
        try await inner.save(records)
    }

    /// Seals every record (signals pass through unsealed, F12), then sends them in order.
    public func save(_ records: [CloudRecord]) async throws {
        let wire = try records.map { $0.kind == WireKind.signal ? $0 : try seal($0) }
        try await inner.save(wire)
    }

    /// Plain names → wire names.
    public func delete(recordNames: [String], in zone: CloudZoneID) async throws {
        let wire = try recordNames.map { try wireName(plain: $0, zone: zone) }
        try await inner.delete(recordNames: wire, in: zone)
    }

    public func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        let batch = try await inner.changes(in: zone, since: token)
        guard zone == .relay else { return filterDataSignals(batch) }
        var changed: [CloudRecord] = []
        for record in batch.changed {
            switch try open(record) {
            case .opened(let plain): changed.append(plain)
            case .unopenable(let reason): report(record.recordName, reason: reason)
            case .rolledBack: break
            }
        }
        return CloudChangeBatch(changed: changed, deletedRecordNames: batch.deletedRecordNames, newToken: batch.newToken)
    }

    /// DataZone envelopes pass through untouched (the replica verifies and opens them). A plaintext `sig` record
    /// passes only in the signal shape (F12): a `sig-` name and an empty payload; anything else is dropped and
    /// reported as `malformedSignal`, never handed to the consumer.
    private func filterDataSignals(_ batch: CloudChangeBatch) -> CloudChangeBatch {
        let changed = batch.changed.filter { record in
            guard record.kind == WireKind.signal else { return true }
            guard record.recordName.hasPrefix(Self.signalPrefix), record.payload.isEmpty else {
                report(record.recordName, reason: "malformedSignal")
                return false
            }
            return true
        }
        return CloudChangeBatch(changed: changed, deletedRecordNames: batch.deletedRecordNames, newToken: batch.newToken)
    }

    /// F1: forwards when `inner` conforms to `CompactingTransport`; otherwise a no-op (the cast a consumer used to
    /// skip, so nothing changes for an inner transport that buffers nothing).
    public func compact(in zone: CloudZoneID, keepSince token: CloudChangeToken) async throws {
        guard let compacting = inner as? any CompactingTransport else { return }
        try await compacting.compact(in: zone, keepSince: token)
    }

    /// F1: forwards when `inner` conforms to `SweepingTransport`; otherwise a no-op returning 0.
    @discardableResult
    public func sweepEvents(in zone: CloudZoneID, olderThan cutoff: Date, upTo token: CloudChangeToken) async throws -> Int {
        guard let sweeping = inner as? any SweepingTransport else { return 0 }
        return try await sweeping.sweepEvents(in: zone, olderThan: cutoff, upTo: token)
    }

    // MARK: - Hub relay hygiene (F2)

    /// The full-scan view of RelayZone: the opened records (`changes` semantics, own h2p echoes included) plus every
    /// record nobody here can open or the rollback guard refuses, by wire name, plaintext `modifiedAt` and reason.
    /// Reports nothing through `onRejected`.
    public func relayHygieneScan() async throws -> (opened: [CloudRecord], unopenable: [UnopenableRecord]) {
        let batch = try await inner.changes(in: .relay, since: nil)
        var opened: [CloudRecord] = []
        var unopenable: [UnopenableRecord] = []
        for record in batch.changed {
            switch try open(record) {
            case .opened(let plain): opened.append(plain)
            case .unopenable(let reason):
                unopenable.append(UnopenableRecord(wireName: record.recordName, modifiedAt: record.modifiedAt, reason: reason))
            case .rolledBack:
                // The server holds an older version than one already seen: hygiene must still be able to age it out.
                unopenable.append(UnopenableRecord(
                    wireName: record.recordName, modifiedAt: record.modifiedAt, reason: Self.rolledBackReason))
            }
        }
        return (opened, unopenable)
    }

    /// Deletes by wire name (records that never opened have no plain name).
    public func deleteWire(wireNames: [String], in zone: CloudZoneID) async throws {
        try await inner.delete(recordNames: wireNames, in: zone)
    }

    // MARK: - Opening

    private enum OpenOutcome {
        case opened(CloudRecord)
        case unopenable(String)
        case rolledBack
    }

    /// Throws only `keysUnavailable` (a locked keychain) and the provider's or the guard's other errors unchanged;
    /// everything about the record itself is an `.unopenable` outcome.
    private func open(_ record: CloudRecord) throws -> OpenOutcome {
        // Signals live in DataZone only (D14), which passes through untouched; a "sig" record in RelayZone is
        // unauthenticated plaintext anyone could write, so it is never handed over.
        if record.kind == WireKind.signal { return .unopenable("signalInRelayZone") }
        do {
            return try openRelay(record)
        } catch KeyStoreError.locked {
            throw SecureTransportError.keysUnavailable
        }
    }

    private func openRelay(_ record: CloudRecord) throws -> OpenOutcome {
        let header: EnvelopeHeader
        do { header = try Envelope.parse(record.payload).header } catch let error as EnvelopeError {
            return .unopenable(Self.code(error))
        }
        guard header.hubID == keys.role.hubID else { return .unopenable("wrongHub") }
        let decrypted: Decrypted
        do {
            decrypted = try decrypt(record, header: header)
        } catch let error as EnvelopeError {
            // Wrong key, moved record, flipped bit, malformed frame: the record's fault, never the keychain's.
            return .unopenable(Self.code(error))
        }
        switch decrypted {
        case .passThrough(let sealed): return .opened(sealed)
        case .refused(let reason): return .unopenable(reason)
        case let .frame(opened, frame): return try accept(record, header: opened, frame: frame)
        }
    }

    private enum Decrypted {
        case frame(EnvelopeHeader, InnerFrame)
        case passThrough(CloudRecord)
        case refused(String)
    }

    /// Picks the key by role and class. Throws `EnvelopeError` for an envelope that does not open.
    private func decrypt(_ record: CloudRecord, header: EnvelopeHeader) throws -> Decrypted {
        let context = EnvelopeContext(zone: .relay, wireName: record.recordName)
        let opened: (header: EnvelopeHeader, frame: InnerFrame)?
        switch (keys.role, header.envelopeClass) {
        case (.hub, .hello):
            // F4: the hub cannot know which kept code's nonce the HPKE info uses; handleHello tries each.
            guard record.recordName.hasPrefix(Self.helloPrefix) else { return .refused("helloName") }
            return .passThrough(CloudRecord(
                recordName: record.recordName, zone: .relay, kind: RelayRecordKind.hello.rawValue,
                modifiedAt: record.modifiedAt, payload: record.payload, assetFileURL: record.assetFileURL,
                creatorUserRecordName: record.creatorUserRecordName))
        case (.hub, .relayToHub):
            opened = try openSymmetric(record, header: header, context: context, direction: .phoneToHub, device: header.senderID)
        case let (.hub(hubID), .relayToPhone):
            guard header.senderID == hubID else { return .refused("wrongSender") }
            opened = try openOwnEcho(record, header: header, context: context)
        case let (.phone(hubID, deviceID), .relayToPhone):
            guard header.senderID == hubID else { return .refused("wrongSender") }
            opened = try openSymmetric(record, header: header, context: context, direction: .hubToPhone, device: deviceID)
        case let (.phone(_, deviceID), .relayToHub):
            guard header.senderID == deviceID else { return .refused("notForThisDevice") }
            opened = try openSymmetric(record, header: header, context: context, direction: .phoneToHub, device: deviceID)
        default:
            return .refused("class\(header.envelopeClass.rawValue)")
        }
        guard let opened else { return .refused("noRelayKey") }
        return .frame(opened.header, opened.frame)
    }

    /// Kind, name binding and the rollback guard for an opened relay frame.
    private func accept(_ record: CloudRecord, header: EnvelopeHeader, frame: InnerFrame) throws -> OpenOutcome {
        guard Self.relayKinds.contains(frame.kind) else { return .unopenable("unknownKind") }
        // The AAD binds the wire name; this binds the frame's plain name to it, so a sender cannot file a
        // record under another record's plain name.
        guard try wireName(plain: frame.id, zone: .relay) == record.recordName else { return .unopenable("nameMismatch") }
        switch try rollback.check(wireName: record.recordName, senderID: header.senderID, epoch: header.epoch, seq: header.seq) {
        case .older:
            logger.notice("ignored an older version of relay record \(record.recordName, privacy: .public)")
            return .rolledBack
        case .newer:
            try rollback.record(wireName: record.recordName, senderID: header.senderID, epoch: header.epoch, seq: header.seq)
        case .same:
            break
        }
        knownNames[record.recordName] = frame.id
        return .opened(CloudRecord(
            recordName: frame.id, zone: .relay, kind: frame.kind, modifiedAt: record.modifiedAt, payload: frame.payload,
            notifyLevel: frame.notifyLevel, assetFileURL: record.assetFileURL,
            creatorUserRecordName: record.creatorUserRecordName, asset: frame.asset,
            sealed: SealedInfo(
                wireName: record.recordName, senderID: header.senderID, epoch: header.epoch, seq: header.seq,
                envelopeClass: header.envelopeClass)))
    }

    /// nil when this side holds no relay key for the device at that epoch (unknown sender, epoch outside D10).
    /// An envelope that fails to open throws its `EnvelopeError`; the provider's errors propagate unchanged.
    private func openSymmetric(
        _ record: CloudRecord, header: EnvelopeHeader, context: EnvelopeContext, direction: RelayDirection, device: UUID
    ) throws -> (header: EnvelopeHeader, frame: InnerFrame)? {
        guard try keys.acceptsRelayEpoch(header.epoch, deviceID: device) else { return nil }
        let key = try keys.relayKey(direction, deviceID: device, epoch: header.epoch)
        return try EnvelopeSealer.openSymmetric(
            record.payload, accepting: [header.envelopeClass], context: context, verifier: nil) { _ in key }
    }

    /// F2: an h2p header names the hub, not the recipient, so the hub tries each linked device's h2p key.
    /// `authenticationFailed` under one device's key is the expected miss; nil when none opens it.
    private func openOwnEcho(
        _ record: CloudRecord, header: EnvelopeHeader, context: EnvelopeContext
    ) throws -> (header: EnvelopeHeader, frame: InnerFrame)? {
        for device in try keys.relayDeviceIDs() {
            do {
                if let opened = try openSymmetric(record, header: header, context: context, direction: .hubToPhone, device: device) {
                    return opened
                }
            } catch EnvelopeError.authenticationFailed {
                continue
            }
        }
        return nil
    }

    private func report(_ wireName: String, reason: String) {
        guard reported.insert("\(wireName)|\(reason)").inserted else { return }
        // Another phone's records in a shared zone are expected; the hub sees strangers in relayHygieneScan.
        logger.debug("dropped relay record \(wireName, privacy: .public): \(reason, privacy: .public)")
        onRejected?(wireName, reason)
    }

    private static func code(_ error: EnvelopeError) -> String {
        String(describing: error)
    }
}

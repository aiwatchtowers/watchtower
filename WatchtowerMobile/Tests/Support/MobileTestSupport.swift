import CryptoKit
import Foundation
import GRDB
import Observation
import WatchtowerE2ETesting
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Counts how often an `@Observable` property is SET (a set notifies its
/// observers even when the value is equal), re-arming the tracking after
/// each notification.
@MainActor
final class ObservedSetCounter {
    private(set) var count = 0
    private let read: @MainActor () -> Void

    init(_ read: @escaping @MainActor () -> Void) {
        self.read = read
        arm()
    }

    private func arm() {
        withObservationTracking { read() } onChange: { [weak self] in
            Task { @MainActor in
                self?.count += 1
                self?.arm()
            }
        }
    }
}

/// Collects every value an async sequence publishes, so a test waits for
/// them with a bounded `poll` instead of an unbounded `next()`.
@MainActor
final class PublishedValues<Value: Sendable> {
    private(set) var values: [Value] = []
    private(set) var failure: (any Error)?
    private var task: Task<Void, Never>?

    init<S: AsyncSequence & Sendable>(_ sequence: S) where S.Element == Value {
        task = Task { [weak self] in
            do {
                for try await value in sequence {
                    self?.values.append(value)
                }
            } catch {
                self?.failure = error
            }
        }
    }

    func cancel() {
        task?.cancel()
    }
}

/// A fetch-loop sleeper the test steps by hand: each sleep records its
/// interval and waits for `tick()`; a cancelled sleep throws at once.
@MainActor
final class TickSleeper {
    private(set) var requested: [Duration] = []
    private var waiting: [UUID: CheckedContinuation<Void, Error>] = [:]

    var waitingCount: Int { waiting.count }

    func sleep(_ interval: Duration) async throws {
        requested.append(interval)
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                MainActor.assumeIsolated { park(id, continuation) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel(id) }
        }
    }

    private func park(_ id: UUID, _ continuation: CheckedContinuation<Void, Error>) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            waiting[id] = continuation
        }
    }

    /// Ends every sleep waiting now.
    func tick() {
        let all = waiting
        waiting = [:]
        all.values.forEach { $0.resume() }
    }

    private func cancel(_ id: UUID) {
        waiting.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    /// Ends every sleep waiting now as cancelled (a test's teardown).
    func cancelAll() {
        let all = waiting
        waiting = [:]
        all.values.forEach { $0.resume(throwing: CancellationError()) }
    }
}

extension XCTestCase {
    /// A pool-backed replica on a throwaway temp path: the production
    /// mechanism (`DatabasePool` + WAL) the app's observations run against,
    /// opened with `pairing`'s phone keys.
    func makePoolStore(_ pairing: TestPhone.Pairing = .test) throws -> ReplicaStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-replica-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try TestPhone.replica(path: dir.appendingPathComponent("replica.sqlite").path, pairing)
    }

    /// A throwaway replica path whose directory is removed on teardown.
    func makeReplicaPath() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("replica.sqlite").path
    }

    /// `reader` was closed (#216): a read fails as on a closed connection,
    /// not with the disk I/O error of one left open on deleted files.
    func assertClosed(_ reader: (any DatabaseReader)?, file: StaticString = #filePath, line: UInt = #line) {
        guard let reader else { return XCTFail("no database", file: file, line: line) }
        XCTAssertThrowsError(try reader.read { _ in }, file: file, line: line) { error in
            XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_MISUSE, "\(error)", file: file, line: line)
        }
    }

    /// A private UserDefaults suite, wiped on teardown.
    func makeDefaults() throws -> UserDefaults {
        let name = "mobile-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    /// Polls the main run loop until `condition` holds or the timeout
    /// elapses: the environment's bootstrap and the observations deliver
    /// asynchronously, so tests must yield to let them land.
    @MainActor
    func poll(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool,
        _ message: @autoclosure () -> String = "condition not met in time",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), message(), file: file, line: line)
    }
}

/// The phone tests' pairings: the Kit's test pairing (`TestE2E`, F25) by default, the demo pairing
/// (`DemoSeed+E2E`) for the demo seed (its grant is the demo phone's keybox). Replicas open with the paired phone's
/// keys, records a test puts into a transport are sealed by the pairing's hub (never plaintext), and the outbox, the
/// uploader and the feed run over the paired phone's `SecureTransport`.
enum TestPhone {
    enum Pairing {
        case test
        case demo
    }

    /// Each hub and phone gets its own block of seqs above every earlier one: the replica refuses an older
    /// `(epoch, seq)` of a record it holds, so a later hub must never restart below an earlier one.
    private static let seqBlock: UInt64 = 1_000_000
    private static let seqLock = NSLock()
    nonisolated(unsafe) private static var nextFirstSeq: UInt64 = 1

    /// A fresh block of seqs above every earlier one (`TestHub`'s hubs and phones take theirs here too).
    static func nextSeqBlock() -> UInt64 { firstSeq() }

    private static func firstSeq() -> UInt64 {
        seqLock.withLock {
            defer { nextFirstSeq += seqBlock }
            return nextFirstSeq
        }
    }

    /// The paired phone's keys (also what an `AppEnvironment` takes).
    static func keys(_ pairing: Pairing = .test) throws -> PhoneKeys {
        switch pairing {
        case .test: PhoneKeys(store: try TestE2E.phoneStore(), hubID: TestE2E.hubID.uuidString)
        case .demo: try DemoSeed.phoneKeys()
        }
    }

    /// The paired phone's device id, as the outbox, the uploader and the grants spell it.
    static func deviceID(_ pairing: Pairing = .test) -> String {
        switch pairing {
        case .test: TestE2E.deviceID.uuidString
        case .demo: DemoSeed.device.deviceID
        }
    }

    /// An in-memory replica opened with the paired phone's keys.
    static func replica(_ pairing: Pairing = .test) throws -> ReplicaStore {
        try ReplicaStore.inMemory(opener: opener(pairing))
    }

    /// An on-disk replica at `path`, opened with the paired phone's keys.
    static func replica(path: String, _ pairing: Pairing = .test, observesSuspension: Bool = false) throws -> ReplicaStore {
        try ReplicaStore(path: path, opener: opener(pairing), observesSuspension: observesSuspension)
    }

    private static func opener(_ pairing: Pairing) throws -> EnvelopeReplicaOpener {
        let keys = try keys(pairing)
        return EnvelopeReplicaOpener(hubID: keys.hubID, deviceID: try keys.store.identity().deviceID, keys: keys.store)
    }

    /// The paired phone sealing and opening over `inner`.
    static func transport(
        over inner: any CloudSyncTransport & Sendable = InMemoryCloudTransport(), _ pairing: Pairing = .test
    ) throws -> SecureTransport {
        let keys = try keys(pairing)
        let first = firstSeq()
        let provider = try PhoneKeyProvider(
            store: keys.store, hubID: keys.hubID, seq: SeqAllocator(load: { first }, store: { _ in }))
        return SecureTransport(inner: inner, keys: provider, rollback: InMemoryRollbackGuard())
    }

    /// The pairing's hub sealing over `inner`: what a test saves through it reaches the transport as the Mac's
    /// envelopes do.
    static func hub(over inner: any CloudSyncTransport & Sendable, _ pairing: Pairing = .test) -> SecureTransport {
        switch pairing {
        case .test: TestE2E.hubTransport(TestE2E.hub(firstSeq: firstSeq()), inner: inner)
        case .demo:
            DemoSeed.hubTransport(inner: inner, seq: { first in SeqAllocator(load: { first }, store: { _ in }) }(firstSeq()))
        }
    }

    /// `plain` as the hub ships a record's asset: sealed into `url`, its
    /// descriptor riding in the record's frame.
    static func sealAsset(_ plain: Data, to url: URL) throws -> AssetDescriptor {
        let (sealed, descriptor) = try ChunkedAssetCipher.encrypt(plain)
        try sealed.write(to: url)
        return descriptor
    }

    /// `grant` as the hub publishes it since E2E: its `device_grant-<device_id>` record carrying the keybox, with
    /// `keys` when given.
    static func grantRecord(_ grant: DeviceGrant, keys: KeyboxKeys? = nil, modifiedAt: Date) throws -> CloudRecord {
        let plain = try CloudRecordFactory.record(for: grant, modifiedAt: modifiedAt)
        return CloudRecord(
            recordName: plain.recordName, zone: plain.zone, kind: plain.kind, modifiedAt: modifiedAt,
            payload: try RelayCoder.makeEncoder().encode(Keybox(grant: grant, keys: keys)))
    }

    /// The test hub's epoch keys as its keybox carries them (base64url of 32 bytes each).
    static func keyboxKeys(epoch: UInt32 = 1) -> KeyboxKeys {
        func text(_ key: SymmetricKey) -> String { WireBytes.base64URL(key.withUnsafeBytes { Data($0) }) }
        return KeyboxKeys(
            epoch: epoch, dataKey: text(TestE2E.dataKey(epoch: epoch)), alertKey: text(TestE2E.alertKey(epoch: epoch)),
            metaKey: text(TestE2E.metaKey))
    }

    /// The confirm nonce the test hub draws for a hello (SAS v2), as raw bytes and as the keybox carries it.
    static let confirmNonce = Data(repeating: 0x5A, count: KeyDerivation.confirmNonceLength)
    static var confirmNonceText: String { WireBytes.base64URL(confirmNonce) }

    /// The `link_code_tag` the hub puts into a waiting keybox for a request made with `code`.
    static func linkCodeTag(_ code: LinkPayload) throws -> String {
        KeyDerivation.linkCodeTag(linkNonce: try XCTUnwrap(WireBytes.fromBase64URL(code.nonce)))
    }

    /// A v3 code of the test hub (its keys and link nonce), issued at `iat`.
    static func linkCode(iat: Int64, macName: String = "Acme Mac") -> LinkPayload {
        LinkPayload(
            hubID: TestE2E.hubID.uuidString, macName: macName, ownerUser: "_owner-acme",
            nonce: WireBytes.base64URL(TestE2E.linkNonce), iat: iat, exp: iat + LinkPayload.lifetime,
            hubSigningKey: WireBytes.base64URL(TestE2E.hubSigningKey.publicKey.rawRepresentation),
            hubAgreementKey: WireBytes.base64URL(TestE2E.hubAgreementKey.publicKey.rawRepresentation))
    }

    /// The Mac's side of a sealed hello (`MobileLinkCenter.openHello`): opened with the test hub's agreement key
    /// under the code's nonce, its signature checked with the enclosed device key, and the code the hub shows for
    /// it, computed as the hub does (`MobileLinkCenter.handleHello`) with the confirm nonce the hub drew (SAS v2).
    static func openHello(
        _ record: CloudRecord, code: LinkPayload, confirmNonce: Data = Self.confirmNonce
    ) throws -> (hello: DeviceHello, sas: String) {
        let hubUUID = try WireBytes.hubUUID(code.hubID)
        let nonce = try XCTUnwrap(WireBytes.fromBase64URL(code.nonce))
        let context = EnvelopeContext(zone: .relay, wireName: record.recordName)
        let opened = try SealedBox.open(
            record.payload, envelopeClass: .hello, recipient: TestE2E.hubAgreementKey,
            info: SealedBox.helloInfo(hubID: hubUUID, linkNonce: nonce), context: context, verifier: nil)
        let hello = try RelayCoder.makeDecoder().decode(DeviceHello.self, from: opened.frame.payload)
        let signing = try Curve25519.Signing.PublicKey(
            rawRepresentation: try XCTUnwrap(WireBytes.fromBase64URL(hello.signingKey)))
        let agreement = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: try XCTUnwrap(WireBytes.fromBase64URL(hello.agreementKey)))
        try EnvelopeSealer.verify(try Envelope.parse(record.payload), context: context, key: signing)
        XCTAssertEqual(opened.header.senderID, KeyDerivation.deviceID(signingPublicKey: signing), "D7: the sender is the key's hash")
        let sas = KeyDerivation.sas(
            hubID: hubUUID, linkNonce: nonce,
            hubSigning: TestE2E.hubSigningKey.publicKey, hubAgreement: TestE2E.hubAgreementKey.publicKey,
            deviceSigning: signing, deviceAgreement: agreement, confirmNonce: confirmNonce)
        return (hello, sas)
    }
}

/// A clock the test moves by hand (seeded from now).
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date()

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}

/// Test hubs for several Macs (multi-hub F2 under E2E): the Kit's test hub (`TestE2E`, `acme`) and others, each with
/// its own key material derived from its id, all linked to the test pairing's phone. A session gets only its own
/// hub's keys (`HubSession` refuses another hub's), so a test of two Macs uses two of these.
enum TestHub {
    static let acme = TestE2E.hubID.uuidString
    static let home = "40E00000-0000-4000-8000-000000000004"
    static let studio = "5D0D1000-0000-4000-8000-000000000002"
    static let lab = "1AB00000-0000-4000-8000-000000000006"
    static let work = "C0DE0000-0000-4000-8000-000000000007"
    static let fresh = "A1E90000-0000-4000-8000-000000000008"
    static let fifth = "F1F70000-0000-4000-8000-000000000005"
    static let orphan = "0E5A0000-0000-4000-8000-000000000009"
    static let pending = "BE4D0000-0000-4000-8000-00000000000A"
    static let gone = "D0E50000-0000-4000-8000-00000000000B"
    static let remove = "DE1E0000-0000-4000-8000-00000000000C"
    static let hubA = "AAAA0000-0000-4000-8000-00000000000D"
    static let hubB = "BBBB0000-0000-4000-8000-00000000000E"

    /// The phone's keys for `hubID` in a fresh test-pairing store that holds that hub's link; nil for an id that
    /// is not a UUID (no hub of E2E has one: the session runs key-less).
    static func keys(_ hubID: String) throws -> PhoneKeys? {
        let store = try TestE2E.phoneStore()
        return try keys(hubID, store: store)
    }

    /// The phone's keys for `hubID` over `store`, its link saved there when missing.
    static func keys(_ hubID: String, store: InMemoryPhoneKeyStore) throws -> PhoneKeys? {
        guard UUID(uuidString: hubID) != nil else { return nil }
        try link(hubID, into: store)
        return PhoneKeys(store: store, hubID: hubID)
    }

    /// Saves `hubID`'s link (epoch 1) into `store` unless it holds one.
    static func link(_ hubID: String, into store: InMemoryPhoneKeyStore) throws {
        guard try store.hubLink(hubID) == nil else { return }
        let keys = HubKeys(hubID)
        try store.saveHubLink(HubLinkKeys(
            hubID: hubID,
            hubSigningKey: keys.signing.publicKey.rawRepresentation,
            hubAgreementKey: keys.agreement.publicKey.rawRepresentation,
            linkNonce: keys.linkNonce,
            metaKey: HubKeys.raw(keys.metaKey),
            epochs: [EpochKeys(epoch: 1, dataKey: HubKeys.raw(keys.dataKey(1)), alertKey: HubKeys.raw(keys.alertKey(1)))]
        ))
    }

    /// `hubID`'s hub sealing over `inner` (what a test saves reaches the transport as that Mac's envelopes).
    static func hub(over inner: any CloudSyncTransport & Sendable, _ hubID: String) -> SecureTransport {
        guard hubID != acme else { return TestPhone.hub(over: inner) }
        return SecureTransport(inner: inner, keys: TestHubKeys(HubKeys(hubID), firstSeq: TestPhone.nextSeqBlock()),
                               rollback: InMemoryRollbackGuard())
    }

    /// The paired phone sealing and opening for `hubID` over `inner`.
    static func phone(over inner: any CloudSyncTransport & Sendable, _ hubID: String) throws -> SecureTransport {
        guard hubID != acme else { return try TestPhone.transport(over: inner) }
        let keys = try XCTUnwrap(try keys(hubID))
        let first = TestPhone.nextSeqBlock()
        let provider = try PhoneKeyProvider(store: keys.store, hubID: hubID, seq: SeqAllocator(load: { first }, store: { _ in }))
        return SecureTransport(inner: inner, keys: provider, rollback: InMemoryRollbackGuard())
    }

    /// One hub's key material, derived from its id (the Kit's test hub keeps `TestE2E`'s).
    struct HubKeys {
        let uuid: UUID
        let signing: Curve25519.Signing.PrivateKey
        let agreement: Curve25519.KeyAgreement.PrivateKey
        let linkNonce: Data
        let metaKey: SymmetricKey
        private let label: String

        init(_ hubID: String) {
            // swiftlint:disable:next force_unwrapping
            uuid = UUID(uuidString: hubID)!
            label = hubID
            // 32 bytes by construction: any 32-byte seed is a valid key.
            // swiftlint:disable force_try
            signing = try! Curve25519.Signing.PrivateKey(rawRepresentation: Self.bytes("\(hubID)/sig"))
            agreement = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.bytes("\(hubID)/kx"))
            // swiftlint:enable force_try
            linkNonce = Data(Self.bytes("\(hubID)/nonce").prefix(16))
            metaKey = SymmetricKey(data: Self.bytes("\(hubID)/meta"))
        }

        func dataKey(_ epoch: UInt32) -> SymmetricKey { SymmetricKey(data: Self.bytes("\(label)/data/\(epoch)")) }
        func alertKey(_ epoch: UInt32) -> SymmetricKey { SymmetricKey(data: Self.bytes("\(label)/alert/\(epoch)")) }

        static func bytes(_ label: String) -> Data { Data(SHA256.hash(data: Data("wt-test-hub/\(label)".utf8))) }
        static func raw(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
    }
}

/// A test hub's `SecureKeyProvider` (hub role): epoch 1, the test pairing's phone linked.
private final class TestHubKeys: SecureKeyProvider, @unchecked Sendable {
    private let keys: TestHub.HubKeys
    private let lock = NSLock()
    private var seq: UInt64

    init(_ keys: TestHub.HubKeys, firstSeq: UInt64) {
        self.keys = keys
        seq = firstSeq
    }

    var role: SecureRole { .hub(hubID: keys.uuid) }
    private var phone: DeviceIdentityKeys { TestE2E.deviceIdentity }

    func metaKey() throws -> SymmetricKey { keys.metaKey }
    func currentEpoch() throws -> UInt32 { 1 }
    func dataKey(epoch: UInt32) throws -> SymmetricKey { keys.dataKey(epoch) }
    func alertKey(epoch: UInt32) throws -> SymmetricKey { keys.alertKey(epoch) }

    func relayKey(_ direction: RelayDirection, deviceID: UUID, epoch: UInt32) throws -> SymmetricKey {
        guard deviceID == phone.deviceID else { throw KeyStoreError.corrupt("no relay key") }
        return try KeyDerivation.relayKey(
            agreementPrivate: keys.agreement, peerPublic: phone.agreement.publicKey, linkNonce: keys.linkNonce,
            hubID: keys.uuid, deviceID: deviceID, epoch: epoch, direction: direction)
    }

    func acceptsRelayEpoch(_ epoch: UInt32, deviceID: UUID) throws -> Bool { deviceID == phone.deviceID && epoch == 1 }
    func relayDeviceIDs() throws -> [UUID] { [phone.deviceID] }

    func nextSeq() throws -> UInt64 {
        lock.withLock {
            defer { seq += 1 }
            return seq
        }
    }

    func hubSigner() throws -> Curve25519.Signing.PrivateKey { keys.signing }
    func hubAgreement() throws -> Curve25519.KeyAgreement.PrivateKey { keys.agreement }
    func keyboxRecipient(deviceID: UUID) throws -> Curve25519.KeyAgreement.PublicKey? {
        deviceID == phone.deviceID ? phone.agreement.publicKey : nil
    }

    func deviceSigner() throws -> Curve25519.Signing.PrivateKey { throw SecureTransportError.wrongRole }
    func hubAgreementPublicKey() throws -> Curve25519.KeyAgreement.PublicKey { throw SecureTransportError.wrongRole }
    func linkNonce() throws -> Data { throw SecureTransportError.wrongRole }
}

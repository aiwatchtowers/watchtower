import CryptoKit
import Foundation
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
    static func replica(path: String, _ pairing: Pairing = .test) throws -> ReplicaStore {
        try ReplicaStore(path: path, opener: opener(pairing))
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
    /// it, computed as the hub does (`MobileLinkCenter.handleHello`).
    static func openHello(_ record: CloudRecord, code: LinkPayload) throws -> (hello: DeviceHello, sas: String) {
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
            deviceSigning: signing, deviceAgreement: agreement)
        return (hello, sas)
    }
}

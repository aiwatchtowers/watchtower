import CryptoKit
import Foundation
import UIKit
import WatchtowerE2ETesting
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The live key store's in-memory cache (mobile E2E Task 17): an observation refetch opens every row, and each
/// open used to read the hub link and the signing key from the Keychain. The cache serves them while the phone is
/// unlocked, drops everything at the lock signal, and follows the link flow's own writes.
final class CachingPhoneKeyStoreTests: XCTestCase {
    /// Counts the reads that reach the wrapped store (the Keychain).
    private final class CountingStore: PhoneKeyStore, @unchecked Sendable {
        let inner: InMemoryPhoneKeyStore
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        init(_ inner: InMemoryPhoneKeyStore) {
            self.inner = inner
        }

        func reads(_ name: String) -> Int { lock.withLock { counts[name] ?? 0 } }

        private func count(_ name: String) {
            lock.withLock { counts[name, default: 0] += 1 }
        }

        func identity() throws -> DeviceIdentityKeys {
            count("identity")
            return try inner.identity()
        }

        func existingIdentity() throws -> DeviceIdentityKeys? {
            count("existingIdentity")
            return try inner.existingIdentity()
        }

        func hubLink(_ hubID: String) throws -> HubLinkKeys? {
            count("hubLink")
            return try inner.hubLink(hubID)
        }

        func saveHubLink(_ keys: HubLinkKeys) throws { try inner.saveHubLink(keys) }
        func removeHubLink(_ hubID: String) throws { try inner.removeHubLink(hubID) }

        func hubSigningKey(_ hubID: String) throws -> Curve25519.Signing.PublicKey? {
            count("hubSigningKey")
            return try inner.hubSigningKey(hubID)
        }

        func alertMaterial(_ hubID: String) throws -> AlertMaterial? {
            count("alertMaterial")
            return try inner.alertMaterial(hubID)
        }

        func deviceID() throws -> UUID? {
            count("deviceID")
            return try inner.deviceID()
        }
    }

    private let hubID = TestE2E.hubID.uuidString

    private func makeStore() throws -> (cache: CachingPhoneKeyStore, counting: CountingStore, center: NotificationCenter) {
        let counting = CountingStore(try TestE2E.phoneStore())
        let center = NotificationCenter()
        return (CachingPhoneKeyStore(wrapping: counting, notifications: center), counting, center)
    }

    func testRepeatedReadsReachTheKeychainOnce() throws {
        let (cache, counting, _) = try makeStore()
        for _ in 0..<5 {
            _ = try cache.identity()
            _ = try cache.hubLink(hubID)
            _ = try cache.hubSigningKey(hubID)
            _ = try cache.deviceID()
        }
        for name in ["identity", "hubLink", "hubSigningKey", "deviceID"] {
            XCTAssertEqual(counting.reads(name), 1, "\(name) read more than once")
        }
        XCTAssertEqual(try cache.hubLink(hubID), try counting.inner.hubLink(hubID))
    }

    /// The lock signal drops every cached key: a locked keychain is never answered from memory. Going to the
    /// background does too (a suspended app is not told about a lock).
    func testTheLockAndTheBackgroundDropEveryCachedKey() throws {
        for signal in [
            UIApplication.protectedDataWillBecomeUnavailableNotification, UIApplication.didEnterBackgroundNotification
        ] {
            let (cache, counting, center) = try makeStore()
            _ = try cache.identity()
            _ = try cache.hubLink(hubID)

            center.post(name: signal, object: nil)
            counting.inner.isLocked = true

            XCTAssertThrowsError(try cache.hubLink(hubID), "\(signal.rawValue)") { XCTAssertEqual($0 as? KeyStoreError, .locked) }
            XCTAssertThrowsError(try cache.identity()) { XCTAssertEqual($0 as? KeyStoreError, .locked) }
            counting.inner.isLocked = false
            _ = try cache.hubLink(hubID)
            XCTAssertEqual(counting.reads("hubLink"), 3, "read again after \(signal.rawValue)")
        }
    }

    /// A failed read (locked) is not remembered: the next read after unlock reaches the keychain.
    func testALockedReadIsNotCached() throws {
        let (cache, counting, _) = try makeStore()
        counting.inner.isLocked = true
        XCTAssertThrowsError(try cache.hubLink(hubID))
        counting.inner.isLocked = false
        XCTAssertNotNil(try cache.hubLink(hubID))
        XCTAssertNotNil(try cache.hubLink(hubID))
        XCTAssertEqual(counting.reads("hubLink"), 2)
    }

    /// The link flow writes through the same store: a re-pair's new keys and an unlink are honoured at once.
    func testSavingAndRemovingALinkReplaceTheCachedOne() throws {
        let (cache, _, _) = try makeStore()
        let current = try XCTUnwrap(try cache.hubLink(hubID))
        let signing = try XCTUnwrap(try cache.hubSigningKey(hubID))
        let repaired = HubLinkKeys(
            hubID: hubID, hubSigningKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            hubAgreementKey: current.hubAgreementKey, linkNonce: current.linkNonce, metaKey: current.metaKey, epochs: [])

        try cache.saveHubLink(repaired)
        XCTAssertEqual(try cache.hubLink(hubID), repaired)
        XCTAssertNotEqual(try cache.hubSigningKey(hubID)?.rawRepresentation, signing.rawRepresentation, "the new signing key")

        try cache.removeHubLink(hubID)
        XCTAssertNil(try cache.hubLink(hubID))
        XCTAssertNil(try cache.hubSigningKey(hubID))
    }

    /// The measured case: opening every row of a replica read reads the hub link once, not once per row.
    func testAReplicaReadOfManyRowsReadsTheKeychainOnce() async throws {
        let (cache, counting, _) = try makeStore()
        let store = try ReplicaStore.inMemory(
            opener: EnvelopeReplicaOpener(hubID: hubID, deviceID: TestE2E.deviceID, keys: cache))
        let transport = InMemoryCloudTransport()
        let now = Date()
        try await TestPhone.hub(over: transport).save((1...20).map { id in
            CloudRecordFactory.record(for: SliceRecord(kind: .workbench, id: "\(id)", modifiedAt: now, payload: Data("{}".utf8)))
        })
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()

        let payloads = try await store.reader.read { db in try store.payloads(of: .workbench, from: db) }

        XCTAssertEqual(payloads.count, 20)
        XCTAssertEqual(counting.reads("hubLink"), 1, "one keychain read for 20 indexed and 20 read rows")
        XCTAssertEqual(counting.reads("hubSigningKey"), 1)
    }
}

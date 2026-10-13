import CryptoKit
import Foundation
import UIKit
import WatchtowerSync

/// The live key store with an in-memory cache (mobile E2E Task 17). Every replica row an observation opens reads
/// the hub link and the hub's signing key, and every observation refetches all its rows on each replica write: a
/// Keychain query per row per refetch. The cache keeps what was read while the phone is unlocked:
/// - the cache serves only while the app is known to run unlocked: from `didBecomeActive` or
///   `protectedDataDidBecomeAvailable` until `protectedDataWillBecomeUnavailable` (the lock), `willResignActive`
///   or `didEnterBackground`, each of which also drops everything. A suspended app is not told about a lock and may
///   next run from a push while locked: it then reads the Keychain, which throws `KeyStoreError.locked`, never
///   memory. It starts not serving;
/// - a failed read is never cached;
/// - the link flow writes through this same store: saving or removing a hub's link replaces its cached keys, so a
///   re-pair's new signing key is honoured by the very next record. A read that was in flight across a drop is
///   not cached (`generation`), so it can never put the old keys back.
/// One instance serves the app (`PhoneKeychain.store()`): the environments and the link flow share it.
final class CachingPhoneKeyStore: PhoneKeyStore, @unchecked Sendable {
    private let wrapped: any PhoneKeyStore
    private let lock = NSLock()
    private var identityKeys: DeviceIdentityKeys?
    private var device: UUID?
    private var links: [String: HubLinkKeys] = [:]
    private var signingKeys: [String: Curve25519.Signing.PublicKey] = [:]
    /// Bumped by every drop: a read caches its value only when no drop ran while it read.
    private var generation = 0
    /// Hits and stores only while true: the app is known to run unlocked.
    private var serving = false
    private var observers: [any NSObjectProtocol] = []
    private let notifications: NotificationCenter

    init(wrapping wrapped: any PhoneKeyStore, notifications: NotificationCenter = .default) {
        self.wrapped = wrapped
        self.notifications = notifications
        let stops = [
            UIApplication.protectedDataWillBecomeUnavailableNotification,
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification
        ]
        let starts = [UIApplication.didBecomeActiveNotification, UIApplication.protectedDataDidBecomeAvailableNotification]
        observers = stops.map { name in
            notifications.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.dropAll() }
        } + starts.map { name in
            notifications.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.startServing() }
        }
    }

    private func startServing() {
        lock.withLock { serving = true }
    }

    deinit {
        observers.forEach(notifications.removeObserver)
    }

    private func dropAll() {
        lock.withLock {
            serving = false
            generation += 1
            identityKeys = nil
            device = nil
            links = [:]
            signingKeys = [:]
        }
    }

    /// The cached value, or the wrapped read (cached when it returns one and no drop ran meanwhile).
    private func cached<Value>(
        _ read: (CachingPhoneKeyStore) -> Value?, store: (CachingPhoneKeyStore, Value) -> Void, load: () throws -> Value?
    ) rethrows -> Value? {
        let (hit, started) = lock.withLock { (serving ? read(self) : nil, generation) }
        if let hit { return hit }
        guard let value = try load() else { return nil }
        lock.withLock {
            if serving, generation == started { store(self, value) }
        }
        return value
    }

    func identity() throws -> DeviceIdentityKeys {
        let (hit, started) = lock.withLock { (serving ? identityKeys : nil, generation) }
        if let hit { return hit }
        let keys = try wrapped.identity()
        lock.withLock {
            if serving, generation == started { identityKeys = keys }
        }
        return keys
    }

    func existingIdentity() throws -> DeviceIdentityKeys? {
        try cached({ $0.identityKeys }, store: { $0.identityKeys = $1 }, load: wrapped.existingIdentity)
    }

    func hubLink(_ hubID: String) throws -> HubLinkKeys? {
        try cached({ $0.links[hubID] }, store: { $0.links[hubID] = $1 }, load: { try wrapped.hubLink(hubID) })
    }

    func saveHubLink(_ keys: HubLinkKeys) throws {
        // Dropped before the write too: a failed write must not leave the old keys served from memory.
        forget(keys.hubID)
        try wrapped.saveHubLink(keys)
        forget(keys.hubID)
    }

    func removeHubLink(_ hubID: String) throws {
        forget(hubID)
        try wrapped.removeHubLink(hubID)
        forget(hubID)
    }

    private func forget(_ hubID: String) {
        lock.withLock {
            generation += 1
            links[hubID] = nil
            signingKeys[hubID] = nil
        }
    }

    func hubSigningKey(_ hubID: String) throws -> Curve25519.Signing.PublicKey? {
        try cached({ $0.signingKeys[hubID] }, store: { $0.signingKeys[hubID] = $1 }, load: { try wrapped.hubSigningKey(hubID) })
    }

    /// Not cached: read by the alert path only, rarely.
    func alertMaterial(_ hubID: String) throws -> AlertMaterial? {
        try wrapped.alertMaterial(hubID)
    }

    func deviceID() throws -> UUID? {
        try cached({ $0.device }, store: { $0.device = $1 }, load: wrapped.deviceID)
    }
}

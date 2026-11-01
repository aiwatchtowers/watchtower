import CryptoKit
import Foundation
import WatchtowerSync
import XCTest
@testable import WatchtowerHostedRelay

/// `KeychainRelayIdentity` over a recording in-memory backend: the `relay.auth`
/// key and the App Attest key id, their access class and group, the
/// add-only creation and the locked and corrupt paths.
final class KeychainRelayIdentityTests: XCTestCase {
    private let group = "TEAM.com.example.app"

    func testSignerIsCreatedOnceAndReused() throws {
        let backend = RecordingRelayKeychain()
        let identity = KeychainRelayIdentity(backend: backend, group: group)

        let first = try identity.signer()
        let second = try identity.signer()

        XCTAssertEqual(first.publicKey, second.publicKey)
        XCTAssertEqual(first.publicKey.count, 32)
        XCTAssertEqual(backend.calls.filter { $0.op == "add" }.count, 1, "created once")
        XCTAssertFalse(backend.calls.contains { $0.op == "write" }, "creation never overwrites")
        let stored = try XCTUnwrap(backend.item("relay.auth", group: group))
        XCTAssertEqual(stored.count, 32)
        XCTAssertEqual(try Curve25519.Signing.PrivateKey(rawRepresentation: stored).publicKey.rawRepresentation, first.publicKey)

        let message = Data("login".utf8)
        let signature = try first.sign(message)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: first.publicKey)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: message))
    }

    func testExistingSignerNeverCreates() throws {
        let backend = RecordingRelayKeychain()
        let identity = KeychainRelayIdentity(backend: backend, group: group)

        XCTAssertNil(try identity.existingSigner())
        XCTAssertFalse(backend.calls.contains { $0.op == "add" || $0.op == "write" })

        let created = try identity.signer()
        XCTAssertEqual(try identity.existingSigner()?.publicKey, created.publicKey)
    }

    func testALostCreateRaceReadsTheWinner() throws {
        let backend = RecordingRelayKeychain()
        let winner = Curve25519.Signing.PrivateKey()
        backend.raceOnAdd("relay.auth", planting: winner.rawRepresentation, group: group)
        let identity = KeychainRelayIdentity(backend: backend, group: group)

        let signer = try identity.signer()

        XCTAssertEqual(signer.publicKey, winner.publicKey.rawRepresentation, "the winner's key, not ours")
        XCTAssertEqual(backend.item("relay.auth", group: group), winner.rawRepresentation, "the winner is never clobbered")
    }

    func testItemsAreAfterFirstUnlockThisDeviceOnlyAndNeverSynced() throws {
        let backend = RecordingRelayKeychain()
        let identity = KeychainRelayIdentity(backend: backend, group: group)

        _ = try identity.signer()
        _ = try identity.existingSigner()
        identity.setKeyID("key-1")
        _ = identity.keyID()
        identity.setKeyID(nil)

        XCTAssertFalse(backend.calls.isEmpty)
        for call in backend.calls {
            XCTAssertEqual(call.group, group, "\(call.op) \(call.account) goes to the private group")
            if call.op == "add" || call.op == "write" {
                XCTAssertEqual(call.access, .afterFirstUnlock, "\(call.op) \(call.account)")
                XCTAssertTrue(call.dataProtection, "\(call.op) \(call.account)")
            }
        }
        XCTAssertEqual(Set(backend.calls.map(\.account)), ["relay.auth", "relay.attestkey"])
    }

    func testACorruptKeyThrowsAndIsKept() throws {
        let backend = RecordingRelayKeychain()
        let junk = Data(repeating: 7, count: 31)
        backend.plant("relay.auth", junk, group: group)
        let identity = KeychainRelayIdentity(backend: backend, group: group)

        XCTAssertThrowsError(try identity.signer()) { error in
            guard case KeyStoreError.corrupt = error else { return XCTFail("expected corrupt, got \(error)") }
        }
        XCTAssertThrowsError(try identity.existingSigner()) { error in
            guard case KeyStoreError.corrupt = error else { return XCTFail("expected corrupt, got \(error)") }
        }
        XCTAssertEqual(backend.item("relay.auth", group: group), junk, "never replaced silently")
        XCTAssertFalse(backend.calls.contains { $0.op != "read" })
    }

    func testLockedCreatesNothing() throws {
        let backend = RecordingRelayKeychain()
        backend.isLocked = true
        let identity = KeychainRelayIdentity(backend: backend, group: group)

        XCTAssertThrowsError(try identity.signer()) { error in
            XCTAssertEqual(error as? KeyStoreError, .locked)
        }
        XCTAssertThrowsError(try identity.existingSigner()) { error in
            XCTAssertEqual(error as? KeyStoreError, .locked)
        }
        backend.isLocked = false
        XCTAssertNil(backend.item("relay.auth", group: group), "nothing was created")
        XCTAssertFalse(backend.calls.contains { $0.op == "add" || $0.op == "write" })
    }

    func testKeyIDRoundTripsAndNilDeletes() throws {
        let backend = RecordingRelayKeychain()
        let identity = KeychainRelayIdentity(backend: backend, group: group)

        XCTAssertNil(identity.keyID())
        identity.setKeyID("attest-key-id")
        XCTAssertEqual(identity.keyID(), "attest-key-id")
        XCTAssertEqual(backend.item("relay.attestkey", group: group), Data("attest-key-id".utf8), "UTF-8")

        identity.setKeyID("attest-key-id-2")
        XCTAssertEqual(identity.keyID(), "attest-key-id-2")

        identity.setKeyID(nil)
        XCTAssertNil(identity.keyID())
        XCTAssertNil(backend.item("relay.attestkey", group: group))
        XCTAssertTrue(backend.calls.contains { $0.op == "delete" && $0.account == "relay.attestkey" })

        // A failed write keeps whatever was stored: plant an id, fail the write while locked.
        identity.setKeyID("attest-key-old")
        backend.isLocked = true
        identity.setKeyID("while-locked")
        XCTAssertNil(identity.keyID(), "a read error returns nil")
        backend.isLocked = false
        XCTAssertEqual(identity.keyID(), "attest-key-old", "the failed write kept the old id")
        XCTAssertEqual(backend.item("relay.attestkey", group: group), Data("attest-key-old".utf8))
    }

    func testRelayDeviceIDOfTheStoredKeyIsStable() throws {
        let backend = RecordingRelayKeychain()
        let seed = Data(repeating: 0x11, count: 32)
        backend.plant("relay.auth", seed, group: group)
        let identity = KeychainRelayIdentity(backend: backend, group: group)

        let expectedPublic = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
        let first = RelayAuthMessages.deviceID(publicKey: try identity.signer().publicKey)
        let again = RelayAuthMessages.deviceID(
            publicKey: try XCTUnwrap(KeychainRelayIdentity(backend: backend, group: group).existingSigner()).publicKey)

        XCTAssertEqual(first, RelayAuthMessages.deviceID(publicKey: expectedPublic))
        XCTAssertEqual(first, again)
        XCTAssertEqual(first.count, 52)
        XCTAssertTrue(first.allSatisfy { ("a"..."z").contains($0) || ("2"..."7").contains($0) })
    }
}

/// An in-memory `KeychainBackend` that records every call with its access
/// class, group and data-protection flag, and can lose an add race or be locked.
private final class RecordingRelayKeychain: KeychainBackend, @unchecked Sendable {
    struct Call: Equatable {
        let op: String
        let account: String
        let group: String?
        let access: KeyAccess?
        /// false for reads and deletes, which take no flag.
        let dataProtection: Bool
    }

    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var log: [Call] = []
    private var racing: [String: Data] = [:]
    private var locked = false

    var calls: [Call] { lock.withLock { log } }

    var isLocked: Bool {
        get { lock.withLock { locked } }
        set { lock.withLock { locked = newValue } }
    }

    func item(_ account: String, group: String?) -> Data? {
        lock.withLock { items[key(account, group)] }
    }

    func plant(_ account: String, _ data: Data, group: String?) {
        lock.withLock { items[key(account, group)] = data }
    }

    /// The next add of `account` finds `data` already stored by another creator.
    func raceOnAdd(_ account: String, planting data: Data, group: String?) {
        lock.withLock { racing[key(account, group)] = data }
    }

    private func key(_ account: String, _ group: String?) -> String { "\(group ?? "")|\(account)" }

    func read(account: String, group: String?) throws -> Data? {
        try lock.withLock {
            log.append(Call(op: "read", account: account, group: group, access: nil, dataProtection: false))
            if locked { throw KeyStoreError.locked }
            return items[key(account, group)]
        }
    }

    func write(_ data: Data, account: String, access: KeyAccess, group: String?, dataProtection: Bool) throws {
        try lock.withLock {
            log.append(Call(op: "write", account: account, group: group, access: access, dataProtection: dataProtection))
            if locked { throw KeyStoreError.locked }
            items[key(account, group)] = data
        }
    }

    func add(_ data: Data, account: String, access: KeyAccess, group: String?, dataProtection: Bool) throws -> Bool {
        try lock.withLock {
            log.append(Call(op: "add", account: account, group: group, access: access, dataProtection: dataProtection))
            if locked { throw KeyStoreError.locked }
            let name = key(account, group)
            if let winner = racing.removeValue(forKey: name) {
                items[name] = winner
                return false
            }
            guard items[name] == nil else { return false }
            items[name] = data
            return true
        }
    }

    func delete(account: String, group: String?) throws {
        try lock.withLock {
            log.append(Call(op: "delete", account: account, group: group, access: nil, dataProtection: false))
            if locked { throw KeyStoreError.locked }
            items[key(account, group)] = nil
        }
    }
}

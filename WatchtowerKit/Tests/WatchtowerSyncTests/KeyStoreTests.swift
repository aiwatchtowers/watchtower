import CryptoKit
import Security
import XCTest
@testable import WatchtowerSync

final class FakeKeychainBackend: KeychainBackend, @unchecked Sendable {
    struct Write: Equatable {
        let account: String
        let data: Data
        let access: KeyAccess
        let group: String?
        let dataProtection: Bool
    }

    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var duplicateOnAdd: Set<String> = []
    private var log: [Write] = []
    private var failure: KeyStoreError?
    private var failingAccounts: Set<String> = []

    var writes: [Write] { lock.withLock { log } }
    func failReads(_ error: KeyStoreError?) { lock.withLock { failure = error } }
    /// Writes to `account` throw `.unexpected(-1)` while set.
    func failWrites(to account: String?) { lock.withLock { failingAccounts = account.map { [$0] } ?? [] } }
    func plant(_ account: String, _ data: Data, group: String? = nil) { lock.withLock { items["\(group ?? "")|\(account)"] = data } }
    /// The next add of this account reports a duplicate after planting `data` (a concurrent creator).
    func raceOnAdd(_ account: String, planting data: Data, group: String? = nil, alsoPlanting extra: [String: Data] = [:]) {
        lock.withLock {
            extras[account] = extra
            duplicateOnAdd.insert("\(group ?? "")|\(account)")
            raced["\(group ?? "")|\(account)"] = data
        }
    }
    private var raced: [String: Data] = [:]
    private var extras: [String: [String: Data]] = [:]

    func read(account: String, group: String?) throws -> Data? {
        try lock.withLock {
            if let failure { throw failure }
            return items["\(group ?? "")|\(account)"]
        }
    }

    func write(_ data: Data, account: String, access: KeyAccess, group: String?, dataProtection: Bool) throws {
        try lock.withLock {
            if failingAccounts.contains(account) { throw KeyStoreError.unexpected(-1) }
            items["\(group ?? "")|\(account)"] = data
            log.append(Write(account: account, data: data, access: access, group: group, dataProtection: dataProtection))
        }
    }

    func add(_ data: Data, account: String, access: KeyAccess, group: String?, dataProtection: Bool) throws -> Bool {
        lock.withLock {
            let key = "\(group ?? "")|\(account)"
            if duplicateOnAdd.remove(key) != nil {
                items[key] = raced[key]
                for (name, value) in extras[account] ?? [:] { items["\(group ?? "")|\(name)"] = value }
                return false
            }
            guard items[key] == nil else { return false }
            items[key] = data
            log.append(Write(account: account, data: data, access: access, group: group, dataProtection: dataProtection))
            return true
        }
    }

    func delete(account: String, group: String?) throws {
        lock.withLock {
            items["\(group ?? "")|\(account)"] = nil
            deletedAccounts.append(account)
        }
    }
    private var deletedAccounts: [String] = []
    var deletes: [String] { lock.withLock { deletedAccounts } }
}

final class KeyStoreTests: XCTestCase {
    private let privateGroup = "TEAM.private"
    private let alertGroup = "TEAM.alerts"

    private func makeStore(_ backend: FakeKeychainBackend) -> KeychainPhoneKeyStore {
        KeychainPhoneKeyStore(backend: backend, privateGroup: privateGroup, alertGroup: alertGroup)
    }

    private func link(epochs: [EpochKeys]? = nil) -> HubLinkKeys {
        HubLinkKeys(
            hubID: "hub-1", hubSigningKey: Data(repeating: 7, count: 32), hubAgreementKey: Data(repeating: 8, count: 32),
            linkNonce: Data(repeating: 9, count: 16), metaKey: Data(repeating: 0xA1, count: 32),
            epochs: epochs ?? [EpochKeys(epoch: 1, dataKey: Data(repeating: 0xD1, count: 32), alertKey: Data(repeating: 0xE1, count: 32))])
    }

    private func contains(_ haystack: Data, _ needle: Data) -> Bool { haystack.firstRange(of: needle) != nil }

    func testPhoneIdentityIsCreatedOnceAndStoredWhenUnlockedThisDeviceOnly() throws {
        let backend = FakeKeychainBackend()
        let store = makeStore(backend)
        let first = try store.identity()
        let second = try store.identity()
        XCTAssertEqual(first.deviceID, second.deviceID)
        let secretWrites = backend.writes.filter { $0.account == "identity.sig" || $0.account == "identity.kx" }
        XCTAssertEqual(secretWrites.map(\.account).sorted(), ["identity.kx", "identity.sig"])
        XCTAssertTrue(secretWrites.allSatisfy { $0.access == .whenUnlocked })
        // Reload through a fresh store: the same persisted keys.
        XCTAssertEqual(try makeStore(backend).identity().deviceID, first.deviceID)
    }

    func testSaveHubLinkWritesTheSecretItemWhenUnlockedAndOnlyPublicOrAlertMaterialAfterFirstUnlock() throws {
        let backend = FakeKeychainBackend()
        let store = makeStore(backend)
        let keys = link()
        try store.saveHubLink(keys)
        let writes = backend.writes
        XCTAssertEqual(writes.first { $0.account == "hub.hub-1" }?.access, .whenUnlocked)
        let relaxed = writes.filter { $0.access == .afterFirstUnlock }
        XCTAssertEqual(Set(relaxed.map(\.account)), ["hubpub.hub-1", "alert.hub-1"])
        for write in relaxed {
            XCTAssertFalse(contains(write.data, Data(repeating: 0xD1, count: 32)), "\(write.account) holds a data key")
            XCTAssertFalse(contains(write.data, try XCTUnwrap(keys.metaKey)))
            XCTAssertFalse(contains(write.data, Data(repeating: 0xD1, count: 32).base64EncodedData()))
            XCTAssertFalse(contains(write.data, try XCTUnwrap(keys.metaKey).base64EncodedData()))
        }
        XCTAssertEqual(try store.hubLink("hub-1"), keys)
    }

    func testALockedKeychainSurfacesLockedNotMissing() throws {
        let backend = FakeKeychainBackend()
        let store = makeStore(backend)
        try store.saveHubLink(link())
        backend.failReads(.locked)
        XCTAssertThrowsError(try store.hubLink("hub-1")) { XCTAssertEqual($0 as? KeyStoreError, .locked) }
        XCTAssertThrowsError(try store.identity()) { XCTAssertEqual($0 as? KeyStoreError, .locked) }
        XCTAssertThrowsError(try store.alertMaterial("hub-1")) { XCTAssertEqual($0 as? KeyStoreError, .locked) }
        XCTAssertThrowsError(try store.hubSigningKey("hub-1")) { XCTAssertEqual($0 as? KeyStoreError, .locked) }
        XCTAssertThrowsError(try store.deviceID()) { XCTAssertEqual($0 as? KeyStoreError, .locked) }
    }

    /// #1499: a read that fails because the device is locked is not "the link is gone": no read path deletes anything,
    /// and the link reads again, unchanged, once the device unlocks.
    func testALockedKeychainReadDeletesNothingAndTheLinkReadsAgainAfterUnlock() throws {
        let backend = FakeKeychainBackend()
        let store = makeStore(backend)
        let keys = link()
        try store.saveHubLink(keys)
        backend.failReads(.locked)
        for _ in 0..<3 {
            XCTAssertThrowsError(try store.hubLink("hub-1")) { XCTAssertEqual($0 as? KeyStoreError, .locked) }
            XCTAssertThrowsError(try store.hubSigningKey("hub-1")) { XCTAssertEqual($0 as? KeyStoreError, .locked) }
            XCTAssertThrowsError(try store.alertMaterial("hub-1")) { XCTAssertEqual($0 as? KeyStoreError, .locked) }
        }
        XCTAssertTrue(backend.deletes.isEmpty, "a locked read removes nothing")
        backend.failReads(nil)
        XCTAssertEqual(try store.hubLink("hub-1"), keys)
    }

    /// F14: the read-only accessor never creates an identity: absent is nil, and nothing is written.
    func testTheExistingIdentityIsReadOnly() throws {
        let backend = FakeKeychainBackend()
        let store = makeStore(backend)
        XCTAssertNil(try store.existingIdentity())
        XCTAssertTrue(backend.writes.isEmpty, "absent stays absent")
        let created = try store.identity()
        XCTAssertEqual(try store.existingIdentity()?.deviceID, created.deviceID)
        backend.failReads(.locked)
        XCTAssertThrowsError(try store.existingIdentity()) { XCTAssertEqual($0 as? KeyStoreError, .locked) }
    }

    func testALockedKeychainNeverCreatesANewIdentity() throws {
        let backend = FakeKeychainBackend()
        backend.failReads(.locked)
        XCTAssertThrowsError(try makeStore(backend).identity())
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testACorruptItemIsCorruptNotAbsent() throws {
        let backend = FakeKeychainBackend()
        let store = makeStore(backend)
        backend.plant("hub.hub-1", Data("not json".utf8), group: privateGroup)
        backend.plant("hubpub.hub-1", Data([1, 2, 3]), group: privateGroup)
        backend.plant("alert.hub-1", Data("{".utf8), group: alertGroup)
        backend.plant("deviceid", Data("nope".utf8), group: privateGroup)
        backend.plant("identity.sig", Data([1]), group: privateGroup)
        backend.plant("identity.kx", Data([2]), group: privateGroup)
        func assertCorrupt(_ body: () throws -> Any?, line: UInt = #line) {
            XCTAssertThrowsError(try body(), line: line) {
                guard case .corrupt = $0 as? KeyStoreError else { return XCTFail("\($0)", line: line) }
            }
        }
        assertCorrupt { try store.hubLink("hub-1") }
        assertCorrupt { try store.hubSigningKey("hub-1") }
        assertCorrupt { try store.alertMaterial("hub-1") }
        assertCorrupt { try store.deviceID() }
        assertCorrupt { try store.identity() }
    }

    func testAHalfPresentIdentityIsCorruptAndNotRecreated() throws {
        let backend = FakeKeychainBackend()
        backend.plant("identity.sig", Curve25519.Signing.PrivateKey().rawRepresentation, group: privateGroup)
        XCTAssertThrowsError(try makeStore(backend).identity())
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testAlertMaterialIsReadFromTheAlertGroupOnly() throws {
        let backend = FakeKeychainBackend()
        backend.plant("alert.hub-1", Data("{}".utf8), group: privateGroup)
        XCTAssertNil(try makeStore(backend).alertMaterial("hub-1"))
    }

    func testSaveHubLinkRejectsWrongKeyLengthsBeforeWritingAnything() throws {
        let backend = FakeKeychainBackend()
        let store = makeStore(backend)
        let good = link()
        var variants: [HubLinkKeys] = []
        func rebuilt(signing: Data? = nil, agreement: Data? = nil) -> HubLinkKeys {
            HubLinkKeys(
                hubID: "hub-1", hubSigningKey: signing ?? good.hubSigningKey, hubAgreementKey: agreement ?? good.hubAgreementKey,
                linkNonce: good.linkNonce, metaKey: good.metaKey, epochs: good.epochs)
        }
        var v = rebuilt(signing: Data(count: 31)); variants.append(v)
        v = rebuilt(agreement: Data(count: 33)); variants.append(v)
        v = good; v.metaKey = Data(count: 16); variants.append(v)
        v = good; v.epochs = [EpochKeys(epoch: 1, dataKey: Data(count: 31), alertKey: Data(count: 32))]; variants.append(v)
        v = good; v.epochs = [EpochKeys(epoch: 1, dataKey: Data(count: 32), alertKey: Data())]; variants.append(v)
        for bad in variants {
            XCTAssertThrowsError(try store.saveHubLink(bad)) {
                guard case .corrupt = $0 as? KeyStoreError else { return XCTFail("\($0)") }
            }
        }
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testLosingTheIdentityRaceReturnsTheWinnersKeys() throws {
        let backend = FakeKeychainBackend()
        let winner = DeviceIdentityKeys(signing: .init(), agreement: .init())
        backend.raceOnAdd(
            "identity.sig", planting: winner.signing.rawRepresentation, group: privateGroup,
            alsoPlanting: ["identity.kx": winner.agreement.rawRepresentation])
        let loaded = try makeStore(backend).identity()
        XCTAssertEqual(loaded.deviceID, winner.deviceID)
        XCTAssertFalse(backend.writes.contains { $0.account == "identity.kx" })
    }

    func testLosingTheHubIdentityRaceReturnsTheWinnersIdentityWithCreatedFalse() throws {
        let backend = FakeKeychainBackend()
        let winner = HubIdentityKeys(signing: .init(), agreement: .init(), wrapKey: SymmetricKey(size: .bits256))
        backend.raceOnAdd(
            "hubid.h.sig", planting: winner.signing.rawRepresentation,
            alsoPlanting: ["hubid.h.kx": winner.agreement.rawRepresentation, "hubid.h.wrap": winner.wrapKey.withUnsafeBytes { Data($0) }])
        let result = try KeychainHubKeyStore(backend: backend).hubIdentity(hubID: "h")
        XCTAssertFalse(result.created)
        XCTAssertEqual(result.keys.signing.rawRepresentation, winner.signing.rawRepresentation)
        XCTAssertTrue(backend.writes.isEmpty, "nothing written over the winner")
    }

    func testLosingALaterHubItemIsCorruptNotMixed() throws {
        let backend = FakeKeychainBackend()
        backend.raceOnAdd("hubid.h.kx", planting: Data(count: 32))
        XCTAssertThrowsError(try KeychainHubKeyStore(backend: backend).hubIdentity(hubID: "h")) {
            guard case .corrupt = $0 as? KeyStoreError else { return XCTFail("\($0)") }
        }
    }

    func testAbsentItemsAreNil() throws {
        let store = makeStore(FakeKeychainBackend())
        XCTAssertNil(try store.hubLink("hub-1"))
        XCTAssertNil(try store.hubSigningKey("hub-1"))
        XCTAssertNil(try store.alertMaterial("hub-1"))
        XCTAssertNil(try store.deviceID())
    }

    func testRemoveHubLinkDeletesAllThreeCopies() throws {
        let store = makeStore(FakeKeychainBackend())
        try store.saveHubLink(link())
        try store.removeHubLink("hub-1")
        XCTAssertNil(try store.hubLink("hub-1"))
        XCTAssertNil(try store.hubSigningKey("hub-1"))
        XCTAssertNil(try store.alertMaterial("hub-1"))
    }

    /// A build before the alerts group (Task 18) kept the alert material in the private group: removal clears it too.
    func testRemoveHubLinkAlsoDeletesAnAlertCopyInThePrivateGroup() throws {
        let backend = FakeKeychainBackend()
        backend.plant("alert.hub-1", Data("{}".utf8), group: privateGroup)
        try makeStore(backend).removeHubLink("hub-1")
        XCTAssertNil(try backend.read(account: "alert.hub-1", group: privateGroup))
    }

    func testHubIdentityIsCreatedAfterFirstUnlockWithDataProtectionAndReportsCreatedOnce() throws {
        let backend = FakeKeychainBackend()
        let store = KeychainHubKeyStore(backend: backend)
        let first = try store.hubIdentity(hubID: "hub-1")
        XCTAssertTrue(first.created)
        let second = try store.hubIdentity(hubID: "hub-1")
        XCTAssertFalse(second.created)
        XCTAssertEqual(first.keys.signing.publicKey.rawRepresentation, second.keys.signing.publicKey.rawRepresentation)
        XCTAssertEqual(first.keys.wrapKey, second.keys.wrapKey)
        let writes = backend.writes
        XCTAssertEqual(Set(writes.map(\.account)), ["hubid.hub-1.sig", "hubid.hub-1.kx", "hubid.hub-1.wrap"])
        XCTAssertEqual(writes.count, 3)
        XCTAssertTrue(writes.allSatisfy { $0.access == .afterFirstUnlock && $0.dataProtection && $0.group == nil })
        try store.deleteHubIdentity(hubID: "hub-1")
        XCTAssertTrue(try store.hubIdentity(hubID: "hub-1").created)
    }

    func testAPartialHubIdentityIsCorruptNotReplaced() throws {
        let backend = FakeKeychainBackend()
        backend.plant("hubid.hub-1.sig", Curve25519.Signing.PrivateKey().rawRepresentation)
        XCTAssertThrowsError(try KeychainHubKeyStore(backend: backend).hubIdentity(hubID: "hub-1")) {
            guard case .corrupt = $0 as? KeyStoreError else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(backend.writes.isEmpty)
    }

    /// The adoption's probe (go hub plan 3 Task 22): reads, never creates.
    func testTheExistingHubIdentityIsReadOnly() throws {
        let backend = FakeKeychainBackend()
        let store = KeychainHubKeyStore(backend: backend)
        XCTAssertNil(try store.existingHubIdentity(hubID: "hub-1"), "none: nil")
        XCTAssertTrue(backend.writes.isEmpty, "nothing created")
        let created = try store.hubIdentity(hubID: "hub-1").keys
        let found = try XCTUnwrap(try store.existingHubIdentity(hubID: "hub-1"))
        XCTAssertEqual(found.signing.rawRepresentation, created.signing.rawRepresentation)

        let partial = FakeKeychainBackend()
        partial.plant("hubid.hub-2.kx", Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
        XCTAssertThrowsError(try KeychainHubKeyStore(backend: partial).existingHubIdentity(hubID: "hub-2")) {
            guard case .corrupt = $0 as? KeyStoreError else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(partial.writes.isEmpty)
    }

    func testHubIdentityLockedSurfacesLocked() throws {
        let backend = FakeKeychainBackend()
        backend.failReads(.locked)
        XCTAssertThrowsError(try KeychainHubKeyStore(backend: backend).hubIdentity(hubID: "h")) {
            XCTAssertEqual($0 as? KeyStoreError, .locked)
        }
        XCTAssertTrue(backend.writes.isEmpty)
    }

    /// Relay client Phase 3 (Owner approval 4): the cap went from 2 to 8; the time rule is `EpochRetentionTests`.
    func testAtMostEightEpochsAreKept() throws {
        let store = makeStore(FakeKeychainBackend())
        let epochs = (1...10).map {
            EpochKeys(epoch: UInt32($0), dataKey: Data(repeating: UInt8($0), count: 32), alertKey: Data(repeating: UInt8($0 + 10), count: 32))
        }
        try store.saveHubLink(link(epochs: epochs))
        XCTAssertEqual(try store.hubLink("hub-1")?.epochs.map(\.epoch), Array(3...10))
        XCTAssertEqual(try store.alertMaterial("hub-1")?.epochs.map(\.epoch), Array(3...10))
    }

    func testTheDeviceIDIsReadableWhileLockedAndEqualsTheIdentitysID() throws {
        let backend = FakeKeychainBackend()
        let store = makeStore(backend)
        XCTAssertNil(try store.deviceID())
        let identity = try store.identity()
        XCTAssertEqual(backend.writes.first { $0.account == "deviceid" }?.access, .afterFirstUnlock)
        XCTAssertEqual(try store.deviceID(), identity.deviceID)
    }

    func testAnExistingIdentityWithoutADeviceIDItemGetsOneOnLoad() throws {
        let backend = FakeKeychainBackend()
        let sig = Curve25519.Signing.PrivateKey()
        backend.plant("identity.sig", sig.rawRepresentation, group: privateGroup)
        backend.plant("identity.kx", Curve25519.KeyAgreement.PrivateKey().rawRepresentation, group: privateGroup)
        let store = makeStore(backend)
        let identity = try store.identity()
        XCTAssertEqual(identity.deviceID, KeyDerivation.deviceID(signingPublicKey: sig.publicKey))
        XCTAssertEqual(try store.deviceID(), identity.deviceID)
    }

    func testAlertMaterialHoldsOnlyAlertKeysAndTheHubSigningKeyInTheAlertGroup() throws {
        let backend = FakeKeychainBackend()
        let store = makeStore(backend)
        let keys = link()
        try store.saveHubLink(keys)
        let material = try XCTUnwrap(store.alertMaterial("hub-1"))
        XCTAssertEqual(material.hubSigningKey, keys.hubSigningKey)
        XCTAssertEqual(material.epochs.map(\.alertKey), keys.epochs.map(\.alertKey))
        XCTAssertTrue(material.epochs.allSatisfy { $0.dataKey.isEmpty })
        XCTAssertEqual(backend.writes.first { $0.account == "alert.hub-1" }?.group, alertGroup)
    }

    func testEveryNonAlertItemIsWrittenToThePrivateGroupExplicitly() throws {
        let backend = FakeKeychainBackend()
        let store = makeStore(backend)
        _ = try store.identity()
        try store.saveHubLink(link())
        for write in backend.writes {
            XCTAssertEqual(write.group, write.account.hasPrefix("alert.") ? alertGroup : privateGroup, write.account)
        }
    }

    func testSecItemAttributesAreThisDeviceOnlyAndNeverSynchronizable() {
        let backend = SecItemKeychainBackend()
        let data = Data([1, 2, 3])
        let unlocked = backend.addAttributes(data, account: "a", access: .whenUnlocked, group: nil, dataProtection: false)
        XCTAssertNil(unlocked[kSecAttrSynchronizable as String])
        XCTAssertEqual(unlocked[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertNil(unlocked[kSecAttrAccessGroup as String])
        XCTAssertNotEqual(unlocked[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(unlocked[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(unlocked[kSecAttrService as String] as? String, "com.aiwatchtowers.watchtower.e2e")
        XCTAssertEqual(unlocked[kSecValueData as String] as? Data, data)
        let relaxed = backend.addAttributes(data, account: "a", access: .afterFirstUnlock, group: "TEAM.g", dataProtection: true)
        XCTAssertNil(relaxed[kSecAttrSynchronizable as String])
        XCTAssertEqual(relaxed[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(relaxed[kSecAttrAccessGroup as String] as? String, "TEAM.g")
        XCTAssertEqual(relaxed[kSecUseDataProtectionKeychain as String] as? Bool, true)
    }

    func testSecItemStatusMapping() {
        XCTAssertEqual(SecItemKeychainBackend.error(for: errSecInteractionNotAllowed), .locked)
        XCTAssertEqual(SecItemKeychainBackend.error(for: errSecMissingEntitlement), .missingEntitlement)
        XCTAssertEqual(SecItemKeychainBackend.error(for: errSecParam), .unexpected(errSecParam))
    }

    func testInMemoryStoreLockedAndBeforeFirstUnlockStates() throws {
        let store = InMemoryPhoneKeyStore()
        _ = try store.identity()
        try store.saveHubLink(link())
        store.isLocked = true
        XCTAssertThrowsError(try store.hubLink("hub-1")) { XCTAssertEqual($0 as? KeyStoreError, .locked) }
        XCTAssertNotNil(try store.deviceID())
        XCTAssertNotNil(try store.alertMaterial("hub-1"))
        XCTAssertNotNil(try store.hubSigningKey("hub-1"))
        store.isBeforeFirstUnlock = true
        XCTAssertThrowsError(try store.deviceID()) { XCTAssertEqual($0 as? KeyStoreError, .locked) }
        XCTAssertThrowsError(try store.alertMaterial("hub-1")) { XCTAssertEqual($0 as? KeyStoreError, .locked) }
        store.isLocked = false
        store.isBeforeFirstUnlock = false
        XCTAssertNotNil(try store.hubLink("hub-1"))
    }

    func testInMemoryBackendBehavesLikeTheKeychainWhileLocked() throws {
        let backend = InMemoryKeychainBackend()
        backend.isLocked = true
        XCTAssertNil(try backend.read(account: "x", group: nil))
        XCTAssertThrowsError(try backend.write(Data([1]), account: "x", access: .whenUnlocked, group: nil, dataProtection: true)) {
            XCTAssertEqual($0 as? KeyStoreError, .locked)
        }
        XCTAssertTrue(try backend.add(Data([1]), account: "y", access: .afterFirstUnlock, group: nil, dataProtection: true))
        XCTAssertFalse(try backend.add(Data([2]), account: "y", access: .afterFirstUnlock, group: nil, dataProtection: true))
        XCTAssertEqual(try backend.read(account: "y", group: nil), Data([1]))
        backend.isBeforeFirstUnlock = true
        XCTAssertThrowsError(try backend.add(Data([1]), account: "z", access: .afterFirstUnlock, group: nil, dataProtection: true))
    }

    func testInMemoryHubStoreCreatesOnce() throws {
        let store = InMemoryHubKeyStore()
        XCTAssertTrue(try store.hubIdentity(hubID: "h").created)
        XCTAssertFalse(try store.hubIdentity(hubID: "h").created)
        try store.deleteHubIdentity(hubID: "h")
        XCTAssertTrue(try store.hubIdentity(hubID: "h").created)
    }

    // MARK: - Relay client Phase 5: ephemeral state on the link item

    private func relayPair(_ seed: UInt8) -> EpochRelayKeys {
        EpochRelayKeys(
            p2h: Data(repeating: seed, count: 32), h2p: Data(repeating: seed + 1, count: 32),
            hubPub: Data(repeating: seed + 2, count: 32), devicePub: Data(repeating: seed + 3, count: 32))
    }

    /// F14 for the copies: a write that fails after `hub.<id>` leaves a stale `alert.<id>`; the retry, whose
    /// change now finds the secret item already current, still repairs it.
    func testARetryAfterAFailureBetweenWritesRepairsTheAlertCopy() throws {
        let backend = FakeKeychainBackend()
        let store = makeStore(backend)
        try store.saveHubLink(link())
        let raise: (HubLinkKeys) -> HubLinkKeys = { keys in
            var copy = keys
            copy.epochs.append(EpochKeys(epoch: 2, dataKey: Data(repeating: 0xD2, count: 32), alertKey: Data(repeating: 0xE2, count: 32)))
            return copy
        }
        backend.failWrites(to: "alert.hub-1")
        XCTAssertThrowsError(try store.updateHubLink("hub-1", raise))
        XCTAssertEqual(try store.hubLink("hub-1")?.epochs.map(\.epoch), [1, 2], "the secret item was written")
        XCTAssertEqual(try store.alertMaterial("hub-1")?.epochs.map(\.epoch), [1], "the alert copy was not")

        backend.failWrites(to: nil)
        let hubWrites = backend.writes.filter { $0.account == "hub.hub-1" }.count
        _ = try store.updateHubLink("hub-1") { keys in keys.epochs.count == 2 ? keys : raise(keys) }
        XCTAssertEqual(try store.alertMaterial("hub-1")?.epochs.map(\.epoch), [1, 2], "repaired by the retry")
        XCTAssertEqual(backend.writes.filter { $0.account == "hub.hub-1" }.count, hubWrites, "an unchanged item is not rewritten")
    }

    func testOldItemDecodesWithNoEphemeralState() throws {
        let backend = FakeKeychainBackend()
        // As a build before Phase 5 wrote it: no currentKX/offeredKX, no relayKeys on the epochs.
        let old = """
        {"hubID":"hub-1","hubSigningKey":"\(Data(repeating: 7, count: 32).base64EncodedString())",
        "hubAgreementKey":"\(Data(repeating: 8, count: 32).base64EncodedString())",
        "linkNonce":"\(Data(repeating: 9, count: 16).base64EncodedString())",
        "epochs":[{"epoch":1,"dataKey":"\(Data(repeating: 0xD1, count: 32).base64EncodedString())",
        "alertKey":"\(Data(repeating: 0xE1, count: 32).base64EncodedString())"}]}
        """
        backend.plant("hub.hub-1", Data(old.utf8), group: privateGroup)
        let keys = try XCTUnwrap(makeStore(backend).hubLink("hub-1"))
        XCTAssertNil(keys.currentKX)
        XCTAssertNil(keys.offeredKX)
        XCTAssertNil(keys.epochs.first?.relayKeys)
        XCTAssertFalse(keys.hasEphemeralState)
        // A link with no ephemeral state encodes as it always did: none of the new keys appear.
        let encoded = try XCTUnwrap(String(bytes: try JSONEncoder().encode(keys), encoding: .utf8))
        for name in ["currentKX", "offeredKX", "relayKeys"] { XCTAssertFalse(encoded.contains(name), name) }
    }

    func testUpdateHubLinkOnARemovedLinkWritesNothing() throws {
        let backend = FakeKeychainBackend()
        let store = makeStore(backend)
        var called = false
        XCTAssertNil(try store.updateHubLink("hub-1") { called = true; return $0 })
        try store.saveHubLink(link())
        try store.removeHubLink("hub-1")
        let writes = backend.writes.count
        XCTAssertNil(try store.updateHubLink("hub-1") { called = true; return $0.withOffer().0 })
        XCTAssertFalse(called, "an unlink is never undone")
        XCTAssertEqual(backend.writes.count, writes)
        XCTAssertNil(try store.hubLink("hub-1"))
    }

    func testUpdateHubLinkRefusesAChangedHubID() throws {
        let store = makeStore(FakeKeychainBackend())
        try store.saveHubLink(link())
        XCTAssertThrowsError(try store.updateHubLink("hub-1") { _ in
            HubLinkKeys(hubID: "hub-2", hubSigningKey: Data(count: 32), hubAgreementKey: Data(count: 32), linkNonce: Data())
        })
        XCTAssertNil(try store.hubLink("hub-2"))
    }

    /// M9: a write from inside the closure would be undone by the outer write (an unlink undone). It throws, the
    /// update with it, and nothing changes; a read inside the closure is fine.
    func testAWriteInsideTheUpdateClosureIsRefused() throws {
        let store = makeStore(FakeKeychainBackend())
        try store.saveHubLink(link())
        for write in [{ try store.removeHubLink("hub-1") }, { try store.saveHubLink(self.link(epochs: [])) }] {
            XCTAssertThrowsError(try store.updateHubLink("hub-1") { keys in
                XCTAssertEqual(try store.hubLink("hub-1"), keys, "reads stay allowed")
                try write()
                return keys.withOffer().0
            }) { XCTAssertEqual($0 as? KeyStoreError, .reentrantWrite) }
            XCTAssertEqual(try store.hubLink("hub-1"), link(), "nothing written")
        }
        XCTAssertNotNil(try store.updateHubLink("hub-1") { $0 }, "the flag is cleared after a throw")
    }

    func testConcurrentUpdatesLoseNothing() throws {
        let store = makeStore(FakeKeychainBackend())
        try store.saveHubLink(link(epochs: []))
        DispatchQueue.concurrentPerform(iterations: HubLinkKeys.maxEpochs) { index in
            let number = UInt32(index + 1)
            _ = try? store.updateHubLink("hub-1") { keys in
                var copy = keys
                copy.epochs.append(EpochKeys(
                    epoch: number, dataKey: Data(repeating: UInt8(number), count: 32), alertKey: Data(repeating: 1, count: 32)))
                copy.epochs.sort { $0.epoch < $1.epoch }
                return copy
            }
        }
        XCTAssertEqual(try store.hubLink("hub-1")?.epochs.map(\.epoch), (1...UInt32(HubLinkKeys.maxEpochs)).map { $0 })
    }

    func testAlertMaterialCarriesNoRelayKeysOrEphemerals() throws {
        let backend = FakeKeychainBackend()
        let store = makeStore(backend)
        var keys = link()
        keys.epochs[0].relayKeys = relayPair(0x51)
        let current = EphemeralKey.generate()
        let offered = EphemeralKey.generate()
        keys.currentKX = current
        keys.offeredKX = offered
        try store.saveHubLink(keys)
        let alertWrite = try XCTUnwrap(backend.writes.last { $0.account == "alert.hub-1" })
        let text = try XCTUnwrap(String(bytes: alertWrite.data, encoding: .utf8))
        // Field by field: the decoded copy holds the alert key and the public signing key, nothing else.
        let material = try JSONDecoder().decode(AlertMaterial.self, from: alertWrite.data)
        XCTAssertEqual(material.hubSigningKey, keys.hubSigningKey)
        XCTAssertEqual(material.epochs, [EpochKeys(epoch: 1, dataKey: Data(), alertKey: keys.epochs[0].alertKey)])
        for name in ["relayKeys", "relayKeysCleared", "currentKX", "offeredKX", "metaKey", "privateKey"] {
            XCTAssertFalse(text.contains(name), name)
        }
        // The secret item keeps all of it.
        XCTAssertEqual(try store.hubLink("hub-1"), keys)
    }

    func testRetentionDropsRelayKeysWithTheEpoch() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let backend = FakeKeychainBackend()
        let store = KeychainPhoneKeyStore(backend: backend, privateGroup: privateGroup, alertGroup: alertGroup) { now }
        let oldPair = relayPair(0x61)
        let newPair = relayPair(0x65)
        try store.saveHubLink(link(epochs: [
            EpochKeys(epoch: 1, dataKey: Data(repeating: 1, count: 32), alertKey: Data(repeating: 2, count: 32),
                      supersededAt: now.addingTimeInterval(-HubLinkKeys.previousEpochGrace - 1), relayKeys: oldPair),
            EpochKeys(epoch: 2, dataKey: Data(repeating: 3, count: 32), alertKey: Data(repeating: 4, count: 32), relayKeys: newPair)
        ]))
        let item = try XCTUnwrap(backend.writes.last { $0.account == "hub.hub-1" }).data
        let stored = try JSONDecoder().decode(HubLinkKeys.self, from: item)
        XCTAssertEqual(stored.epochs.map(\.epoch), [2])
        XCTAssertFalse(stored.epochs.contains { $0.relayKeys == oldPair }, "the retired epoch's pair is gone")
        XCTAssertEqual(try store.hubLink("hub-1")?.epochs.map(\.relayKeys), [newPair])
    }

    func testKeychainSizeCheckCoversTheNewKeys() throws {
        let backend = FakeKeychainBackend()
        let store = makeStore(backend)
        let good = link()
        let real = EphemeralKey.generate()
        var variants: [HubLinkKeys] = []
        let full = Data(count: 32)
        var v = good; v.epochs[0].relayKeys = EpochRelayKeys(p2h: Data(count: 31), h2p: full, hubPub: full, devicePub: full)
        variants.append(v)
        v = good; v.epochs[0].relayKeys = EpochRelayKeys(p2h: full, h2p: Data(count: 33), hubPub: full, devicePub: full)
        variants.append(v)
        v = good; v.epochs[0].relayKeys = EpochRelayKeys(p2h: full, h2p: full, hubPub: Data(count: 16), devicePub: full)
        variants.append(v)
        v = good; v.epochs[0].relayKeys = EpochRelayKeys(p2h: full, h2p: full, hubPub: full, devicePub: Data())
        variants.append(v)
        v = good; v.currentKX = EphemeralKey(publicKey: real.publicKey, privateKey: Data(count: 31)); variants.append(v)
        v = good; v.offeredKX = EphemeralKey(publicKey: Data(count: 16), privateKey: real.privateKey); variants.append(v)
        // Halves that disagree: the transcript public would not be the agreement key's.
        v = good; v.offeredKX = EphemeralKey(publicKey: real.publicKey, privateKey: EphemeralKey.generate().privateKey)
        variants.append(v)
        for bad in variants {
            XCTAssertThrowsError(try store.saveHubLink(bad)) {
                guard case .corrupt = $0 as? KeyStoreError else { return XCTFail("\($0)") }
            }
        }
        XCTAssertTrue(backend.writes.isEmpty)
        v = good; v.offeredKX = real; v.epochs[0].relayKeys = EpochRelayKeys(p2h: full, h2p: full, hubPub: full, devicePub: full)
        XCTAssertNoThrow(try store.saveHubLink(v))
    }
}

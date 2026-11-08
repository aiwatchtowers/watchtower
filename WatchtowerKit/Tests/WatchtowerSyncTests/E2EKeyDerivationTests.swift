import CryptoKit
import XCTest
@testable import WatchtowerSync

/// Every derivation of `KeyDerivation` as hex strings; frozen in `Fixtures/e2e/kdf.json`.
struct KDFVectors: Codable, Equatable {
    var deviceID: String
    var relayKeys: [String: String]
    var recordNames: [String: String]
    var sas: String
    var linkCodeTag: String
    var ephemeralRelayKeys: EphemeralRelayVectors

    init(keys k: E2EFixtureKeys) throws {
        deviceID = k.deviceID.uuidString
        var relay = [String: String]()
        for epoch: UInt32 in [1, 2] {
            for direction in RelayDirection.allCases {
                let key = try KeyDerivation.relayKey(
                    agreementPrivate: k.hubKX, peerPublic: k.devKX.publicKey, linkNonce: k.linkNonce,
                    hubID: k.hubID, deviceID: k.deviceID, epoch: epoch, direction: direction)
                relay["\(direction.rawValue)/\(epoch)"] = key.withUnsafeBytes { Data($0) }.hexString
            }
        }
        relayKeys = relay
        let meta = SymmetricKey(data: E2EFixtureKeys.metaKeyBytes)
        let actionID = "6f1c2d3e-4a5b-4c6d-8e7f-0a1b2c3d4e5f"
        recordNames = [
            "data/owner_ask/42": KeyDerivation.recordName(metaKey: meta, zone: .data, kind: "owner_ask", id: "42"),
            "data/workbench/7": KeyDerivation.recordName(metaKey: meta, zone: .data, kind: "workbench", id: "7"),
            "relay/action/\(actionID)": KeyDerivation.recordName(metaKey: meta, zone: .relay, kind: "action", id: actionID)
        ]
        sas = k.sas()
        linkCodeTag = KeyDerivation.linkCodeTag(linkNonce: k.linkNonce)
        ephemeralRelayKeys = try EphemeralRelayVectors(keys: k)
    }
}

/// The `wt/relay/v2/` keys of the fixture's ephemeral pair, with the two ephemeral public keys, as hex.
struct EphemeralRelayVectors: Codable, Equatable {
    var hubEphemeralPublic: String
    var deviceEphemeralPublic: String
    var keys: [String: String]

    init(keys k: E2EFixtureKeys) throws {
        hubEphemeralPublic = k.hubEph.publicKey.rawRepresentation.hexString
        deviceEphemeralPublic = k.devEph.publicKey.rawRepresentation.hexString
        var derived = [String: String]()
        for epoch: UInt32 in [1, 2] {
            for direction in RelayDirection.allCases {
                derived["\(direction.rawValue)/\(epoch)"] = try k.ephemeralRelayKey(direction, epoch)
                    .withUnsafeBytes { Data($0) }.hexString
            }
        }
        keys = derived
    }
}

final class E2EKeyDerivationTests: XCTestCase {
    func testRelayKeysAgreeOnBothSidesAndDifferPerDirectionAndEpoch() throws {
        let k = try E2EFixtureKeys()
        func key(
            _ own: Curve25519.KeyAgreement.PrivateKey,
            _ peer: Curve25519.KeyAgreement.PublicKey,
            _ dir: RelayDirection,
            _ epoch: UInt32
        ) throws -> SymmetricKey {
            try KeyDerivation.relayKey(agreementPrivate: own, peerPublic: peer, linkNonce: k.linkNonce,
                                       hubID: k.hubID, deviceID: k.deviceID, epoch: epoch, direction: dir)
        }
        XCTAssertEqual(try key(k.hubKX, k.devKX.publicKey, .phoneToHub, 1), try key(k.devKX, k.hubKX.publicKey, .phoneToHub, 1))
        XCTAssertNotEqual(try key(k.hubKX, k.devKX.publicKey, .phoneToHub, 1), try key(k.hubKX, k.devKX.publicKey, .hubToPhone, 1))
        XCTAssertNotEqual(try key(k.hubKX, k.devKX.publicKey, .phoneToHub, 1), try key(k.hubKX, k.devKX.publicKey, .phoneToHub, 2))
    }

    /// The frozen `ephemeralRelayKeys` block of `kdf.json`, which the Go hub reads too.
    func testEphemeralRelayKeyVector() throws {
        let k = try E2EFixtureKeys()
        let url = E2EFixtures.directory.appendingPathComponent("kdf.json")
        let frozen = try JSONDecoder().decode(KDFVectors.self, from: Data(contentsOf: url)).ephemeralRelayKeys
        XCTAssertEqual(try EphemeralRelayVectors(keys: k), frozen)
        XCTAssertEqual(Set(frozen.keys.keys), ["p2h/1", "h2p/1", "p2h/2", "h2p/2"])
    }

    func testEphemeralRelayKeysAgreeAndBindEveryInput() throws {
        let k = try E2EFixtureKeys()
        let base = try k.ephemeralRelayKey(.phoneToHub, 1)
        XCTAssertEqual(base, try k.ephemeralRelayKey(.phoneToHub, 1, phoneSide: true))
        XCTAssertNotEqual(base, try KeyDerivation.relayKey(
            agreementPrivate: k.hubKX, peerPublic: k.devKX.publicKey, linkNonce: k.linkNonce,
            hubID: k.hubID, deviceID: k.deviceID, epoch: 1, direction: .phoneToHub))
        XCTAssertNotEqual(base, try k.ephemeralRelayKey(.hubToPhone, 1))
        XCTAssertNotEqual(base, try k.ephemeralRelayKey(.phoneToHub, 2))
        XCTAssertNotEqual(base, try k.ephemeralRelayKey(.phoneToHub, 1, hubEph: .init()))
        XCTAssertNotEqual(base, try k.ephemeralRelayKey(.phoneToHub, 1, devEph: .init()))
    }

    /// A low-order peer key (u = 0, u = 1) makes X25519 all zero, on the ephemeral half or the static half: the
    /// derivation throws. CryptoKit refuses such an agreement itself, before `refuseAllZero` runs, so this pins
    /// CryptoKit's refusal; `testRefuseAllZeroFoldsEveryByte` covers the Kit's own check.
    func testEphemeralRelayKeyRefusesAnAllZeroSharedSecret() throws {
        let k = try E2EFixtureKeys()
        var one = Data(count: 32)
        one[0] = 1
        let lowOrder = [
            try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(count: 32)),
            try Curve25519.KeyAgreement.PublicKey(rawRepresentation: one)
        ]
        func derive(
            peerEphemeral: Curve25519.KeyAgreement.PublicKey,
            peerStatic: Curve25519.KeyAgreement.PublicKey,
            hubEphemeralPublic: Data? = nil
        ) throws -> SymmetricKey {
            try KeyDerivation.ephemeralRelayKey(
                ownEphemeral: k.hubEph, peerEphemeral: peerEphemeral, ownStatic: k.hubKX, peerStatic: peerStatic,
                hubEphemeralPublic: hubEphemeralPublic ?? k.hubEph.publicKey.rawRepresentation,
                deviceEphemeralPublic: peerEphemeral.rawRepresentation,
                linkNonce: k.linkNonce, hubID: k.hubID, deviceID: k.deviceID, epoch: 1, direction: .phoneToHub)
        }
        for point in lowOrder {
            XCTAssertThrowsError(try k.hubEph.sharedSecretFromKeyAgreement(with: point)) {
                XCTAssertTrue($0 is CryptoKitError, "CryptoKit refuses the low-order point: \($0)")
            }
            XCTAssertThrowsError(try derive(peerEphemeral: point, peerStatic: k.devKX.publicKey))
            XCTAssertThrowsError(try derive(peerEphemeral: k.devEph.publicKey, peerStatic: point))
        }
        // The transcript's ephemeral publics are 32 bytes each.
        XCTAssertThrowsError(try derive(
            peerEphemeral: k.devEph.publicKey, peerStatic: k.devKX.publicKey,
            hubEphemeralPublic: k.hubEph.publicKey.rawRepresentation.prefix(31))) {
            XCTAssertEqual($0 as? E2EError, .badEphemeralPublicKey)
        }
    }

    /// The constant-time fold refuses only the all-zero secret: one non-zero byte anywhere passes.
    func testRefuseAllZeroFoldsEveryByte() throws {
        XCTAssertThrowsError(try KeyDerivation.refuseAllZero(Data(count: 32))) {
            XCTAssertEqual($0 as? E2EError, .allZeroSharedSecret)
        }
        for index in [0, 15, 31] {
            var secret = Data(count: 32)
            secret[index] = 0x01
            XCTAssertNoThrow(try KeyDerivation.refuseAllZero(secret), "byte \(index)")
        }
    }

    func testRecordNameIs26Base32CharactersAndBindsZoneKindAndID() {
        let meta = SymmetricKey(data: E2EFixtureKeys.metaKeyBytes)
        let name = KeyDerivation.recordName(metaKey: meta, zone: .data, kind: "owner_ask", id: "42")
        XCTAssertEqual(name.count, 26)
        XCTAssertTrue(name.allSatisfy { "abcdefghijklmnopqrstuvwxyz234567".contains($0) })
        XCTAssertNotEqual(name, KeyDerivation.recordName(metaKey: meta, zone: .relay, kind: "owner_ask", id: "42"))
        // The length byte keeps ("owner_ask", "42") apart from ("owner_as", "k42").
        XCTAssertNotEqual(name, KeyDerivation.recordName(metaKey: meta, zone: .data, kind: "owner_as", id: "k42"))
        XCTAssertEqual(name, KeyDerivation.recordName(metaKey: meta, zone: .data, kind: "owner_ask", id: "42"))
    }

    func testOverlongKindIsClampedNotTrapped() {
        let meta = SymmetricKey(data: E2EFixtureKeys.metaKeyBytes)
        let name = KeyDerivation.recordName(metaKey: meta, zone: .data, kind: String(repeating: "k", count: 300), id: "1")
        XCTAssertEqual(name.count, 26)
    }

    func testSASIsFourDigitsAndChangesWithEveryTranscriptInput() throws {
        let k = try E2EFixtureKeys()
        let base = k.sas()
        XCTAssertEqual(base.count, 4)
        XCTAssertTrue(base.allSatisfy(\.isNumber))
        XCTAssertNotEqual(base, k.sas(nonce: Data(repeating: 0xEE, count: 32)))
        XCTAssertNotEqual(base, k.sas(deviceAgreement: Curve25519.KeyAgreement.PrivateKey().publicKey))
        XCTAssertNotEqual(base, k.sas(confirmNonce: Data(repeating: 0x11, count: 32)))
    }

    /// I-1 (SAS v2): the code depends on the hub's confirm nonce, which the hub draws only after it accepted the
    /// hello. A grinder who fixes keys whose code matches the owner's under one nonce does not keep that code under
    /// the nonce the hub actually draws: across 64 nonces the same keys show many different codes.
    func testTheSASOfFixedKeysIsSpreadByTheConfirmNonce() throws {
        let k = try E2EFixtureKeys()
        let codes = Set((0 ..< 64).map { byte in k.sas(confirmNonce: Data(repeating: UInt8(byte), count: 32)) })
        XCTAssertGreaterThan(codes.count, 56, "fixed device keys must not fix the code")
    }

    /// The waiting keybox names the link code it answers: base64url of SHA-256("wt/link-code/v1" ‖ nonce)[0..<16].
    func testTheLinkCodeTagBindsTheNonce() throws {
        let k = try E2EFixtureKeys()
        let tag = KeyDerivation.linkCodeTag(linkNonce: k.linkNonce)
        XCTAssertEqual(WireBytes.fromBase64URL(tag)?.count, 16)
        XCTAssertEqual(tag, KeyDerivation.linkCodeTag(linkNonce: k.linkNonce))
        XCTAssertNotEqual(tag, KeyDerivation.linkCodeTag(linkNonce: Data(repeating: 0xEE, count: 32)))
    }

    func testDeviceIDIsDerivedFromTheSigningKey() throws {
        let k = try E2EFixtureKeys()
        XCTAssertEqual(KeyDerivation.deviceID(signingPublicKey: k.devSig.publicKey), k.deviceID)
        XCTAssertNotEqual(KeyDerivation.deviceID(signingPublicKey: k.hubSig.publicKey), k.deviceID)
    }

    /// The frozen `linkCodeTag` of the fixture link nonce (0xA0...0xBF).
    func testLinkCodeTagVector() throws {
        let k = try E2EFixtureKeys()
        try E2EFixtures.check(try KDFVectors(keys: k), file: "kdf")
        let url = E2EFixtures.directory.appendingPathComponent("kdf.json")
        let frozen = try JSONDecoder().decode(KDFVectors.self, from: Data(contentsOf: url))
        XCTAssertEqual(frozen.linkCodeTag, KeyDerivation.linkCodeTag(linkNonce: k.linkNonce))
        XCTAssertEqual(WireBytes.fromBase64URL(frozen.linkCodeTag)?.count, 16)
    }

    func testDerivationsMatchTheFrozenVectors() throws {
        let computed = try KDFVectors(keys: E2EFixtureKeys())
        try E2EFixtures.check(computed, file: "kdf")
    }
}

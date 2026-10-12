import CryptoKit
import XCTest
@testable import WatchtowerSync

/// Every derivation of `KeyDerivation` as hex strings; frozen in `Fixtures/e2e/kdf.json`.
struct KDFVectors: Codable, Equatable {
    var deviceID: String
    var relayKeys: [String: String]
    var recordNames: [String: String]
    var sas: String

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
    }

    func testDeviceIDIsDerivedFromTheSigningKey() throws {
        let k = try E2EFixtureKeys()
        XCTAssertEqual(KeyDerivation.deviceID(signingPublicKey: k.devSig.publicKey), k.deviceID)
        XCTAssertNotEqual(KeyDerivation.deviceID(signingPublicKey: k.hubSig.publicKey), k.deviceID)
    }

    func testDerivationsMatchTheFrozenVectors() throws {
        let computed = try KDFVectors(keys: E2EFixtureKeys())
        try E2EFixtures.check(computed, file: "kdf")
    }
}

import CryptoKit
import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerSync

/// The Swift → Go vector of the sealed sidecar keys (Go hub plan 1a Task 6): `HubKeyring` seals `K_meta` and epoch
/// 1's `K_data ‖ K_alert` under a fixed identity, and Go's `identity.Keyring` must open them with the same wrap key
/// and AADs (`TestKeyring_OpensSwiftSealedKeys`), so phase 3 can adopt a Swift sidecar. Sealing is randomized, so the
/// file is written once with `WT_E2E_REGENERATE=1`; a plain run re-opens its sealed values through `HubKeyring`.
final class HubKeyringVectorTests: XCTestCase {
    struct Vector: Codable, Equatable {
        struct Epoch: Codable, Equatable {
            let epoch: UInt32
            let sealedKeys: String

            enum CodingKeys: String, CodingKey {
                case epoch
                case sealedKeys = "sealed_keys"
            }
        }

        let hubID: String
        let kMetaSealed: String
        let epochs: [Epoch]
        let kMeta: String
        let dataKey: String
        let alertKey: String

        enum CodingKeys: String, CodingKey {
            case epochs
            case hubID = "hub_id"
            case kMetaSealed = "k_meta_sealed"
            case kMeta = "k_meta"
            case dataKey = "data_key"
            case alertKey = "alert_key"
        }
    }

    /// The Kit fixtures' synthetic hub id.
    private static let hubID = "00112233-4455-6677-8899-AABBCCDDEEFF"

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // this file
        .deletingLastPathComponent() // MobileHub
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerDesktop
        .appendingPathComponent("internal/hub/identity/testdata/swift-keyring.json")

    func testEmitSidecarKeyVector() throws {
        if ProcessInfo.processInfo.environment["WT_E2E_REGENERATE"] == "1" {
            try regenerate()
            XCTFail("regenerated, re-run without WT_E2E_REGENERATE")
            return
        }
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: Self.fixtureURL))
        XCTAssertEqual(vector.hubID, Self.hubID)
        let epoch = try XCTUnwrap(vector.epochs.first)
        let sidecar = try HubSyncState.inMemory()
        try sidecar.writeKeys { db in
            try HubSyncState.setMetaValue(
                Data(hex: vector.kMetaSealed).base64EncodedString(), HubKeyring.metaKeySealedKey, db)
            try HubSyncState.insertEpoch(.init(
                epoch: epoch.epoch, sealedKeys: Data(hex: epoch.sealedKeys), createdAt: Date(), firstSeq: 0,
                retiredAt: nil), db)
        }
        let ring = try HubKeyring(hubID: vector.hubID, sidecar: sidecar, store: FixedHubKeyStore())
        XCTAssertEqual(try ring.metaKey().withUnsafeBytes { Data($0) }.hex, vector.kMeta)
        let keys = try ring.epochKeys(epoch.epoch)
        XCTAssertEqual(keys.dataKey.hex, vector.dataKey)
        XCTAssertEqual(keys.alertKey.hex, vector.alertKey)
    }

    private func regenerate() throws {
        let sidecar = try HubSyncState.inMemory()
        let ring = try HubKeyring(hubID: Self.hubID, sidecar: sidecar, store: FixedHubKeyStore())
        try ring.ensureGroupKeys()
        let metaText = try XCTUnwrap(sidecar.metaValue(forKey: HubKeyring.metaKeySealedKey))
        let metaSealed = try XCTUnwrap(Data(base64Encoded: metaText))
        let stored = try XCTUnwrap(sidecar.latestEpochs().last)
        let keys = try ring.epochKeys(stored.epoch)
        let vector = Vector(
            hubID: Self.hubID, kMetaSealed: metaSealed.hex,
            epochs: [.init(epoch: stored.epoch, sealedKeys: stored.sealedKeys.hex)],
            kMeta: try ring.metaKey().withUnsafeBytes { Data($0) }.hex,
            dataKey: keys.dataKey.hex, alertKey: keys.alertKey.hex)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(vector)
        data.append(0x0A)
        try FileManager.default.createDirectory(
            at: Self.fixtureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: Self.fixtureURL)
    }
}

/// The vector's fixed identity: `hub_sig` = 0x41…0x60, `hub_kx` = 0x01…0x20 (the Kit fixtures' runs), wrap key =
/// 32 × 0xF0.
private struct FixedHubKeyStore: HubKeyStore {
    func hubIdentity(hubID: String) throws -> (keys: HubIdentityKeys, created: Bool) {
        let keys = HubIdentityKeys(
            signing: try .init(rawRepresentation: Data((0x41...0x60).map { UInt8($0) })),
            agreement: try .init(rawRepresentation: Data((0x01...0x20).map { UInt8($0) })),
            wrapKey: SymmetricKey(data: Data(repeating: 0xF0, count: 32)))
        return (keys, false)
    }

    func deleteHubIdentity(hubID: String) throws {}
}

private extension Data {
    init(hex: String) {
        precondition(hex.count.isMultiple(of: 2), "odd hex length")
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { preconditionFailure("bad hex") }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

import CryptoKit
import Foundation
import XCTest
import WatchtowerSync

/// The Swift → Go vector of the sealed sidecar keys (Go hub plan 1a Task 6): the Swift hub sealed `K_meta` and
/// epoch 1's `K_data ‖ K_alert` with ChaChaPoly under the identity's wrap key, the AAD binding the hub id
/// (`wt/hub-meta/v1` ‖ hub UUID, `wt/hub-epoch/v1` ‖ hub UUID ‖ epoch u32 BE). Go's `identity.Keyring` must open
/// them with the same wrap key and AADs (`TestKeyring_OpensSwiftSealedKeys`), so an adoption reads a Swift sidecar.
/// The Swift hub is gone (go hub plan 3 Task 24); this test keeps the vector honest on its own: a plain run opens
/// the fixture's sealed values, and `WT_E2E_REGENERATE=1` writes a fresh fixture with the same layout.
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
    /// The vector's fixed wrap key: 32 × 0xF0.
    private static let wrapKey = SymmetricKey(data: Data(repeating: 0xF0, count: 32))

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
        let meta = try Self.open(Data(hex: vector.kMetaSealed), aad: try Self.metaAAD(vector.hubID))
        XCTAssertEqual(meta.hex, vector.kMeta)
        let keys = try Self.open(Data(hex: epoch.sealedKeys), aad: try Self.epochAAD(vector.hubID, epoch.epoch))
        XCTAssertEqual(keys.count, 64, "K_data ‖ K_alert")
        XCTAssertEqual(keys.prefix(32).hex, vector.dataKey)
        XCTAssertEqual(keys.suffix(32).hex, vector.alertKey)
    }

    /// The AADs bind the hub and the epoch: the same sealed value opens under no other hub id or epoch.
    func testTheAADsBindTheHubAndTheEpoch() throws {
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: Self.fixtureURL))
        let epoch = try XCTUnwrap(vector.epochs.first)
        let otherHub = "00112233-4455-6677-8899-AABBCCDDEE00"
        XCTAssertThrowsError(try Self.open(Data(hex: vector.kMetaSealed), aad: try Self.metaAAD(otherHub)))
        XCTAssertThrowsError(try Self.open(Data(hex: epoch.sealedKeys), aad: try Self.epochAAD(vector.hubID, epoch.epoch + 1)))
        XCTAssertThrowsError(try Self.open(Data(hex: epoch.sealedKeys), aad: try Self.metaAAD(vector.hubID)))
    }

    private func regenerate() throws {
        let meta = Self.randomKey()
        let keys = Self.randomKey() + Self.randomKey()
        let vector = Vector(
            hubID: Self.hubID,
            kMetaSealed: try Self.seal(meta, aad: try Self.metaAAD(Self.hubID)).hex,
            epochs: [.init(epoch: 1, sealedKeys: try Self.seal(keys, aad: try Self.epochAAD(Self.hubID, 1)).hex)],
            kMeta: meta.hex, dataKey: keys.prefix(32).hex, alertKey: keys.suffix(32).hex)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(vector)
        data.append(0x0A)
        try FileManager.default.createDirectory(
            at: Self.fixtureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: Self.fixtureURL)
    }

    private static func metaAAD(_ hubID: String) throws -> Data {
        Data("wt/hub-meta/v1".utf8) + WireBytes.bytes(of: try WireBytes.hubUUID(hubID))
    }

    private static func epochAAD(_ hubID: String, _ epoch: UInt32) throws -> Data {
        var aad = Data("wt/hub-epoch/v1".utf8) + WireBytes.bytes(of: try WireBytes.hubUUID(hubID))
        WireBytes.append(epoch, to: &aad)
        return aad
    }

    private static func seal(_ plain: Data, aad: Data) throws -> Data {
        try ChaChaPoly.seal(plain, using: wrapKey, authenticating: aad).combined
    }

    private static func open(_ sealed: Data, aad: Data) throws -> Data {
        try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: wrapKey, authenticating: aad)
    }

    private static func randomKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
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

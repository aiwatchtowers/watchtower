import CryptoKit
import Foundation
import XCTest
@testable import WatchtowerSync

extension Data {
    /// Test-only hex parser; traps on malformed input (fixtures are literals).
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

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

/// The fixed synthetic inputs of every e2e fixture (`a...b` is a, a+1, ..., b).
struct E2EFixtureKeys {
    static let metaKeyBytes = sequence(0xC0, 0xDF)
    /// The hub's confirm nonce of the SAS v2 vector (chosen after the hello, delivered in the waiting keybox).
    static let confirmNonce = sequence(0xE0, 0xFF)
    static let hubIDString = "00112233-4455-6677-8899-AABBCCDDEEFF"

    let hubID: UUID
    let linkNonce: Data
    let hubKX: Curve25519.KeyAgreement.PrivateKey
    let devKX: Curve25519.KeyAgreement.PrivateKey
    let hubSig: Curve25519.Signing.PrivateKey
    let devSig: Curve25519.Signing.PrivateKey
    let deviceID: UUID

    init() throws {
        hubID = try XCTUnwrap(UUID(uuidString: Self.hubIDString))
        linkNonce = Self.sequence(0xA0, 0xBF)
        hubKX = try .init(rawRepresentation: Self.sequence(0x01, 0x20))
        devKX = try .init(rawRepresentation: Self.sequence(0x21, 0x40))
        hubSig = try .init(rawRepresentation: Self.sequence(0x41, 0x60))
        devSig = try .init(rawRepresentation: Self.sequence(0x61, 0x80))
        deviceID = KeyDerivation.deviceID(signingPublicKey: devSig.publicKey)
    }

    static func sequence(_ from: UInt8, _ through: UInt8) -> Data {
        Data((Int(from)...Int(through)).map { UInt8($0) })
    }

    func sas(
        nonce: Data? = nil, deviceAgreement: Curve25519.KeyAgreement.PublicKey? = nil, confirmNonce: Data? = nil
    ) -> String {
        KeyDerivation.sas(
            hubID: hubID, linkNonce: nonce ?? linkNonce,
            hubSigning: hubSig.publicKey, hubAgreement: hubKX.publicKey,
            deviceSigning: devSig.publicKey, deviceAgreement: deviceAgreement ?? devKX.publicKey,
            confirmNonce: confirmNonce ?? Self.confirmNonce)
    }
}

enum E2EFixtures {
    /// `Tests/Fixtures/e2e`: this file sits in `WatchtowerSyncTests/Support/`.
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Support
        .deletingLastPathComponent() // WatchtowerSyncTests
        .deletingLastPathComponent() // Tests
        .appendingPathComponent("Fixtures/e2e")

    static func check<T: Codable & Equatable>(
        _ computed: T, file: String, testFile: StaticString = #filePath, line: UInt = #line
    ) throws {
        let url = directory.appendingPathComponent("\(file).json")
        if ProcessInfo.processInfo.environment["WT_E2E_REGENERATE"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            var data = try encoder.encode(computed)
            data.append(0x0A)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url)
            XCTFail("regenerated, re-run without WT_E2E_REGENERATE", file: testFile, line: line)
            return
        }
        let frozen = try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
        XCTAssertEqual(computed, frozen, file: testFile, line: line)
    }
}

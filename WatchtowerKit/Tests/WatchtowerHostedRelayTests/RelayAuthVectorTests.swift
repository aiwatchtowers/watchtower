import CryptoKit
import Foundation
import WatchtowerHostedRelay
import WatchtowerSync
import XCTest

/// The relay device id and the register/login messages, pinned to the Go client by
/// `Fixtures/relay/auth_vectors.json` (written by Go `TestKitRelayAuthVectors`, `-update`).
/// CryptoKit's Ed25519 is randomized, so Swift signatures are verified, never compared (R17).
final class RelayAuthVectorTests: XCTestCase {
    private struct Vector: Decodable {
        let seed: String
        let authPub: String
        let relayDeviceId: String
        let nonce: String
        let origin: String
        let registerClientDataHash: String
        let registerSignature: String
        let loginMessage: String
        let loginSignature: String
        let loginClientDataHash: String
    }

    private struct Vectors: Decodable {
        let cases: [Vector]
    }

    private func vectors() throws -> [Vector] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<2 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("Fixtures/relay/auth_vectors.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let cases = try decoder.decode(Vectors.self, from: Data(contentsOf: url)).cases
        XCTAssertEqual(cases.count, 2)
        return cases
    }

    private func hex(_ string: String) throws -> Data {
        var data = Data(capacity: string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = try XCTUnwrap(string.index(index, offsetBy: 2, limitedBy: string.endIndex))
            data.append(try XCTUnwrap(UInt8(string[index..<next], radix: 16)))
            index = next
        }
        return data
    }

    func testDeviceIDMatchesTheGoClient() throws {
        for vector in try vectors() {
            let pub = try hex(vector.authPub)
            XCTAssertEqual(RelayAuthMessages.deviceID(publicKey: pub), vector.relayDeviceId)
            XCTAssertEqual(RelayIDs.deviceID(publicKey: pub), vector.relayDeviceId)
            XCTAssertTrue(RelayIDs.isValid(vector.relayDeviceId))
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: hex(vector.seed))
            XCTAssertEqual(Ed25519RelaySigner(key).publicKey, pub)
        }
    }

    func testRelayIDFormatRule() {
        let valid = String(repeating: "a", count: 50) + "27"
        XCTAssertTrue(RelayIDs.isValid(valid))
        XCTAssertFalse(RelayIDs.isValid(String(valid.dropLast())), "51 characters")
        XCTAssertFalse(RelayIDs.isValid(valid + "a"), "53 characters")
        XCTAssertFalse(RelayIDs.isValid(valid.uppercased()), "upper case")
        XCTAssertFalse(RelayIDs.isValid(String(valid.dropLast()) + "1"), "1 is not base32")
        XCTAssertFalse(RelayIDs.isValid(String(valid.dropLast()) + "="), "padding")
        XCTAssertFalse(RelayIDs.isValid("CCCCCCCC-0000-4000-8000-000000000003"))
        XCTAssertFalse(RelayIDs.isValid(""))
    }

    func testRegisterClientDataHashVector() throws {
        for vector in try vectors() {
            let origin = try RelayOrigin(vector.origin)
            let got = try RelayAuthMessages.registerClientDataHash(
                nonce: hex(vector.nonce), authPub: hex(vector.authPub), origin: origin
            )
            XCTAssertEqual(got, try hex(vector.registerClientDataHash))
        }
    }

    func testLoginMessageAndHashMatchTheGoClient() throws {
        for vector in try vectors() {
            let origin = try RelayOrigin(vector.origin)
            let nonce = try hex(vector.nonce)
            XCTAssertEqual(
                RelayAuthMessages.loginMessage(nonce: nonce, deviceID: vector.relayDeviceId, origin: origin),
                try hex(vector.loginMessage)
            )
            XCTAssertEqual(
                RelayAuthMessages.loginClientDataHash(nonce: nonce, deviceID: vector.relayDeviceId, origin: origin),
                try hex(vector.loginClientDataHash)
            )
        }
    }

    /// The relay's vouch vector (board #1432): SHA256("relay/v1/vouch" ‖ nonce ‖ hub_device_id ‖ auth_pub ‖ origin).
    func testVouchClientDataHashVector() throws {
        let got = RelayAuthMessages.vouchClientDataHash(
            nonce: Data([1, 2]), hubDeviceID: "h", authPub: Data([3]), origin: try RelayOrigin("https://r")
        )
        XCTAssertEqual(got, try hex("ecdda44ae74bd86e122f2edd43708cf2b8012cc194f78ed5728052e5c109956d"))
    }

    func testGoSignaturesVerifyAndOursVerifyToo() throws {
        for vector in try vectors() {
            let pub = try Curve25519.Signing.PublicKey(rawRepresentation: hex(vector.authPub))
            let registerHash = try hex(vector.registerClientDataHash)
            let loginMessage = try hex(vector.loginMessage)
            XCTAssertTrue(pub.isValidSignature(try hex(vector.registerSignature), for: registerHash))
            XCTAssertTrue(pub.isValidSignature(try hex(vector.loginSignature), for: loginMessage))

            let signer = try Ed25519RelaySigner(Curve25519.Signing.PrivateKey(rawRepresentation: hex(vector.seed)))
            XCTAssertTrue(pub.isValidSignature(try signer.sign(registerHash), for: registerHash))
            XCTAssertTrue(pub.isValidSignature(try signer.sign(loginMessage), for: loginMessage))
        }
    }

    func testOriginTrimsTheTrailingSlashAndRefusesPaths() throws {
        let origin = try RelayOrigin("https://relay.example.com/")
        XCTAssertEqual(origin.string, "https://relay.example.com")
        XCTAssertEqual(origin.url, URL(string: "https://relay.example.com"))
        XCTAssertEqual(try RelayOrigin("http://127.0.0.1:8787").string, "http://127.0.0.1:8787")
        XCTAssertThrowsError(try RelayOrigin("https://relay.example.com/v1")) { error in
            XCTAssertEqual(error as? RelayOriginError, .invalid)
        }
        XCTAssertThrowsError(try RelayOrigin("ftp://x")) { error in
            XCTAssertEqual(error as? RelayOriginError, .invalid)
        }
    }
}

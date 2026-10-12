import CryptoKit
import XCTest
@testable import WatchtowerSync

/// The one cross-language HPKE check (Go 1.25 has no `crypto/hpke`): the RFC 9180 Appendix A.2.1 vector,
/// hand-transcribed into `Fixtures/e2e/hpke-rfc9180-a21.json` (source URL inside the file).
final class HPKEVectorTests: XCTestCase {
    private struct Vector: Decodable {
        let source: String
        let info: String
        let skRm: String
        let pkRm: String
        let enc: String
        let aad: String
        let pt: String
        let ct: String
    }

    private func loadVector() throws -> Vector {
        let url = E2EFixtures.directory.appendingPathComponent("hpke-rfc9180-a21.json")
        return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
    }

    func testCryptoKitOpensRFC9180A21BaseModeFirstEncryption() throws {
        let vector = try loadVector()
        XCTAssertTrue(vector.source.contains("rfc9180"))
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: vector.skRm))
        XCTAssertEqual(privateKey.publicKey.rawRepresentation.hexString, vector.pkRm)
        var recipient = try HPKE.Recipient(
            privateKey: privateKey, ciphersuite: SealedBox.ciphersuite,
            info: Data(hex: vector.info), encapsulatedKey: Data(hex: vector.enc))
        let plain = try recipient.open(Data(hex: vector.ct), authenticating: Data(hex: vector.aad))
        XCTAssertEqual(plain, Data(hex: vector.pt))
    }
}

import CryptoKit
import XCTest
@testable import WatchtowerSync

final class E2EPrimitiveTests: XCTestCase {
    func testHKDFMatchesRFC5869CaseA1() {
        let ikm = SymmetricKey(data: Data(repeating: 0x0b, count: 22))
        let salt = Data(hex: "000102030405060708090a0b0c")
        let info = Data(hex: "f0f1f2f3f4f5f6f7f8f9")
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: info, outputByteCount: 42)
        XCTAssertEqual(okm.withUnsafeBytes { Data($0) }.hexString,
                       "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
    }

    func testX25519MatchesRFC7748Section61() throws {
        let alice = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(hex: "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"))
        let bob = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(hex: "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"))
        XCTAssertEqual(alice.publicKey.rawRepresentation.hexString,
                       "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        XCTAssertEqual(bob.publicKey.rawRepresentation.hexString,
                       "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
        let shared = try alice.sharedSecretFromKeyAgreement(with: bob.publicKey)
        XCTAssertEqual(shared.withUnsafeBytes { Data($0) }.hexString,
                       "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
    }

    func testEd25519VerifiesRFC8032Test1() throws {
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(hex: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"))
        XCTAssertEqual(key.publicKey.rawRepresentation.hexString,
                       "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        let signature = Data(hex: "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
            + "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data()))
    }

    func testHMACSHA256MatchesRFC4231Case2() {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("what do ya want for nothing?".utf8), using: SymmetricKey(data: Data("Jefe".utf8)))
        XCTAssertEqual(Data(mac).hexString, "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    }

    /// RFC 8439 §2.8.2 (key 80..9f, nonce 07000000 40414243 44454647,
    /// AAD 50515253c0c1c2c3c4c5c6c7, tag 1ae10b594f09e26a7e902ecbd0600691).
    private static let expectedCiphertext =
        "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6"
        + "3dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b36"
        + "92ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc"
        + "3ff4def08e4b7a9de576d26586cec64b6116"

    func testChaChaPolyMatchesRFC8439Section282() throws {
        let key = SymmetricKey(data: Data((0x80...0x9f).map { UInt8($0) }))
        let nonce = try ChaChaPoly.Nonce(data: Data(hex: "070000004041424344454647"))
        let plaintext = Data(("Ladies and Gentlemen of the class of '99: If I could offer you only one tip "
            + "for the future, sunscreen would be it.").utf8)
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce,
                                      authenticating: Data(hex: "50515253c0c1c2c3c4c5c6c7"))
        XCTAssertEqual(box.tag.hexString, "1ae10b594f09e26a7e902ecbd0600691")
        XCTAssertEqual(box.ciphertext.hexString, Self.expectedCiphertext)
    }

    func testBase32MatchesRFC4648Section10LowercaseUnpadded() {
        let cases = ["": "", "f": "my", "fo": "mzxq", "foo": "mzxw6", "foob": "mzxw6yq",
                     "fooba": "mzxw6ytb", "foobar": "mzxw6ytboi"]
        for (input, expected) in cases {
            XCTAssertEqual(WireBytes.base32(Data(input.utf8)), expected, input)
        }
    }

    func testBigEndianRoundTripAndOutOfRangeReadsNil() {
        var data = Data()
        WireBytes.append(UInt32(0x0102_0304), to: &data)
        WireBytes.append(UInt64(0x0506_0708_090A_0B0C), to: &data)
        XCTAssertEqual(data.hexString, "01020304" + "05060708090a0b0c")
        XCTAssertEqual(WireBytes.readUInt64(data, at: 4), 0x0506_0708_090A_0B0C)
        XCTAssertNil(WireBytes.readUInt64(data, at: 5))
        XCTAssertNil(WireBytes.readUInt64(data, at: -1))
    }

    func testUInt16AndSlicedDataReads() {
        var data = Data()
        WireBytes.append(UInt16(0xABCD), to: &data)
        XCTAssertEqual(data.hexString, "abcd")
        XCTAssertEqual(WireBytes.readUInt16(data, at: 0), 0xABCD)
        XCTAssertNil(WireBytes.readUInt16(data, at: 1))
        let sliced = Data([0xFF, 0x01, 0x02, 0x03, 0x04]).dropFirst()
        XCTAssertEqual(WireBytes.readUInt32(sliced, at: 0), 0x0102_0304)
    }

    func testUUIDBytesRoundTripAndHubUUID() throws {
        let id = try WireBytes.hubUUID("00112233-4455-6677-8899-AABBCCDDEEFF")
        XCTAssertEqual(WireBytes.bytes(of: id).hexString, "00112233445566778899aabbccddeeff")
        XCTAssertEqual(WireBytes.uuid(WireBytes.bytes(of: id)), id)
        XCTAssertNil(WireBytes.uuid(Data(repeating: 0, count: 15)))
        XCTAssertThrowsError(try WireBytes.hubUUID("not-a-uuid")) {
            XCTAssertEqual($0 as? E2EError, .badHubID("not-a-uuid"))
        }
    }

    func testBase64URLIsCanonicalOnly() {
        let data = Data([0xFB, 0xFF, 0xFE])
        XCTAssertEqual(WireBytes.base64URL(data), "-__-")
        XCTAssertEqual(WireBytes.fromBase64URL("-__-"), data)
        XCTAssertNil(WireBytes.fromBase64URL("+//+"))
        XCTAssertNil(WireBytes.fromBase64URL("QQ=="))
        XCTAssertNil(WireBytes.fromBase64URL("QR")) // non-zero trailing bits
        XCTAssertNil(WireBytes.fromBase64URL(""))
    }
}

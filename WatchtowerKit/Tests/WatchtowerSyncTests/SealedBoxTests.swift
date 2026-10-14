import CryptoKit
import XCTest
@testable import WatchtowerSync

final class SealedBoxTests: XCTestCase {
    private var keys: E2EFixtureKeys!

    override func setUpWithError() throws {
        keys = try E2EFixtureKeys()
    }

    private var helloContext: EnvelopeContext { EnvelopeContext(zone: .relay, wireName: "hello-\(keys.deviceID.uuidString)") }
    private var keyboxContext: EnvelopeContext { EnvelopeContext(zone: .data, wireName: "keybox-\(keys.deviceID.uuidString)") }
    private let frame = InnerFrame(kind: "hello", id: "d1", payload: Data(#"{"device":{}}"#.utf8))

    private func sealHello(nonce: Data? = nil) throws -> Data {
        try SealedBox.seal(
            frame, envelopeClass: .hello, to: keys.hubKX.publicKey,
            info: SealedBox.helloInfo(hubID: keys.hubID, linkNonce: nonce ?? keys.linkNonce),
            hubID: keys.hubID, senderID: keys.deviceID, epoch: 0, seq: 1,
            context: helloContext, signer: keys.devSig)
    }

    private func sealKeybox(signer: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        try SealedBox.seal(
            frame, envelopeClass: .keybox, to: keys.devKX.publicKey,
            info: SealedBox.keyboxInfo(hubID: keys.hubID, deviceID: keys.deviceID),
            hubID: keys.hubID, senderID: keys.hubID, epoch: 1, seq: 2,
            context: keyboxContext, signer: signer ?? keys.hubSig)
    }

    func testAHelloOpensOnlyWithTheHubKeyAndTheCodesNonce() throws {
        let data = try sealHello()
        let opened = try SealedBox.open(
            data, envelopeClass: .hello, recipient: keys.hubKX,
            info: SealedBox.helloInfo(hubID: keys.hubID, linkNonce: keys.linkNonce), context: helloContext, verifier: nil)
        XCTAssertEqual(opened.frame, frame)
        XCTAssertEqual(opened.header.senderID, keys.deviceID)

        let otherNonce = Data(repeating: 7, count: 32)
        XCTAssertThrowsError(try SealedBox.open(
            data, envelopeClass: .hello, recipient: keys.hubKX,
            info: SealedBox.helloInfo(hubID: keys.hubID, linkNonce: otherNonce), context: helloContext, verifier: nil)
        ) { XCTAssertEqual($0 as? EnvelopeError, .authenticationFailed) }

        XCTAssertThrowsError(try SealedBox.open(
            data, envelopeClass: .hello, recipient: Curve25519.KeyAgreement.PrivateKey(),
            info: SealedBox.helloInfo(hubID: keys.hubID, linkNonce: keys.linkNonce), context: helloContext, verifier: nil)
        ) { XCTAssertEqual($0 as? EnvelopeError, .authenticationFailed) }

        // A hello moved to another record name does not open (AAD).
        XCTAssertThrowsError(try SealedBox.open(
            data, envelopeClass: .hello, recipient: keys.hubKX,
            info: SealedBox.helloInfo(hubID: keys.hubID, linkNonce: keys.linkNonce),
            context: EnvelopeContext(zone: .relay, wireName: "hello-other"), verifier: nil)
        ) { XCTAssertEqual($0 as? EnvelopeError, .authenticationFailed) }
    }

    func testAHelloSignatureVerifiesWithTheDevicesOwnKeyAfterOpening() throws {
        let data = try sealHello()
        let envelope = try Envelope.parse(data)
        XCTAssertNoThrow(try EnvelopeSealer.verify(envelope, context: helloContext, key: keys.devSig.publicKey))
        XCTAssertThrowsError(try EnvelopeSealer.verify(envelope, context: helloContext, key: keys.hubSig.publicKey))
        // A verifier handed to open is checked too.
        XCTAssertThrowsError(try SealedBox.open(
            data, envelopeClass: .hello, recipient: keys.hubKX,
            info: SealedBox.helloInfo(hubID: keys.hubID, linkNonce: keys.linkNonce),
            context: helloContext, verifier: keys.hubSig.publicKey)
        ) { XCTAssertEqual($0 as? EnvelopeError, .signatureInvalid) }
    }

    func testAKeyboxOpensWithTheHubSignatureAndIsRefusedWithoutIt() throws {
        let data = try sealKeybox()
        let info = SealedBox.keyboxInfo(hubID: keys.hubID, deviceID: keys.deviceID)
        let opened = try SealedBox.open(
            data, envelopeClass: .keybox, recipient: keys.devKX, info: info,
            context: keyboxContext, verifier: keys.hubSig.publicKey)
        XCTAssertEqual(opened.frame, frame)

        // No unsigned bypass: a keybox needs a verifier.
        XCTAssertThrowsError(try SealedBox.open(
            data, envelopeClass: .keybox, recipient: keys.devKX, info: info, context: keyboxContext, verifier: nil)
        ) { XCTAssertEqual($0 as? EnvelopeError, .signatureRequired) }
    }

    func testAKeyboxIsRefusedWithoutTheHubSignature() throws {
        let forged = try sealKeybox(signer: keys.devSig)
        XCTAssertThrowsError(try SealedBox.open(
            forged, envelopeClass: .keybox, recipient: keys.devKX,
            info: SealedBox.keyboxInfo(hubID: keys.hubID, deviceID: keys.deviceID),
            context: keyboxContext, verifier: keys.hubSig.publicKey)
        ) { XCTAssertEqual($0 as? EnvelopeError, .signatureInvalid) }
    }

    func testAnUnsignedKeyboxIsRefusedAsMissingTheSignature() throws {
        let envelope = try Envelope.parse(try sealKeybox())
        let flags = envelope.header.flags.subtracting(.signed)
        let header = try EnvelopeHeader(
            flags: flags, hubID: envelope.header.hubID, senderID: envelope.header.senderID, epoch: envelope.header.epoch,
            seq: envelope.header.seq, nonce: envelope.header.nonce, envelopeClass: .keybox, bodyLength: envelope.header.bodyLength)
        let stripped = Envelope(header: header, body: envelope.body, signature: nil).encoded()
        XCTAssertThrowsError(try SealedBox.open(
            stripped, envelopeClass: .keybox, recipient: keys.devKX,
            info: SealedBox.keyboxInfo(hubID: keys.hubID, deviceID: keys.deviceID),
            context: keyboxContext, verifier: keys.hubSig.publicKey)
        ) { XCTAssertEqual($0 as? EnvelopeError, .signatureMissing) }
    }

    func testHPKEBodiesDifferEachSealButOpenToTheSameFrame() throws {
        let first = try sealKeybox(), second = try sealKeybox()
        XCTAssertNotEqual(first, second)
        let info = SealedBox.keyboxInfo(hubID: keys.hubID, deviceID: keys.deviceID)
        for data in [first, second] {
            let opened = try SealedBox.open(
                data, envelopeClass: .keybox, recipient: keys.devKX, info: info,
                context: keyboxContext, verifier: keys.hubSig.publicKey)
            XCTAssertEqual(opened.frame, frame)
        }
    }

    func testTheEnvelopeNonceOfAnHPKEClassIsZero() throws {
        for data in [try sealHello(), try sealKeybox()] {
            let envelope = try Envelope.parse(data)
            XCTAssertEqual(envelope.header.nonce, Data(count: 12))
            XCTAssertTrue(envelope.header.flags.contains(.signed))
            XCTAssertTrue(envelope.header.flags.contains(.padded))
            XCTAssertEqual(Int(envelope.header.bodyLength), envelope.body.count)
            XCTAssertGreaterThanOrEqual(envelope.body.count, 32 + 16)
        }
    }

    func testTheClassMustMatchAndSymmetricClassesAreNotSealedHere() throws {
        XCTAssertThrowsError(try SealedBox.seal(
            frame, envelopeClass: .data, to: keys.devKX.publicKey, info: Data(), hubID: keys.hubID,
            senderID: keys.hubID, epoch: 1, seq: 1, context: keyboxContext, signer: keys.hubSig)
        ) { XCTAssertEqual($0 as? EnvelopeError, .wrongClass(.data)) }
        let info = SealedBox.keyboxInfo(hubID: keys.hubID, deviceID: keys.deviceID)
        XCTAssertThrowsError(try SealedBox.open(
            try sealKeybox(), envelopeClass: .hello, recipient: keys.devKX, info: info,
            context: keyboxContext, verifier: keys.hubSig.publicKey)
        ) { XCTAssertEqual($0 as? EnvelopeError, .wrongClass(.keybox)) }
    }

    func testInfoStringsAreDomainSeparated() {
        let hub = keys.hubID
        XCTAssertEqual(
            SealedBox.helloInfo(hubID: hub, linkNonce: keys.linkNonce),
            Data("wt/hello/v1".utf8) + WireBytes.bytes(of: hub) + keys.linkNonce)
        XCTAssertEqual(
            SealedBox.keyboxInfo(hubID: hub, deviceID: keys.deviceID),
            Data("wt/keybox/v1".utf8) + WireBytes.bytes(of: hub) + WireBytes.bytes(of: keys.deviceID))
    }
}

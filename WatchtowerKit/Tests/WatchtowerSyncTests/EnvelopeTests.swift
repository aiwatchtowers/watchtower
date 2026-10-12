import CryptoKit
import XCTest
@testable import WatchtowerSync

/// Frozen in `Fixtures/e2e/envelope.json`. CryptoKit's Ed25519 is randomized, so `signature` is NOT part of
/// equality (header + body are deterministic under the fixed nonce); the stored signatures are checked by
/// verification in `verifyStoredSignatures`.
struct EnvelopeVectors: Codable, Equatable {
    struct Case: Codable, Equatable {
        var envelopeClass: UInt16
        var zone: String
        var wireName: String
        var kind: String
        var id: String
        var notifyLevel: String?
        var payload: String
        var header: String
        var body: String
        var signature: String?

        static func == (lhs: Self, rhs: Self) -> Bool {
            var left = lhs, right = rhs
            left.signature = nil
            right.signature = nil
            return left.envelopeClass == right.envelopeClass && left.zone == right.zone && left.wireName == right.wireName
                && left.kind == right.kind && left.id == right.id && left.notifyLevel == right.notifyLevel
                && left.payload == right.payload && left.header == right.header && left.body == right.body
                && (lhs.signature == nil) == (rhs.signature == nil)
        }
    }

    var cases: [String: Case]

    init(keys k: E2EFixtureKeys, dataKey: SymmetricKey, nonce: ChaChaPoly.Nonce) throws {
        let asset = try ChunkedAssetCipher.encrypt(
            Data("[]".utf8), assetID: k.hubID, key: SymmetricKey(data: E2EFixtureKeys.sequence(0x90, 0xAF)), chunkSize: 16).descriptor
        let hubToPhone = try Self.relayKey(k, .hubToPhone), phoneToHub = try Self.relayKey(k, .phoneToHub)
        cases = [:]
        cases["data"] = try Self.make(
            k, class: .data, key: dataKey, sender: k.hubID, place: EnvelopeContext(zone: .data, wireName: "abcdefghijklmnopqrstuvwxyz"), signed: true,
            frame: InnerFrame(kind: "meeting_transcript", id: "9", notifyLevel: "urgent", asset: asset,
                              payload: Data(#"{"title":"Acme sync"}"#.utf8)), nonce: nonce)
        cases["relayToHub"] = try Self.make(
            k, class: .relayToHub, key: phoneToHub, sender: k.deviceID, place: EnvelopeContext(zone: .relay, wireName: "zyxwvutsrqponmlkjihgfedcba"),
            signed: false, frame: InnerFrame(kind: "action", id: "a1", payload: Data(#"{"op":"close"}"#.utf8)), nonce: nonce)
        cases["relayToPhone"] = try Self.make(
            k, class: .relayToPhone, key: hubToPhone, sender: k.hubID, place: EnvelopeContext(zone: .relay, wireName: "zyxwvutsrqponmlkjihgfedcba"),
            signed: false, frame: InnerFrame(kind: "echo", id: "a1", payload: Data(#"{"ok":true}"#.utf8)), nonce: nonce)
    }

    private static func relayKey(_ k: E2EFixtureKeys, _ direction: RelayDirection) throws -> SymmetricKey {
        try KeyDerivation.relayKey(
            agreementPrivate: k.hubKX, peerPublic: k.devKX.publicKey, linkNonce: k.linkNonce,
            hubID: k.hubID, deviceID: k.deviceID, epoch: 1, direction: direction)
    }

    private static func make(
        _ k: E2EFixtureKeys,
        class envelopeClass: EnvelopeClass,
        key: SymmetricKey,
        sender: UUID,
        place: EnvelopeContext,
        signed: Bool,
        frame: InnerFrame,
        nonce: ChaChaPoly.Nonce
    ) throws -> Case {
        let (zone, name) = (place.zone, place.wireName)
        let context = place
        let data = try EnvelopeSealer.sealSymmetric(
            frame, envelopeClass: envelopeClass, key: key, hubID: k.hubID, senderID: sender, epoch: 1, seq: 7,
            context: context, signer: signed ? k.hubSig : nil, nonce: nonce)
        let envelope = try Envelope.parse(data)
        return Case(
            envelopeClass: envelopeClass.rawValue, zone: zone.rawValue, wireName: name, kind: frame.kind, id: frame.id,
            notifyLevel: frame.notifyLevel, payload: frame.payload.hexString, header: envelope.header.encoded().hexString,
            body: envelope.body.hexString, signature: envelope.signature?.hexString)
    }

    static func verifyStoredSignatures(file: String, key: Curve25519.Signing.PublicKey) throws {
        let url = E2EFixtures.directory.appendingPathComponent("\(file).json")
        let frozen = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        var verified = 0
        for (_, item) in frozen.cases {
            guard let signature = item.signature else { continue }
            let header = try EnvelopeHeader.parse(Data(hex: item.header))
            let zone = try XCTUnwrap(CloudZoneID(rawValue: item.zone))
            let message = try EnvelopeSealer.signatureMessage(
                header, body: Data(hex: item.body), context: EnvelopeContext(zone: zone, wireName: item.wireName))
            XCTAssertTrue(key.isValidSignature(Data(hex: signature), for: message))
            verified += 1
        }
        XCTAssertEqual(verified, 1)
    }
}

final class EnvelopeTests: XCTestCase {
    private var k: E2EFixtureKeys!
    private let dataKey = SymmetricKey(data: Data((0x10...0x2F).map { UInt8($0) }))
    private var fixedNonce: ChaChaPoly.Nonce!
    private let context = EnvelopeContext(zone: .data, wireName: "abcdefghijklmnopqrstuvwxyz")

    override func setUpWithError() throws {
        k = try E2EFixtureKeys()
        fixedNonce = try ChaChaPoly.Nonce(data: Data((0x50...0x5B).map { UInt8($0) }))
    }

    private func seal(_ frame: InnerFrame, seq: UInt64 = 7, context: EnvelopeContext? = nil) throws -> Data {
        try EnvelopeSealer.sealSymmetric(frame, envelopeClass: .data, key: dataKey, hubID: k.hubID, senderID: k.hubID,
                                         epoch: 1, seq: seq, context: context ?? self.context, signer: k.hubSig, nonce: fixedNonce)
    }

    func testHeaderLayoutIsSixtyEightBytesInSpecOrder() throws {
        let data = try seal(InnerFrame(kind: "owner_ask", id: "42", payload: Data("{}".utf8)))
        XCTAssertEqual(data.prefix(3), Data("WTE".utf8))
        XCTAssertEqual(data[3], 1); XCTAssertEqual(data[4], 1); XCTAssertEqual(data[5], 0b101)   // signed | padded
        XCTAssertEqual(data[6..<22], WireBytes.bytes(of: k.hubID))
        XCTAssertEqual(WireBytes.readUInt32(data, at: 38), 1)
        XCTAssertEqual(WireBytes.readUInt64(data, at: 42), 7)
        XCTAssertEqual(data[50..<62], Data((0x50...0x5B).map { UInt8($0) }))
        XCTAssertEqual(WireBytes.readUInt16(data, at: 62), EnvelopeClass.data.rawValue)
        XCTAssertEqual(data.count, 68 + 256 + 16 + 64)
        XCTAssertNil(data.range(of: Data("owner_ask".utf8)), "the kind is inside the ciphertext (D1)")
    }

    func testRoundTripReturnsTheFrame() throws {
        let frame = InnerFrame(kind: "meeting_transcript", id: "9", notifyLevel: "urgent",
                               asset: try ChunkedAssetCipher.encrypt(Data("[]".utf8), chunkSize: 16).descriptor,
                               payload: Data(#"{"title":"Acme sync"}"#.utf8))
        let opened = try EnvelopeSealer.openSymmetric(try seal(frame), accepting: [.data], context: context,
                                                      verifier: k.hubSig.publicKey) { _ in self.dataKey }
        XCTAssertEqual(opened.frame, frame)
        XCTAssertEqual(opened.header.seq, 7)
        XCTAssertTrue(opened.header.flags.contains(.hasAsset))
    }

    func testMovingTheEnvelopeToAnotherRecordOrZoneFails() throws {
        let data = try seal(InnerFrame(kind: "owner_ask", id: "42", payload: Data()))
        for other in [EnvelopeContext(zone: .data, wireName: "another-record-name-aaaaaa"),
                      EnvelopeContext(zone: .relay, wireName: context.wireName)] {
            XCTAssertThrowsError(try EnvelopeSealer.openSymmetric(data, accepting: [.data], context: other,
                                                                  verifier: k.hubSig.publicKey) { _ in self.dataKey })
        }
    }

    func testAFlippedHeaderByteFailsAndUnsignedDataIsRefusedWhenAVerifierIsGiven() throws {
        var data = try seal(InnerFrame(kind: "owner_ask", id: "42", payload: Data()))
        data[45] ^= 1   // seq
        XCTAssertThrowsError(try EnvelopeSealer.openSymmetric(data, accepting: [.data], context: context,
                                                              verifier: k.hubSig.publicKey) { _ in self.dataKey })
        let unsigned = try EnvelopeSealer.sealSymmetric(InnerFrame(kind: "x", id: "1", payload: Data()), envelopeClass: .data,
                                                        key: dataKey, hubID: k.hubID, senderID: k.hubID, epoch: 1, seq: 1,
                                                        context: context, signer: nil)
        XCTAssertThrowsError(try EnvelopeSealer.openSymmetric(unsigned, accepting: [.data], context: context,
                                                              verifier: k.hubSig.publicKey) { _ in self.dataKey }) {
            XCTAssertEqual($0 as? EnvelopeError, .signatureMissing)
        }
    }

    func testASignatureByAnotherKeyIsRefusedEvenWithTheRightAEADKey() throws {
        // A same-Apple-ID writer that learned K_data (a relay or team member, spec §2.2) still cannot author.
        let forged = try EnvelopeSealer.sealSymmetric(InnerFrame(kind: "owner_ask", id: "42", payload: Data()),
                                                      envelopeClass: .data, key: dataKey, hubID: k.hubID, senderID: k.hubID,
                                                      epoch: 1, seq: 9, context: context, signer: k.devSig)
        XCTAssertThrowsError(try EnvelopeSealer.openSymmetric(forged, accepting: [.data], context: context,
                                                              verifier: k.hubSig.publicKey) { _ in self.dataKey }) {
            XCTAssertEqual($0 as? EnvelopeError, .signatureInvalid)
        }
    }

    func testUnknownVersionAndSuiteAreRefusedLoudly() throws {
        var data = try seal(InnerFrame(kind: "x", id: "1", payload: Data()))
        data[3] = 2
        XCTAssertThrowsError(try Envelope.parse(data)) { XCTAssertEqual($0 as? EnvelopeError, .unsupportedVersion(2)) }
        data[3] = 1; data[4] = 2
        XCTAssertThrowsError(try Envelope.parse(data)) { XCTAssertEqual($0 as? EnvelopeError, .unsupportedSuite(2)) }
    }

    func testTrailingBytesAreRefused() throws {
        let data = try seal(InnerFrame(kind: "x", id: "1", payload: Data()))
        XCTAssertThrowsError(try Envelope.parse(data + Data([0]))) { XCTAssertEqual($0 as? EnvelopeError, .lengthMismatch) }
    }

    func testNonZeroPaddingIsRefused() throws {
        var frame = try InnerFrame(kind: "x", id: "1", payload: Data([7])).encoded(paddedTo: 256)
        frame[255] = 1
        XCTAssertThrowsError(try InnerFrame.parse(frame)) { XCTAssertEqual($0 as? EnvelopeError, .frameMalformed) }
    }

    func testAFrameThatDoesNotFitEvenUnpaddedThrowsOversized() {
        let frame = InnerFrame(kind: "x", id: "1", payload: Data(count: EnvelopeSealer.frameCap(signed: true)))
        XCTAssertThrowsError(try seal(frame)) { XCTAssertEqual($0 as? EnvelopeError, .oversized) }
    }

    func testAFrameThatFitsOnlyUnpaddedStillSealsToTheCap() throws {
        let cap = EnvelopeSealer.frameCap(signed: true)
        let overhead = InnerFrame(kind: "x", id: "1", payload: Data()).encodedLength
        let data = try seal(InnerFrame(kind: "x", id: "1", payload: Data(count: cap - overhead - 5)))
        XCTAssertEqual(data.count, Envelope.maxBytes)
    }

    func testTruncatedAndGarbageInputIsRefusedWithoutTrapping() throws {
        let data = try seal(InnerFrame(kind: "x", id: "1", payload: Data()))
        for count in [0, 2, 67, 68, 200, data.count - 1] {
            XCTAssertThrowsError(try Envelope.parse(data.prefix(count)))
        }
        var badMagic = data
        badMagic[0] = 0x58
        XCTAssertThrowsError(try Envelope.parse(badMagic)) { XCTAssertEqual($0 as? EnvelopeError, .badMagic) }
        var badClass = data
        badClass[62] = 0; badClass[63] = 99
        XCTAssertThrowsError(try Envelope.parse(badClass)) { XCTAssertEqual($0 as? EnvelopeError, .unknownClass(99)) }
        XCTAssertThrowsError(try InnerFrame.parse(Data([1, 200, 0x41]))) { XCTAssertEqual($0 as? EnvelopeError, .frameMalformed) }
    }

    func testAClassOutsideTheAcceptedSetIsRefused() throws {
        let data = try seal(InnerFrame(kind: "x", id: "1", payload: Data()))
        XCTAssertThrowsError(try EnvelopeSealer.openSymmetric(data, accepting: [.relayToHub], context: context,
                                                              verifier: nil) { _ in self.dataKey }) {
            XCTAssertEqual($0 as? EnvelopeError, .wrongClass(.data))
        }
    }

    func testAWrongKeyIsAnAuthenticationFailure() throws {
        let data = try seal(InnerFrame(kind: "x", id: "1", payload: Data()))
        XCTAssertThrowsError(try EnvelopeSealer.openSymmetric(data, accepting: [.data], context: context,
                                                              verifier: k.hubSig.publicKey) { _ in SymmetricKey(size: .bits256) }) {
            XCTAssertEqual($0 as? EnvelopeError, .authenticationFailed)
        }
    }

    func testVerifyNeedsNoSecretKey() throws {
        let envelope = try Envelope.parse(try seal(InnerFrame(kind: "x", id: "1", payload: Data())))
        XCTAssertNoThrow(try EnvelopeSealer.verify(envelope, context: context, key: k.hubSig.publicKey))
        XCTAssertThrowsError(try EnvelopeSealer.verify(envelope, context: context, key: k.devSig.publicKey))
    }

    private func sealRelay(context: EnvelopeContext? = nil) throws -> Data {
        try EnvelopeSealer.sealSymmetric(InnerFrame(kind: "action", id: "1", payload: Data()), envelopeClass: .relayToHub,
                                         key: dataKey, hubID: k.hubID, senderID: k.deviceID, epoch: 1, seq: 3,
                                         context: context ?? EnvelopeContext(zone: .relay, wireName: "relay-record-aaaaaaaaaaa"),
                                         signer: nil, nonce: fixedNonce)
    }

    private func openRelay(_ data: Data, context: EnvelopeContext) throws {
        _ = try EnvelopeSealer.openSymmetric(data, accepting: [.relayToHub], context: context, verifier: nil) { _ in self.dataKey }
    }

    func testRelayAADBindsNameZoneAndHeaderWithoutASignature() throws {
        let home = EnvelopeContext(zone: .relay, wireName: "relay-record-aaaaaaaaaaa")
        let data = try sealRelay()
        XCTAssertNoThrow(try openRelay(data, context: home))
        for other in [EnvelopeContext(zone: .relay, wireName: "relay-record-bbbbbbbbbbb"),
                      EnvelopeContext(zone: .data, wireName: home.wireName)] {
            XCTAssertThrowsError(try openRelay(data, context: other)) { XCTAssertEqual($0 as? EnvelopeError, .authenticationFailed) }
        }
        var flipped = data
        flipped[45] ^= 1   // seq
        XCTAssertThrowsError(try openRelay(flipped, context: home)) { XCTAssertEqual($0 as? EnvelopeError, .authenticationFailed) }
    }

    func testDataAndAlertRequireAVerifier() throws {
        let signed = try seal(InnerFrame(kind: "x", id: "1", payload: Data()))
        XCTAssertThrowsError(try EnvelopeSealer.openSymmetric(signed, accepting: [.data], context: context,
                                                              verifier: nil) { _ in self.dataKey }) {
            XCTAssertEqual($0 as? EnvelopeError, .signatureRequired)
        }
        let alert = try EnvelopeSealer.sealSymmetric(InnerFrame(kind: "x", id: "1", payload: Data()), envelopeClass: .alert,
                                                     key: dataKey, hubID: k.hubID, senderID: k.hubID, epoch: 1, seq: 1,
                                                     context: context, signer: nil)
        XCTAssertThrowsError(try EnvelopeSealer.openSymmetric(alert, accepting: [.alert], context: context,
                                                              verifier: nil) { _ in self.dataKey }) {
            XCTAssertEqual($0 as? EnvelopeError, .signatureRequired)
        }
    }

    func testAKeyResolverErrorSurfacesUnchanged() throws {
        struct Locked: Error, Equatable {}
        let data = try seal(InnerFrame(kind: "x", id: "1", payload: Data()))
        XCTAssertThrowsError(try EnvelopeSealer.openSymmetric(data, accepting: [.data], context: context,
                                                              verifier: k.hubSig.publicKey) { _ in throw Locked() }) {
            XCTAssertEqual($0 as? Locked, Locked())
        }
    }

    func testAnOverlongRecordNameIsRefused() {
        let long = EnvelopeContext(zone: .data, wireName: String(repeating: "a", count: 65_536))
        XCTAssertThrowsError(try seal(InnerFrame(kind: "x", id: "1", payload: Data()), context: long)) {
            XCTAssertEqual($0 as? EnvelopeError, .frameMalformed)
        }
    }

    func testVectorsMatchTheFrozenFile() throws {
        let computed = try EnvelopeVectors(keys: k, dataKey: dataKey, nonce: fixedNonce)
        try E2EFixtures.check(computed, file: "envelope")
        try EnvelopeVectors.verifyStoredSignatures(file: "envelope", key: k.hubSig.publicKey)
    }
}

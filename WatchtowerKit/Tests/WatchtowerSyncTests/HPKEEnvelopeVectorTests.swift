import CryptoKit
import XCTest
@testable import WatchtowerSync

/// A hello (phone to `hub_kx`, signed by `dev_sig`) and a keybox (hub to `dev_kx`, signed by `hub_sig`) sealed with
/// the fixture keys; frozen in `Fixtures/e2e/hpke-envelope.json`. HPKE and Ed25519 are randomized, so `envelope` is
/// NOT part of equality: the stored envelopes are opened (`SealedBox.open`) and verified instead.
struct HPKEEnvelopeVectors: Codable, Equatable {
    struct Case: Codable, Equatable {
        var envelope: String
        var zone: String
        var wireName: String
        var info: String
        var kind: String
        var id: String
        var payload: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.zone == rhs.zone && lhs.wireName == rhs.wireName && lhs.info == rhs.info && lhs.kind == rhs.kind
                && lhs.id == rhs.id && lhs.payload == rhs.payload && lhs.envelope.isEmpty == rhs.envelope.isEmpty
        }
    }

    static let epoch: UInt32 = 1
    static let seq: UInt64 = 7
    static let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    /// The keybox's `data_key`: the same 0x10...0x2F as `EnvelopeTests`' data key.
    static let dataKeyBytes = E2EFixtureKeys.sequence(0x10, 0x2F)

    var hello: Case
    var keybox: Case

    init(keys k: E2EFixtureKeys) throws {
        let device = k.deviceID.uuidString
        let helloPayload = try RelayCoder.makeEncoder().encode(DeviceHello(
            device: DevicePayload(
                deviceID: device, name: "Acme iPhone", model: "iPhone", appVersion: "1.0", scope: .private,
                userRecordName: "_owner", linkNonce: WireBytes.base64URL(k.linkNonce), typingRequested: false,
                startSessions: true, updatedAt: Self.stamp),
            signingKey: WireBytes.base64URL(k.devSig.publicKey.rawRepresentation),
            agreementKey: WireBytes.base64URL(k.devKX.publicKey.rawRepresentation)))
        hello = try Self.make(
            k, class: .hello, to: k.hubKX.publicKey, info: SealedBox.helloInfo(hubID: k.hubID, linkNonce: k.linkNonce),
            sender: k.deviceID, signer: k.devSig, place: EnvelopeContext(zone: .relay, wireName: "hello-\(device)"),
            frame: InnerFrame(kind: RelayRecordKind.hello.rawValue, id: "hello-\(device)", payload: helloPayload))

        let grant = DeviceGrant(
            deviceID: device, hubID: k.hubID.uuidString, name: "Acme iPhone", scope: .private, linked: true,
            linkedAt: Self.stamp, typingAllowed: false, startSessionsAllowed: true, decidedAt: Self.stamp)
        let keys = KeyboxKeys(
            epoch: Self.epoch, dataKey: WireBytes.base64URL(Self.dataKeyBytes),
            alertKey: WireBytes.base64URL(E2EFixtureKeys.sequence(0xD0, 0xEF)),
            metaKey: WireBytes.base64URL(E2EFixtureKeys.metaKeyBytes))
        let keyboxPayload = try RelayCoder.makeEncoder().encode(Keybox(grant: grant, keys: keys))
        keybox = try Self.make(
            k, class: .keybox, to: k.devKX.publicKey, info: SealedBox.keyboxInfo(hubID: k.hubID, deviceID: k.deviceID),
            sender: k.hubID, signer: k.hubSig, place: EnvelopeContext(zone: .data, wireName: Keybox.recordName(deviceID: device)),
            frame: InnerFrame(kind: SliceKind.deviceGrant.rawValue, id: grant.recordName, payload: keyboxPayload))
    }

    private static func make(
        _ k: E2EFixtureKeys,
        class envelopeClass: EnvelopeClass,
        to recipient: Curve25519.KeyAgreement.PublicKey,
        info: Data,
        sender: UUID,
        signer: Curve25519.Signing.PrivateKey,
        place: EnvelopeContext,
        frame: InnerFrame
    ) throws -> Case {
        let envelope = try SealedBox.seal(
            frame, envelopeClass: envelopeClass, to: recipient, info: info, hubID: k.hubID, senderID: sender,
            epoch: epoch, seq: seq, context: place, signer: signer)
        return Case(
            envelope: envelope.hexString, zone: place.zone.rawValue, wireName: place.wireName, info: info.hexString,
            kind: frame.kind, id: frame.id, payload: frame.payload.hexString)
    }
}

final class HPKEEnvelopeVectorTests: XCTestCase {
    private var k: E2EFixtureKeys!

    override func setUpWithError() throws {
        k = try E2EFixtureKeys()
    }

    private func frozen() throws -> HPKEEnvelopeVectors {
        let url = E2EFixtures.directory.appendingPathComponent("hpke-envelope.json")
        return try JSONDecoder().decode(HPKEEnvelopeVectors.self, from: Data(contentsOf: url))
    }

    private func open(
        _ item: HPKEEnvelopeVectors.Case,
        _ envelopeClass: EnvelopeClass,
        recipient: Curve25519.KeyAgreement.PrivateKey,
        verifier: Curve25519.Signing.PublicKey?
    ) throws -> (header: EnvelopeHeader, frame: InnerFrame) {
        let zone = try XCTUnwrap(CloudZoneID(rawValue: item.zone))
        return try SealedBox.open(
            Data(hex: item.envelope), envelopeClass: envelopeClass, recipient: recipient, info: Data(hex: item.info),
            context: EnvelopeContext(zone: zone, wireName: item.wireName), verifier: verifier)
    }

    private func assertOpened(
        _ opened: (header: EnvelopeHeader, frame: InnerFrame),
        _ item: HPKEEnvelopeVectors.Case,
        sender: UUID,
        line: UInt = #line
    ) {
        XCTAssertEqual(opened.frame, InnerFrame(kind: item.kind, id: item.id, payload: Data(hex: item.payload)), line: line)
        XCTAssertEqual(opened.header.hubID, k.hubID, line: line)
        XCTAssertEqual(opened.header.senderID, sender, line: line)
        XCTAssertEqual(opened.header.epoch, HPKEEnvelopeVectors.epoch, line: line)
        XCTAssertEqual(opened.header.seq, HPKEEnvelopeVectors.seq, line: line)
        XCTAssertEqual(opened.header.nonce, Data(count: EnvelopeHeader.nonceLength), "HPKE envelopes carry a zero nonce", line: line)
    }

    func testHelloAndKeyboxVectorsOpen() throws {
        try E2EFixtures.check(try HPKEEnvelopeVectors(keys: k), file: "hpke-envelope")
        let vectors = try frozen()

        // Hello: opened by hub_kx without a verifier, then verified with the dev_sig key it carries.
        let hello = try open(vectors.hello, .hello, recipient: k.hubKX, verifier: nil)
        assertOpened(hello, vectors.hello, sender: k.deviceID)
        let payload = try RelayCoder.makeDecoder().decode(DeviceHello.self, from: hello.frame.payload)
        let signingKey = try Curve25519.Signing.PublicKey(rawRepresentation: try XCTUnwrap(WireBytes.fromBase64URL(payload.signingKey)))
        XCTAssertEqual(KeyDerivation.deviceID(signingPublicKey: signingKey), k.deviceID)
        let helloContext = EnvelopeContext(zone: .relay, wireName: vectors.hello.wireName)
        let helloEnvelope = try Envelope.parse(Data(hex: vectors.hello.envelope))
        XCTAssertNoThrow(try EnvelopeSealer.verify(helloEnvelope, context: helloContext, key: signingKey))
        XCTAssertThrowsError(try EnvelopeSealer.verify(helloEnvelope, context: helloContext, key: k.hubSig.publicKey)) {
            XCTAssertEqual($0 as? EnvelopeError, .signatureInvalid)
        }

        // Keybox: verified with hub_sig, opened by dev_kx; the payload is a Keybox with the grant and the keys.
        let keybox = try open(vectors.keybox, .keybox, recipient: k.devKX, verifier: k.hubSig.publicKey)
        assertOpened(keybox, vectors.keybox, sender: k.hubID)
        let box = try RelayCoder.makeDecoder().decode(Keybox.self, from: keybox.frame.payload)
        XCTAssertEqual(box.grant.deviceID, k.deviceID.uuidString)
        XCTAssertEqual(box.keys?.dataKey, WireBytes.base64URL(HPKEEnvelopeVectors.dataKeyBytes))
        XCTAssertThrowsError(try open(vectors.keybox, .keybox, recipient: k.devKX, verifier: k.devSig.publicKey)) {
            XCTAssertEqual($0 as? EnvelopeError, .signatureInvalid)
        }
        XCTAssertThrowsError(try open(vectors.keybox, .keybox, recipient: k.hubKX, verifier: k.hubSig.publicKey)) {
            XCTAssertEqual($0 as? EnvelopeError, .authenticationFailed)
        }
    }
}

import CryptoKit
import Foundation

/// The HPKE classes of the envelope (spec §2.3): `.hello` (phone to hub, signed by the phone's own key as proof
/// of possession) and `.keybox` (hub to phone, signed by `hub_sig`). Body = enc (32) ‖ HPKE ciphertext ‖ tag;
/// the header nonce is 12 zero bytes (HPKE derives its own); AAD = `context.aad(header)`.
public enum SealedBox {
    public static let ciphersuite = HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .chaChaPoly)
    private static let encapsulatedKeyLength = 32
    private static let tagLength = 16
    private static let hpkeClasses: Set<EnvelopeClass> = [.hello, .keybox]

    /// "wt/hello/v1" ‖ hub_id ‖ link_nonce.
    public static func helloInfo(hubID: UUID, linkNonce: Data) -> Data {
        Data("wt/hello/v1".utf8) + WireBytes.bytes(of: hubID) + linkNonce
    }

    /// "wt/keybox/v1" ‖ hub_id ‖ device_id.
    public static func keyboxInfo(hubID: UUID, deviceID: UUID) -> Data {
        Data("wt/keybox/v1".utf8) + WireBytes.bytes(of: hubID) + WireBytes.bytes(of: deviceID)
    }

    // Always signed and padded. Throws `.wrongClass` for any class but `.hello`/`.keybox`, `.oversized` when the
    // padded frame cannot fit under `Envelope.maxBytes`.
    // swiftlint:disable:next function_parameter_count
    public static func seal(
        _ frame: InnerFrame,
        envelopeClass: EnvelopeClass,
        to recipient: Curve25519.KeyAgreement.PublicKey,
        info: Data,
        hubID: UUID,
        senderID: UUID,
        epoch: UInt32,
        seq: UInt64,
        context: EnvelopeContext,
        signer: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        guard hpkeClasses.contains(envelopeClass) else { throw EnvelopeError.wrongClass(envelopeClass) }
        let cap = EnvelopeSealer.frameCap(signed: true) - encapsulatedKeyLength
        guard let padded = Padding.paddedLength(frame.encodedLength, cap: cap) else { throw EnvelopeError.oversized }
        var flags: EnvelopeHeader.Flags = [.padded, .signed]
        if frame.asset != nil { flags.insert(.hasAsset) }
        let header = try EnvelopeHeader(
            flags: flags, hubID: hubID, senderID: senderID, epoch: epoch, seq: seq,
            nonce: Data(count: EnvelopeHeader.nonceLength), envelopeClass: envelopeClass,
            bodyLength: UInt32(encapsulatedKeyLength + padded + tagLength))
        var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: ciphersuite, info: info)
        let sealed = try sender.seal(try frame.encoded(paddedTo: padded), authenticating: try context.aad(header: header))
        let body = sender.encapsulatedKey + sealed
        let signature = try Data(signer.signature(for: EnvelopeSealer.signatureMessage(header, body: body, context: context)))
        return Envelope(header: header, body: body, signature: signature).encoded()
    }

    /// Parses, checks the class, verifies the signature when `verifier` is given, then opens.
    /// A `.keybox` needs a verifier (`.signatureRequired` without one: there is no unsigned bypass), and an envelope
    /// without a signature is `.signatureMissing`. For `.hello` the verifier is nil at this step: the device's key
    /// is inside the sealed payload, so the hub verifies afterwards with `EnvelopeSealer.verify` and checks
    /// `device_id == KeyDerivation.deviceID(signingKey)`.
    public static func open(
        _ data: Data,
        envelopeClass: EnvelopeClass,
        recipient: Curve25519.KeyAgreement.PrivateKey,
        info: Data,
        context: EnvelopeContext,
        verifier: Curve25519.Signing.PublicKey?
    ) throws -> (header: EnvelopeHeader, frame: InnerFrame) {
        guard hpkeClasses.contains(envelopeClass) else { throw EnvelopeError.wrongClass(envelopeClass) }
        let envelope = try Envelope.parse(data)
        let header = envelope.header
        guard header.envelopeClass == envelopeClass else { throw EnvelopeError.wrongClass(header.envelopeClass) }
        guard header.flags.contains(.signed), envelope.signature != nil else { throw EnvelopeError.signatureMissing }
        if envelopeClass == .keybox {
            guard verifier != nil else { throw EnvelopeError.signatureRequired }
        }
        if let verifier { try EnvelopeSealer.verify(envelope, context: context, key: verifier) }
        guard envelope.body.count >= encapsulatedKeyLength + tagLength else { throw EnvelopeError.lengthMismatch }
        let aad = try context.aad(header: header)
        let plain: Data
        do {
            var opener = try HPKE.Recipient(
                privateKey: recipient, ciphersuite: ciphersuite, info: info,
                encapsulatedKey: envelope.body.prefix(encapsulatedKeyLength))
            plain = try opener.open(envelope.body.dropFirst(encapsulatedKeyLength), authenticating: aad)
        } catch {
            // Wrong key, wrong code nonce, moved record, flipped bit: one outcome, no detail leaks.
            throw EnvelopeError.authenticationFailed
        }
        let frame = try InnerFrame.parse(plain)
        guard header.flags.contains(.hasAsset) == (frame.asset != nil) else { throw EnvelopeError.frameMalformed }
        return (header, frame)
    }
}

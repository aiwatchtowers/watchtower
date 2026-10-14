import CryptoKit
import Foundation

public enum EnvelopeSealer {
    private static let tagLength = 16
    private static let symmetricClasses: Set<EnvelopeClass> = [.data, .alert, .relayToHub, .relayToPhone]

    /// Largest padded frame for a class: Envelope.maxBytes − 68 − 16 − (signed ? 64 : 0).
    public static func frameCap(signed: Bool) -> Int {
        Envelope.maxBytes - EnvelopeHeader.length - tagLength - (signed ? Envelope.signatureLength : 0)
    }

    /// The envelope size for a frame whose length is ALREADY padded (header + frameLength + tag + signature);
    /// nil when it cannot fit. It does not pad: pass `Padding.paddedLength(...)`.
    public static func sealedLength(frameLength: Int, signed: Bool) -> Int? {
        guard frameLength >= 0, frameLength <= frameCap(signed: signed) else { return nil }
        return EnvelopeHeader.length + frameLength + tagLength + (signed ? Envelope.signatureLength : 0)
    }

    /// Message signed: "wt/sig/v1" ‖ context.aad(header) ‖ body.
    static func signatureMessage(_ header: EnvelopeHeader, body: Data, context: EnvelopeContext) throws -> Data {
        try Data("wt/sig/v1".utf8) + context.aad(header: header) + body
    }

    // swiftlint:disable:next function_parameter_count
    public static func sealSymmetric(
        _ frame: InnerFrame,
        envelopeClass: EnvelopeClass,
        key: SymmetricKey,
        hubID: UUID,
        senderID: UUID,
        epoch: UInt32,
        seq: UInt64,
        context: EnvelopeContext,
        signer: Curve25519.Signing.PrivateKey?,
        nonce: ChaChaPoly.Nonce = ChaChaPoly.Nonce()
    ) throws -> Data {
        guard symmetricClasses.contains(envelopeClass) else { throw EnvelopeError.wrongClass(envelopeClass) }
        let signed = signer != nil
        guard let padded = Padding.paddedLength(frame.encodedLength, cap: frameCap(signed: signed)) else {
            throw EnvelopeError.oversized
        }
        var flags: EnvelopeHeader.Flags = [.padded]
        if signed { flags.insert(.signed) }
        if frame.asset != nil { flags.insert(.hasAsset) }
        let header = try EnvelopeHeader(
            flags: flags, hubID: hubID, senderID: senderID, epoch: epoch, seq: seq,
            nonce: nonce.withUnsafeBytes { Data($0) }, envelopeClass: envelopeClass,
            bodyLength: UInt32(padded + tagLength))
        let box = try ChaChaPoly.seal(
            frame.encoded(paddedTo: padded), using: key, nonce: nonce, authenticating: try context.aad(header: header))
        let body = box.ciphertext + box.tag
        let signature = try signer.map { try Data($0.signature(for: signatureMessage(header, body: body, context: context))) }
        return Envelope(header: header, body: body, signature: signature).encoded()
    }

    /// Parses, checks the class is one of `accepting`, verifies the signature when `verifier` is given
    /// (and requires one then), resolves the key from the header, opens, parses the frame.
    public static func openSymmetric(
        _ data: Data,
        accepting: Set<EnvelopeClass>,
        context: EnvelopeContext,
        verifier: Curve25519.Signing.PublicKey?,
        key: (EnvelopeHeader) throws -> SymmetricKey
    ) throws -> (header: EnvelopeHeader, frame: InnerFrame) {
        let envelope = try Envelope.parse(data)
        let header = envelope.header
        guard accepting.contains(header.envelopeClass), symmetricClasses.contains(header.envelopeClass) else {
            throw EnvelopeError.wrongClass(header.envelopeClass)
        }
        // Spec §2.2: every DataZone/alert envelope is signed by hub_sig; the AEAD key alone is not authorship.
        if header.envelopeClass == .data || header.envelopeClass == .alert {
            guard verifier != nil else { throw EnvelopeError.signatureRequired }
        }
        if let verifier { try verify(envelope, context: context, key: verifier) }
        guard envelope.body.count >= tagLength else { throw EnvelopeError.lengthMismatch }
        let split = envelope.body.count - tagLength
        // Resolved outside the do/catch: a locked keychain or unknown epoch must surface as itself.
        let symmetricKey = try key(header)
        let aad = try context.aad(header: header)
        let plain: Data
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: header.nonce),
                ciphertext: envelope.body.prefix(split), tag: envelope.body.suffix(tagLength))
            plain = try ChaChaPoly.open(box, using: symmetricKey, authenticating: aad)
        } catch let error as EnvelopeError {
            throw error
        } catch {
            // Wrong key, moved record, flipped bit: all one outcome, no detail leaks.
            throw EnvelopeError.authenticationFailed
        }
        let frame = try InnerFrame.parse(plain)
        guard header.flags.contains(.hasAsset) == (frame.asset != nil) else { throw EnvelopeError.frameMalformed }
        return (header, frame)
    }

    /// Signature check only (no secret key): the replica's apply-time check.
    public static func verify(_ envelope: Envelope, context: EnvelopeContext, key: Curve25519.Signing.PublicKey) throws {
        guard envelope.header.flags.contains(.signed), let signature = envelope.signature else {
            throw EnvelopeError.signatureMissing
        }
        let message = try signatureMessage(envelope.header, body: envelope.body, context: context)
        guard key.isValidSignature(signature, for: message) else { throw EnvelopeError.signatureInvalid }
    }
}

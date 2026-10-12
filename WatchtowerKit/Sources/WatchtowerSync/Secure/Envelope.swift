import Foundation

public enum EnvelopeClass: UInt16, Sendable, CaseIterable {
    case data = 1          // AEAD K_data[e], signed by hub_sig
    case alert = 2         // AEAD K_alert[e], signed by hub_sig
    case keybox = 3        // HPKE to dev_kx, signed by hub_sig
    case hello = 4         // HPKE to hub_kx, signed by dev_sig
    case relayToHub = 5    // AEAD K_relay p2h[e]
    case relayToPhone = 6  // AEAD K_relay h2p[e]
}

public enum EnvelopeError: Error, Equatable {
    case tooShort, badMagic, unsupportedVersion(UInt8), unsupportedSuite(UInt8), unknownClass(UInt16)
    case lengthMismatch, signatureMissing, signatureInvalid, authenticationFailed, frameMalformed
    case signatureRequired, oversized, wrongClass(EnvelopeClass), wrongHub, wrongSender
}

/// 68 bytes: "WTE" | ver | suite | flags | hub_id 16 | sender_id 16 | epoch u32 | seq u64 | nonce 12 | class u16 | body_len u32.
public struct EnvelopeHeader: Equatable, Sendable {
    public static let length = 68
    public static let version: UInt8 = 1
    public static let suite1: UInt8 = 1
    public static let nonceLength = 12
    static let magic = Data("WTE".utf8)

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let signed = Self(rawValue: 1)
        public static let hasAsset = Self(rawValue: 2)
        public static let padded = Self(rawValue: 4)
    }

    public let flags: Flags
    public let hubID: UUID
    public let senderID: UUID
    public let epoch: UInt32
    public let seq: UInt64
    public let nonce: Data            // 12 bytes; zeros for the HPKE classes
    public let envelopeClass: EnvelopeClass
    public let bodyLength: UInt32

    /// Throws `.lengthMismatch` unless `nonce` is exactly 12 bytes.
    public init(
        flags: Flags,
        hubID: UUID,
        senderID: UUID,
        epoch: UInt32,
        seq: UInt64,
        nonce: Data,
        envelopeClass: EnvelopeClass,
        bodyLength: UInt32
    ) throws {
        guard nonce.count == Self.nonceLength else { throw EnvelopeError.lengthMismatch }
        self.flags = flags
        self.hubID = hubID
        self.senderID = senderID
        self.epoch = epoch
        self.seq = seq
        self.nonce = Data(nonce)
        self.envelopeClass = envelopeClass
        self.bodyLength = bodyLength
    }

    public func encoded() -> Data {
        var out = Self.magic
        out.append(Self.version)
        out.append(Self.suite1)
        out.append(flags.rawValue)
        out.append(WireBytes.bytes(of: hubID))
        out.append(WireBytes.bytes(of: senderID))
        WireBytes.append(epoch, to: &out)
        WireBytes.append(seq, to: &out)
        out.append(nonce)
        WireBytes.append(envelopeClass.rawValue, to: &out)
        WireBytes.append(bodyLength, to: &out)
        return out
    }

    /// Strict: refuses wrong magic, unknown version, suite, class and flag bits.
    static func parse(_ raw: Data) throws -> Self {
        let data = Data(raw)
        guard data.count >= length else { throw EnvelopeError.tooShort }
        guard data.prefix(3) == magic else { throw EnvelopeError.badMagic }
        guard data[3] == version else { throw EnvelopeError.unsupportedVersion(data[3]) }
        guard data[4] == suite1 else { throw EnvelopeError.unsupportedSuite(data[4]) }
        let known: UInt8 = Flags.signed.rawValue | Flags.hasAsset.rawValue | Flags.padded.rawValue
        guard data[5] & ~known == 0 else { throw EnvelopeError.frameMalformed }
        guard let hub = WireBytes.uuid(data.subdata(in: 6 ..< 22)),
              let sender = WireBytes.uuid(data.subdata(in: 22 ..< 38)),
              let epoch = WireBytes.readUInt32(data, at: 38),
              let seq = WireBytes.readUInt64(data, at: 42),
              let rawClass = WireBytes.readUInt16(data, at: 62),
              let bodyLength = WireBytes.readUInt32(data, at: 64)
        else { throw EnvelopeError.tooShort }
        guard let envelopeClass = EnvelopeClass(rawValue: rawClass) else { throw EnvelopeError.unknownClass(rawClass) }
        return try Self(
            flags: Flags(rawValue: data[5]), hubID: hub, senderID: sender, epoch: epoch, seq: seq,
            nonce: data.subdata(in: 50 ..< 62), envelopeClass: envelopeClass, bodyLength: bodyLength)
    }
}

/// The out-of-band AAD (spec §2.4): which zone and which wire record name the envelope belongs to.
public struct EnvelopeContext: Equatable, Sendable {
    public let zone: CloudZoneID
    public let wireName: String

    public init(zone: CloudZoneID, wireName: String) {
        self.zone = zone
        self.wireName = wireName
    }

    /// header ‖ zone u8 ‖ name_len u16 ‖ name utf8
    /// Throws `.frameMalformed` for a name above 65 535 UTF-8 bytes (it cannot be length-prefixed).
    func aad(header: EnvelopeHeader) throws -> Data {
        let name = Data(wireName.utf8)
        var out = header.encoded()
        out.append(KeyDerivation.zoneByte[zone] ?? 0)
        guard let nameLength = UInt16(exactly: name.count) else { throw EnvelopeError.frameMalformed }
        WireBytes.append(nameLength, to: &out)
        out.append(name)
        return out
    }
}

public struct Envelope: Equatable, Sendable {
    public static let maxBytes = 900_000          // the single source: SlicePublisher.maxPayloadBytes references it (F33, Task 11)
    public static let signatureLength = 64

    public let header: EnvelopeHeader
    public let body: Data            // ciphertext ‖ tag (AEAD) or enc 32 ‖ ciphertext ‖ tag (HPKE)
    public let signature: Data?      // 64 bytes when header.flags contains .signed

    public init(header: EnvelopeHeader, body: Data, signature: Data?) {
        self.header = header
        self.body = body
        self.signature = signature
    }

    public func encoded() -> Data {
        var out = header.encoded()
        out.append(body)
        if let signature { out.append(signature) }
        return out
    }

    /// Refuses wrong magic, unknown version or suite (loudly: `.unsupportedVersion`/`.unsupportedSuite`,
    /// the phone's "Update Watchtower" path), unknown class, and any length mismatch.
    public static func parse(_ raw: Data) throws -> Self {
        let data = Data(raw)
        guard data.count <= maxBytes else { throw EnvelopeError.oversized }
        let header = try EnvelopeHeader.parse(data)
        let signatureBytes = header.flags.contains(.signed) ? signatureLength : 0
        guard data.count == EnvelopeHeader.length + Int(header.bodyLength) + signatureBytes else {
            throw EnvelopeError.lengthMismatch
        }
        let bodyEnd = EnvelopeHeader.length + Int(header.bodyLength)
        return Self(
            header: header,
            body: data.subdata(in: EnvelopeHeader.length ..< bodyEnd),
            signature: signatureBytes == 0 ? nil : data.subdata(in: bodyEnd ..< data.count))
    }
}

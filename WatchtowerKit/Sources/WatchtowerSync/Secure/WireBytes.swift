import Foundation

public enum E2EError: Error, Equatable {
    case badHubID(String)
}

/// Byte-level helpers shared by the E2E envelope, key derivation and the
/// link payload: big-endian integers, base32/base64url text, UUID bytes.
public enum WireBytes {
    // MARK: - Big-endian integers

    public static func append(_ value: UInt16, to data: inout Data) {
        append(bigEndian: UInt64(value), width: 2, to: &data)
    }

    public static func append(_ value: UInt32, to data: inout Data) {
        append(bigEndian: UInt64(value), width: 4, to: &data)
    }

    public static func append(_ value: UInt64, to data: inout Data) {
        append(bigEndian: value, width: 8, to: &data)
    }

    public static func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
        read(data, at: offset, width: 2).map { UInt16($0) }
    }

    public static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        read(data, at: offset, width: 4).map { UInt32($0) }
    }

    public static func readUInt64(_ data: Data, at offset: Int) -> UInt64? {
        read(data, at: offset, width: 8)
    }

    private static func append(bigEndian value: UInt64, width: Int, to data: inout Data) {
        for shift in stride(from: (width - 1) * 8, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    private static func read(_ data: Data, at offset: Int, width: Int) -> UInt64? {
        guard offset >= 0, offset <= data.count - width else { return nil }
        let start = data.startIndex + offset
        return data[start ..< start + width].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    // MARK: - Text encodings

    private static let base32Alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    /// RFC 4648 §6 alphabet, lowercase, no padding.
    public static func base32(_ data: Data) -> String {
        var out = ""
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                out.append(base32Alphabet[Int((buffer >> UInt32(bits - 5)) & 31)])
                bits -= 5
            }
            buffer &= (1 << UInt32(bits)) - 1
        }
        if bits > 0 {
            out.append(base32Alphabet[Int((buffer << UInt32(5 - bits)) & 31)])
        }
        return out
    }

    /// base64url without padding (RFC 4648 §5).
    public static func base64URL(_ data: Data) -> String {
        var string = data.base64EncodedString()
        string = string.replacingOccurrences(of: "+", with: "-")
        string = string.replacingOccurrences(of: "/", with: "_")
        while string.hasSuffix("=") { string.removeLast() }
        return string
    }

    /// Accepts only the canonical unpadded base64url form: anything that does
    /// not re-encode to the same string (padding, `+`, `/`, stray characters
    /// or trailing bits) is nil.
    public static func fromBase64URL(_ string: String) -> Data? {
        guard !string.isEmpty else { return nil }
        var base64 = string.replacingOccurrences(of: "-", with: "+")
        base64 = base64.replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), base64URL(data) == string else { return nil }
        return data
    }

    // MARK: - UUIDs

    public static func bytes(of uuid: UUID) -> Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    public static func uuid(_ data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        let b = [UInt8](data)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    public static func hubUUID(_ hubID: String) throws -> UUID {
        guard let uuid = UUID(uuidString: hubID) else { throw E2EError.badHubID(hubID) }
        return uuid
    }
}

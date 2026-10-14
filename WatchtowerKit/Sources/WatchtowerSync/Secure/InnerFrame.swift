import Foundation

/// The encrypted plaintext (D1): inner_ver u8 (1) | kind_len u8 | kind | id_len u16 | id | notify_len u8 | notify
/// | asset_flag u8 | [AssetDescriptor 101] | payload_len u32 | payload | zero padding.
public struct InnerFrame: Equatable, Sendable {
    public let kind: String
    public let id: String
    public let notifyLevel: String?
    public let asset: AssetDescriptor?
    public let payload: Data

    private static let version: UInt8 = 1

    public init(kind: String, id: String, notifyLevel: String? = nil, asset: AssetDescriptor? = nil, payload: Data) {
        self.kind = kind
        self.id = id
        self.notifyLevel = notifyLevel
        self.asset = asset
        self.payload = payload
    }

    public var encodedLength: Int {
        1 + 1 + kind.utf8.count + 2 + id.utf8.count + 1 + (notifyLevel?.utf8.count ?? 0)
            + 1 + (asset == nil ? 0 : AssetDescriptor.encodedLength) + 4 + payload.count
    }

    /// Throws `.oversized` when `length` is below `encodedLength` and `.frameMalformed` when a field
    /// exceeds its length prefix (kind or notify level above 255 bytes, id above 65 535, payload above u32).
    public func encoded(paddedTo length: Int) throws -> Data {
        let kindBytes = Data(kind.utf8), idBytes = Data(id.utf8), notifyBytes = Data((notifyLevel ?? "").utf8)
        guard kindBytes.count <= 255, idBytes.count <= 65_535, notifyBytes.count <= 255,
              UInt64(payload.count) <= UInt64(UInt32.max)
        else { throw EnvelopeError.frameMalformed }
        guard length >= encodedLength else { throw EnvelopeError.oversized }
        var out = Data(capacity: length)
        out.append(Self.version)
        out.append(UInt8(kindBytes.count))
        out.append(kindBytes)
        WireBytes.append(UInt16(idBytes.count), to: &out)
        out.append(idBytes)
        out.append(UInt8(notifyBytes.count))
        out.append(notifyBytes)
        if let asset {
            out.append(1)
            out.append(asset.encoded())
        } else {
            out.append(0)
        }
        WireBytes.append(UInt32(payload.count), to: &out)
        out.append(payload)
        out.append(Data(count: length - out.count))
        return out
    }

    /// Ignores trailing zeros only; any non-zero byte after the payload is `.frameMalformed`.
    public static func parse(_ data: Data) throws -> Self {
        var cursor = Cursor(data: Data(data))
        guard try cursor.byte() == version else { throw EnvelopeError.frameMalformed }
        let kind = try cursor.string(length: Int(cursor.byte()))
        let id = try cursor.string(length: Int(cursor.uint16()))
        let notify = try cursor.string(length: Int(cursor.byte()))
        let asset: AssetDescriptor?
        switch try cursor.byte() {
        case 0: asset = nil
        case 1:
            do { asset = try AssetDescriptor.parse(cursor.take(AssetDescriptor.encodedLength)) } catch {
                throw EnvelopeError.frameMalformed
            }
        default: throw EnvelopeError.frameMalformed
        }
        let payload = try cursor.take(Int(cursor.uint32()))
        guard cursor.remaining.allSatisfy({ $0 == 0 }) else { throw EnvelopeError.frameMalformed }
        return Self(kind: kind, id: id, notifyLevel: notify.isEmpty ? nil : notify, asset: asset, payload: payload)
    }

    /// Bounds-checked reader over a zero-based `Data`.
    private struct Cursor {
        let data: Data
        var position = 0

        init(data: Data) { self.data = data }

        var remaining: Data { data.subdata(in: position ..< data.count) }

        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= data.count - position else { throw EnvelopeError.frameMalformed }
            defer { position += count }
            return data.subdata(in: position ..< position + count)
        }

        mutating func byte() throws -> UInt8 { try take(1)[0] }

        mutating func uint16() throws -> UInt16 {
            guard let value = WireBytes.readUInt16(try take(2), at: 0) else { throw EnvelopeError.frameMalformed }
            return value
        }

        mutating func uint32() throws -> UInt32 {
            guard let value = WireBytes.readUInt32(try take(4), at: 0) else { throw EnvelopeError.frameMalformed }
            return value
        }

        mutating func string(length: Int) throws -> String {
            guard let text = String(data: try take(length), encoding: .utf8) else { throw EnvelopeError.frameMalformed }
            return text
        }
    }
}

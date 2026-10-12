import CryptoKit
import Foundation

public enum AssetCipherError: Error, Equatable {
    case badHeader, headerMismatch, truncated, oversized, chunkAuthenticationFailed(UInt32), digestMismatch
}

/// 37 bytes on the wire: "WTA" | ver u8 (1) | suite u8 (1) | asset_id 16 | chunk_size u32 | total_len u64 | chunk_count u32.
public struct AssetHeader: Equatable, Sendable {
    public let assetID: UUID
    public let suite: UInt8
    public let chunkSize: UInt32
    public let totalLength: UInt64
    public let chunkCount: UInt32
    public static let encodedLength = 37

    private static let magic = Data("WTA".utf8)
    private static let version: UInt8 = 1
    /// A sanity bound that keeps every length computation far from overflow (1 TiB).
    private static let maxTotalLength: UInt64 = 1 << 40

    public init(assetID: UUID, suite: UInt8 = 1, chunkSize: UInt32, totalLength: UInt64) {
        self.assetID = assetID
        self.suite = suite
        self.chunkSize = chunkSize
        self.totalLength = totalLength
        let chunks = chunkSize == 0 ? 0 : max(1, (totalLength + UInt64(chunkSize) - 1) / UInt64(chunkSize))
        self.chunkCount = UInt32(truncatingIfNeeded: chunks)
    }

    public func encoded() -> Data {
        var out = Self.magic
        out.append(Self.version)
        out.append(suite)
        out.append(WireBytes.bytes(of: assetID))
        WireBytes.append(chunkSize, to: &out)
        WireBytes.append(totalLength, to: &out)
        WireBytes.append(chunkCount, to: &out)
        return out
    }

    public static func parse(_ data: Data) throws -> Self {
        guard data.count == encodedLength, data.prefix(3) == magic else { throw AssetCipherError.badHeader }
        let base = data.startIndex
        guard data[base + 3] == version, data[base + 4] == 1,
              let id = WireBytes.uuid(data.subdata(in: base + 5 ..< base + 21)),
              let size = WireBytes.readUInt32(data, at: 21),
              let total = WireBytes.readUInt64(data, at: 25),
              let count = WireBytes.readUInt32(data, at: 33),
              size > 0, total <= maxTotalLength
        else { throw AssetCipherError.badHeader }
        let header = Self(assetID: id, suite: 1, chunkSize: size, totalLength: total)
        guard header.chunkCount == count else { throw AssetCipherError.badHeader }
        return header
    }
}

/// What the owning record's inner frame carries (101 bytes encoded): key 32 ‖ header 37 ‖ SHA-256(plaintext) 32.
public struct AssetDescriptor: Equatable, Sendable {
    public let key: Data
    public let header: AssetHeader
    public let plaintextDigest: Data
    public static let encodedLength = 101

    public init(key: Data, header: AssetHeader, plaintextDigest: Data) {
        self.key = key
        self.header = header
        self.plaintextDigest = plaintextDigest
    }

    public func encoded() -> Data {
        key + header.encoded() + plaintextDigest
    }

    public static func parse(_ data: Data) throws -> Self {
        guard data.count == encodedLength else { throw AssetCipherError.badHeader }
        let base = data.startIndex
        return Self(
            key: data.subdata(in: base ..< base + 32),
            header: try AssetHeader.parse(data.subdata(in: base + 32 ..< base + 69)),
            plaintextDigest: data.subdata(in: base + 69 ..< base + 101))
    }
}

public enum ChunkedAssetCipher {
    public static let chunkSize: UInt32 = 1 << 20
    private static let tagLength = 16

    /// File layout: header (37) ‖ chunk_0 … chunk_{n-1}; each chunk = chunkSize plaintext bytes (the last
    /// zero-padded) sealed with nonce u32 0 ‖ u64 c, AAD header ‖ u64 c ‖ u8 last, plus a 16-byte tag.
    public static func sealedLength(forPlaintext length: Int64, chunkSize: UInt32 = chunkSize) -> Int64 {
        let size = Int64(chunkSize)
        let chunks = max(1, (length + size - 1) / size)
        return Int64(AssetHeader.encodedLength) + chunks * (size + Int64(tagLength))
    }

    public static func encrypt(
        _ plaintext: Data,
        assetID: UUID = UUID(),
        key: SymmetricKey = SymmetricKey(size: .bits256),
        chunkSize: UInt32 = chunkSize
    ) throws -> (sealed: Data, descriptor: AssetDescriptor) {
        let header = AssetHeader(assetID: assetID, chunkSize: chunkSize, totalLength: UInt64(plaintext.count))
        var out = header.encoded()
        var hasher = SHA256()
        hasher.update(data: plaintext)
        let size = Int(chunkSize)
        var offset = plaintext.startIndex
        for index in 0 ..< header.chunkCount {
            let end = min(offset + size, plaintext.endIndex)
            out.append(try sealChunk(plaintext[offset ..< end], index: index, header: header, key: key))
            offset = end
        }
        return (out, descriptor(key: key, header: header, hasher: hasher))
    }

    public static func decrypt(_ sealed: Data, descriptor: AssetDescriptor) throws -> Data {
        var plain = Data()
        var position = 0
        try decryptStream(
            descriptor: descriptor, fileLength: Int64(sealed.count),
            read: { count in
                let start = sealed.startIndex + position
                position += count
                return sealed.subdata(in: start ..< start + count)
            },
            write: { plain.append($0) })
        return plain
    }

    /// Streaming, one chunk resident: reads `source`, writes `destination` atomically (temp file + move).
    public static func encryptFile(
        at source: URL,
        to destination: URL,
        assetID: UUID = UUID(),
        key: SymmetricKey = SymmetricKey(size: .bits256),
        chunkSize: UInt32 = chunkSize
    ) throws -> Self {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let length = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let header = AssetHeader(assetID: assetID, chunkSize: chunkSize, totalLength: length)
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        var hasher = SHA256()
        try writeAtomically(to: destination) { writer in
            try writer.write(contentsOf: header.encoded())
            var remaining = length
            for index in 0 ..< header.chunkCount {
                let want = Int(min(remaining, UInt64(chunkSize)))
                let chunk = try readExactly(reader, count: want)
                hasher.update(data: chunk)
                remaining -= UInt64(want)
                try writer.write(contentsOf: sealChunk(chunk, index: index, header: header, key: key))
            }
        }
        return descriptor(key: key, header: header, hasher: hasher)
    }

    public static func decryptFile(at source: URL, to destination: URL, descriptor: AssetDescriptor) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let length = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        try writeAtomically(to: destination) { writer in
            try decryptStream(
                descriptor: descriptor, fileLength: length,
                read: { try readExactly(reader, count: $0) },
                write: { try writer.write(contentsOf: $0) })
        }
    }

    // MARK: - Internals

    private static func descriptor(key: SymmetricKey, header: AssetHeader, hasher: SHA256) -> Self {
        AssetDescriptor(
            key: key.withUnsafeBytes { Data($0) }, header: header, plaintextDigest: Data(hasher.finalize()))
    }

    private static func nonce(_ index: UInt32) throws -> ChaChaPoly.Nonce {
        var data = Data(count: 4)
        WireBytes.append(UInt64(index), to: &data)
        return try ChaChaPoly.Nonce(data: data)
    }

    private static func aad(header: AssetHeader, index: UInt32) -> Data {
        var data = header.encoded()
        WireBytes.append(UInt64(index), to: &data)
        data.append(index == header.chunkCount - 1 ? 1 : 0)
        return data
    }

    /// Seals `plain` (at most `chunkSize` bytes) zero-padded to the full chunk size; returns ciphertext ‖ tag.
    private static func sealChunk(
        _ plain: Data, index: UInt32, header: AssetHeader, key: SymmetricKey
    ) throws -> Data {
        var padded = Data(plain)
        padded.append(Data(count: Int(header.chunkSize) - plain.count))
        let box = try ChaChaPoly.seal(padded, using: key, nonce: nonce(index), authenticating: aad(header: header, index: index))
        return box.ciphertext + box.tag
    }

    /// Validates the header and total length, then opens every chunk in order, handing the plaintext
    /// (trimmed to `totalLength`) to `write`, and checks the digest at the end.
    private static func decryptStream(
        descriptor: AssetDescriptor,
        fileLength: Int64,
        read: (Int) throws -> Data,
        write: (Data) throws -> Void
    ) throws {
        guard fileLength >= Int64(AssetHeader.encodedLength) else { throw AssetCipherError.truncated }
        let header = try AssetHeader.parse(read(AssetHeader.encodedLength))
        guard header == descriptor.header else { throw AssetCipherError.headerMismatch }
        let expected = sealedLength(forPlaintext: Int64(header.totalLength), chunkSize: header.chunkSize)
        guard fileLength >= expected else { throw AssetCipherError.truncated }
        guard fileLength == expected else { throw AssetCipherError.oversized }
        let key = SymmetricKey(data: descriptor.key)
        var hasher = SHA256()
        var remaining = header.totalLength
        for index in 0 ..< header.chunkCount {
            let sealedChunk = try read(Int(header.chunkSize) + tagLength)
            let box: ChaChaPoly.SealedBox
            do {
                box = try ChaChaPoly.SealedBox(
                    nonce: nonce(index), ciphertext: sealedChunk.prefix(Int(header.chunkSize)),
                    tag: sealedChunk.suffix(tagLength))
            } catch {
                throw AssetCipherError.chunkAuthenticationFailed(index)
            }
            let opened: Data
            do {
                opened = try ChaChaPoly.open(box, using: key, authenticating: aad(header: header, index: index))
            } catch {
                throw AssetCipherError.chunkAuthenticationFailed(index)
            }
            let keep = Int(min(remaining, UInt64(header.chunkSize)))
            let plain = opened.prefix(keep)
            remaining -= UInt64(keep)
            hasher.update(data: plain)
            try write(Data(plain))
        }
        guard Data(hasher.finalize()) == descriptor.plaintextDigest else { throw AssetCipherError.digestMismatch }
    }

    private static func readExactly(_ handle: FileHandle, count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let part = try handle.read(upToCount: count - data.count), !part.isEmpty else {
                throw AssetCipherError.truncated
            }
            data.append(part)
        }
        return data
    }

    /// Writes into a temp file beside `destination` and moves it into place only if `body` returns.
    private static func writeAtomically(to destination: URL, _ body: (FileHandle) throws -> Void) throws {
        let fileManager = FileManager.default
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temp.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let writer = try FileHandle(forWritingTo: temp)
            defer { try? writer.close() }
            try body(writer)
            try writer.close()
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }
}

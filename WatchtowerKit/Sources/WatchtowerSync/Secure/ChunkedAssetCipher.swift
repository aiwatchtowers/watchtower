import CryptoKit
import Foundation
import os

public enum AssetCipherError: Error, Equatable {
    case badHeader, headerMismatch, truncated, oversized, chunkAuthenticationFailed(UInt32), digestMismatch
    /// The source file grew or shrank (or reported no size) while it was being sealed.
    case sourceChanged
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

    /// Suite 1 only; throws `badHeader` for a zero chunk size, a total above 1 TiB or a chunk count beyond u32.
    public init(assetID: UUID, chunkSize: UInt32, totalLength: UInt64) throws {
        guard chunkSize > 0, totalLength <= Self.maxTotalLength else { throw AssetCipherError.badHeader }
        let chunks = max(1, (totalLength + UInt64(chunkSize) - 1) / UInt64(chunkSize))
        guard chunks <= UInt64(UInt32.max) else { throw AssetCipherError.badHeader }
        self.assetID = assetID
        self.suite = 1
        self.chunkSize = chunkSize
        self.totalLength = totalLength
        self.chunkCount = UInt32(chunks)
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
              size > 0
        else { throw AssetCipherError.badHeader }
        let header = try Self(assetID: id, chunkSize: size, totalLength: total)
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

    /// File layout: chunk_0 … chunk_{n-1} and nothing else (no plaintext header: the exact length and the
    /// asset id would cancel the padding, spec threat 8; the header travels in the encrypted descriptor).
    /// Each chunk = chunkSize plaintext bytes (the last zero-padded) sealed with nonce u32 0 ‖ u64 c,
    /// AAD header ‖ u64 c ‖ u8 last, plus a 16-byte tag. Returns 0 for a zero chunk size.
    public static func sealedLength(forPlaintext length: Int64, chunkSize: UInt32 = chunkSize) -> Int64 {
        guard chunkSize > 0 else { return 0 }
        let size = Int64(chunkSize)
        let chunks = max(1, (length + size - 1) / size)
        return chunks * (size + Int64(tagLength))
    }

    private static let logger = Logger(subsystem: "WatchtowerKit", category: "ChunkedAssetCipher")

    /// `key` MUST be fresh per asset: the nonce sequence is fixed (0, 1, 2, ...), so reusing a key across
    /// assets repeats (key, nonce) pairs, which breaks ChaCha20-Poly1305. The default is the production use.
    public static func encrypt(
        _ plaintext: Data,
        assetID: UUID = UUID(),
        key: SymmetricKey = SymmetricKey(size: .bits256),
        chunkSize: UInt32 = chunkSize
    ) throws -> (sealed: Data, descriptor: AssetDescriptor) {
        let header = try AssetHeader(assetID: assetID, chunkSize: chunkSize, totalLength: UInt64(plaintext.count))
        var out = Data()
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
    /// `key` MUST be fresh per asset (see `encrypt`). Fails with `.truncated` / `.sourceChanged` when the
    /// source shrinks or grows while it is being sealed.
    public static func encryptFile(
        at source: URL,
        to destination: URL,
        assetID: UUID = UUID(),
        key: SymmetricKey = SymmetricKey(size: .bits256),
        chunkSize: UInt32 = chunkSize
    ) throws -> AssetDescriptor {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard let length = (attributes[.size] as? NSNumber)?.uint64Value else { throw AssetCipherError.sourceChanged }
        return try encryptFile(at: source, to: destination, declaredLength: length, assetID: assetID, key: key, chunkSize: chunkSize)
    }

    /// Seam for tests: `declaredLength` is what the header promises; the file must hold exactly that many bytes.
    static func encryptFile(
        at source: URL,
        to destination: URL,
        declaredLength length: UInt64,
        assetID: UUID,
        key: SymmetricKey,
        chunkSize: UInt32
    ) throws -> AssetDescriptor {
        let header = try AssetHeader(assetID: assetID, chunkSize: chunkSize, totalLength: length)
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        var hasher = SHA256()
        try writeAtomically(to: destination) { writer in
            var remaining = length
            for index in 0 ..< header.chunkCount {
                let want = Int(min(remaining, UInt64(chunkSize)))
                let chunk = try readExactly(reader, count: want)
                hasher.update(data: chunk)
                remaining -= UInt64(want)
                try writer.write(contentsOf: sealChunk(chunk, index: index, header: header, key: key))
            }
            if let extra = try reader.read(upToCount: 1), !extra.isEmpty { throw AssetCipherError.sourceChanged }
        }
        return descriptor(key: key, header: header, hasher: hasher)
    }

    public static func decryptFile(at source: URL, to destination: URL, descriptor: AssetDescriptor) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard let length = (attributes[.size] as? NSNumber)?.int64Value else { throw AssetCipherError.truncated }
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

    private static func descriptor(key: SymmetricKey, header: AssetHeader, hasher: SHA256) -> AssetDescriptor {
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
        let header = descriptor.header
        guard header.suite == 1, header.chunkSize > 0, header.chunkCount > 0 else { throw AssetCipherError.badHeader }
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

    /// Writes into a temp file beside `destination` and moves it into place only if `body` returns. The temp file
    /// is created empty and owner-only (0600) before a byte is written, so `decryptFile`'s plaintext is never
    /// readable by another user, not even mid-write; the move keeps the mode.
    private static func writeAtomically(to destination: URL, _ body: (FileHandle) throws -> Void) throws {
        let fileManager = FileManager.default
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let writer = try FileHandle(forWritingTo: temp)
            do {
                try body(writer)
            } catch {
                // The body's error is the one reported; a failing close adds nothing.
                try? writer.close()
                throw error
            }
            try writer.close()
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: destination)
            }
        } catch {
            // Best effort: the original error is what the caller needs, but a temp file that survives may hold
            // authenticated plaintext (decryptFile), so a failed removal is logged, never silent.
            do {
                try fileManager.removeItem(at: temp)
            } catch let removalError {
                logger.error("temp file removal failed: \(removalError.localizedDescription)")
            }
            throw error
        }
    }
}

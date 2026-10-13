import CryptoKit
import XCTest
@testable import WatchtowerSync

/// Sealed bytes and descriptor of three small plaintexts (chunk size 16); frozen in `Fixtures/e2e/asset.json`.
struct AssetVectors: Codable, Equatable {
    var sealed: [String: String]
    var descriptors: [String: String]

    init(key: SymmetricKey, assetID: UUID) throws {
        var sealed = [String: String]()
        var descriptors = [String: String]()
        for length in [0, 16, 40] {
            let plain = Data((0 ..< length).map { UInt8(($0 * 7 + 3) & 0xFF) })
            let result = try ChunkedAssetCipher.encrypt(plain, assetID: assetID, key: key, chunkSize: 16)
            sealed["\(length)"] = result.sealed.hexString
            descriptors["\(length)"] = result.descriptor.encoded().hexString
        }
        self.sealed = sealed
        self.descriptors = descriptors
    }
}

final class ChunkedAssetCipherTests: XCTestCase {
    private let key = SymmetricKey(data: Data((0xE0 ... 0xFF).map { UInt8($0) }))
    // swiftlint:disable:next force_unwrapping
    private let assetID = UUID(uuidString: "0F0E0D0C-0B0A-0908-0706-050403020100")!
    private var scratch: URL?

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        scratch = nil
        super.tearDown()
    }

    func testRoundTripAcrossChunkBoundariesAndPadsEveryChunkToFullSize() throws {
        for length in [0, 1, 15, 16, 17, 47, 48, 49] {
            let plain = Data((0 ..< length).map { UInt8($0 & 0xFF) })
            let (sealed, descriptor) = try ChunkedAssetCipher.encrypt(plain, assetID: assetID, key: key, chunkSize: 16)
            XCTAssertEqual(Int64(sealed.count), ChunkedAssetCipher.sealedLength(forPlaintext: Int64(length), chunkSize: 16))
            XCTAssertEqual(descriptor.header.chunkCount, UInt32(max(1, (length + 15) / 16)))
            XCTAssertEqual(try ChunkedAssetCipher.decrypt(sealed, descriptor: descriptor), plain, "length \(length)")
        }
    }

    func testTruncationDroppingTheLastChunkFails() throws {
        let (sealed, d) = try ChunkedAssetCipher.encrypt(Data(count: 40), assetID: assetID, key: key, chunkSize: 16)
        XCTAssertThrowsError(try ChunkedAssetCipher.decrypt(sealed.dropLast(32), descriptor: d)) {
            XCTAssertEqual($0 as? AssetCipherError, .truncated)
        }
    }

    func testSwappedChunksFailAuthentication() throws {
        let (sealed, d) = try ChunkedAssetCipher.encrypt(Data((0 ..< 48).map { UInt8($0) }), assetID: assetID, key: key, chunkSize: 16)
        let c = 32
        var swapped = Data(sealed[c ..< 2 * c])
        swapped.append(sealed[0 ..< c])
        swapped.append(sealed.suffix(from: 2 * c))
        XCTAssertThrowsError(try ChunkedAssetCipher.decrypt(swapped, descriptor: d)) {
            XCTAssertEqual($0 as? AssetCipherError, .chunkAuthenticationFailed(0))
        }
    }

    func testAFileOfAnotherAssetFailsBecauseTheHeaderIsInTheAAD() throws {
        let (sealed, _) = try ChunkedAssetCipher.encrypt(Data(count: 20), assetID: assetID, key: key, chunkSize: 16)
        let (_, other) = try ChunkedAssetCipher.encrypt(Data(count: 20), assetID: UUID(), key: key, chunkSize: 16)
        XCTAssertThrowsError(try ChunkedAssetCipher.decrypt(sealed, descriptor: other)) {
            XCTAssertEqual($0 as? AssetCipherError, .chunkAuthenticationFailed(0))
        }
    }

    func testTheSealedFileCarriesNoPlaintextHeader() throws {
        let (sealed, d) = try ChunkedAssetCipher.encrypt(Data(count: 20), assetID: assetID, key: key, chunkSize: 16)
        XCTAssertEqual(sealed.count, 2 * 32)
        XCTAssertNil(sealed.range(of: WireBytes.bytes(of: assetID)))
        XCTAssertNil(sealed.range(of: d.header.encoded().prefix(3)))
    }

    func testZeroChunkSizeIsRefused() {
        XCTAssertThrowsError(try ChunkedAssetCipher.encrypt(Data(count: 4), assetID: assetID, key: key, chunkSize: 0)) {
            XCTAssertEqual($0 as? AssetCipherError, .badHeader)
        }
        XCTAssertEqual(ChunkedAssetCipher.sealedLength(forPlaintext: 10, chunkSize: 0), 0)
    }

    func testAHeaderWhoseChunkCountOverflowsU32IsRefused() {
        XCTAssertThrowsError(try AssetHeader(assetID: assetID, chunkSize: 1, totalLength: 1 << 33)) {
            XCTAssertEqual($0 as? AssetCipherError, .badHeader)
        }
    }

    func testAppendedBytesAreRefused() throws {
        let (sealed, d) = try ChunkedAssetCipher.encrypt(Data(count: 20), assetID: assetID, key: key, chunkSize: 16)
        XCTAssertThrowsError(try ChunkedAssetCipher.decrypt(sealed + Data([0]), descriptor: d)) {
            XCTAssertEqual($0 as? AssetCipherError, .oversized)
        }
    }

    func testTheProductionChunkSizeAllowsTwentyMiBInTheReplicaCap() {
        XCTAssertEqual(ChunkedAssetCipher.sealedLength(forPlaintext: 20 * 1_048_576), 20 * 1_048_576 + 20 * 16)
    }

    func testDescriptorAndHeaderEncodingRoundTripAndRefuseBadInput() throws {
        let (_, d) = try ChunkedAssetCipher.encrypt(Data(count: 20), assetID: assetID, key: key, chunkSize: 16)
        XCTAssertEqual(d.encoded().count, AssetDescriptor.encodedLength)
        XCTAssertEqual(d.header.encoded().count, AssetHeader.encodedLength)
        XCTAssertEqual(try AssetDescriptor.parse(d.encoded()), d)
        XCTAssertThrowsError(try AssetDescriptor.parse(d.encoded().dropLast()))
        var badMagic = d.header.encoded()
        badMagic[0] = 0x00
        XCTAssertThrowsError(try AssetHeader.parse(badMagic)) { XCTAssertEqual($0 as? AssetCipherError, .badHeader) }
        var badSuite = d.header.encoded()
        badSuite[4] = 2
        XCTAssertThrowsError(try AssetHeader.parse(badSuite)) { XCTAssertEqual($0 as? AssetCipherError, .badHeader) }
        var zeroChunk = d.header.encoded()
        zeroChunk.replaceSubrange(21 ..< 25, with: [0, 0, 0, 0])
        XCTAssertThrowsError(try AssetHeader.parse(zeroChunk)) { XCTAssertEqual($0 as? AssetCipherError, .badHeader) }
    }

    func testAWrongDigestIsRefused() throws {
        let (sealed, d) = try ChunkedAssetCipher.encrypt(Data(count: 20), assetID: assetID, key: key, chunkSize: 16)
        let wrong = AssetDescriptor(key: d.key, header: d.header, plaintextDigest: Data(count: 32))
        XCTAssertThrowsError(try ChunkedAssetCipher.decrypt(sealed, descriptor: wrong)) {
            XCTAssertEqual($0 as? AssetCipherError, .digestMismatch)
        }
    }

    func testVectorsMatchTheFrozenFile() throws {
        try E2EFixtures.check(AssetVectors(key: key, assetID: assetID), file: "asset")
    }

    /// The decrypted plaintext (and the sealed file) is owner-only: the temp file is created 0600 before a byte is
    /// written, and the move into place keeps the mode.
    func testFileOutputsAreOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratch = dir
        let input = dir.appendingPathComponent("in.bin")
        let sealedURL = dir.appendingPathComponent("in.sealed")
        let output = dir.appendingPathComponent("out.bin")
        try Data(repeating: 7, count: 40).write(to: input)

        let descriptor = try ChunkedAssetCipher.encryptFile(at: input, to: sealedURL, assetID: assetID, key: key, chunkSize: 16)
        try ChunkedAssetCipher.decryptFile(at: sealedURL, to: output, descriptor: descriptor)

        for url in [sealedURL, output] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600, url.lastPathComponent)
        }
    }

    func testFileStreamingMatchesInMemoryAndLeavesNoTempFileOnFailure() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratch = dir
        let input = dir.appendingPathComponent("in.bin")
        let sealedURL = dir.appendingPathComponent("in.sealed")
        let output = dir.appendingPathComponent("out.bin")
        let plain = Data((0 ..< 56).map { UInt8($0 & 0xFF) })
        try plain.write(to: input)

        let descriptor = try ChunkedAssetCipher.encryptFile(at: input, to: sealedURL, assetID: assetID, key: key, chunkSize: 16)
        let inMemory = try ChunkedAssetCipher.encrypt(plain, assetID: assetID, key: key, chunkSize: 16)
        XCTAssertEqual(try Data(contentsOf: sealedURL), inMemory.sealed)
        XCTAssertEqual(descriptor, inMemory.descriptor)

        try ChunkedAssetCipher.decryptFile(at: sealedURL, to: output, descriptor: descriptor)
        XCTAssertEqual(try Data(contentsOf: output), plain)
        try FileManager.default.removeItem(at: output)

        var bytes = try Data(contentsOf: sealedURL)
        bytes[5] ^= 0x01
        try bytes.write(to: sealedURL)
        XCTAssertThrowsError(try ChunkedAssetCipher.decryptFile(at: sealedURL, to: output, descriptor: descriptor)) {
            XCTAssertEqual($0 as? AssetCipherError, .chunkAuthenticationFailed(0))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(names, ["in.bin", "in.sealed"])
    }

    func testEncryptFileOfAMissingSourceThrowsAndLeavesNothing() throws {
        let dir = try makeScratch()
        let missing = dir.appendingPathComponent("absent.bin")
        XCTAssertThrowsError(try ChunkedAssetCipher.encryptFile(at: missing, to: dir.appendingPathComponent("o"), key: key))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testASourceThatShrankWhileSealingFailsAndLeavesNoTempFile() throws {
        let dir = try makeScratch()
        let input = dir.appendingPathComponent("in.bin")
        try Data(count: 40).write(to: input)
        // The header promised 56 bytes; the file now holds 40.
        XCTAssertThrowsError(try ChunkedAssetCipher.encryptFile(
            at: input, to: dir.appendingPathComponent("o"), declaredLength: 56,
            assetID: assetID, key: key, chunkSize: 16)) {
            XCTAssertEqual($0 as? AssetCipherError, .truncated)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["in.bin"])
    }

    func testASourceThatGrewWhileSealingFailsAndLeavesNoTempFile() throws {
        let dir = try makeScratch()
        let input = dir.appendingPathComponent("in.bin")
        try Data(count: 40).write(to: input)
        XCTAssertThrowsError(try ChunkedAssetCipher.encryptFile(
            at: input, to: dir.appendingPathComponent("o"), declaredLength: 32,
            assetID: assetID, key: key, chunkSize: 16)) {
            XCTAssertEqual($0 as? AssetCipherError, .sourceChanged)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["in.bin"])
    }

    func testAWrongDigestThroughDecryptFileLeavesNoDestination() throws {
        let dir = try makeScratch()
        let (sealed, d) = try ChunkedAssetCipher.encrypt(Data(count: 20), assetID: assetID, key: key, chunkSize: 16)
        let wrong = AssetDescriptor(key: d.key, header: d.header, plaintextDigest: Data(count: 32))
        let src = dir.appendingPathComponent("s.bin")
        try sealed.write(to: src)
        XCTAssertThrowsError(try ChunkedAssetCipher.decryptFile(at: src, to: dir.appendingPathComponent("o"), descriptor: wrong)) {
            XCTAssertEqual($0 as? AssetCipherError, .digestMismatch)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["s.bin"])
    }

    private func makeScratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratch = dir
        return dir
    }
}

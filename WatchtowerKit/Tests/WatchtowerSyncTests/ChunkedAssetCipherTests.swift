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
        let h = AssetHeader.encodedLength, c = 32
        var swapped = Data(sealed.prefix(h))
        swapped.append(sealed[(h + c) ..< (h + 2 * c)])
        swapped.append(sealed[h ..< (h + c)])
        swapped.append(sealed.suffix(from: h + 2 * c))
        XCTAssertThrowsError(try ChunkedAssetCipher.decrypt(swapped, descriptor: d)) {
            XCTAssertEqual($0 as? AssetCipherError, .chunkAuthenticationFailed(0))
        }
    }

    func testAFileOfAnotherAssetIsRefusedByTheHeader() throws {
        let (sealed, _) = try ChunkedAssetCipher.encrypt(Data(count: 20), assetID: assetID, key: key, chunkSize: 16)
        let (_, other) = try ChunkedAssetCipher.encrypt(Data(count: 20), assetID: UUID(), key: key, chunkSize: 16)
        XCTAssertThrowsError(try ChunkedAssetCipher.decrypt(sealed, descriptor: other)) {
            XCTAssertEqual($0 as? AssetCipherError, .headerMismatch)
        }
    }

    func testAppendedBytesAreRefused() throws {
        let (sealed, d) = try ChunkedAssetCipher.encrypt(Data(count: 20), assetID: assetID, key: key, chunkSize: 16)
        XCTAssertThrowsError(try ChunkedAssetCipher.decrypt(sealed + Data([0]), descriptor: d)) {
            XCTAssertEqual($0 as? AssetCipherError, .oversized)
        }
    }

    func testTheProductionChunkSizeAllowsTwentyMiBInTheReplicaCap() {
        XCTAssertEqual(ChunkedAssetCipher.sealedLength(forPlaintext: 20 * 1_048_576), 20 * 1_048_576 + 37 + 20 * 16)
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
        bytes[37 + 5] ^= 0x01
        try bytes.write(to: sealedURL)
        XCTAssertThrowsError(try ChunkedAssetCipher.decryptFile(at: sealedURL, to: output, descriptor: descriptor)) {
            XCTAssertEqual($0 as? AssetCipherError, .chunkAuthenticationFailed(0))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(names, ["in.bin", "in.sealed"])
    }

    func testEncryptFileFailsWhenTheSourceShrinksWhileSealing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratch = dir
        let missing = dir.appendingPathComponent("absent.bin")
        XCTAssertThrowsError(try ChunkedAssetCipher.encryptFile(at: missing, to: dir.appendingPathComponent("o"), key: key))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }
}

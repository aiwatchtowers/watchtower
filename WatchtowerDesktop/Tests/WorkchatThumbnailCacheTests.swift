import AppKit
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// The Workchat's pasted-image thumbnails (`WorkchatThumbnailCache`): a file gone is missing before any cached image is
/// used, a decoded one is kept by path and modification time, one that does not decode is not kept.
@MainActor
final class WorkchatThumbnailCacheTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt-thumbs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        try super.tearDownWithError()
    }

    private func png(width: Int = 8, height: Int = 6) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    private func file(_ name: String, _ data: Data) throws -> String {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url.path
    }

    func testMissingFileIsMissing() async {
        let path = folder.appendingPathComponent("gone.png").path
        guard case .missing? = WorkchatThumbnailCache.cached(path) else { return XCTFail("starts missing") }
        guard case .missing = await WorkchatThumbnailCache.load(path) else { return XCTFail("loads missing") }
    }

    func testUndecodableFileIsNotKept() async throws {
        let path = try file("junk.png", Data("not an image".utf8))
        guard case .undecodable = await WorkchatThumbnailCache.load(path) else { return XCTFail("undecodable") }
        XCTAssertNil(WorkchatThumbnailCache.cached(path), "not cached: tried again next time")
    }

    func testValidFileIsKept() async throws {
        let path = try file("shot.png", try png())
        guard case .image(let image) = await WorkchatThumbnailCache.load(path) else { return XCTFail("decoded") }
        XCTAssertEqual(image.width, 8, "a small image is never enlarged")
        guard case .image? = WorkchatThumbnailCache.cached(path) else { return XCTFail("kept") }
    }

    func testCachedThenDeletedIsMissing() async throws {
        let path = try file("swept.png", try png())
        guard case .image = await WorkchatThumbnailCache.load(path) else { return XCTFail("decoded") }
        try FileManager.default.removeItem(atPath: path)
        guard case .missing? = WorkchatThumbnailCache.cached(path) else { return XCTFail("gone before the cache") }
        guard case .missing = await WorkchatThumbnailCache.load(path) else { return XCTFail("loads missing") }
    }

    func testRewrittenFileIsDecodedAgain() async throws {
        let path = try file("again.png", try png())
        guard case .image = await WorkchatThumbnailCache.load(path) else { return XCTFail("decoded") }
        try png(width: 4, height: 4).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: path)
        XCTAssertNil(WorkchatThumbnailCache.cached(path), "another modification time: not the old decode")
        guard case .image(let image) = await WorkchatThumbnailCache.load(path) else { return XCTFail("decoded") }
        XCTAssertEqual(image.width, 4)
    }
}

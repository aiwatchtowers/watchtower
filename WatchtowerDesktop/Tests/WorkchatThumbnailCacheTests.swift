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

    /// `path` as a paste in the attachments folder `folder`.
    private func paste(_ path: String) -> WorkchatOwnerImages.ImageFile {
        .init(path: path, attachmentsRoot: folder.path)
    }

    func testMissingFileIsMissing() async {
        let path = folder.appendingPathComponent("gone.png").path
        guard case .missing? = WorkchatThumbnailCache.cached(paste(path)) else { return XCTFail("starts missing") }
        guard case .missing = await WorkchatThumbnailCache.load(paste(path)) else { return XCTFail("loads missing") }
    }

    func testUndecodableFileIsNotKept() async throws {
        let path = try file("junk.png", Data("not an image".utf8))
        guard case .undecodable = await WorkchatThumbnailCache.load(paste(path)) else { return XCTFail("undecodable") }
        XCTAssertNil(WorkchatThumbnailCache.cached(paste(path)), "not cached: tried again next time")
    }

    func testValidFileIsKept() async throws {
        let path = try file("shot.png", try png())
        guard case .image(let image) = await WorkchatThumbnailCache.load(paste(path)) else { return XCTFail("decoded") }
        XCTAssertEqual(image.width, 8, "a small image is never enlarged")
        guard case .image? = WorkchatThumbnailCache.cached(paste(path)) else { return XCTFail("kept") }
    }

    func testCachedThenDeletedIsMissing() async throws {
        let path = try file("swept.png", try png())
        guard case .image = await WorkchatThumbnailCache.load(paste(path)) else { return XCTFail("decoded") }
        try FileManager.default.removeItem(atPath: path)
        guard case .missing? = WorkchatThumbnailCache.cached(paste(path)) else { return XCTFail("gone before the cache") }
        guard case .missing = await WorkchatThumbnailCache.load(paste(path)) else { return XCTFail("loads missing") }
    }

    /// A symlink in the attachments folder to a file elsewhere (a file or a folder) is never followed: the image is
    /// not decoded, so a protected folder's file is never read through it.
    func testSymlinkOutOfTheFolderIsNotRead() async throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("wt-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let target = outside.appendingPathComponent("private.png")
        try png().write(to: target)
        let link = folder.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("7"), withDestinationURL: outside)
        for path in [link.path, folder.appendingPathComponent("7/private.png").path] {
            XCTAssertNil(WorkchatThumbnailCache.file(of: paste(path)), path)
            guard case .undecodable? = WorkchatThumbnailCache.cached(paste(path)) else { return XCTFail(path) }
            guard case .undecodable = await WorkchatThumbnailCache.load(paste(path)) else { return XCTFail(path) }
        }
    }

    /// The attachments folder's own path may go through a symlink (a temporary folder under `/var`): a file in it is
    /// still read.
    func testSymlinkedFolderStillReads() async throws {
        let alias = FileManager.default.temporaryDirectory.appendingPathComponent("wt-alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        defer { try? FileManager.default.removeItem(at: alias) }
        _ = try file("shot.png", try png())
        let image = WorkchatOwnerImages.ImageFile(path: alias.path + "/shot.png", attachmentsRoot: alias.path)
        guard case .image = await WorkchatThumbnailCache.load(image) else { return XCTFail("decoded") }
    }

    func testImageOutsideTheFolderIsNotRead() async throws {
        let path = try file("shot.png", try png())
        let chip = WorkchatOwnerImages.ImageFile(path: path, attachmentsRoot: nil)
        XCTAssertNil(WorkchatThumbnailCache.file(of: chip))
        guard case .undecodable = await WorkchatThumbnailCache.load(chip) else { return XCTFail("not read") }
    }

    /// A thumbnail is drawn at its own point size on this screen, never enlarged, at most `Thumbnail.maxSide`.
    func testDrawnSize() {
        let size = WorkchatImageThumbnail.drawnSize
        XCTAssertEqual(size(CGSize(width: 100, height: 40), 2), CGSize(width: 50, height: 20), "a small Retina shot")
        XCTAssertEqual(size(CGSize(width: 100, height: 40), 1), CGSize(width: 100, height: 40))
        XCTAssertEqual(size(CGSize(width: 440, height: 275), 2), CGSize(width: 220, height: 137.5), "the decode's cap")
        XCTAssertEqual(size(CGSize(width: 440, height: 880), 1), CGSize(width: 110, height: 220), "shrunk to fit")
        XCTAssertEqual(size(.zero, 2), .zero)
    }

    func testRewrittenFileIsDecodedAgain() async throws {
        let path = try file("again.png", try png())
        guard case .image = await WorkchatThumbnailCache.load(paste(path)) else { return XCTFail("decoded") }
        try png(width: 4, height: 4).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: path)
        XCTAssertNil(WorkchatThumbnailCache.cached(paste(path)), "another modification time: not the old decode")
        guard case .image(let image) = await WorkchatThumbnailCache.load(paste(path)) else { return XCTFail("decoded") }
        XCTAssertEqual(image.width, 4)
    }
}

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import WatchtowerCore

final class ProjectImageLoaderTests: XCTestCase {
    private func writePNG(width: Int, height: Int) throws -> URL {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-image-\(UUID().uuidString).png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testThumbnailIsDownscaledAndFullImageKeepsItsSize() throws {
        let url = try writePNG(width: 400, height: 200)
        let thumb = try XCTUnwrap(ProjectImageLoader.thumbnail(at: url, maxPixel: 100))
        XCTAssertEqual(max(thumb.width, thumb.height), 100)
        let full = try XCTUnwrap(ProjectImageLoader.fullImage(at: url))
        XCTAssertEqual(full.width, 400)
        XCTAssertEqual(full.height, 200)
    }

    func testMissingOrUndecodableFileYieldsNil() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString).png")
        XCTAssertNil(ProjectImageLoader.thumbnail(at: missing, maxPixel: 100))
        XCTAssertNil(ProjectImageLoader.fullImage(at: missing))
        let text = FileManager.default.temporaryDirectory.appendingPathComponent("text-\(UUID().uuidString).png")
        try Data("not an image".utf8).write(to: text)
        addTeardownBlock { try? FileManager.default.removeItem(at: text) }
        XCTAssertNil(ProjectImageLoader.thumbnail(at: text, maxPixel: 100))
    }
}

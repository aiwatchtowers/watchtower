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

    func testLoadDownscalesAndNeverEnlarges() throws {
        let url = try writePNG(width: 400, height: 200)
        let thumb = try XCTUnwrap(ProjectImageLoader.load(at: url, maxPixel: 100).image)
        XCTAssertEqual(max(thumb.width, thumb.height), 100)
        let full = try XCTUnwrap(ProjectImageLoader.load(at: url, maxPixel: ProjectImageLoader.viewerMaxPixel).image)
        XCTAssertEqual(full.width, 400)
        XCTAssertEqual(full.height, 200)
    }

    func testMissingAndUndecodableAreDifferentStates() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString).png")
        guard case .missing = ProjectImageLoader.load(at: missing, maxPixel: 100) else {
            return XCTFail("a file that is not there is missing")
        }
        let text = FileManager.default.temporaryDirectory.appendingPathComponent("text-\(UUID().uuidString).png")
        try Data("not an image".utf8).write(to: text)
        addTeardownBlock { try? FileManager.default.removeItem(at: text) }
        guard case .undecodable = ProjectImageLoader.load(at: text, maxPixel: 100) else {
            return XCTFail("a file that is there but not an image is undecodable, not missing")
        }
    }
}

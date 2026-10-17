import XCTest
import AppKit
@testable import WatchtowerDesktop
@testable import WatchtowerCore

final class PastedContentTests: XCTestCase {
    private func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("wt-test-\(UUID().uuidString)"))
    }

    private func onePixelImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return image
    }

    /// Random pixels compress badly, so the PNG is large for its size.
    private func noisePNG(side: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try XCTUnwrap(rep.bitmapData)
        for index in 0..<(rep.bytesPerRow * side) { bytes[index] = UInt8.random(in: 0...255) }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testImageOnlyPasteboardYieldsPNGAndAttachImage() throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([onePixelImage()])
        XCTAssertEqual(PastedContent.action(from: pasteboard), .attachImage)
        let png = try XCTUnwrap(PastedContent.pngData(from: pasteboard))
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    func testTIFFOnlyScreenshotConvertsToPNG() throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let tiff = try XCTUnwrap(onePixelImage().tiffRepresentation)
        pasteboard.setData(tiff, forType: .tiff)
        XCTAssertEqual(PastedContent.action(from: pasteboard), .attachImage)
        let png = try XCTUnwrap(PastedContent.pngData(from: pasteboard))
        XCTAssertEqual(try AttachmentValidator.validate(data: png, fileName: PastedContent.imageName).get(),
                       .image(mime: "image/png"))
    }

    func testTextWinsOverImage() {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([onePixelImage()])
        pasteboard.setString("hello", forType: .string)
        XCTAssertEqual(PastedContent.action(from: pasteboard), .insertText(offerAsFile: false))
    }

    func testFinderCopyYieldsFileURLs() {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let urls = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.pdf")]
        pasteboard.writeObjects(urls as [NSURL])
        XCTAssertEqual(PastedContent.action(from: pasteboard), .attachFiles(urls))
    }

    func testWebLinkIsTextNotAFile() {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(string: "https://example.com")! as NSURL])
        pasteboard.setString("https://example.com", forType: .string)
        XCTAssertEqual(PastedContent.action(from: pasteboard), .insertText(offerAsFile: false))
    }

    func testPDFDataAttachesAsPDF() throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let pdf = Data("%PDF-1.4\n%fake\n".utf8)
        pasteboard.setData(pdf, forType: .pdf)
        XCTAssertEqual(PastedContent.action(from: pasteboard), .attachPDF)
        XCTAssertEqual(PastedContent.pdfData(from: pasteboard), pdf)
    }

    func testOversizedImageIsDownscaledUnderTheLimit() throws {
        let png = try noisePNG(side: 200)
        let limit = png.count / 4
        let fitted = PastedContent.downscaled(png, toFit: limit)
        XCTAssertLessThanOrEqual(fitted.count, limit)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: fitted))
        XCTAssertLessThan(rep.pixelsWide, 200)
        XCTAssertEqual(PastedContent.downscaled(png, toFit: png.count), png, "within the limit: untouched")
    }
}

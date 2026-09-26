import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import OCRKit

final class OCRRecognizerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: fixtures (rendered in memory with CoreText, no fixture files)

    private static let phrase = "Hello Watchtower 42"

    private func renderImage(_ text: String = phrase) throws -> CGImage {
        let width = 1200, height = 300
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 96, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.textPosition = CGPoint(x: 40, y: 110)
        CTLineDraw(line, ctx)
        return try XCTUnwrap(ctx.makeImage())
    }

    /// One PDF page per image, each page the image's size, drawn with
    /// CoreGraphics' PDF context — a scan, no text layer.
    private func writePDF(_ images: [CGImage], name: String = "scan.pdf") throws -> URL {
        let url = dir.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 1200, height: 300)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for image in images {
            ctx.beginPDFPage(nil)
            ctx.draw(image, in: box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    private func writePNG(_ image: CGImage, name: String = "shot.png") throws -> URL {
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func assertPhrase(_ text: String?, file: StaticString = #filePath, line: UInt = #line) {
        let got = text ?? ""
        XCTAssertTrue(got.contains("Watchtower"), "got \(got)", file: file, line: line)
        XCTAssertTrue(got.contains("42"), "got \(got)", file: file, line: line)
    }

    // MARK: recognizer

    func testRecognizesRenderedImage() throws {
        assertPhrase(try OCRRecognizer.recognize(image: try renderImage()))
    }

    /// Vision throws on a 2x2 image; a tiny image is "no text", not an OCR
    /// failure (which the Go side would retry three times).
    func testTinyImageIsEmptyNotAnError() throws {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        XCTAssertEqual(try OCRRecognizer.recognize(image: try XCTUnwrap(ctx.makeImage())), "")
    }

    func testRecognizerSettingsArePinned() {
        XCTAssertEqual(OCRRecognizer.languages, ["ru-RU", "uk-UA", "en-US"])
        XCTAssertEqual(OCRRecognizer.maxPages, 50)
    }

    func testRecognizesPDFPage() throws {
        let url = try writePDF([try renderImage()])
        let got = try OCRRecognizer.recognize(pdfURL: url, pages: [0])
        XCTAssertEqual(Array(got.keys), [0])
        assertPhrase(got[0])
    }

    func testPDFPagesOutOfRangeAreSkipped() throws {
        let url = try writePDF([try renderImage()])
        let got = try OCRRecognizer.recognize(pdfURL: url, pages: [3, -1])
        XCTAssertTrue(got.isEmpty)
    }

    func testPDFPageListIsCappedAtMaxPages() {
        let many = Array(0..<120)
        XCTAssertEqual(OCRRecognizer.cappedPages(many, pageCount: 200), Array(0..<50))
        XCTAssertEqual(OCRRecognizer.cappedPages(nil, pageCount: 3), [0, 1, 2])
        XCTAssertEqual(OCRRecognizer.cappedPages([2, 2, 9, 0], pageCount: 3), [2, 0])
    }

    /// A crafted media box must not turn into a multi-gigabyte bitmap.
    func testRenderScaleIsBounded() {
        XCTAssertEqual(OCRRecognizer.renderScale(for: CGSize(width: 600, height: 800)), 2)
        let huge = OCRRecognizer.renderScale(for: CGSize(width: 14400, height: 14400))
        XCTAssertLessThanOrEqual(14400 * huge, CGFloat(OCRRecognizer.maxRenderPixels) + 0.5)
    }

    // MARK: file entry point (what main.swift runs)

    func testRunOnPNGIgnoresPages() throws {
        let url = try writePNG(try renderImage())
        let pages = try OCRRecognizer.run(path: url.path, pages: [5, 7])
        XCTAssertEqual(pages.map(\.index), [0])
        assertPhrase(pages.first?.text)
    }

    func testRunOnPDFSniffsTheHeaderNotTheExtension() throws {
        let url = try writePDF([try renderImage()], name: "att-123")
        let pages = try OCRRecognizer.run(path: url.path, pages: nil)
        XCTAssertEqual(pages.map(\.index), [0])
        assertPhrase(pages.first?.text)
    }

    func testRunOnUnreadableFileThrows() throws {
        let url = dir.appendingPathComponent("garbage.bin")
        try Data("not an image, not a pdf".utf8).write(to: url)
        XCTAssertThrowsError(try OCRRecognizer.run(path: url.path, pages: nil))
        XCTAssertThrowsError(try OCRRecognizer.run(path: dir.appendingPathComponent("missing").path, pages: nil))
    }

    func testOutputJSONShape() throws {
        let data = try OCRRecognizer.encode([OCRPage(index: 0, text: "a\"b")])
        XCTAssertEqual(String(bytes: data, encoding: .utf8), #"{"pages":[{"index":0,"text":"a\"b"}]}"#)
    }

    // MARK: argument parsing

    func testParseArguments() throws {
        XCTAssertEqual(try HelperArguments.parse(["x.png"]), HelperArguments(path: "x.png", pages: nil))
        XCTAssertEqual(try HelperArguments.parse(["x.pdf", "--pages", "0,2,5"]),
                       HelperArguments(path: "x.pdf", pages: [0, 2, 5]))
        XCTAssertThrowsError(try HelperArguments.parse([]))
        XCTAssertThrowsError(try HelperArguments.parse(["x.pdf", "--pages"]))
        XCTAssertThrowsError(try HelperArguments.parse(["x.pdf", "--pages", "1,a"]))
        XCTAssertThrowsError(try HelperArguments.parse(["x.pdf", "--pages", "-1"]))
        XCTAssertThrowsError(try HelperArguments.parse(["x.pdf", "extra"]))
    }

    // MARK: self deadline (an orphan must not outlive its parent's timeout)

    func testSelfDeadlineIsTimeoutPlusMargin() {
        XCTAssertEqual(SelfDeadline.seconds, 70)
    }

    func testSelfDeadlineFires() {
        let fired = expectation(description: "deadline fired")
        SelfDeadline.arm(after: 0.05) { code in
            XCTAssertEqual(code, 2)
            fired.fulfill()
        }
        wait(for: [fired], timeout: 5)
    }
}

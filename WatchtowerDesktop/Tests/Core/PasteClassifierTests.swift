import XCTest
@testable import WatchtowerCore

final class PasteClassifierTests: XCTestCase {
    private let png = "public.png"
    private let tiff = "public.tiff"
    private let pdf = "com.adobe.pdf"
    private let string = "public.utf8-plain-text"
    private let fileURL = "public.file-url"

    func testPlainTextInsertsAsBefore() {
        XCTAssertEqual(PasteClassifier.classify(types: [string], fileURLs: [], text: "hello"),
                       .insertText(offerAsFile: false))
    }

    func testFinderCopyAttachesEveryFileIgnoringNamesAndIcon() {
        let urls = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b dir")]
        XCTAssertEqual(PasteClassifier.classify(types: [fileURL, string, tiff], fileURLs: urls, text: "a.png\rb dir"),
                       .attachFiles(urls))
    }

    func testScreenshotPNGOrTIFFAttachesImage() {
        XCTAssertEqual(PasteClassifier.classify(types: [png], fileURLs: [], text: nil), .attachImage)
        XCTAssertEqual(PasteClassifier.classify(types: [tiff], fileURLs: [], text: nil), .attachImage)
        XCTAssertEqual(PasteClassifier.classify(types: ["public.jpeg"], fileURLs: [], text: nil), .attachImage)
    }

    func testTextWithImageKeepsTheText() {
        // A rich copy (a document, Slack, a spreadsheet) carries a picture of the same selection.
        XCTAssertEqual(PasteClassifier.classify(types: [string, tiff, pdf], fileURLs: [], text: "Q3 numbers"),
                       .insertText(offerAsFile: false))
    }

    func testCopyImageWithItsLinkAttachesTheImage() {
        XCTAssertEqual(PasteClassifier.classify(types: [string, tiff], fileURLs: [],
                                                text: "https://example.com/pic.png"), .attachImage)
        XCTAssertEqual(PasteClassifier.classify(types: [string, png], fileURLs: [], text: "  \n"), .attachImage)
    }

    func testALinkAloneStaysText() {
        XCTAssertEqual(PasteClassifier.classify(types: [string], fileURLs: [], text: "https://example.com"),
                       .insertText(offerAsFile: false))
    }

    func testPDFOnlyAttachesPDF() {
        XCTAssertEqual(PasteClassifier.classify(types: [pdf], fileURLs: [], text: nil), .attachPDF)
    }

    func testImageBeatsPDFRenderingOfTheSameSelection() {
        XCTAssertEqual(PasteClassifier.classify(types: [pdf, tiff], fileURLs: [], text: nil), .attachImage)
    }

    func testNothingUsableFallsBackToTheNormalPaste() {
        XCTAssertEqual(PasteClassifier.classify(types: ["public.rtf"], fileURLs: [], text: nil),
                       .insertText(offerAsFile: false))
    }

    func testLongTextGetsTheOffer() {
        let long = String(repeating: "a", count: PasteClassifier.longTextThreshold)
        XCTAssertEqual(PasteClassifier.classify(types: [string], fileURLs: [], text: long),
                       .insertText(offerAsFile: true))
        let short = String(repeating: "a", count: PasteClassifier.longTextThreshold - 1)
        XCTAssertEqual(PasteClassifier.classify(types: [string], fileURLs: [], text: short),
                       .insertText(offerAsFile: false))
    }

    func testTextOverTheAttachmentLimitGetsNoOffer() {
        let huge = String(repeating: "a", count: Int(AttachmentValidator.textLimit) + 1)
        XCTAssertEqual(PasteClassifier.classify(types: [string], fileURLs: [], text: huge),
                       .insertText(offerAsFile: false))
    }

    func testALinkBesideAPDFPastesAsTheLink() {
        XCTAssertEqual(PasteClassifier.classify(types: [string, pdf], fileURLs: [],
                                                text: "https://example.com/doc"), .insertText(offerAsFile: false))
    }

    func testAnyImageTypeCounts() {
        XCTAssertEqual(PasteClassifier.classify(types: ["com.microsoft.bmp"], fileURLs: [], text: nil), .attachImage)
        XCTAssertEqual(PasteClassifier.classify(types: ["public.jpeg-2000"], fileURLs: [], text: nil), .attachImage)
        XCTAssertFalse(PasteClassifier.isImageType(pdf))
        XCTAssertFalse(PasteClassifier.isImageType(string))
    }
}

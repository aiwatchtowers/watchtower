import XCTest
import AppKit
@testable import WatchtowerDesktop

final class PastedImageTests: XCTestCase {
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

    func testImageOnlyPasteboardYieldsPNG() throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([onePixelImage()])
        let png = try XCTUnwrap(PastedImage.pngData(from: pasteboard))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testTextWinsOverImage() {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([onePixelImage()])
        pasteboard.setString("hello", forType: .string)
        XCTAssertNil(PastedImage.pngData(from: pasteboard))
    }
}

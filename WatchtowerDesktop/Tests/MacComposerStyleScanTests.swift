import XCTest

/// Every Mac surface that draws ChatUI's composer gives it the Mac's look and dictation (`.macComposerStyle()`):
/// without it the field silently draws the phone's look and has no mic (#1822 T13 review m8).
final class MacComposerStyleScanTests: XCTestCase {
    func testEveryMacComposerCarriesTheMacStyle() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var composers: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            guard ["ChatComposerField(", "ChatComposerBar(", "ChatComposerView("].contains(where: text.contains) else { continue }
            composers.append(url.lastPathComponent)
            XCTAssertTrue(text.contains(".macComposerStyle()"), "\(url.lastPathComponent) draws a composer without .macComposerStyle()")
        }
        XCTAssertGreaterThanOrEqual(composers.count, 6, "the scan found the Mac's composers: \(composers)")
    }
}

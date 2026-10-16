import Foundation
import XCTest

/// The bundled Monaco page's protocol (the header comment of
/// `CodeEditorWeb/index.html`) and its script (`CodeEditorWeb/editor.js`)
/// stay in step: a message the Swift side may call is documented and handled.
final class CodeEditorPageProtocolTests: XCTestCase {
    func testSetReadOnlyIsDocumentedAndHandled() throws {
        let header = try Self.headerComment()
        XCTAssertTrue(header.contains("setReadOnly(bool)"), "index.html's header does not document setReadOnly")
        let script = try String(contentsOf: Self.web.appendingPathComponent("editor.js"), encoding: .utf8)
        XCTAssertNotNil(
            script.range(of: #"setReadOnly:\s*function"#, options: .regularExpression),
            "editor.js's window.wt does not define setReadOnly"
        )
        XCTAssertTrue(script.contains("window.wt = {"), "editor.js no longer defines window.wt")
    }

    private static let web = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Core
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerDesktop
        .appendingPathComponent("Sources/CodeEditorWeb")

    /// The page's leading `<!-- … -->` comment, where the protocol lives.
    private static func headerComment() throws -> String {
        let html = try String(contentsOf: web.appendingPathComponent("index.html"), encoding: .utf8)
        let start = try XCTUnwrap(html.range(of: "<!--"), "index.html has no header comment")
        let end = try XCTUnwrap(html.range(of: "-->", range: start.upperBound..<html.endIndex))
        return String(html[start.upperBound..<end.lowerBound])
    }
}

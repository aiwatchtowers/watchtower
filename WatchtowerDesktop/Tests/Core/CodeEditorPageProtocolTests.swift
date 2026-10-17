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

    /// textmate.js loads only grammars scripts/fetch-textmate.sh vendors,
    /// and every vendored grammar is one textmate.js names (board #738).
    func testTextMateGrammarsMatchTheFetchScript() throws {
        let script = try String(contentsOf: Self.web.appendingPathComponent("textmate.js"), encoding: .utf8)
        let named = try Self.table("GRAMMARS", in: script)
        let repo = Self.web
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent()
        let fetch = try String(contentsOf: repo.appendingPathComponent("scripts/fetch-textmate.sh"), encoding: .utf8)
        let list = try XCTUnwrap(fetch.range(of: #"GRAMMARS="([^"]*)""#, options: .regularExpression), "no GRAMMARS list")
        let names = fetch[list].dropFirst("GRAMMARS=\"".count).dropLast()
        let vendored = Set(names.split(whereSeparator: \.isWhitespace).map(String.init))
        XCTAssertEqual(Set(named.keys), vendored)
        // Each language's grammar is one of them.
        let languages = try Self.table("LANGUAGES", in: script)
        for (language, grammar) in languages {
            XCTAssertNotNil(named[grammar], "\(language) names grammar \(grammar), which is not vendored")
        }
    }

    /// The `"key": "value"` pairs of `var <name> = { … };` in a script.
    private static func table(_ name: String, in script: String) throws -> [String: String] {
        let start = try XCTUnwrap(script.range(of: "var \(name) = {"), "no \(name) table")
        let end = try XCTUnwrap(script.range(of: "};", range: start.upperBound..<script.endIndex))
        let body = String(script[start.upperBound..<end.lowerBound])
        let pair = try NSRegularExpression(pattern: #""([^"]+)":\s*"([^"]+)""#)
        var out: [String: String] = [:]
        for match in pair.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let key = Range(match.range(at: 1), in: body),
                  let value = Range(match.range(at: 2), in: body) else { continue }
            out[String(body[key])] = String(body[value])
        }
        XCTAssertFalse(out.isEmpty, "\(name) is empty")
        return out
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

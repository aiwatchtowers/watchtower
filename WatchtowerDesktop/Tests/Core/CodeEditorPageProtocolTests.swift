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

    /// The diff page's Changes | Full file switch (board #959).
    func testDiffSetFullFileIsDocumentedAndHandled() throws {
        let header = try Self.headerComment(page: "diff.html")
        XCTAssertTrue(header.contains("setFullFile(bool)"), "diff.html's header does not document setFullFile")
        let script = try String(contentsOf: Self.web.appendingPathComponent("diff.js"), encoding: .utf8)
        XCTAssertNotNil(
            script.range(of: #"setFullFile:\s*function"#, options: .regularExpression),
            "diff.js's window.wt does not define setFullFile"
        )
    }

    /// The diff page's Ask agent post (board #962): documented, registered
    /// as a Monaco action and decoded by MonacoDiffView.
    func testDiffAskIsDocumentedAndPosted() throws {
        let header = try Self.headerComment(page: "diff.html")
        XCTAssertTrue(header.contains("ask     {startLine, endLine, side}"), "diff.html's header does not document ask")
        let script = try String(contentsOf: Self.web.appendingPathComponent("diff.js"), encoding: .utf8)
        XCTAssertTrue(script.contains(#"id: "wt.ask""#), "diff.js does not register wt.ask")
        XCTAssertTrue(script.contains(#"type: "ask""#), "diff.js does not post ask")
        let swift = try String(
            contentsOf: Self.web.deletingLastPathComponent().appendingPathComponent("Views/Workbench/Review/MonacoDiffView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(swift.contains(#"case "ask":"#), "MonacoDiffView does not handle ask")
    }

    /// Go to definition and Usages from the diff's new side (board #960):
    /// the editor page's messages and calls, documented and handled.
    func testDiffNavigationIsDocumentedAndHandled() throws {
        let header = try Self.headerComment(page: "diff.html")
        for documented in [
            "definitionAtCursor()", "definitionDone(req)", "usagesAtCursor()",
            "definition {req, id, word, line, col, x, y}", "usages {id, word, line, col}"
        ] {
            XCTAssertTrue(header.contains(documented), "diff.html's header does not document \(documented)")
        }
        let script = try String(contentsOf: Self.web.appendingPathComponent("diff.js"), encoding: .utf8)
        for call in ["definitionAtCursor", "definitionDone", "usagesAtCursor"] {
            XCTAssertNotNil(
                script.range(of: #"\#(call):\s*function"#, options: .regularExpression),
                "diff.js's window.wt does not define \(call)"
            )
        }
        XCTAssertTrue(script.contains("wtCodeNav(editor.getModifiedEditor()"), "diff.js does not use codenav.js on the new side")
        let shared = try String(contentsOf: Self.web.appendingPathComponent("codenav.js"), encoding: .utf8)
        for message in [#"type: "definition""#, #"type: "usages""#] {
            XCTAssertTrue(shared.contains(message), "codenav.js never posts \(message)")
        }
    }

    /// One go-to-definition and usages script for both pages: each loads
    /// codenav.js before its own script, which calls it.
    func testBothPagesShareCodeNav() throws {
        for (page, script) in [("index.html", "editor.js"), ("diff.html", "diff.js")] {
            let html = try String(contentsOf: Self.web.appendingPathComponent(page), encoding: .utf8)
            let shared = try XCTUnwrap(html.range(of: #"<script src="codenav.js"></script>"#), "\(page) does not load codenav.js")
            let own = try XCTUnwrap(html.range(of: #"<script src="\#(script)"></script>"#), "\(page) does not load \(script)")
            XCTAssertLessThan(shared.lowerBound, own.lowerBound, "\(page) loads codenav.js after \(script)")
            let code = try String(contentsOf: Self.web.appendingPathComponent(script), encoding: .utf8)
            XCTAssertTrue(code.contains("wtCodeNav("), "\(script) does not call wtCodeNav")
        }
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

    /// A page's leading `<!-- … -->` comment, where the protocol lives.
    private static func headerComment(page: String = "index.html") throws -> String {
        let html = try String(contentsOf: web.appendingPathComponent(page), encoding: .utf8)
        let start = try XCTUnwrap(html.range(of: "<!--"), "\(page) has no header comment")
        let end = try XCTUnwrap(html.range(of: "-->", range: start.upperBound..<html.endIndex))
        return String(html[start.upperBound..<end.lowerBound])
    }
}

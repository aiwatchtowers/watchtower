import Foundation
import XCTest
@testable import WatchtowerDesktop

/// The Files pane's editor page is locked to the bundle: its web view never
/// navigates away from the editor, and the page's CSP allows no inline or
/// remote script, no eval and no network.
final class CodeEditorPageTests: XCTestCase {
    func testOnlyTheEditorPageInTheMainFrameIsAllowed() {
        XCTAssertTrue(CodeEditorSchemeHandler.allowsNavigation(to: CodeEditorSchemeHandler.pageURL, mainFrame: true))
    }

    func testEveryOtherNavigationIsCancelled() {
        let others = [
            "https://example.com/",
            "http://127.0.0.1:8080/index.html",
            "file:///tmp/index.html",
            "wtcode://editor/vs/loader.js",
            "wtcode://other/index.html",
            "about:blank",
            "javascript:alert(1)"
        ]
        for string in others {
            XCTAssertFalse(CodeEditorSchemeHandler.allowsNavigation(to: URL(string: string), mainFrame: true), string)
        }
        XCTAssertFalse(CodeEditorSchemeHandler.allowsNavigation(to: nil, mainFrame: true))
        // A subframe or a new window, even of the editor page itself.
        XCTAssertFalse(CodeEditorSchemeHandler.allowsNavigation(to: CodeEditorSchemeHandler.pageURL, mainFrame: false))
    }

    func testPageDeclaresAStrictContentSecurityPolicy() throws {
        let html = try String(contentsOf: Self.page, encoding: .utf8)
        let policy = try XCTUnwrap(Self.contentSecurityPolicy(in: html), "index.html has no CSP meta")
        let pairs = policy.split(separator: ";").compactMap { part -> (String, String)? in
            let words = part.split(separator: " ").map(String.init)
            guard let name = words.first else { return nil }
            return (name, words.dropFirst().joined(separator: " "))
        }
        let directives = Dictionary(pairs) { first, _ in first }
        XCTAssertEqual(directives["default-src"], "'none'")
        // 'wasm-unsafe-eval' lets the page compile the bundled Oniguruma
        // WebAssembly the TextMate highlighting runs on (board #738); it
        // allows no JavaScript eval.
        XCTAssertEqual(directives["script-src"], "'self' 'wasm-unsafe-eval'")
        XCTAssertEqual(directives["connect-src"], "'none'")
        XCTAssertEqual(directives["base-uri"], "'none'")
        for (name, value) in directives {
            XCTAssertFalse(value.contains("http"), "\(name) allows a remote origin: \(value)")
            XCTAssertFalse(value.contains("'unsafe-eval'"), "\(name) allows eval")
        }
    }

    func testPageHasNoInlineScript() throws {
        let html = try String(contentsOf: Self.page, encoding: .utf8)
        let scriptTag = try NSRegularExpression(pattern: "<script\\b[^>]*>")
        let matches = scriptTag.matches(in: html, range: NSRange(html.startIndex..., in: html))
        let scripts = matches.map { (html as NSString).substring(with: $0.range) }
        XCTAssertFalse(scripts.isEmpty)
        for tag in scripts {
            XCTAssertTrue(tag.contains("src="), "inline script: \(tag)")
        }
        let handlers = try NSRegularExpression(pattern: "<[^>]*\\son[a-z]+\\s*=", options: .caseInsensitive)
        XCTAssertNil(handlers.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), "an inline event handler")
    }

    private static let page = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/CodeEditorWeb/index.html")

    private static func contentSecurityPolicy(in html: String) -> String? {
        let pattern = "<meta\\s+http-equiv=\"Content-Security-Policy\"\\s+content=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }
}

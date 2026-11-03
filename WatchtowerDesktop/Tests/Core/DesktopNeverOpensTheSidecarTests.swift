import Foundation
import XCTest

/// Desktop never opens the hub's sidecar, not even read only (go hub plan 3
/// Global Constraints, Task 24): the Go hub is its one writer and reader, and
/// every Desktop read goes through `watchtower hub … --json` or the control
/// socket. The Swift hub (and its `MobileHub/` directory) is gone, and the
/// hand-over reads the Swift state only through `hub adopt --status --json`
/// (Go derives the Swift directory itself). So no Swift string literal under
/// `WatchtowerDesktop/Sources` names `hubstate.db` or `MobileHub` — with no
/// exception. Type and file names (`AppState+MobileHub.swift`) are not
/// literals and are not matched; neither are comments.
final class DesktopNeverOpensTheSidecarTests: XCTestCase {
    static let forbidden = ["hubstate.db", "MobileHub"]

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Core
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerDesktop
        .appendingPathComponent("Sources")

    func testDesktopNeverOpensTheSidecar() throws {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for literal in Self.stringLiterals(in: text) {
                for word in Self.forbidden where literal.contains(word) {
                    XCTFail("\(url.path.replacingOccurrences(of: Self.sources.path, with: "Sources")): "
                        + "a string literal names \(word): read the hub through `hub … --json` or its socket")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 500, "the scan found too few files: wrong path?")
    }

    /// The scanner finds what it must and skips what it must, so the guard
    /// above cannot pass by finding nothing.
    func testTheScannerSeesLiteralsAndSkipsComments() {
        let source = #"""
            // "hubstate.db" in a comment
            /* "MobileHub" in a block comment */
            let a = "Watchtower/MobileHub"
            let b = #"raw \(x) hubstate.db"#
            let c = """
                multi "line" hubstate.db
                """
            let d = "escaped \" quote" + "plain"
            let e = "interpolated \(f("MobileHub"))"
            """#
        XCTAssertEqual(Self.stringLiterals(in: source), [
            "Watchtower/MobileHub", #"raw \(x) hubstate.db"#, "\n    multi \"line\" hubstate.db\n    ",
            #"escaped \" quote"#, "plain", #"interpolated \(f("MobileHub"))"#
        ])
        XCTAssertEqual(Self.stringLiterals(in: source).filter { lit in Self.forbidden.contains { lit.contains($0) } }.count, 4)
    }

    /// The contents of every string literal in `text` (`"…"`, `"""…"""` and
    /// their raw `#` forms), comments skipped. An interpolation's text stays
    /// inside the literal it belongs to.
    static func stringLiterals(in text: String) -> [String] {
        let chars = Array(text)
        var literals: [String] = []
        var index = 0
        func starts(_ token: String, at position: Int) -> Bool {
            let token = Array(token)
            guard position + token.count <= chars.count else { return false }
            return Array(chars[position..<position + token.count]) == token
        }
        while index < chars.count {
            if starts("//", at: index) {
                while index < chars.count, chars[index] != "\n" { index += 1 }
                continue
            }
            if starts("/*", at: index) {
                var depth = 0
                repeat {
                    if starts("/*", at: index) {
                        depth += 1
                        index += 2
                    } else if starts("*/", at: index) {
                        depth -= 1
                        index += 2
                    } else {
                        index += 1
                    }
                } while depth > 0 && index < chars.count
                continue
            }
            var hashes = 0
            while index + hashes < chars.count, chars[index + hashes] == "#" { hashes += 1 }
            let quote = index + hashes
            guard quote < chars.count, chars[quote] == "\"" else {
                index += max(hashes, 1)
                continue
            }
            let pounds = String(repeating: "#", count: hashes)
            let multiline = starts("\"\"\"", at: quote)
            let open = multiline ? 3 : 1
            let close = (multiline ? "\"\"\"" : "\"") + pounds
            var end = quote + open
            var depth = 0 // open interpolation parentheses
            while end < chars.count {
                if depth == 0, starts(close, at: end) { break }
                if chars[end] == "\\", starts(pounds, at: end + 1) {
                    let after = end + 1 + hashes
                    if after < chars.count, chars[after] == "(" {
                        depth += 1
                        end = after + 1
                        continue
                    }
                    if hashes == 0 {
                        end += 2 // an escape: the next character never closes the literal
                        continue
                    }
                }
                if depth > 0 {
                    if chars[end] == "(" { depth += 1 }
                    if chars[end] == ")" { depth -= 1 }
                }
                end += 1
            }
            literals.append(String(chars[min(quote + open, chars.count)..<min(end, chars.count)]))
            index = end + close.count
        }
        return literals
    }
}

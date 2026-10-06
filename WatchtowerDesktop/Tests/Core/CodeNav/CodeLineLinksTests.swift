import XCTest
@testable import WatchtowerCore

/// `path:line` citations in a code answer (spec 2026-10-02 §9.2) become
/// links that open the file in the Files pane; fenced code is left alone.
final class CodeLineLinksTests: XCTestCase {
    private func url(_ path: String, _ line: Int, _ col: Int? = nil) -> String {
        CodeLineLinks.url(path: path, line: line, col: col)
    }

    func testInlineCodeCitationBecomesALink() {
        XCTAssertEqual(CodeLineLinks.linkified("See `Sources/App.swift:12`."),
                       "See [`Sources/App.swift:12`](\(url("Sources/App.swift", 12))).")
    }

    func testBareCitationBecomesALink() {
        XCTAssertEqual(CodeLineLinks.linkified("Called from main.go:7 and cmd/run.go:40:3, done"),
                       "Called from [main.go:7](\(url("main.go", 7))) and [cmd/run.go:40:3](\(url("cmd/run.go", 40, 3))), done")
    }

    func testFencedCodeIsLeftAlone() {
        let text = "Look:\n```swift\nlet a = \"x.swift:3\"\n```\nthen x.swift:4"
        XCTAssertEqual(CodeLineLinks.linkified(text),
                       "Look:\n```swift\nlet a = \"x.swift:3\"\n```\nthen [x.swift:4](\(url("x.swift", 4)))")
    }

    func testInlineCodeThatIsNotACitationIsLeftAlone() {
        XCTAssertEqual(CodeLineLinks.linkified("Use `a.b:3 + 1` or `load()`"), "Use `a.b:3 + 1` or `load()`")
    }

    /// Hosts with ports, URLs and existing links are not citations.
    func testURLsAndExistingLinksAreNotTouched() {
        let text = "Open https://example.com:8080/x or [App.swift:3](https://example.com) or user@example.com:22"
        XCTAssertEqual(CodeLineLinks.linkified(text), text)
    }

    /// A citation inside an existing link's text — plain or as code — is
    /// not linked again (no link within a link); one after it still is.
    func testACitationInsideAnExistingLinkIsLeftAlone() {
        let text = "See [the loader in main.go:3](https://example.com/x) or [`Sources/App.swift:12`](https://example.com)"
        XCTAssertEqual(CodeLineLinks.linkified(text), text)
        XCTAssertEqual(CodeLineLinks.linkified("[docs](https://example.com) then main.go:3"),
                       "[docs](https://example.com) then [main.go:3](\(url("main.go", 3)))")
        XCTAssertEqual(CodeLineLinks.linkified("![shot of a.swift:2](img.png)"), "![shot of a.swift:2](img.png)")
    }

    /// A link written to a workbench path opens the file: at its line,
    /// or the first one.
    func testALinkToAPathOpensTheFile() {
        XCTAssertEqual(CodeLineLinks.linkified("Read [the plan](docs/plan.md) first"),
                       "Read [the plan](\(url("docs/plan.md", 1))) first")
        XCTAssertEqual(CodeLineLinks.linkified("[run](cmd/run.go:40:3) and [x](a.go#L12-L14)"),
                       "[run](\(url("cmd/run.go", 40, 3))) and [x](\(url("a.go", 12)))")
    }

    /// Images, anchors, absolute paths, paths out of the folder and other
    /// schemes keep their target.
    func testALinkToAnythingElseKeepsItsTarget() {
        for text in ["![shot](img.png)", "[top](#intro)", "[hosts](/etc/hosts)", "[up](../secret.txt)",
                     "[mail](mailto:someone@example.com)", "[site](https://example.com/a.md)", "[name](README)"] {
            XCTAssertEqual(CodeLineLinks.linkified(text), text)
        }
    }

    func testANameWithoutExtensionOrFolderIsNoCitation() {
        XCTAssertEqual(CodeLineLinks.linkified("at line:3 and time 10:30"), "at line:3 and time 10:30")
    }

    func testLinesRangeLinksItsFirstLine() {
        XCTAssertEqual(CodeLineLinks.linkified("`a/b.ts:10-14`"), "[`a/b.ts:10-14`](\(url("a/b.ts", 10)))")
    }

    func testTargetReadsTheLinkBack() throws {
        let link = try XCTUnwrap(URL(string: url("Sources/My App/x.swift", 12, 4)))
        XCTAssertEqual(CodeLineLinks.target(from: link), OpenQuicklyTarget(path: "Sources/My App/x.swift", line: 12, col: 4))
        let noCol = try XCTUnwrap(URL(string: url("x.go", 3)))
        XCTAssertEqual(CodeLineLinks.target(from: noCol), OpenQuicklyTarget(path: "x.go", line: 3, col: nil))
    }

    /// A link never leaves the workbench folder.
    func testTargetRefusesPathsOutsideTheFolder() throws {
        for path in ["../secret.txt", "/etc/hosts", "a/../../b.go", ""] {
            let link = try XCTUnwrap(URL(string: url(path, 1)))
            XCTAssertNil(CodeLineLinks.target(from: link), path)
        }
        XCTAssertNil(CodeLineLinks.target(from: try XCTUnwrap(URL(string: "https://example.com/x.go?line=1"))))
    }
}

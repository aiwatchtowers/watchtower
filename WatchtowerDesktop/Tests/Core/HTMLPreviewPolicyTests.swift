import WebKit
import XCTest
@testable import WatchtowerCore

final class HTMLPreviewPolicyTests: XCTestCase {
    private let page = URL(string: "wtpreview://0a1b/index.html")!

    func testContentRulesBlockEverythingButLocalSchemes() throws {
        for allowFiles in [false, true] {
            let json = HTMLPreviewPolicy.contentRules(allowFiles: allowFiles)
            let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: [String: Any]]])
            XCTAssertEqual(rules.first?["trigger"]?["url-filter"] as? String, ".*")
            XCTAssertEqual(rules.first?["action"]?["type"] as? String, "block")
            let allowed = rules.dropFirst().compactMap { $0["trigger"]?["url-filter"] as? String }
            let cdns = HTMLPreviewPolicy.cdnHosts.map { "^https://" + HTMLPreviewPolicy.regexEscaped($0) + "/" }
            XCTAssertEqual(Set(allowed), Set(["^about:", "^data:", "^blob:"] + (allowFiles ? ["^wtpreview:"] + cdns : [])))
            XCTAssertTrue(rules.dropFirst().allSatisfy { $0["action"]?["type"] as? String == "ignore-previous-rules" })
            XCTAssertFalse(allowed.contains("^https:"), "never any https host (#563)")
            XCTAssertFalse(allowed.contains("^file:"), "never file: — the folder goes through the scheme handler (#563)")
            if allowFiles {
                // The preview's own files never as fetch/XHR (#563).
                let files = try XCTUnwrap(rules.first { $0["trigger"]?["url-filter"] as? String == "^wtpreview:" })
                XCTAssertEqual(files["trigger"]?["resource-type"] as? [String],
                               ["document", "image", "style-sheet", "script", "font", "media", "svg-document"])
                // The allowlisted CDNs only for subresources, never fetch/XHR, sockets, media or documents.
                for cdn in cdns {
                    let rule = try XCTUnwrap(rules.first { $0["trigger"]?["url-filter"] as? String == cdn }, cdn)
                    XCTAssertEqual(rule["trigger"]?["resource-type"] as? [String], ["script", "style-sheet", "font", "image"])
                }
            } else {
                XCTAssertFalse(json.contains("http"), "a chat artifact never gets a network scheme back")
                XCTAssertFalse(json.contains("wtpreview"), "nor a file")
            }
        }
    }

    func testTheCDNAllowlistIsTheOwnersList() {
        XCTAssertEqual(HTMLPreviewPolicy.cdnHosts,
                       ["cdn.jsdelivr.net", "cdnjs.cloudflare.com", "unpkg.com", "fonts.googleapis.com", "fonts.gstatic.com"])
    }

    /// The view fails closed when the rules do not compile: they must.
    @MainActor
    func testContentRulesCompileInWebKit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: folder))
        for allowFiles in [false, true] {
            let list = try await store.compileContentRuleList(
                forIdentifier: "test.\(allowFiles)", encodedContentRuleList: HTMLPreviewPolicy.contentRules(allowFiles: allowFiles)
            )
            XCTAssertNotNil(list)
        }
    }

    // MARK: the preview scheme (#563)

    func testPageURLsEncodeEachSegmentUnderTheFolder() {
        let folder = URL(fileURLWithPath: "/tmp/repo/.claude/worktrees/Презентация deck")
        let url = { (name: String) in
            HTMLPreviewPolicy.pageURL(file: folder.appendingPathComponent(name), folder: folder, token: "0a1b")?.absoluteString
        }
        XCTAssertEqual(url("index.html"), "wtpreview://0a1b/index.html")
        XCTAssertEqual(url("my deck%20#1.html"), "wtpreview://0a1b/my%20deck%2520%231.html")
        XCTAssertEqual(url("sub/a.html"), "wtpreview://0a1b/sub/a.html")
        XCTAssertNil(HTMLPreviewPolicy.pageURL(file: URL(fileURLWithPath: "/etc/hosts"), folder: folder, token: "0a1b"))
    }

    func testPreviewFilesResolveRealPathsAndRefuseHiddenOnes() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString)")
        // The folder itself may sit in a hidden folder (a session worktree).
        let folder = base.appendingPathComponent(".claude/worktrees/Презентация deck")
        defer { try? manager.removeItem(at: base) }
        try manager.createDirectory(at: folder.appendingPathComponent(".secrets"), withIntermediateDirectories: true)
        try manager.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try manager.createDirectory(at: folder.appendingPathComponent("img"), withIntermediateDirectories: true)
        for name in ["index.html", ".env", ".secrets/config.js", ".git/config", "img/a b.png", "my deck%20.html"] {
            try "x".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try "outside".write(to: base.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        try manager.createSymbolicLink(atPath: folder.appendingPathComponent("notes.js").path, withDestinationPath: ".secrets/config.js")
        try manager.createSymbolicLink(atPath: folder.appendingPathComponent("x").path, withDestinationPath: ".git")
        try manager.createSymbolicLink(atPath: folder.appendingPathComponent("up.txt").path, withDestinationPath: "../../../outside.txt")
        let file = { (raw: String) in
            // swiftlint:disable:next force_unwrapping
            HTMLPreviewPolicy.previewFile(for: URL(string: "wtpreview://0a1b/" + raw)!, folder: folder)
        }
        XCTAssertEqual(file("index.html")?.lastPathComponent, "index.html")
        XCTAssertEqual(file("index.html?v=1#s2")?.lastPathComponent, "index.html")
        XCTAssertEqual(file("img/a%20b.png")?.lastPathComponent, "a b.png")
        XCTAssertEqual(file("my%20deck%2520.html")?.lastPathComponent, "my deck%20.html")
        for raw in [".env", "%2Eenv", ".secrets/config.js", ".git/config", "notes.js", "x/config", "up.txt",
                    "../outside.txt", "%2E%2E/outside.txt", "img/", "img", "missing.html", ""] {
            XCTAssertNil(file(raw), raw)
        }
        XCTAssertNil(HTMLPreviewPolicy.previewFile(for: folder.appendingPathComponent("index.html"), folder: folder), "file: is not served")
    }

    func testByteRanges() {
        XCTAssertEqual(HTMLPreviewPolicy.byteRange(nil, length: 10), .whole)
        XCTAssertEqual(HTMLPreviewPolicy.byteRange("bytes=0-1", length: 10), .partial(0..<2))
        XCTAssertEqual(HTMLPreviewPolicy.byteRange("bytes=4-", length: 10), .partial(4..<10))
        XCTAssertEqual(HTMLPreviewPolicy.byteRange("bytes=-3", length: 10), .partial(7..<10))
        XCTAssertEqual(HTMLPreviewPolicy.byteRange("bytes=8-100", length: 10), .partial(8..<10))
        for header in ["bytes=5-2", "bytes=0-1,4-5", "items=0-1", "bytes=a-b"] {
            XCTAssertEqual(HTMLPreviewPolicy.byteRange(header, length: 10), .whole, header)
        }
        for header in ["bytes=10-", "bytes=10-12", "bytes=-0"] {
            XCTAssertEqual(HTMLPreviewPolicy.byteRange(header, length: 10), .unsatisfiable, header)
        }
        XCTAssertEqual(HTMLPreviewPolicy.byteRange("bytes=0-", length: 0), .unsatisfiable)
    }

    // MARK: navigation

    func testAnInMemoryPageStaysOnItself() {
        XCTAssertTrue(HTMLPreviewPolicy.allowsNavigation(to: URL(string: "about:blank"), isMainFrame: true, page: nil))
        XCTAssertTrue(HTMLPreviewPolicy.allowsNavigation(to: URL(string: "about:blank#s2"), isMainFrame: true, page: nil))
        XCTAssertTrue(HTMLPreviewPolicy.allowsNavigation(to: URL(string: "about:srcdoc"), isMainFrame: false, page: nil))
        for raw in ["https://example.com", "http://127.0.0.1:8080/", "file:///etc/hosts", "data:text/html,x", "javascript:alert(1)",
                    "mailto:a@example.com", "wtpreview://0a1b/index.html"] {
            XCTAssertFalse(HTMLPreviewPolicy.allowsNavigation(to: URL(string: raw), isMainFrame: true, page: nil), raw)
            XCTAssertFalse(HTMLPreviewPolicy.allowsNavigation(to: URL(string: raw), isMainFrame: false, page: nil), raw)
        }
        XCTAssertFalse(HTMLPreviewPolicy.allowsNavigation(to: nil, isMainFrame: true, page: nil))
    }

    func testAFilePreviewAllowsItsPageAndFramesFromItsFolderOnly() {
        let allows = { (raw: String, main: Bool) in
            HTMLPreviewPolicy.allowsNavigation(to: URL(string: raw), isMainFrame: main, page: self.page)
        }
        XCTAssertTrue(allows("wtpreview://0a1b/index.html", true))
        XCTAssertTrue(allows("wtpreview://0a1b/index.html#/3", true))
        XCTAssertFalse(allows("wtpreview://0a1b/other.html", true), "a link to another file opens nothing")
        XCTAssertTrue(allows("wtpreview://0a1b/slides/one.html", false))
        XCTAssertFalse(allows("file:///tmp/deck/slides/one.html", false), "never file:")
        XCTAssertFalse(allows("wtpreview://ffff/one.html", false), "another load's token")
        XCTAssertFalse(allows("https://example.com/", false))
        // No dotfile in a frame (#563); the handler refuses links into one.
        XCTAssertFalse(allows("wtpreview://0a1b/.env", false))
        XCTAssertFalse(allows("wtpreview://0a1b/%2Eenv", false))
        XCTAssertFalse(allows("wtpreview://0a1b/.git/config", false))
        XCTAssertFalse(allows("wtpreview://0a1b/slides/.secret.html", false))
    }

    func testHTMLFiles() {
        XCTAssertTrue(HTMLPreviewPolicy.isHTMLFile("docs/deck.html"))
        XCTAssertTrue(HTMLPreviewPolicy.isHTMLFile("Deck.HTM"))
        XCTAssertFalse(HTMLPreviewPolicy.isHTMLFile("deck.md"))
        XCTAssertFalse(HTMLPreviewPolicy.isHTMLFile("html"))
    }
}

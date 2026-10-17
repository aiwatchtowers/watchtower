import WebKit
import XCTest
@testable import WatchtowerCore

final class HTMLPreviewPolicyTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/deck")
    private var page: URL { folder.appendingPathComponent("index.html") }

    func testContentRulesBlockEverythingButLocalSchemes() throws {
        for allowFiles in [false, true] {
            let json = HTMLPreviewPolicy.contentRules(allowFiles: allowFiles)
            let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: [String: Any]]])
            XCTAssertEqual(rules.first?["trigger"]?["url-filter"] as? String, ".*")
            XCTAssertEqual(rules.first?["action"]?["type"] as? String, "block")
            let allowed = rules.dropFirst().compactMap { $0["trigger"]?["url-filter"] as? String }
            XCTAssertEqual(Set(allowed), Set(["^about:", "^data:", "^blob:"] + (allowFiles ? ["^file:", "^https:"] : [])))
            XCTAssertTrue(rules.dropFirst().allSatisfy { $0["action"]?["type"] as? String == "ignore-previous-rules" })
            if allowFiles {
                // https only for CDN subresources, never fetch/XHR, sockets, media or documents.
                let https = try XCTUnwrap(rules.first { $0["trigger"]?["url-filter"] as? String == "^https:" })
                XCTAssertEqual(https["trigger"]?["resource-type"] as? [String], ["script", "style-sheet", "font", "image"])
            } else {
                XCTAssertFalse(json.contains("http"), "a chat artifact never gets a network scheme back")
            }
        }
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

    func testAnInMemoryPageStaysOnItself() {
        XCTAssertTrue(HTMLPreviewPolicy.allowsNavigation(to: URL(string: "about:blank"), isMainFrame: true, page: nil, folder: nil))
        XCTAssertTrue(HTMLPreviewPolicy.allowsNavigation(to: URL(string: "about:blank#s2"), isMainFrame: true, page: nil, folder: nil))
        XCTAssertTrue(HTMLPreviewPolicy.allowsNavigation(to: URL(string: "about:srcdoc"), isMainFrame: false, page: nil, folder: nil))
        for raw in ["https://example.com", "http://127.0.0.1:8080/", "file:///etc/hosts", "data:text/html,x", "javascript:alert(1)",
                    "mailto:a@example.com"] {
            XCTAssertFalse(HTMLPreviewPolicy.allowsNavigation(to: URL(string: raw), isMainFrame: true, page: nil, folder: nil), raw)
        }
        XCTAssertFalse(HTMLPreviewPolicy.allowsNavigation(to: nil, isMainFrame: true, page: nil, folder: nil))
    }

    func testAFilePreviewAllowsItsPageAndFramesFromItsFolderOnly() {
        let allows = { (raw: String, main: Bool) in
            HTMLPreviewPolicy.allowsNavigation(to: URL(string: raw), isMainFrame: main, page: self.page, folder: self.folder)
        }
        XCTAssertTrue(allows("file:///tmp/deck/index.html", true))
        XCTAssertTrue(allows("file:///tmp/deck/index.html#/3", true))
        XCTAssertFalse(allows("file:///tmp/deck/other.html", true), "a link to another file opens nothing")
        XCTAssertTrue(allows("file:///tmp/deck/slides/one.html", false))
        XCTAssertFalse(allows("file:///tmp/deck/../secret.html", false))
        XCTAssertFalse(allows("file:///tmp/deckish/one.html", false))
        XCTAssertFalse(allows("https://example.com/", false))
    }

    func testHTMLFiles() {
        XCTAssertTrue(HTMLPreviewPolicy.isHTMLFile("docs/deck.html"))
        XCTAssertTrue(HTMLPreviewPolicy.isHTMLFile("Deck.HTM"))
        XCTAssertFalse(HTMLPreviewPolicy.isHTMLFile("deck.md"))
        XCTAssertFalse(HTMLPreviewPolicy.isHTMLFile("html"))
    }
}

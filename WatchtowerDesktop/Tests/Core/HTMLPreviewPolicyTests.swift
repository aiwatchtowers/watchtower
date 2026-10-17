import WebKit
import XCTest
@testable import WatchtowerCore

final class HTMLPreviewPolicyTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/deck")
    private var page: URL { folder.appendingPathComponent("index.html") }

    func testContentRulesBlockEverythingButLocalSchemes() throws {
        for previewFolder in [nil, folder] {
            let json = HTMLPreviewPolicy.contentRules(folder: previewFolder)
            let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: [String: Any]]])
            XCTAssertEqual(rules.first?["trigger"]?["url-filter"] as? String, ".*")
            XCTAssertEqual(rules.first?["action"]?["type"] as? String, "block")
            let allowed = rules.dropFirst().compactMap { $0["trigger"]?["url-filter"] as? String }
            let cdns = HTMLPreviewPolicy.cdnHosts.map { "^https://" + HTMLPreviewPolicy.regexEscaped($0) + "/" }
            let files = previewFolder.map { [HTMLPreviewPolicy.visibleFilesFilter(under: $0)] } ?? []
            XCTAssertEqual(Set(allowed), Set(["^about:", "^data:", "^blob:"] + files + (previewFolder == nil ? [] : cdns)))
            XCTAssertTrue(rules.dropFirst().allSatisfy { $0["action"]?["type"] as? String == "ignore-previous-rules" })
            XCTAssertFalse(allowed.contains("^https:"), "never any https host (#563)")
            XCTAssertFalse(allowed.contains("^file:"), "never every file")
            if previewFolder != nil {
                // The allowlisted CDNs only for subresources, never fetch/XHR, sockets, media or documents.
                for cdn in cdns {
                    let rule = try XCTUnwrap(rules.first { $0["trigger"]?["url-filter"] as? String == cdn }, cdn)
                    XCTAssertEqual(rule["trigger"]?["resource-type"] as? [String], ["script", "style-sheet", "font", "image"])
                }
            } else {
                XCTAssertFalse(json.contains("http"), "a chat artifact never gets a network scheme back")
                XCTAssertFalse(json.contains("file"), "nor a file")
            }
        }
    }

    func testTheCDNAllowlistIsTheOwnersList() {
        XCTAssertEqual(HTMLPreviewPolicy.cdnHosts,
                       ["cdn.jsdelivr.net", "cdnjs.cloudflare.com", "unpkg.com", "fonts.googleapis.com", "fonts.gstatic.com"])
    }

    /// Files under the folder load unless a component below it is hidden;
    /// the folder itself may sit in a hidden folder (a session worktree).
    func testTheFileFilterAllowsVisibleFilesUnderTheFolderOnly() throws {
        let worktree = URL(fileURLWithPath: "/tmp/repo/.claude/worktrees/my deck")
        let regex = try NSRegularExpression(pattern: HTMLPreviewPolicy.visibleFilesFilter(under: worktree), options: [.caseInsensitive])
        let matches = { (raw: String) in
            regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil
        }
        let base = "file:///tmp/repo/.claude/worktrees/my%20deck/"
        for raw in ["index.html", "style.css", "img/logo.png", "a/b/c.js", "index.html#/2", "x.js?v=1"] {
            XCTAssertTrue(matches(base + raw), raw)
        }
        for raw in [".env", ".git/config", "sub/.secrets/config.js", "sub/.hidden.html", "../other/index.html"] {
            XCTAssertFalse(matches(base + raw), raw)
        }
        XCTAssertFalse(matches("file:///tmp/repo/.claude/worktrees/my%20deckish/index.html"))
        XCTAssertFalse(matches("file:///etc/hosts"))
    }

    /// The view fails closed when the rules do not compile: they must.
    @MainActor
    func testContentRulesCompileInWebKit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: folder))
        let weird = URL(fileURLWithPath: "/tmp/a (b) [c] {d} +e$f^g.h|i/.claude/deck")
        for (index, previewFolder) in [nil, self.folder, weird].enumerated() {
            let list = try await store.compileContentRuleList(
                forIdentifier: "test.\(index)", encodedContentRuleList: HTMLPreviewPolicy.contentRules(folder: previewFolder)
            )
            XCTAssertNotNil(list)
        }
    }

    // MARK: blocked resources banner

    func testBlockedResourcesNameEveryHostOffTheAllowlist() {
        let html = """
        <html><head>
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/reveal.js/dist/reveal.css">
        <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter">
        <link rel="stylesheet" href='https://evil.example/a.css'>
        <script src=https://tracker.example/t.js></script>
        <style>body { background: url("https://evil.example/bg.png") } @import "http://cdn.jsdelivr.net/x.css";</style>
        </head><body>
        <img src="logo.png"><img src="data:image/png;base64,AAAA"><img src="//third.example/p.gif">
        <img srcset="small.png 1x, https://fourth.example/big.png 2x">
        <img src="https://evil.example/a.css">
        <a href="https://linked.example/">a link is not a resource</a>
        <form action="https://form.example/"></form>
        </body></html>
        """
        let blocked = HTMLPreviewPolicy.blockedResources(in: html)
        XCTAssertEqual(blocked.hosts, ["evil.example", "tracker.example", "third.example", "fourth.example", "cdn.jsdelivr.net"])
        XCTAssertEqual(blocked.total, 6, "distinct URLs: a.css twice counts once; http to an allowlisted host is blocked")
        XCTAssertEqual(blocked.banner(), "Blocked 6 external resources: evil.example, tracker.example, third.example…")
    }

    func testNoBannerWhenEverythingIsLocalOrAllowlisted() {
        let html = #"<script src="https://unpkg.com/x.js"></script><img src="a.png"><a href="https://x.example">x</a>"#
        XCTAssertEqual(HTMLPreviewPolicy.blockedResources(in: html), .init(total: 0, hosts: []))
        XCTAssertNil(HTMLPreviewPolicy.blockedResources(in: html).banner())
        XCTAssertEqual(HTMLPreviewPolicy.blockedResources(in: #"<img src="https://a.example/1.png">"#).banner(),
                       "Blocked 1 external resource: a.example")
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
        // No dotfile in a frame (#563).
        XCTAssertFalse(allows("file:///tmp/deck/.env", false))
        XCTAssertFalse(allows("file:///tmp/deck/.git/config", false))
        XCTAssertFalse(allows("file:///tmp/deck/slides/.secret.html", false))
    }

    func testAFolderInsideAHiddenFolderStillFramesItsVisibleFiles() {
        let worktree = URL(fileURLWithPath: "/tmp/repo/.claude/worktrees/wt")
        let page = worktree.appendingPathComponent("index.html")
        XCTAssertTrue(HTMLPreviewPolicy.allowsNavigation(
            to: URL(string: "file:///tmp/repo/.claude/worktrees/wt/slides/one.html"), isMainFrame: false, page: page, folder: worktree
        ))
        XCTAssertFalse(HTMLPreviewPolicy.allowsNavigation(
            to: URL(string: "file:///tmp/repo/.claude/worktrees/wt/.env"), isMainFrame: false, page: page, folder: worktree
        ))
    }

    func testHTMLFiles() {
        XCTAssertTrue(HTMLPreviewPolicy.isHTMLFile("docs/deck.html"))
        XCTAssertTrue(HTMLPreviewPolicy.isHTMLFile("Deck.HTM"))
        XCTAssertFalse(HTMLPreviewPolicy.isHTMLFile("deck.md"))
        XCTAssertFalse(HTMLPreviewPolicy.isHTMLFile("html"))
    }
}

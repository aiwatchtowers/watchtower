import XCTest
@testable import WatchtowerChatText

final class WebAddressLinksTests: XCTestCase {
    /// The addresses `text` links, as (shown text, URL) pairs.
    private func links(_ text: String) -> [String] {
        WebAddressLinks.matches(in: text).map { "\(text[$0.range]) → \($0.url)" }
    }

    func testFullURLs() {
        XCTAssertEqual(links("Open https://api.slack.com/apps/A0123ABCD now"),
                       ["https://api.slack.com/apps/A0123ABCD → https://api.slack.com/apps/A0123ABCD"])
        XCTAssertEqual(links("http://localhost:8080/x"), ["http://localhost:8080/x → http://localhost:8080/x"])
        XCTAssertEqual(links("HTTPS://Example.com"), ["HTTPS://Example.com → HTTPS://Example.com"])
        XCTAssertEqual(links("https://example.com/search?q=a&b=c#top"),
                       ["https://example.com/search?q=a&b=c#top → https://example.com/search?q=a&b=c#top"])
    }

    func testBareHostsOpenAsHTTPS() {
        XCTAssertEqual(links("Go to api.slack.com/apps and pick it"), ["api.slack.com/apps → https://api.slack.com/apps"])
        XCTAssertEqual(links("console.cloud.google.com"), ["console.cloud.google.com → https://console.cloud.google.com"])
        XCTAssertEqual(links("admin.atlassian.com/o/1/users"),
                       ["admin.atlassian.com/o/1/users → https://admin.atlassian.com/o/1/users"])
        XCTAssertEqual(links("example.co.uk:8443/a"), ["example.co.uk:8443/a → https://example.co.uk:8443/a"])
        XCTAssertEqual(links("Example.COM"), ["Example.COM → https://Example.COM"])
    }

    func testTrailingPunctuationStaysOut() {
        XCTAssertEqual(links("See api.slack.com/apps."), ["api.slack.com/apps → https://api.slack.com/apps"])
        XCTAssertEqual(links("example.com, then"), ["example.com → https://example.com"])
        XCTAssertEqual(links("(see https://example.com/a)"), ["https://example.com/a → https://example.com/a"])
        XCTAssertEqual(links("(example.com/a)!"), ["example.com/a → https://example.com/a"])
        XCTAssertEqual(links("https://en.wikipedia.org/wiki/Swift_(language)."),
                       ["https://en.wikipedia.org/wiki/Swift_(language) → https://en.wikipedia.org/wiki/Swift_(language)"])
        XCTAssertEqual(links("Is it example.com?"), ["example.com → https://example.com"])
    }

    func testFileNamesVersionsAndMailStayText() {
        for text in [
            "config.json", "main.go", "notes.md", "run.sh", "app.py", "lib.rs", "Watchtower.app", "Package.swift",
            "index.ts", "v1.2.3", "1.2.3", "go 1.26", "mail me@example.com", "first.last@example.com",
            "e.g. this", "i.e.", "file.tar.gz", "https://", "http:// x", "a.b", "foo.comx", "path/to/example.com",
            "x.example.com_y", "~/api.slack.com"
        ] {
            XCTAssertEqual(links(text), [], text)
        }
    }

    /// Two labels with no port or path read like code as often as a site:
    /// only a domain no identifier ends in links.
    func testCodeIdentifiersStayText() {
        for text in [
            "logger.info(x)", "java.io", "System.Net", "item.info", "self.page", "user.me", "model.pt", "os.at",
            "the site.dev value", "an api.ai call", "use foo.co", "show.tv", "us.us", "x.site"
        ] {
            XCTAssertEqual(links(text), [], text)
        }
    }

    func testHostsThatLinkWithoutAScheme() {
        XCTAssertEqual(links("api.slack.com/apps"), ["api.slack.com/apps → https://api.slack.com/apps"])
        XCTAssertEqual(links("console.cloud.google.com"), ["console.cloud.google.com → https://console.cloud.google.com"])
        XCTAssertEqual(links("example.com"), ["example.com → https://example.com"])
        XCTAssertEqual(links("admin.atlassian.com/x"), ["admin.atlassian.com/x → https://admin.atlassian.com/x"])
        XCTAssertEqual(links("acme.org"), ["acme.org → https://acme.org"])
        XCTAssertEqual(links("docs.example.io"), ["docs.example.io → https://docs.example.io"], "three labels")
        XCTAssertEqual(links("example.io/start"), ["example.io/start → https://example.io/start"], "a path")
        XCTAssertEqual(links("example.dev:8080"), ["example.dev:8080 → https://example.dev:8080"], "a port")
        XCTAssertEqual(links("https://java.io"), ["https://java.io → https://java.io"], "a full URL always links")
    }

    func testClosingQuotesStayOut() {
        XCTAssertEqual(links("Откройте «api.slack.com/apps»."), ["api.slack.com/apps → https://api.slack.com/apps"])
        XCTAssertEqual(links("«example.com»"), ["example.com → https://example.com"])
        XCTAssertEqual(links("“https://example.com”"), ["https://example.com → https://example.com"])
        XCTAssertEqual(links("‘https://example.com/a’"), ["https://example.com/a → https://example.com/a"])
        XCTAssertEqual(links("‹https://example.com/a›"), ["https://example.com/a → https://example.com/a"])
    }

    /// `_` and `~` are URL characters: a link ending in one keeps it.
    func testUnderscoreAndTildeStayInTheLink() {
        XCTAssertEqual(links("https://example.com/~user"), ["https://example.com/~user → https://example.com/~user"])
        XCTAssertEqual(links("https://example.com/a_"), ["https://example.com/a_ → https://example.com/a_"])
        XCTAssertEqual(links("example.com/path_"), ["example.com/path_ → https://example.com/path_"])
    }

    func testInlineCodeAndLinksAreLeftAlone() {
        XCTAssertEqual(MarkdownDocument.parse("Run `curl api.slack.com/apps` or [the page](https://example.com/x)"), [
            .paragraph([.text("Run "), .code("curl api.slack.com/apps"), .text(" or "),
                        .link(destination: "https://example.com/x", children: [.text("the page")])])
        ])
        XCTAssertEqual(MarkdownDocument.parse("[api.slack.com](https://api.slack.com)"), [
            .paragraph([.link(destination: "https://api.slack.com", children: [.text("api.slack.com")])])
        ])
        XCTAssertEqual(MarkdownDocument.parse("```\napi.slack.com/apps\n```"), [.code(language: nil, code: "api.slack.com/apps")])
    }

    func testProseBecomesLinksThroughEmphasis() {
        XCTAssertEqual(MarkdownDocument.parse("Open api.slack.com/apps, then **https://example.com**."), [
            .paragraph([.text("Open "), .link(destination: "https://api.slack.com/apps", children: [.text("api.slack.com/apps")]),
                        .text(", then "),
                        .strong([.link(destination: "https://example.com", children: [.text("https://example.com")])]),
                        .text(".")])
        ])
        XCTAssertEqual(MarkdownDocument.parse("# Docs at example.com"), [
            .heading(level: 1, inlines: [.text("Docs at "),
                                         .link(destination: "https://example.com", children: [.text("example.com")])])
        ])
    }

    func testTableCellsAndListItemsLink() {
        let table = MarkdownDocument.parse("| Site |\n| --- |\n| example.com |")
        guard case let .table(t) = table.first else { return XCTFail("no table") }
        XCTAssertEqual(t.rows, [[[.link(destination: "https://example.com", children: [.text("example.com")])]]])
        XCTAssertEqual(MarkdownDocument.parse("- example.com"), [.list(MarkdownList(ordered: false, start: 1, items: [
            MarkdownListItem(task: .none, blocks: [
                .paragraph([.link(destination: "https://example.com", children: [.text("example.com")])])
            ])
        ]))])
    }

    func testTextWithoutAddressesKeepsItsPieces() {
        let pieces: [MarkdownInline] = [.text("a "), .text("[b]")]
        XCTAssertEqual(WebAddressLinks.linked(pieces), pieces)
    }

    func testRendersAsAWebLink() {
        let blocks = MarkdownDocument.parse("Open api.slack.com/apps")
        guard case let .paragraph(inlines) = blocks.first else { return XCTFail("no paragraph") }
        let attributed = MarkdownInlineRenderer.attributed(inlines)
        XCTAssertTrue(attributed.runs.contains { $0.link?.absoluteString == "https://api.slack.com/apps" })
    }
}

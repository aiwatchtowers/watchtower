import XCTest
@testable import WatchtowerCore

/// Preflight ruling A12: a `jira:<KEY>` ref resolves to its site's browse
/// URL; everything else that carries no `url` stays unresolved.
final class SourceLinkResolverTests: XCTestCase {
    private func source(kind: String, title: String = "t", url: String? = nil, ref: String) -> ChatSource {
        ChatSource(kind: kind, title: title, url: url, ref: ref)
    }

    func testExplicitURLWins() {
        let src = source(kind: "jira", url: "https://x.example.com/PAY-7", ref: "jira:PAY-7")
        XCTAssertEqual(SourceLinkResolver.url(for: src, jiraSiteURL: "https://ignored.example.com")?.absoluteString,
                       "https://x.example.com/PAY-7")
    }

    func testJiraRefResolvesViaSite() {
        let src = source(kind: "jira", ref: "jira:PAY-7")
        XCTAssertEqual(SourceLinkResolver.url(for: src, jiraSiteURL: "https://acme.atlassian.net")?.absoluteString,
                       "https://acme.atlassian.net/browse/PAY-7")
    }

    func testJiraRefTrimsTrailingSlashInSite() {
        let src = source(kind: "jira", ref: "jira:PAY-7")
        XCTAssertEqual(SourceLinkResolver.url(for: src, jiraSiteURL: "https://acme.atlassian.net/")?.absoluteString,
                       "https://acme.atlassian.net/browse/PAY-7")
    }

    func testNilSiteReturnsNil() {
        let src = source(kind: "jira", ref: "jira:PAY-7")
        XCTAssertNil(SourceLinkResolver.url(for: src, jiraSiteURL: nil))
    }

    func testEmptySiteReturnsNil() {
        let src = source(kind: "jira", ref: "jira:PAY-7")
        XCTAssertNil(SourceLinkResolver.url(for: src, jiraSiteURL: ""))
    }

    func testNonJiraKindWithoutURLReturnsNil() {
        let src = source(kind: "slack", ref: "slack:C1:100.1")
        XCTAssertNil(SourceLinkResolver.url(for: src, jiraSiteURL: "https://acme.atlassian.net"))
    }

    func testRefMissingJiraPrefixReturnsNil() {
        let src = source(kind: "jira", ref: "PAY-7")
        XCTAssertNil(SourceLinkResolver.url(for: src, jiraSiteURL: "https://acme.atlassian.net"))
    }

    func testEmptyKeyAfterJiraPrefixReturnsNil() {
        let src = source(kind: "jira", ref: "jira:")
        XCTAssertNil(SourceLinkResolver.url(for: src, jiraSiteURL: "https://acme.atlassian.net"))
    }

    /// #737: a published source follows the link card's rule — any URL but
    /// an https claude.ai page is plain text, never a link.
    func testPublishedSourceLinksOnlyAClaudeAIPage() {
        let kind = PublishedLink.sourceKind
        XCTAssertEqual(SourceLinkResolver.url(for: source(kind: kind, url: "https://claude.ai/artifact/abc", ref: "r"),
                                              jiraSiteURL: nil)?.absoluteString,
                       "https://claude.ai/artifact/abc")
        XCTAssertNil(SourceLinkResolver.url(for: source(kind: kind, url: "https://example.com/x", ref: "r"), jiraSiteURL: nil))
        XCTAssertNil(SourceLinkResolver.url(for: source(kind: kind, url: "http://claude.ai/artifact/abc", ref: "r"),
                                            jiraSiteURL: nil))
        XCTAssertNil(SourceLinkResolver.url(for: source(kind: kind, ref: "https://claude.ai/artifact/abc"), jiraSiteURL: nil))
    }
}

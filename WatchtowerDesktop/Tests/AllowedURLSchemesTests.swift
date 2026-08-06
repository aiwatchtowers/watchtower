import XCTest
@testable import WatchtowerDesktop

final class AllowedURLSchemesTests: XCTestCase {

    // MARK: - Allowed schemes

    func testAllowsWebSchemes() {
        XCTAssertTrue(AllowedURLSchemes.permits(URL(string: "https://acme.slack.com/archives/C1/p123")!))
        XCTAssertTrue(AllowedURLSchemes.permits(URL(string: "http://example.com")!))
    }

    func testAllowsMailto() {
        XCTAssertTrue(AllowedURLSchemes.permits(URL(string: "mailto:someone@example.com")!))
    }

    func testAllowsSlackDeepLink() {
        XCTAssertTrue(AllowedURLSchemes.permits(URL(string: "slack://channel?team=T1&id=C1")!))
    }

    func testAllowsMemoryWikiLink() throws {
        let raw = try XCTUnwrap(MemoryMarkdown.linkURL(for: "situation:23"))
        XCTAssertTrue(AllowedURLSchemes.permits(try XCTUnwrap(URL(string: raw))))
    }

    // MARK: - Rejected schemes

    func testRejectsFileSharingSchemes() {
        XCTAssertFalse(AllowedURLSchemes.permits(URL(string: "smb://198.51.100.7/share")!))
        XCTAssertFalse(AllowedURLSchemes.permits(URL(string: "afp://198.51.100.7/share")!))
    }

    func testRejectsFileScheme() {
        XCTAssertFalse(AllowedURLSchemes.permits(URL(string: "file:///Applications/Evil.app")!))
    }

    func testRejectsSystemPreferencesScheme() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings")!
        XCTAssertFalse(AllowedURLSchemes.permits(url))
    }

    func testRejectsJavascriptScheme() {
        XCTAssertFalse(AllowedURLSchemes.permits(URL(string: "javascript:alert(1)")!))
    }

    /// `watchtower-auth` is an inbound OAuth callback only — it must not be
    /// openable from rendered content.
    func testRejectsAuthCallbackScheme() {
        XCTAssertFalse(AllowedURLSchemes.permits(URL(string: "watchtower-auth://done")!))
    }

    func testRejectsSchemelessURL() {
        let url = URL(string: "/etc/passwd")!
        XCTAssertNil(url.scheme)
        XCTAssertFalse(AllowedURLSchemes.permits(url))
    }

    // MARK: - Case handling

    /// Foundation does NOT normalise the scheme's case — `URL.scheme` returns
    /// it exactly as written. Pinned here because it makes the `lowercased()`
    /// in `permits` load-bearing: without it `SMB://` slips past a raw
    /// `Set.contains` check.
    func testURLSchemeKeepsAuthorCase() {
        XCTAssertEqual(URL(string: "SMB://198.51.100.7/share")!.scheme, "SMB")
        XCTAssertEqual(URL(string: "HtTpS://example.com")!.scheme, "HtTpS")
    }

    func testSchemeComparisonIsCaseInsensitive() {
        XCTAssertFalse(AllowedURLSchemes.permits(URL(string: "SMB://198.51.100.7/share")!))
        XCTAssertFalse(AllowedURLSchemes.permits(URL(string: "FiLe:///Applications/Evil.app")!))
        XCTAssertTrue(AllowedURLSchemes.permits(URL(string: "HtTpS://example.com")!))
    }

    // MARK: - Link stripping

    func testStrippingRemovesDisallowedLinkButKeepsText() throws {
        let source = try AttributedString(
            markdown: "[Q3 numbers](smb://198.51.100.7/share)",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        XCTAssertNotNil(source.runs.first { $0.link != nil }, "precondition: markdown set a link")

        let stripped = AllowedURLSchemes.strippingDisallowedLinks(source)
        XCTAssertNil(stripped.runs.first { $0.link != nil })
        XCTAssertEqual(String(stripped.characters), "Q3 numbers")
    }

    func testStrippingKeepsAllowedLink() throws {
        let source = try AttributedString(
            markdown: "[Q3 numbers](https://example.com/q3)",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        let stripped = AllowedURLSchemes.strippingDisallowedLinks(source)
        XCTAssertEqual(stripped.runs.first { $0.link != nil }?.link?.absoluteString,
                       "https://example.com/q3")
    }

    /// A mixed run must lose only the disallowed link — the neighbouring
    /// allowed one survives the same pass.
    func testStrippingIsPerRun() throws {
        let source = try AttributedString(
            markdown: "[bad](smb://host/share) and [good](https://example.com)",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        let stripped = AllowedURLSchemes.strippingDisallowedLinks(source)
        let links = stripped.runs.compactMap { $0.link?.absoluteString }
        XCTAssertEqual(links, ["https://example.com"])
        XCTAssertEqual(String(stripped.characters), "bad and good")
    }
}

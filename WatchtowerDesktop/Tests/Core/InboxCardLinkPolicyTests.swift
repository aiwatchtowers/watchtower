import XCTest
@testable import WatchtowerCore

/// A card link (`link`, an action's `open`) is checked again at press time:
/// http(s), or `watchtower-nav://` to a visible screen, nothing else.
final class InboxCardLinkPolicyTests: XCTestCase {
    private func url(_ text: String) throws -> URL {
        try XCTUnwrap(URL(string: text))
    }

    func testAllowsHttpAndHttps() throws {
        XCTAssertTrue(InboxCardLinkPolicy.permits(try url("https://example.com/a"), navScreens: []))
        XCTAssertTrue(InboxCardLinkPolicy.permits(try url("http://example.com"), navScreens: []))
    }

    func testSchemeIsCaseInsensitive() throws {
        XCTAssertTrue(InboxCardLinkPolicy.permits(try url("HTTPS://example.com/a"), navScreens: []))
        XCTAssertTrue(InboxCardLinkPolicy.permits(try url("WATCHTOWER-NAV://home"), navScreens: ["home"]))
    }

    func testNavOnlyToVisibleScreens() throws {
        XCTAssertTrue(InboxCardLinkPolicy.permits(try url("watchtower-nav://home"), navScreens: ["home"]))
        XCTAssertFalse(InboxCardLinkPolicy.permits(try url("watchtower-nav://home"), navScreens: []))
        XCTAssertFalse(InboxCardLinkPolicy.permits(try url("watchtower-nav://settings"), navScreens: ["home"]))
    }

    /// What a press opens: a screen link rebuilt with the lowercase scheme
    /// `NavLink.destination` compares, a web link as written, nothing refused.
    func testRouteNormalisesScreenLinks() throws {
        XCTAssertEqual(InboxCardLinkPolicy.route(try url("WATCHTOWER-NAV://home"), navScreens: ["home"]),
                       .screen(try url("watchtower-nav://home")))
        XCTAssertEqual(InboxCardLinkPolicy.route(try url("HTTPS://example.com/a"), navScreens: []),
                       .web(try url("HTTPS://example.com/a")))
        XCTAssertNil(InboxCardLinkPolicy.route(try url("watchtower-nav://hidden"), navScreens: ["home"]))
        XCTAssertNil(InboxCardLinkPolicy.route(try url("file:///etc/hosts"), navScreens: ["home"]))
    }

    func testRefusesOtherSchemes() throws {
        for text in ["file:///etc/hosts", "smb://example.com/share", "javascript:alert(1)",
                     "mailto:a@example.com", "slack://channel?id=C1", "notes/today.md", "https://"] {
            XCTAssertFalse(InboxCardLinkPolicy.permits(try url(text), navScreens: ["home"]), text)
        }
    }
}

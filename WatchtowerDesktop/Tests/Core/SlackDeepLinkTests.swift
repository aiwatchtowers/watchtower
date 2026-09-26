import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// `SlackLinkResolver` + `SlackDeepLink` — the one Desktop path from a stored
/// (possibly namespaced) Slack id to a link. Fixtures carry TWO accounts with
/// DIFFERENT team ids on purpose: a single-account fixture cannot tell "resolves
/// the owning account" from "always uses account #1's team", and every link test
/// before this one used bare ids only.
final class SlackDeepLinkTests: XCTestCase {

    private let resolver = SlackLinkResolver(
        teamIDByAccount: [1: "T001", 2: "T999", 5: ""],
        fallbackTeamID: "TWS"
    )

    // MARK: - Resolver ladder (mirrors internal/ai/slack_link.go)

    func testNamespacedIDResolvesItsOwnAccountsTeam() throws {
        try assertChannelLink(resolver.channelURL("1:C0123"), team: "T001", id: "C0123")
        try assertChannelLink(resolver.channelURL("2:C0456"), team: "T999", id: "C0456")
    }

    func testBareLegacyIDKeepsFallbackTeamUnchanged() throws {
        try assertChannelLink(resolver.channelURL("C0123"), team: "TWS", id: "C0123")
    }

    func testUnknownAccountFallsBackButStillStrips() throws {
        try assertChannelLink(resolver.channelURL("3:C0789"), team: "TWS", id: "C0789")
    }

    func testAccountWithEmptyTeamIDFallsBack() throws {
        try assertChannelLink(resolver.channelURL("5:C0555"), team: "TWS", id: "C0555")
    }

    /// A non-numeric prefix is not a namespace — the id passes through whole
    /// (pins that resolution goes through `SlackAccountID.split`).
    func testNonNumericPrefixPassesThroughUntouched() throws {
        try assertChannelLink(resolver.channelURL("C:0123"), team: "TWS", id: "C:0123")
    }

    func testMessageLinkCarriesTSAndResolvedTeam() throws {
        let url = try XCTUnwrap(resolver.channelURL("2:C0456", messageTS: "1740577800.000100"))
        let items = try queryItems(url)
        XCTAssertEqual(url.host, "channel")
        XCTAssertEqual(items["team"], "T999")
        XCTAssertEqual(items["id"], "C0456")
        XCTAssertEqual(items["message"], "1740577800.000100")
    }

    /// An empty ts is Go's GenerateDeeplink channel-only shape, not `&message=`.
    func testEmptyMessageTSYieldsChannelOnlyLink() throws {
        let url = try XCTUnwrap(resolver.channelURL("1:C0123", messageTS: ""))
        XCTAssertEqual(url.absoluteString, "slack://channel?team=T001&id=C0123")
    }

    /// No team anywhere → no slack:// channel link (a teamless one opens nothing useful).
    func testNoTeamYieldsNoChannelLink() {
        let empty = SlackLinkResolver(teamIDByAccount: [:], fallbackTeamID: "")
        XCTAssertNil(empty.channelURL("C0123"))
        XCTAssertNil(empty.channelURL("3:C0789", messageTS: "1.2"))
    }

    // MARK: - User links

    func testUserLinkResolvesTeamAndStripsID() throws {
        let url = try XCTUnwrap(resolver.userURL("2:U0042"))
        let items = try queryItems(url)
        XCTAssertEqual(url.host, "user")
        XCTAssertEqual(items["team"], "T999")
        XCTAssertEqual(items["id"], "U0042")
    }

    func testUserLinkWithoutAnyTeamOmitsTeam() {
        let empty = SlackLinkResolver(teamIDByAccount: [:], fallbackTeamID: "")
        XCTAssertEqual(empty.userURL("1:U0042")?.absoluteString, "slack://user?id=U0042")
    }

    // MARK: - Web archives family (no team needed, id must be raw)

    func testArchivesStripsNamespaceAndDotlessTS() {
        XCTAssertEqual(
            SlackDeepLink.archives(channelID: "2:C0456", messageTS: "1740577800.000100")?.absoluteString,
            "https://slack.com/archives/C0456/p1740577800000100"
        )
        XCTAssertEqual(
            SlackDeepLink.archives(channelID: "C:0123", messageTS: "1.2")?.absoluteString,
            "https://slack.com/archives/C:0123/p12"
        )
    }

    func testTargetRefParsesNamespacedAndBareForms() {
        XCTAssertEqual(SlackDeepLink.targetRef("slack:2:C0456:1740577800.000100")?.absoluteString,
                       "https://slack.com/archives/C0456/p1740577800000100")
        XCTAssertEqual(SlackDeepLink.targetRef("slack:C0123:1740577800.000100")?.absoluteString,
                       "https://slack.com/archives/C0123/p1740577800000100")
        XCTAssertEqual(SlackDeepLink.targetRef("slack:2:C0456")?.absoluteString,
                       "https://slack.com/app_redirect?channel=C0456")
        XCTAssertEqual(SlackDeepLink.targetRef("slack:C0123")?.absoluteString,
                       "https://slack.com/app_redirect?channel=C0123")
        XCTAssertNil(SlackDeepLink.targetRef("slack:"))
        XCTAssertNil(SlackDeepLink.targetRef("jira:PROJ-1"))
    }

    // MARK: - Loading from the database

    func testLoadReadsPerAccountTeamsAndWorkspaceFallback() throws {
        let (pool, _) = try TestDatabase.createPool()
        let ids = try pool.write { db -> [Int64] in
            try TestDatabase.insertWorkspace(db, id: "TWS")
            return [
                try TestDatabase.insertSlackAccount(db, teamID: "T001"),
                try TestDatabase.insertSlackAccount(db, teamID: "T999"),
                try TestDatabase.insertSlackAccount(db, teamID: "")
            ]
        }

        let loaded = try pool.read { try SlackLinkResolver.load($0) }

        XCTAssertEqual(loaded.fallbackTeamID, "TWS")
        XCTAssertEqual(loaded.teamIDByAccount, [Int(ids[0]): "T001", Int(ids[1]): "T999", Int(ids[2]): ""])
        try assertChannelLink(loaded.channelURL("\(ids[1]):C0456"), team: "T999", id: "C0456")
    }

    func testLoadWithoutWorkspaceRowHasEmptyFallback() throws {
        let (pool, _) = try TestDatabase.createPool()
        let loaded = try pool.read { try SlackLinkResolver.load($0) }
        XCTAssertEqual(loaded, SlackLinkResolver(teamIDByAccount: [:], fallbackTeamID: ""))
    }

    // MARK: - Helpers

    private func assertChannelLink(
        _ url: URL?, team: String, id: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let url = try XCTUnwrap(url, file: file, line: line)
        let items = try queryItems(url)
        XCTAssertEqual(url.scheme, "slack", file: file, line: line)
        XCTAssertEqual(url.host, "channel", file: file, line: line)
        XCTAssertEqual(items["team"], team, file: file, line: line)
        XCTAssertEqual(items["id"], id, file: file, line: line)
        XCTAssertNil(items["message"], file: file, line: line)
    }

    private func queryItems(_ url: URL) throws -> [String: String] {
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { first, _ in first }
    }
}

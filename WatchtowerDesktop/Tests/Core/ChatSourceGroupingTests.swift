import XCTest
@testable import WatchtowerCore

final class ChatSourceGroupingTests: XCTestCase {
    private func slack(_ title: String, url: String? = nil, ref: String = "r", group: String? = nil) -> ChatSource {
        ChatSource(kind: "slack", title: title, url: url, ref: ref, group: group)
    }

    // MARK: - Legacy rows (no group field)

    func testLegacyTitlesDeriveTheirGroup() {
        XCTAssertEqual(ChatSourceGrouping.groupName(slack("#payments — refund is live")), "#payments")
        XCTAssertEqual(ChatSourceGrouping.groupName(slack("#payments · 2026-05-13")), "#payments")
        XCTAssertEqual(ChatSourceGrouping.groupName(slack("#payments thread")), "#payments")
        XCTAssertEqual(ChatSourceGrouping.groupName(slack("DM with Ann — lunch?")), "DM with Ann")
        XCTAssertEqual(ChatSourceGrouping.groupName(slack("something else")), "Other")
        XCTAssertEqual(ChatSourceGrouping.groupName(ChatSource(kind: "jira", title: "PAY-7: Refund", url: nil,
                                                               ref: "jira:PAY-7")), "PAY")
        XCTAssertEqual(ChatSourceGrouping.groupName(ChatSource(kind: "jira", title: "x", url: nil, ref: "jira:")), "Other")
        XCTAssertEqual(ChatSourceGrouping.groupName(ChatSource(kind: "email", title: "Re: x", url: nil, ref: "g")), "Mail")
        XCTAssertEqual(ChatSourceGrouping.groupName(ChatSource(kind: "meeting", title: "Sync", url: nil, ref: "t")),
                       "Meetings")
        XCTAssertEqual(ChatSourceGrouping.groupName(ChatSource(kind: "document", title: "Doc", url: nil, ref: "d")), "Other")
    }

    func testExplicitGroupWinsOverTheTitle() {
        XCTAssertEqual(ChatSourceGrouping.groupName(slack("#old — x", group: "#new")), "#new")
    }

    /// A `sources_json` persisted before group/snippet/date existed decodes
    /// with them nil and still groups by its title.
    func testLegacyPersistedJSONDecodes() {
        let json = ##"[{"kind":"slack","title":"#payments — shipped","url":"https://acme.slack.com/archives/C1/p1","ref":"r"}]"##
        let decoded = ChatSource.decodeList(json)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].group)
        XCTAssertNil(decoded[0].snippet)
        XCTAssertNil(decoded[0].date)
        XCTAssertEqual(ChatSourceGrouping.groupName(decoded[0]), "#payments")
    }

    func testNewFieldsRoundTripAndNilsAreOmitted() throws {
        let full = ChatSource(kind: "jira", title: "PAY-1: A", url: nil, ref: "jira:PAY-1",
                              group: "PAY", snippet: "In Progress", date: "2026-05-10")
        XCTAssertEqual(ChatSource.decodeList(ChatSource.encodeList([full])), [full])
        let bare = ChatSource.encodeList([ChatSource(kind: "jira", title: "t", url: nil, ref: "r")])
        XCTAssertFalse(bare.contains("group"))
        XCTAssertFalse(bare.contains("snippet"))
        XCTAssertFalse(bare.contains("date"))
    }

    // MARK: - Titles and dates

    func testDisplayTitleDropsTheGroupPrefix() {
        XCTAssertEqual(ChatSourceGrouping.displayTitle(slack("#payments — refund is live")), "refund is live")
        XCTAssertEqual(ChatSourceGrouping.displayTitle(slack("#payments · Ann", group: "#payments")), "Ann")
        XCTAssertEqual(ChatSourceGrouping.displayTitle(slack("#payments thread")), "#payments thread")
        XCTAssertEqual(ChatSourceGrouping.displayTitle(slack("#payments — ")), "#payments — ")
        XCTAssertEqual(ChatSourceGrouping.displayTitle(ChatSource(kind: "document", title: "", url: nil, ref: "digest:9")),
                       "digest:9")
    }

    func testDisplayDate() {
        XCTAssertNotNil(ChatSourceGrouping.displayDate("2026-05-13"))
        XCTAssertTrue(ChatSourceGrouping.displayDate("2026-05-13")?.contains("2026") ?? false)
        XCTAssertNil(ChatSourceGrouping.displayDate(nil))
        XCTAssertNil(ChatSourceGrouping.displayDate("yesterday"))
        XCTAssertNil(ChatSourceGrouping.displayDate("2026-05-13T10:00:00Z"))
    }

    // MARK: - Dedupe

    func testSameThreadCollapsesToOneItem() {
        let root = slack("#payments — a", url: "https://acme.slack.com/archives/C1/p1001", ref: "kb")
        let reply = ChatSource(kind: "slack", title: "#payments · Ann",
                               url: "https://acme.slack.com/archives/C1/p2002?thread_ts=100.1&cid=C1",
                               ref: "slack:payments:200.2", snippet: "reply text", date: "2026-05-13")
        let other = slack("#payments — b", url: "https://acme.slack.com/archives/C1/p3003", ref: "kb2")
        let unique = ChatSource.dedupe([root, reply, other])
        XCTAssertEqual(unique.count, 2)
        XCTAssertEqual(unique[0].title, "#payments — a", "the first occurrence is kept")
        XCTAssertEqual(unique[0].snippet, "reply text", "a later duplicate fills missing optional fields")
        XCTAssertEqual(unique[0].date, "2026-05-13")
    }

    func testSameURLOrSameRefIsOneItem() {
        let aURL = slack("x", url: "https://example.com/doc", ref: "a")
        let bURL = slack("y", url: "https://example.com/doc", ref: "b")
        let jira1 = ChatSource(kind: "jira", title: "PAY-1", url: nil, ref: "jira:PAY-1")
        let jira2 = ChatSource(kind: "jira", title: "PAY-1: A", url: nil, ref: "jira:PAY-1")
        XCTAssertEqual(ChatSource.dedupe([aURL, bURL, jira1, jira2]).count, 2)
    }

    func testThreadKeyIgnoresNonSlackURLs() {
        XCTAssertNil(ChatSourceGrouping.threadKey("https://example.com/browse/PAY-1"))
        XCTAssertNil(ChatSourceGrouping.threadKey("https://acme.slack.com/archives/C1"))
        XCTAssertEqual(ChatSourceGrouping.threadKey("https://acme.slack.com/archives/C1/p1001"),
                       ChatSourceGrouping.threadKey("https://acme.slack.com/archives/C1/p5?thread_ts=100.1"))
    }

    // MARK: - Groups and the summary row

    private var sample: [ChatSource] {
        (1...6).map { slack("#security — t\($0)", url: "https://acme.slack.com/archives/C1/p\($0)", ref: "s\($0)") }
            + [slack("#sdlc — x", url: "https://acme.slack.com/archives/C2/p9", ref: "d1"),
               ChatSource(kind: "jira", title: "PAY-1: A", url: nil, ref: "jira:PAY-1", group: "PAY"),
               ChatSource(kind: "jira", title: "PAY-2: B", url: nil, ref: "jira:PAY-2", group: "PAY"),
               ChatSource(kind: "document", title: "Daily digest", url: nil, ref: "digest:9"),
               ChatSource(kind: "email", title: "Re: vendor", url: nil, ref: "gmail:1:t")]
    }

    func testGroupsRankBySizeWithOtherLast() {
        let groups = ChatSourceGrouping.groups(sample + [sample[0]])
        XCTAssertEqual(groups.map(\.name), ["#security", "PAY", "#sdlc", "Mail", "Other"])
        XCTAssertEqual(groups.map(\.sources.count), [6, 2, 1, 1, 1], "the duplicate is dropped")
        XCTAssertEqual(groups[0].kind, "slack")
        XCTAssertEqual(groups[1].kind, "jira")
    }

    func testSummaryCountsKindsAndTopGroups() {
        let summary = ChatSourceGrouping.summary(sample)
        XCTAssertEqual(summary.count, 11)
        XCTAssertEqual(summary.countLabel, "11 sources")
        XCTAssertEqual(summary.kinds, ["slack", "jira", "document", "email"])
        XCTAssertEqual(summary.topGroups, "#security ×6, PAY ×2, #sdlc")
    }

    func testSummaryCapsIconsAndHandlesOneAndNone() {
        let kinds = ["slack", "jira", "email", "meeting", "document", "person"]
        let many = kinds.enumerated().map { ChatSource(kind: $0.element, title: "t", url: nil, ref: "r\($0.offset)") }
        XCTAssertEqual(ChatSourceGrouping.summary(many).kinds.count, ChatSourceGrouping.maxIcons)
        let one = ChatSourceGrouping.summary([ChatSource(kind: "document", title: "Doc", url: nil, ref: "d")])
        XCTAssertEqual(one.countLabel, "1 source")
        XCTAssertEqual(one.topGroups, "", "an Other-only answer names no group")
        XCTAssertEqual(ChatSourceGrouping.summary([]).count, 0)
    }

    // MARK: - Inspector mode

    func testInspectorShowsThePreferredOpenPanelAndFallsBack() {
        XCTAssertEqual(ChatInspectorPolicy.visibleMode(preferred: .sources, artifactOpen: true, sourcesOpen: true),
                       .sources)
        XCTAssertEqual(ChatInspectorPolicy.visibleMode(preferred: .sources, artifactOpen: true, sourcesOpen: false),
                       .artifacts, "closing Sources falls back to the still-open artifact")
        XCTAssertEqual(ChatInspectorPolicy.visibleMode(preferred: .artifacts, artifactOpen: false, sourcesOpen: true),
                       .sources)
        XCTAssertNil(ChatInspectorPolicy.visibleMode(preferred: .artifacts, artifactOpen: false, sourcesOpen: false))
        XCTAssertTrue(ChatInspectorPolicy.showsTabs(artifactOpen: true, sourcesOpen: true))
        XCTAssertFalse(ChatInspectorPolicy.showsTabs(artifactOpen: false, sourcesOpen: true))
    }

    func testSelectionDedupesItsSources() {
        let src = ChatSource(kind: "jira", title: "PAY-1", url: nil, ref: "jira:PAY-1")
        XCTAssertEqual(ChatSourcesSelection(messageID: 1, sources: [src, src]).sources.count, 1)
    }
}

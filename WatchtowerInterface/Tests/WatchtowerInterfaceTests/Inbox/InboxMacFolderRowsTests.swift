import Foundation
import WatchtowerInterface
import XCTest

/// The Mac folder list's texts, pinned to today's `InboxFolderEntries.row`.
final class InboxMacFolderRowsTests: XCTestCase {
    /// 2026-11-16T12:00:00Z.
    private let now = Date(timeIntervalSince1970: 1_794_830_400)

    private func ref(_ id: Int64, open: Bool = true, waits: Bool = true) -> RefFacts {
        RefFacts(kind: .inboxItem, id: id, open: open, waits: waits, reply: false, replyWaiting: false, link: "",
                 triggerType: "", custom: false, linkedTargetID: 0, ideaKind: "", ideaStatus: "")
    }

    private func legacy(
        _ id: String,
        _ kind: LegacyKind,
        title: String,
        source: String = "",
        preview: String = "",
        stamp: String = "2026-11-16T11:54:00Z",
        unread: Bool = false,
        items: [LegacyItem] = []
    ) throws -> Card {
        var card = try InboxFixtures.artifact(id)
        card.cardKind = .legacy
        card.title = title
        card.sourceLine = source
        card.preview = preview
        card.stamp = stamp
        card.unread = unread
        card.automation = nil
        card.legacy = LegacySection(kind: kind, items: items, attention: [])
        return card
    }

    private func item(_ id: Int64, title: String = "t", stamp: String = "2026-11-16T09:00:00Z") -> LegacyItem {
        LegacyItem(refKind: .action, id: id, title: title, subtitle: "", preview: "", stamp: stamp, end: "",
                   unread: false, high: false, stopped: false, done: false, date: "")
    }

    func testArtifactRowCountsWaitingRowsAndShowsTheRun() throws {
        var card = try InboxFixtures.artifact("o5", stamp: "2026-11-16T10:00:00Z", unread: true,
                                              refs: [ref(1), ref(2), ref(3, open: false), ref(4, waits: false)])
        card.title = "Standup notes"
        card.automation?.runID = 12
        let row = try XCTUnwrap(InboxMacFolderRows.rows([card], approvals: false, now: now).first)
        XCTAssertEqual(row.kind, .artifact)
        XCTAssertEqual(row.title, "Standup notes")
        XCTAssertEqual(row.summary, "2 waiting")
        XCTAssertEqual(row.detail, "run #12 · 2 h ago")
        XCTAssertTrue(row.unread)
    }

    func testLivingArtifactShowsUpdatedAndNoSummaryWithoutWaitingRows() throws {
        let card = try InboxFixtures.artifact("o6", stamp: "2026-11-16T11:54:00Z", living: true)
        let row = try XCTUnwrap(InboxMacFolderRows.rows([card], approvals: false, now: now).first)
        XCTAssertEqual(row.summary, "")
        XCTAssertEqual(row.detail, "updated 6 min ago")
        let fresh = try InboxFixtures.artifact("o7", stamp: "2026-11-16T11:59:30Z", living: true)
        XCTAssertEqual(InboxMacFolderRows.rows([fresh], approvals: false, now: now).first?.detail, "updated just now")
    }

    func testNeedsApprovalRowsAreUnreadApprovalsWithTheirTitles() throws {
        var card = try InboxFixtures.artifact("o8")
        card.title = "Send the summary"
        let rows = InboxMacFolderRows.rows([card], approvals: true, now: now)
        XCTAssertEqual(rows, [InboxMacFolderRow(cardID: "o8", kind: .approval, title: "Send the summary", unread: true)])
    }

    func testAnOversizeArtifactNoticeStaysAnArtifactRow() throws {
        var card = try InboxFixtures.artifact("o9")
        card.cardKind = .notice
        XCTAssertEqual(InboxMacFolderRows.rows([card], approvals: false, now: now).first?.kind, .artifact)
        card.id = "n3"
        XCTAssertEqual(InboxMacFolderRows.rows([card], approvals: false, now: now).first?.kind, .approval)
    }

    func testLegacyRowsKeepTheMacTexts() throws {
        let brief = try legacy("brief-2026-11-16", .morningBrief, title: "Morning brief",
                               source: "Your day · Mon 16 Nov", preview: "today", unread: true)
        let tracks = try legacy("tracks", .tracks, title: "Track my threads", preview: "2 unread", unread: true,
                                items: [item(1)])
        let ideas = try legacy("ideas", .ideas, title: "Idea finder", stamp: "0001-01-01T00:00:00Z")
        let messages = try legacy("messages", .messages, title: "Messages", source: "Mentions, DMs and replies",
                                  preview: "3 waiting")
        let rows = InboxMacFolderRows.rows([brief, tracks, ideas, messages], approvals: false, now: now)
        XCTAssertEqual(rows, [
            InboxMacFolderRow(cardID: "brief-2026-11-16", kind: .legacy, title: "Morning brief", summary: "today",
                              detail: "Your day · Mon 16 Nov", unread: true),
            InboxMacFolderRow(cardID: "tracks", kind: .legacy, title: "Track my threads", summary: "2 unread",
                              detail: "updated 6 min ago", unread: true),
            InboxMacFolderRow(cardID: "ideas", kind: .legacy, title: "Idea finder"),
            InboxMacFolderRow(cardID: "messages", kind: .legacy, title: "Messages", summary: "3 waiting",
                              detail: "Mentions, DMs and replies")
        ])
    }

    func testThreadBriefsBecomeOneResultRowPerBrief() throws {
        let card = try legacy("thread-briefs", .threadBriefs, title: "Thread briefs",
                              items: [item(41, title: "Release thread"), item(40, title: "Thread brief", stamp: "")])
        let rows = InboxMacFolderRows.rows([card], approvals: false, now: now)
        XCTAssertEqual(rows, [
            InboxMacFolderRow(cardID: "thread-briefs", briefID: 41, kind: .result, title: "Release thread",
                              detail: "Thread brief · 3 h ago"),
            InboxMacFolderRow(cardID: "thread-briefs", briefID: 40, kind: .result, title: "Thread brief",
                              detail: "Thread brief")
        ])
    }
}

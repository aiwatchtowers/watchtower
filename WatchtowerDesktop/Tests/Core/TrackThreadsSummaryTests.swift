import GRDB
import XCTest
@testable import WatchtowerCore

final class TrackThreadsSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func refsJSON(_ refs: [(ts: String, author: String, text: String)]) throws -> String {
        let items = refs.map { ref -> [String: String] in
            ["ts": ref.ts, "author": ref.author, "text": ref.text]
        }
        let data = try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func card(
        id: Int,
        text: String = "Thread",
        hasUpdates: Bool = false,
        readAt: String? = "2026-01-01T00:00:00Z",
        lastEventDaysAgo: Double = 1,
        newEvents: Int = 0,
        summary: String = "",
        attachment: Bool = false,
        context: String = "",
        category: String = "task",
        ballOn: String = "",
        assignee: String = "acme:U1",
        decisionSummary: String = "",
        refs: [(ts: String, author: String, text: String)] = []
    ) throws -> InboxTrackCard {
        var columns: [String: (any DatabaseValueConvertible)?] = [
            "id": id, "text": text, "has_updates": hasUpdates, "context": context,
            "category": category, "ball_on": ballOn, "assignee_user_id": assignee,
            "decision_summary": decisionSummary, "source_refs": try refsJSON(refs)
        ]
        columns["read_at"] = readAt
        return InboxTrackCard(
            track: Track(row: Row(columns)),
            lastEventAt: now.addingTimeInterval(-lastEventDaysAgo * 24 * 3600),
            newEventCount: newEvents,
            latestEventSummary: summary,
            newestRefHasAttachment: attachment
        )
    }

    // MARK: - Split

    func testSplitsNewsAndQuietWithTheRule() throws {
        let tracks = [
            try card(id: 1, hasUpdates: true),
            try card(id: 2, readAt: nil, lastEventDaysAgo: 1), // never read, within 72 h
            try card(id: 3, lastEventDaysAgo: 5), // read, no news, not old
            try card(id: 4, lastEventDaysAgo: 40), // quiet over the limit
            try card(id: 5, readAt: nil, lastEventDaysAgo: 31) // never read, old → quiet
        ]
        let summary = TrackThreadsSummary.build(tracks: tracks, now: now)
        XCTAssertEqual(summary.news.map(\.track.id).sorted(), [1, 2])
        XCTAssertEqual(summary.quietCount, 3)
        XCTAssertEqual(summary.quietOverLimitCount, 2)
    }

    func testNewsNewestFirst() throws {
        let tracks = [
            try card(id: 1, hasUpdates: true, lastEventDaysAgo: 3),
            try card(id: 2, hasUpdates: true, lastEventDaysAgo: 1),
            try card(id: 3, hasUpdates: true, lastEventDaysAgo: 3),
            try card(id: 4, hasUpdates: true, lastEventDaysAgo: 2)
        ]
        let summary = TrackThreadsSummary.build(tracks: tracks, now: now)
        XCTAssertEqual(summary.news.map(\.track.id), [2, 4, 3, 1])
    }

    // MARK: - Latest line

    func testLatestLinePrefersEventThenSourceRefThenContext() throws {
        let refs: [(ts: String, author: String, text: String)] = [
            ("1700000002.000100", "Colleague B", "newest"),
            ("1700000001.000100", "Colleague A", "older")
        ]
        XCTAssertEqual(
            TrackThreadsSummary.latestLine(try card(id: 1, summary: "Event summary", context: "ctx", refs: refs)),
            "Event summary"
        )
        XCTAssertEqual(
            TrackThreadsSummary.latestLine(try card(id: 1, context: "ctx", refs: refs)),
            "Colleague B: “newest”"
        )
        XCTAssertEqual(
            TrackThreadsSummary.latestLine(try card(id: 1, context: "\n  \nFirst line\nSecond line")),
            "First line"
        )
        XCTAssertEqual(TrackThreadsSummary.latestLine(try card(id: 1)), "")
    }

    // MARK: - Reason

    func testReasonReplyToYouBeatsDecision() throws {
        let c = try card(id: 1, category: "decision", ballOn: "acme:U1", assignee: "acme:U1")
        XCTAssertEqual(TrackThreadsSummary.reason(c), .replyToYou)
        XCTAssertEqual(TrackNewsReason.replyToYou.label, "reply to you")
        // Ball on someone else → not a reply to you.
        let other = try card(id: 2, ballOn: "acme:U2", assignee: "acme:U1")
        XCTAssertNil(TrackThreadsSummary.reason(other))
    }

    func testReasonDecisionBeatsMention() throws {
        let refs: [(ts: String, author: String, text: String)] = [("1700000001.0", "A", "hi <@U1>")]
        XCTAssertEqual(TrackThreadsSummary.reason(try card(id: 1, category: "decision", refs: refs)), .decision)
        XCTAssertEqual(TrackThreadsSummary.reason(try card(id: 2, category: "decision_needed", refs: refs)), .decision)
        XCTAssertEqual(TrackThreadsSummary.reason(try card(id: 3, decisionSummary: "Go with B", refs: refs)), .decision)
        XCTAssertEqual(TrackNewsReason.decision.label, "decision")
    }

    func testReasonMentionFromSlackMarkup() throws {
        let plain: [(ts: String, author: String, text: String)] = [
            ("1700000002.0", "A", "ping <@U1> please"),
            ("1700000001.0", "A", "older")
        ]
        XCTAssertEqual(TrackThreadsSummary.reason(try card(id: 1, assignee: "acme:U1", refs: plain)), .mention)
        let named: [(ts: String, author: String, text: String)] = [("1700000001.0", "A", "cc <@U1|owner>")]
        XCTAssertEqual(TrackThreadsSummary.reason(try card(id: 2, assignee: "acme:U1", refs: named)), .mention)
        let another: [(ts: String, author: String, text: String)] = [("1700000001.0", "A", "cc <@U2>")]
        XCTAssertNil(TrackThreadsSummary.reason(try card(id: 3, assignee: "acme:U1", refs: another)))
        // Only the newest ref counts.
        let olderMention: [(ts: String, author: String, text: String)] = [
            ("1700000002.0", "A", "nothing"),
            ("1700000001.0", "A", "hey <@U1>")
        ]
        XCTAssertNil(TrackThreadsSummary.reason(try card(id: 4, assignee: "acme:U1", refs: olderMention)))
        XCTAssertEqual(TrackNewsReason.mention.label, "mention")
    }

    func testReasonAttachmentFromFlag() throws {
        XCTAssertEqual(TrackThreadsSummary.reason(try card(id: 1, attachment: true)), .attachment)
        XCTAssertEqual(TrackNewsReason.attachment.label, "attachment")
    }

    func testReasonNilWithoutSignal() throws {
        XCTAssertNil(TrackThreadsSummary.reason(try card(id: 1)))
        // An empty ball_on never equals an empty assignee.
        XCTAssertNil(TrackThreadsSummary.reason(try card(id: 2, ballOn: "", assignee: "")))
    }

    func testReasonReplyToYouMatchesRawBallOn() throws {
        XCTAssertEqual(TrackThreadsSummary.reason(try card(id: 1, ballOn: "U1", assignee: "acme:U1")), .replyToYou)
        XCTAssertNil(TrackThreadsSummary.reason(try card(id: 2, ballOn: "U2", assignee: "acme:U1")))
        // An empty raw part never matches.
        XCTAssertNil(TrackThreadsSummary.reason(try card(id: 3, ballOn: "other:", assignee: "acme:")))
    }

    func testLatestLineSkipsEmptyLinesAndEmptyRefText() throws {
        XCTAssertEqual(
            TrackThreadsSummary.latestLine(try card(id: 1, summary: "\n  Moved to Friday\nDetails")),
            "Moved to Friday"
        )
        let emptyRef: [(ts: String, author: String, text: String)] = [("1700000001.0", "Colleague A", "  \n")]
        XCTAssertEqual(TrackThreadsSummary.latestLine(try card(id: 2, context: "From context", refs: emptyRef)), "From context")
        let multiline: [(ts: String, author: String, text: String)] = [("1700000001.0", "Colleague A", "\nFirst\nSecond")]
        XCTAssertEqual(TrackThreadsSummary.latestLine(try card(id: 3, refs: multiline)), "Colleague A: “First”")
    }

    func testLatestLineRendersSlackMarkup() throws {
        func line(_ text: String, assignee: String = "acme:U1") throws -> String {
            TrackThreadsSummary.latestLine(
                try card(id: 1, assignee: assignee, refs: [("1700000001.0", "Colleague A", text)]))
        }
        XCTAssertEqual(try line("<@U1> can you check?"), "Colleague A: “@you can you check?”")
        XCTAssertEqual(try line("cc <@U2>"), "Colleague A: “cc @someone”")
        XCTAssertEqual(try line("cc <@U2|colleague-b>"), "Colleague A: “cc @colleague-b”")
        XCTAssertEqual(try line("<@U1|owner> ok"), "Colleague A: “@owner ok”")
        // No raw assignee: a bare mention is never "you".
        XCTAssertEqual(try line("<@U1> hi", assignee: "acme:"), "Colleague A: “@someone hi”")
        XCTAssertEqual(try line("see <https://example.com/doc|the doc>"), "Colleague A: “see the doc”")
        XCTAssertEqual(try line("see <https://example.com/doc>"), "Colleague A: “see https://example.com/doc”")
        XCTAssertEqual(try line("in <#C1|general>"), "Colleague A: “in #general”")
        // The event summary goes through the same rendering.
        XCTAssertEqual(
            TrackThreadsSummary.latestLine(try card(id: 2, summary: "<@U1> asked for a date")),
            "@you asked for a date")
        // Unknown markup and stray brackets stay as they are.
        XCTAssertEqual(try line("<!here> a < b > c"), "Colleague A: “<!here> a < b > c”")
    }

    func testNewCountText() throws {
        XCTAssertEqual(TrackThreadsSummary.newCountText(try card(id: 1, newEvents: 3)), "3 new")
        XCTAssertNil(TrackThreadsSummary.newCountText(try card(id: 1)))
    }

    // MARK: - Copy

    func testRowCopyWithNews() throws {
        let tracks = [
            try card(id: 1, text: "Release plan", hasUpdates: true, lastEventDaysAgo: 1, summary: "Date moved"),
            try card(id: 2, text: "Budget", hasUpdates: true, lastEventDaysAgo: 2),
            try card(id: 3, text: "Hiring", hasUpdates: true, lastEventDaysAgo: 3, summary: "Offer sent"),
            try card(id: 4, lastEventDaysAgo: 5),
            try card(id: 5, lastEventDaysAgo: 6)
        ]
        let summary = TrackThreadsSummary.build(tracks: tracks, now: now)
        XCTAssertEqual(summary.rowPreview, "Release plan: Date moved\nBudget")
        XCTAssertEqual(summary.pillCount, 3)
        XCTAssertTrue(summary.isUnread)
        XCTAssertEqual(summary.rowMeta, "2 quiet threads folded")
        XCTAssertEqual(
            summary.paneSubtitle,
            "3 threads with news for you · 2 quiet · scanned after every sync"
        )
        XCTAssertEqual(summary.quietNote, "2 threads have nothing new for you.")
        XCTAssertFalse(summary.showsStopQuiet)
    }

    func testRowCopyWithoutNews() throws {
        let tracks = [try card(id: 1, lastEventDaysAgo: 5), try card(id: 2, lastEventDaysAgo: 6), try card(id: 3, lastEventDaysAgo: 7)]
        let summary = TrackThreadsSummary.build(tracks: tracks, now: now)
        XCTAssertEqual(summary.rowPreview, "Nothing new in 3 threads")
        XCTAssertNil(summary.pillCount)
        XCTAssertFalse(summary.isUnread)
        XCTAssertEqual(summary.rowMeta, "3 quiet threads folded")

        let empty = TrackThreadsSummary.build(tracks: [], now: now)
        XCTAssertEqual(empty.rowPreview, "")
        XCTAssertEqual(empty.rowMeta, "")
        XCTAssertNil(empty.pillCount)
        XCTAssertNil(empty.quietNote)
        XCTAssertFalse(empty.showsStopQuiet)
    }

    func testSingularCopy() throws {
        let one = TrackThreadsSummary.build(tracks: [try card(id: 1, lastEventDaysAgo: 40)], now: now)
        XCTAssertEqual(one.rowPreview, "Nothing new in 1 thread")
        XCTAssertEqual(one.rowMeta, "1 quiet thread folded")
        XCTAssertEqual(
            one.quietNote,
            "1 thread has nothing new for you. 1 of them has been quiet for over 30 days."
        )
        let news = TrackThreadsSummary.build(
            tracks: [try card(id: 1, hasUpdates: true), try card(id: 2, lastEventDaysAgo: 5)], now: now
        )
        XCTAssertEqual(news.paneSubtitle, "1 thread with news for you · 1 quiet · scanned after every sync")
    }

    func testQuietNoteAndButtonOnlyWithOldQuiet() throws {
        let tracks = [
            try card(id: 1, lastEventDaysAgo: 5),
            try card(id: 2, lastEventDaysAgo: 35),
            try card(id: 3, lastEventDaysAgo: 50)
        ]
        let summary = TrackThreadsSummary.build(tracks: tracks, now: now)
        XCTAssertEqual(
            summary.quietNote,
            "3 threads have nothing new for you. 2 of them have been quiet for over 30 days."
        )
        XCTAssertTrue(summary.showsStopQuiet)

        let recent = TrackThreadsSummary.build(tracks: [try card(id: 1, lastEventDaysAgo: 5)], now: now)
        XCTAssertEqual(recent.quietNote, "1 thread has nothing new for you.")
        XCTAssertFalse(recent.showsStopQuiet)
    }
}

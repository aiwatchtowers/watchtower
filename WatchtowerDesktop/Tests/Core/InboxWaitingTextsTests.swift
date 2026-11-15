import XCTest
@testable import WatchtowerCore

/// The pinned lines of Waiting for me and Mail waiting (spec "Waiting for me
/// and Mail waiting", plan Task 13).
final class InboxWaitingTextsTests: XCTestCase {
    private func summary(open: Int, today: Int, senders: Int, share: Int) -> MailWaitingSummary {
        MailWaitingSummary(open: open, today: today, senderCount: senders, topTenShare: share, senders: [])
    }

    func testMailPreview() {
        XCTAssertEqual(
            InboxWaitingTexts.mailPreview(summary(open: 214, today: 9, senders: 40, share: 72)),
            "9 new today. Most of it comes from 10 senders: clear a sender in one press.")
        XCTAssertEqual(
            InboxWaitingTexts.mailPreview(summary(open: 5, today: 2, senders: 3, share: 100)),
            "2 new today. Most of it comes from 3 senders: clear a sender in one press.",
            "fewer than ten senders: K is the sender count")
    }

    func testMailPreviewZeroAndSingular() {
        XCTAssertEqual(
            InboxWaitingTexts.mailPreview(summary(open: 4, today: 0, senders: 1, share: 100)),
            "No new mail today. Most of it comes from 1 sender: clear a sender in one press.")
        XCTAssertEqual(
            InboxWaitingTexts.mailPreview(summary(open: 0, today: 0, senders: 0, share: 0)),
            "No new mail today.", "no sender: the second sentence is dropped")
        XCTAssertEqual(
            InboxWaitingTexts.mailPreview(summary(open: 1, today: 1, senders: 1, share: 100)),
            "1 new today. Most of it comes from 1 sender: clear a sender in one press.")
    }

    func testMostOfItOnlyAboveHalf() {
        XCTAssertEqual(
            InboxWaitingTexts.mailPreview(summary(open: 100, today: 3, senders: 25, share: 51)),
            "3 new today. Most of it comes from 10 senders: clear a sender in one press.")
        XCTAssertEqual(
            InboxWaitingTexts.mailPreview(summary(open: 100, today: 3, senders: 25, share: 50)),
            "3 new today. It comes from 25 senders: clear a sender in one press.")
        XCTAssertEqual(
            InboxWaitingTexts.mailPreview(summary(open: 100, today: 3, senders: 40, share: 30)),
            "3 new today. It comes from 40 senders: clear a sender in one press.")
    }

    func testMailMeta() {
        XCTAssertEqual(InboxWaitingTexts.mailMeta(summary(open: 214, today: 9, senders: 40, share: 72)),
                       "214 open · 72% from 10 senders")
        XCTAssertEqual(InboxWaitingTexts.mailMeta(summary(open: 3, today: 0, senders: 1, share: 100)),
                       "3 open · 100% from 1 sender", "singular")
        XCTAssertEqual(InboxWaitingTexts.mailMeta(summary(open: 0, today: 0, senders: 0, share: 0)),
                       "0 open", "no sender: no share")
    }

    func testMailPaneSubtitle() {
        XCTAssertEqual(InboxWaitingTexts.mailPaneSubtitle(summary(open: 214, today: 9, senders: 40, share: 72)),
                       "214 open · 9 new today · grouped by sender, the busiest first")
        XCTAssertEqual(InboxWaitingTexts.mailPaneSubtitle(.empty),
                       "0 open · 0 new today · grouped by sender, the busiest first")
    }

    func testPeoplePaneSubtitle() {
        XCTAssertEqual(
            InboxWaitingTexts.peoplePaneSubtitle(PeopleWaitingCounts(open: 30, today: 4, week: 20, older: 6)),
            "People in Slack, Jira and Linear · 4 new today · 6 older · mail is in Mail waiting")
        XCTAssertEqual(
            InboxWaitingTexts.peoplePaneSubtitle(.zero),
            "People in Slack, Jira and Linear · 0 new today · 0 older · mail is in Mail waiting")
    }
}

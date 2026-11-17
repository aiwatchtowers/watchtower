import WatchtowerInterface
import XCTest

/// Every Inbox string of `TowerText` is pinned here (mobile Inbox mockups §1–§7).
final class TowerTextInboxTests: XCTestCase {
    private typealias Fix = InboxFixtures

    func testEveryInboxStringIsPinned() {
        XCTAssertEqual(TowerText.loadingInbox(hub: "Acme Mac"), "Getting your Inbox from Acme Mac…")
        XCTAssertEqual(TowerText.loadingInboxMac, "Loading the Inbox…")
        XCTAssertEqual(TowerText.emptyTitle, "Nothing waits for you")
        XCTAssertEqual(TowerText.emptyBody(hub: "Acme Mac"), "New cards arrive after the next sync on Acme Mac.")
        XCTAssertEqual(TowerText.emptyFolderTitle("Team"), "No cards in Team")
        XCTAssertEqual(
            TowerText.emptyFolderBody,
            "Automations routed here write their cards into this folder. Routes are set on your Mac."
        )
        XCTAssertEqual(TowerText.tooOldTitle(hub: "Acme Mac"), "Update Watchtower on Acme Mac")
        XCTAssertEqual(TowerText.tooOldBody(hub: "Acme Mac"), "Watchtower on Acme Mac is too old to send its Inbox to the phone.")
        XCTAssertEqual(TowerText.policyTitle, "The Inbox stays on your Mac")
        XCTAssertEqual(TowerText.policyBody, "Your organization lets this phone see only Workbench.")
        XCTAssertEqual(TowerText.olderCards(42), "42 older cards are on your Mac.")
        XCTAssertEqual(TowerText.onYourMac, "On your Mac")
        XCTAssertEqual(TowerText.approveOnTheMac, "Approve on the Mac")
        XCTAssertEqual(TowerText.propose, "Propose")
        XCTAssertEqual(TowerText.snoozeOneHour, "Snooze 1h")
        XCTAssertEqual(TowerText.makeATask, "Make a Task")
        XCTAssertEqual(TowerText.unsupportedCard, "This card needs a newer Watchtower on this iPhone. Showing its text.")
        XCTAssertEqual(TowerText.needsYourDecision, "Needs your decision")
        XCTAssertEqual(TowerText.sent, "Sent")
        XCTAssertEqual(TowerText.today, "Today")
        XCTAssertEqual(TowerText.earlier, "Earlier")
        XCTAssertEqual(TowerText.justNow, "just now")
        XCTAssertEqual(TowerText.secondsSpan(45), "45 s")
        XCTAssertEqual(TowerText.minutesSpan(6), "6 min")
        XCTAssertEqual(TowerText.hoursSpan(2), "2 h")
        XCTAssertEqual(TowerText.daysSpan(3), "3 d")
        XCTAssertEqual(TowerText.ago("6 min"), "6 min ago")
        XCTAssertEqual(TowerText.discussInChat, "Discuss in Chat")
        XCTAssertEqual(TowerText.handToAgent, "Hand to Agent…")
        XCTAssertEqual(TowerText.goToTarget, "Go to Target")
        XCTAssertEqual(TowerText.deleteTrack, "Delete…")
        XCTAssertEqual(TowerText.activate, "Activate")
        XCTAssertEqual(TowerText.drop, "Drop")
        XCTAssertEqual(TowerText.openLabel(trigger: "mention"), "Open in Slack")
        XCTAssertEqual(TowerText.openLabel(trigger: "jira_assigned"), "Open in Jira")
        XCTAssertEqual(TowerText.openLabel(trigger: "linear_comment_mention"), "Open in Linear")
        XCTAssertEqual(TowerText.openLabel(trigger: "email_received"), "Open in Mail")
        XCTAssertEqual(TowerText.notDone, "Not done")
        XCTAssertEqual(TowerText.stopWatching, "Stop watching")
        XCTAssertEqual(TowerText.thisIPhone, "this iPhone")
        XCTAssertEqual(TowerText.didntFinish, "Didn't finish")
        XCTAssertEqual(TowerText.tryAgain, "Try again")
    }

    func testRefreshFailedFormatsTheTimeInTheGivenZone() throws {
        // 08:14 UTC is 09:14 in Berlin.
        let shownAt = try Fix.date("2026-11-16T08:14:00Z")
        let berlin = try Fix.zone("Europe/Berlin")
        XCTAssertEqual(
            TowerText.refreshFailed(reason: TowerText.daemonDown, shownAt: shownAt, timeZone: berlin, now: try Fix.date("2026-11-16T10:00:00Z")),
            "Couldn't refresh the Inbox: Watchtower's background service isn't running. Showing the list from 09:14."
        )
        XCTAssertEqual(
            TowerText.refreshFailed(reason: "busy", shownAt: shownAt, timeZone: berlin, now: try Fix.date("2026-11-17T10:00:00Z")),
            "Couldn't refresh the Inbox: busy. Showing the list from Nov 16, 09:14."
        )
    }

    func testUnsupportedBannerOnlyWhenBlocksAreUnreadable() throws {
        func banner(_ readable: Bool) throws -> String? {
            InboxCardModel(
                card: try Fix.artifact("o1"), platform: .phone, grants: .all, blocksReadable: readable,
                now: try Fix.date("2026-11-16T12:00:00Z"), timeZone: try Fix.zone("UTC")
            ).unsupportedBanner
        }
        XCTAssertEqual(try banner(false), "This card needs a newer Watchtower on this iPhone. Showing its text.")
        XCTAssertNil(try banner(true))
    }

    func testEveryMockupStringIsPinned() throws {
        let now = try Fix.date("2026-11-16T12:00:00Z")
        let utc = try Fix.zone("UTC")
        // §1
        XCTAssertEqual(TowerText.inThisFolder, "In this folder")
        XCTAssertEqual(TowerText.waitingSubtitle(4, updated: now.addingTimeInterval(-6 * 60), now: now), "4 waiting · updated 6 min ago")
        XCTAssertEqual(TowerText.updatedAgo(now.addingTimeInterval(-12 * 60), now: now), "Updated 12 min ago")
        XCTAssertEqual(TowerText.living, "living")
        XCTAssertEqual(TowerText.runLine(run: 12, at: now.addingTimeInterval(-2 * 3600), now: now), "ϟ run #12 · 2 h ago")
        XCTAssertEqual(TowerText.legacyBriefTitle, "Morning brief · today")
        XCTAssertEqual(TowerText.withNews(2), "2 with news")
        XCTAssertEqual(TowerText.toJudge(1), "1 to judge")
        // §2
        XCTAssertEqual(TowerText.done, "Done")
        XCTAssertEqual(TowerText.snooze, "Snooze")
        XCTAssertEqual(TowerText.hide, "Hide")
        XCTAssertEqual(TowerText.reply, "Reply…")
        XCTAssertEqual(TowerText.snoozeMenu, "Snooze ▸")
        XCTAssertEqual(TowerText.snoozeOneDay, "1 day")
        XCTAssertEqual(TowerText.snoozeThreeDays, "3 days")
        XCTAssertEqual(TowerText.snoozeOneWeek, "1 week")
        XCTAssertEqual(TowerText.snoozePicker, "Snooze ▾")
        XCTAssertEqual(TowerText.openIn("Slack"), "Open in Slack")
        XCTAssertEqual(TowerText.openInDetail("Slack"), "Open in Slack ↗")
        XCTAssertEqual(TowerText.markingDone, "Marking done…")
        XCTAssertEqual(TowerText.snoozing, "Snoozing…")
        XCTAssertEqual(TowerText.hiding, "Hiding…")
        XCTAssertEqual(TowerText.ageBadge(hours: 26), "26 h")
        XCTAssertEqual(TowerText.whyItMatters, "Why it matters")
        XCTAssertEqual(TowerText.thread, "Thread")
        XCTAssertEqual(TowerText.cancel, "Cancel")
        XCTAssertEqual(TowerText.replyIn("#acme-release"), "Reply in #acme-release")
        XCTAssertEqual(
            TowerText.replyNote,
            "The reply goes to Needs approval. Nothing is sent until you approve it there, on this phone or on the Mac."
        )
        // §3
        XCTAssertEqual(TowerText.approve, "Approve")
        XCTAssertEqual(TowerText.reject, "Reject")
        XCTAssertEqual(TowerText.dismiss, "Dismiss")
        XCTAssertEqual(TowerText.approving, "Approving…")
        XCTAssertEqual(TowerText.rejecting, "Rejecting…")
        XCTAssertEqual(
            TowerText.recipeOff(hub: "Acme Mac"),
            "Showing approvals in the standard card — Needs approval is off on Acme Mac."
        )
        XCTAssertEqual(TowerText.editOnYourMac, "Edit on your Mac")
        XCTAssertEqual(TowerText.openDraftOnYourMac, "Open Draft — on your Mac")
        XCTAssertEqual(TowerText.failedPrefix("the team was archived"), "Failed: the team was archived")
        let fourteen = try Fix.date("2026-11-16T14:00:00Z")
        XCTAssertEqual(TowerText.reminderLine(at: fourteen, timeZone: utc), "Reminder · 14:00")
        XCTAssertEqual(TowerText.assistantProposal(at: try Fix.date("2026-11-16T08:55:00Z"), timeZone: utc), "Assistant proposal · 08:55")
        XCTAssertEqual(
            TowerText.replyFromWaiting(device: TowerText.thisIPhone, at: try Fix.date("2026-11-16T09:40:00Z"), timeZone: utc),
            "Reply from Waiting for me · this iPhone · 09:40"
        )
        // §4
        XCTAssertEqual(TowerText.chatOnYourMac, "Chat — on your Mac")
        XCTAssertEqual(TowerText.scrolls, "scrolls ›")
        XCTAssertEqual(TowerText.runNow, "Run Now")
        XCTAssertEqual(TowerText.runningNow, "Running…")
        XCTAssertEqual(TowerText.macOnlyMenuNote, "Edit, Move to Folder, Turn Off and Delete are on your Mac")
        // §5
        XCTAssertEqual(TowerText.stopped(3), "Stopped · 3")
        XCTAssertEqual(TowerText.show, "Show")
        XCTAssertEqual(TowerText.toJudgeHeader(1), "To judge · 1")
        XCTAssertEqual(TowerText.notNow, "Not now")
        XCTAssertEqual(TowerText.recent, "Recent")
        XCTAssertEqual(TowerText.trackHint, "Swipe: Done · Stop watching · long press: Make a Task")
    }

    func testBusyLabelsPerVerb() {
        func ref(_ verb: RefVerb) -> ActRequest {
            ActRequest(requestID: "r", target: "o1", verb: .ref, params: ActParams(refKind: .inboxItem, refID: 1, refVerb: verb))
        }
        func approval(_ verb: ApprovalVerb) -> ActRequest {
            ActRequest(requestID: "r", target: "a1", verb: .approval, params: ActParams(approvalVerb: verb, argsSHA256: "x"))
        }
        let card = ActRequest(requestID: "r", target: "o1", verb: .done, params: ActParams())
        let runNow = ActRequest(requestID: "r", target: "o1", verb: .runNow, params: ActParams())
        XCTAssertEqual(TowerText.busyLabel(for: card), "Marking done…")
        XCTAssertEqual(TowerText.busyLabel(for: ref(.resolve)), "Marking done…")
        XCTAssertEqual(TowerText.busyLabel(for: ref(.done)), "Marking done…")
        XCTAssertEqual(TowerText.busyLabel(for: approval(.approve)), "Approving…")
        XCTAssertEqual(TowerText.busyLabel(for: ref(.approve)), "Approving…")
        XCTAssertEqual(TowerText.busyLabel(for: ref(.snooze)), "Snoozing…")
        XCTAssertEqual(TowerText.busyLabel(for: ref(.dismiss)), "Hiding…")
        XCTAssertEqual(TowerText.busyLabel(for: approval(.reject)), "Rejecting…")
        XCTAssertEqual(TowerText.busyLabel(for: ref(.reject)), "Rejecting…")
        XCTAssertEqual(TowerText.busyLabel(for: runNow), "Running…")
        XCTAssertNil(TowerText.busyLabel(for: approval(.dismiss)))
    }
}

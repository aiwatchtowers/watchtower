import SwiftUI
import UIKit
import WatchtowerDesign
import WatchtowerInterface
import XCTest
@testable import WatchtowerMobile

/// The Inbox tab (mobile Inbox spec §7): second in the tab bar with the orange waiting badge; a pressed row hides
/// on `ok` until the hub's publishes say otherwise, and comes back with Retry on a refusal; Reply… proposes; the
/// Mac-only and ungranted presses say where they go; Didn't confirm is never sent again; unreadable blocks show
/// the card's text.
@MainActor
final class InboxTabWiringTests: XCTestCase {
    private let now = Date()

    private var feed: Feed { DemoSeed.Inbox.feed(now: now) }

    private func card(_ id: String, in center: InboxCenter, grants: Grants = .all) throws -> InboxCardModel {
        let card = try XCTUnwrap(center.feed?.cards.first { $0.id == id })
        return InboxCardModel(
            card: card, platform: .phone, grants: grants, blocksReadable: InboxCardDocument.readable(card), now: now, hidden: center.hidden
        )
    }

    private func actions(
        _ center: InboxCenter, _ card: InboxCardModel, reply: @escaping (InboxRefRowModel) -> Void = { _ in }
    ) -> InboxRefRowActions {
        InboxRefRowActions(center: center, card: card, now: now, onReply: reply) { _ in }
    }

    private let ping = ArtifactRef(kind: .inboxItem, id: 301)

    func testInboxIsTheSecondTab() {
        XCTAssertEqual(RootTabView.Tab.allCases, [.now, .inbox, .workbench, .chats, .calendar])
        XCTAssertEqual(RootTabView.Tab.inbox.title, "Inbox")
        XCTAssertEqual(RootTabView.Tab.inbox.systemImage, "tray")
        let navigation = AppNavigation()
        navigation.inboxPath = [.folder(DemoSeed.Inbox.releaseID)]
        navigation.resetStacks()
        XCTAssertEqual(navigation.inboxPath, [], "a hub switch starts the Inbox at its root")
    }

    func testBadgeIsOrangeSumOfWaiting() throws {
        let center = InboxCenter.detached()
        XCTAssertEqual(center.badge, 0, "nothing read yet")
        center.showForTour(feed: feed)
        XCTAssertEqual(center.badge, 5, "Needs approval's 2 and Waiting for me's 3")
        XCTAssertEqual(RootTabView.Tab.inbox.badge(waitingCount: 9, inboxWaiting: center.badge), 5)
        XCTAssertEqual(RootTabView.Tab.now.badge(waitingCount: 9, inboxWaiting: center.badge), 9)
        XCTAssertEqual(RootTabView.Tab.chats.badge(waitingCount: 9, inboxWaiting: 5), 0)
        RootTabView.configureTabBarAppearance()
        XCTAssertEqual(UITabBar.appearance().standardAppearance.stackedLayoutAppearance.normal.badgeBackgroundColor, .systemOrange)
        // A hidden folder (and what is under it) counts nothing.
        var hidden = feed
        hidden.folders = hidden.folders.map { folder in
            var folder = folder
            if folder.kind == .approvals { folder.hidden = true }
            return folder
        }
        center.showForTour(feed: hidden)
        XCTAssertEqual(center.badge, 3)
    }

    func testOptimisticHideThenTheHubWinsAfterTwoPublishes() async throws {
        let hub = FakeInboxHub(feed: feed)
        let center = try await startedInboxCenter(hub)
        let card = try card(DemoSeed.Inbox.waitingForMe, in: center)
        let row = try XCTUnwrap(card.refRows.first { $0.facts.id == 301 })
        XCTAssertEqual(row.trailingSwipe, [.resolve, .snooze], "swipe left: Done and Snooze")
        XCTAssertEqual(row.leadingSwipe, [.dismiss], "swipe right: Hide")
        let swipes = actions(center, card)(ping)
        XCTAssertEqual(swipes.trailing.map(\.title), [InboxText.done, InboxText.snooze])
        XCTAssertEqual(swipes.leading.map(\.title), [InboxText.hide])

        swipes.trailing[0].action()
        try await poll({ hub.requests.count == 1 }, "Done queued")
        XCTAssertEqual(hub.requests[0].params.refVerb, .resolve)
        XCTAssertEqual(actions(center, card)(ping).busyLabel, InboxText.markingDone, "busy while it goes")
        XCTAssertFalse(actions(center, card)(ping).hidden, "never optimistic success")
        hub.transport.settle(actionID: "act-1", .applied(result: nil))
        try await poll({ center.hidden.isHidden(row.key) }, "ok hides the row")
        XCTAssertTrue(actions(center, try self.card(DemoSeed.Inbox.waitingForMe, in: center))(ping).hidden)

        // The hub still holds the row after one publish: it stays hidden; after the second, the hub wins.
        var reads = center.reads
        center.cardsPublished()
        try await poll({ center.reads > reads }, "the first publish read")
        XCTAssertTrue(center.hidden.isHidden(row.key))
        reads = center.reads
        center.cardsPublished()
        try await poll({ center.reads > reads }, "the second publish read")
        XCTAssertFalse(center.hidden.isHidden(row.key), "two publishes still hold it: it shows again")
        XCTAssertFalse(actions(center, try self.card(DemoSeed.Inbox.waitingForMe, in: center))(ping).hidden)
    }

    func testRefusalBringsTheRowBackWithRetry() async throws {
        let hub = FakeInboxHub(feed: feed)
        let center = try await startedInboxCenter(hub)
        let card = try card(DemoSeed.Inbox.waitingForMe, in: center)
        let snooze = ArtifactRef(kind: .inboxItem, id: 302)

        actions(center, card)(snooze).trailing[1].action()
        try await poll({ hub.requests.count == 1 }, "Snooze queued")
        XCTAssertNotNil(hub.requests[0].params.until, "a snooze carries its end")
        let sentence = "Couldn't snooze: the item was already closed."
        hub.transport.settle(actionID: "act-1", .refused(code: .changed, sentence: sentence))
        try await poll({ actions(center, card)(snooze).error != nil }, "the refusal reached the row")

        let refused = actions(center, card)(snooze)
        XCTAssertFalse(refused.hidden, "a refusal never hides the row")
        XCTAssertEqual(refused.error, sentence)
        XCTAssertEqual(refused.retry?.title, InboxText.retry)
        refused.retry?.action()
        try await poll({ hub.requests.count == 2 }, "Retry sends the press again")
        XCTAssertEqual(hub.requests[1].params.refVerb, .snooze)
    }

    func testReplyOpensASheetWithPropose() async throws {
        let hub = FakeInboxHub(feed: feed)
        let center = try await startedInboxCenter(hub)
        let card = try card(DemoSeed.Inbox.waitingForMe, in: center)
        var opened: InboxRefRowModel?
        let menu = actions(center, card) { opened = $0 }(ping).menu
        XCTAssertEqual(
            menu.map(\.title),
            [InboxText.openIn("Slack"), InboxText.reply, InboxText.done, InboxText.hide, InboxText.snooze,
             InboxPhoneText.macOnlyLabel(InboxText.discussInChat), InboxPhoneText.macOnlyLabel(InboxText.handToAgent)]
        )
        XCTAssertEqual(menu[4].children.map(\.title), [InboxText.snoozeOneDay, InboxText.snoozeThreeDays, InboxText.snoozeOneWeek])
        menu[1].action()
        let row = try XCTUnwrap(opened, "Reply… opens the sheet for its row")
        XCTAssertEqual(row.facts.id, 301)

        XCTAssertFalse(InboxReplySheet.canPropose("  \n"))
        XCTAssertTrue(InboxReplySheet.canPropose("Signing off now"))
        let send = Task { await InboxReplySheet.send("Signing off now", center: center, cardID: card.id, row: row) }
        try await poll({ hub.requests.count == 1 }, "Propose queued")
        XCTAssertEqual(hub.requests[0].verb, .replyPropose)
        XCTAssertEqual(hub.requests[0].params.text, "Signing off now")
        XCTAssertEqual(hub.requests[0].params.refID, 301)
        hub.transport.settle(actionID: "act-1", .applied(result: nil))
        await send.value
        XCTAssertFalse(center.hidden.isHidden(row.key), "a proposal keeps the row: it waits for the approval")
        let detail = InboxRowDetailModel(row: row, document: try XCTUnwrap(Self.document(card)))
        XCTAssertEqual(InboxText.replyIn(detail.place), "Reply in #acme-release")
    }

    func testMacOnlyActionsShowOnYourMac() throws {
        let center = InboxCenter.detached()
        center.showForTour(feed: feed)
        let roundup = try card(DemoSeed.Inbox.roundup, in: center)
        let chat = InboxCardButtons.state(2, roundup, center: center)
        XCTAssertFalse(chat.enabled)
        XCTAssertEqual(chat.label, "Chat — on your Mac")
        XCTAssertTrue(InboxCardButtons.state(0, roundup, center: center).enabled, "a reply works from the phone")

        let waiting = try card(DemoSeed.Inbox.waitingForMe, in: center)
        let menu = actions(center, waiting)(ping).menu
        let handOff = try XCTUnwrap(menu.first { $0.title.hasPrefix(InboxText.handToAgent) })
        XCTAssertFalse(handOff.enabled)
        XCTAssertEqual(handOff.title, "\(InboxText.handToAgent) — on your Mac")
    }

    func testApproveWithoutPermissionsGrantIsDisabledWithItsLine() throws {
        let center = InboxCenter.detached()
        center.showForTour(feed: feed)
        let proposal = try XCTUnwrap(feed.cards.first { $0.id == DemoSeed.Inbox.slackProposal })
        let without = InboxApprovalModel(card: proposal, platform: .phone, grants: Grants(permissions: false, typing: true), now: now)
        XCTAssertFalse(without.canApprove)
        XCTAssertEqual(without.approveNote, InboxText.approveOnTheMac)
        XCTAssertTrue(without.canReject, "Reject needs no grant")
        let with = InboxApprovalModel(card: proposal, platform: .phone, grants: .all, now: now)
        XCTAssertTrue(with.canApprove)
        XCTAssertNil(with.approveNote)
        XCTAssertEqual(with.approve(requestID: "r").params.argsSHA256, "args-101", "Approve pins the arguments drawn")

        // The card draws without the grant (the disabled line in place of Approve).
        let model = try card(DemoSeed.Inbox.slackProposal, in: center, grants: Grants(permissions: false, typing: false))
        let view = InboxApprovalCard(center: center, card: model, grants: Grants(permissions: false, typing: false), now: now).frame(width: 393)
        XCTAssertNotNil(ImageRenderer(content: view).uiImage)
        // A target press needs the grant too.
        let roundup = try card(DemoSeed.Inbox.roundup, in: center, grants: Grants(permissions: false, typing: true))
        XCTAssertFalse(InboxCardButtons.state(1, roundup, center: center).enabled)
    }

    func testDidntConfirmShowsRefresh() async throws {
        let hub = FakeInboxHub(feed: feed)
        let center = try await startedInboxCenter(hub)
        let roundup = try card(DemoSeed.Inbox.roundup, in: center)
        let key = InboxPressKey.button(roundup.card, index: 0)
        let reply = try XCTUnwrap(roundup.actions.first)
        let press = Task {
            await center.press(key, on: InboxCardDetailView.buttonRow(roundup.id, 0), hides: false) { roundup.press(reply, requestID: $0) }
        }
        try await poll({ hub.requests.count == 1 }, "the press queued")
        XCTAssertEqual(hub.requests[0].params.actionKind, "reply", "every press names its button's kind")
        hub.transport.settle(actionID: "act-1", .unknown)
        await press.value

        XCTAssertEqual(InboxCardButtons.state(0, roundup, center: center).note, InboxText.didntConfirmPhone)
        XCTAssertEqual(InboxText.didntConfirmPhone, "Didn't confirm — check on the Mac.")
        XCTAssertEqual(InboxText.refresh, "Refresh")
        let reads = center.reads
        await center.refresh()
        XCTAssertGreaterThan(center.reads, reads, "Refresh reads the Inbox again")
        XCTAssertNil(center.state(key), "and the owner may press again")
    }

    func testCardMenuOffersRunNow() async throws {
        let hub = FakeInboxHub(feed: feed)
        let center = try await startedInboxCenter(hub)
        let roundup = try card(DemoSeed.Inbox.roundup, in: center)
        XCTAssertNotNil(roundup.card.automation, "an automation's card offers Run Now")
        XCTAssertEqual(InboxText.runNow, "Run Now")
        XCTAssertEqual(InboxText.macOnlyMenuNote, "Edit, Move to Folder, Turn Off and Delete are on your Mac")
        let key = InboxPressKey.card(roundup.card, .runNow)

        let first = Task { await center.press(key, on: roundup.id, hides: false) { roundup.request(.runNow, requestID: $0) } }
        try await poll({ hub.requests.count == 1 }, "Run Now queued")
        await center.press(key, on: roundup.id, hides: false) { roundup.request(.runNow, requestID: $0) }
        XCTAssertEqual(hub.requests.count, 1, "a tap while busy sends nothing")
        hub.transport.settle(actionID: "act-1", .unknown)
        await first.value
        XCTAssertEqual(center.rowState(roundup.id)?.state, .unknown)

        await center.press(key, on: roundup.id, hides: false) { roundup.request(.runNow, requestID: $0) }
        XCTAssertEqual(hub.requests.count, 1, "non-idempotent: a tap while unknown sends nothing")
        XCTAssertEqual(InboxPhoneText.runNowTitle("Weekly report"), "Run “Weekly report” now")
    }

    func testUnreadableBlocksShowTheUnsupportedBanner() throws {
        let center = InboxCenter.detached()
        center.showForTour(feed: feed)
        let board = try card(DemoSeed.Inbox.sprintBoard, in: center)
        XCTAssertEqual(board.unsupportedBanner, InboxText.unsupportedCard)
        XCTAssertEqual(InboxText.unsupportedCard, "This card needs a newer Watchtower on this iPhone. Showing its text.")
        XCTAssertTrue(board.card.body.hasPrefix("Sprint 47"), "the card's text is what shows")
        XCTAssertNil(try card(DemoSeed.Inbox.roundup, in: center).unsupportedBanner)
        let header = InboxCardHeader(board, now: now)
        XCTAssertEqual(header.line, "ϟ Sprint board · \(InboxText.updatedAgo(now.addingTimeInterval(-180), now: now))")
    }

    private static func document(_ card: InboxCardModel) -> ArtifactDocument? {
        if case let .document(document) = ArtifactDocument.decode(card.card.blocks) { return document }
        return nil
    }
}

import SwiftUI
import WatchtowerInterface
import XCTest
@testable import WatchtowerMobile

/// The Inbox's frames of the tour (mobile Inbox mockups §1–§6): one named shot per mockup frame, light and dark.
/// `DemoTourTests.testEveryInboxMockupFrameHasAShot` pins the list.
enum InboxTourFrames {
    /// Mockup §, frame → shot.
    static let all: [(frame: String, slug: String)] = [
        ("1 Root — dark / light", "inbox-root"),
        ("1 Owner folder (pushed)", "inbox-owner-folder"),
        ("2 List + one row swiped", "inbox-waiting-swiped"),
        ("2 Busy row + failed row with Retry", "inbox-row-busy-failed"),
        ("2c Row detail", "inbox-row-detail"),
        ("2d Reply… sheet", "inbox-reply-sheet"),
        ("3 Needs approval", "inbox-approvals"),
        ("3 Approve — sending, then changed on the Mac", "inbox-approve-changed"),
        ("4 Feed card", "inbox-artifact"),
        ("4 Living card with a table", "inbox-artifact-table"),
        ("4 Card ⋯ menu (Run Now)", "inbox-card-menu"),
        ("4 Unsupported / unreadable card", "inbox-card-unsupported"),
        ("5 Morning brief", "inbox-legacy-brief"),
        ("5 Track my threads", "inbox-legacy-tracks"),
        ("5 Idea finder", "inbox-legacy-ideas"),
        ("6 Loading", "inbox-loading"),
        ("6 Empty", "inbox-empty"),
        ("6 Empty folder", "inbox-empty-folder"),
        ("6 Mac away + queued and not delivered", "inbox-mac-away"),
        ("6 Old Mac", "inbox-too-old"),
        ("6 Organization policy", "inbox-policy"),
        ("6 Didn't confirm", "inbox-didnt-confirm"),
        ("6 Older cards on the Mac", "inbox-older-cards")
    ]
}

extension ScreenshotTourTests {
    /// One Inbox frame: the tab over its own center and inputs, at `path`; or a view on its own (the Reply… sheet).
    struct InboxFrame {
        var shot: InboxShot
        var path: [InboxRoute] = []
        var alone: AnyView?
    }

    /// Every Inbox frame in the full app (the tab bar with its badge), light and dark; the Reply… sheet on its own.
    /// The Mac-away frame goes last, after `fallAsleep` made the demo Mac asleep, so its chip reads it.
    func captureInbox(host: ScreenshotHost, fallAsleep: () async throws -> Void) async throws -> [ScreenshotHost.IndexRow] {
        let env = host.env
        let now = Date()
        let away = "inbox-mac-away"
        var rows: [String: ScreenshotHost.IndexRow] = [:]
        for (frame, slug) in InboxTourFrames.all.sorted(by: { ($0.slug == away ? 1 : 0) < ($1.slug == away ? 1 : 0) }) {
            if slug == away { try await fallAsleep() }
            var made = Self.inboxFrame(slug, now: now)
            if slug == away, let asOf = env.macReachability(now: now).asOf {
                // "as of" agrees with the chip's last seen.
                made.shot.inputs.macAway = asOf
            }
            if let alone = made.alone {
                try await host.capture(slug, alone)
            } else {
                env.navigation.tab = .inbox
                env.navigation.inboxPath = made.path
                try await host.capture(slug, RootTabView(inboxShot: made.shot), settle: .milliseconds(1_500))
            }
            rows[slug] = ScreenshotHost.IndexRow(
                number: slug, view: "InboxTabView", source: "Features/Inbox/", reached: "mockup §\(frame), light/dark"
            )
        }
        env.navigation.inboxPath = []
        return InboxTourFrames.all.compactMap { rows[$0.slug] }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func inboxFrame(_ slug: String, now: Date) -> InboxFrame {
        typealias Seed = DemoSeed.Inbox
        let center = InboxCenter.detached()
        center.showForTour(feed: Seed.feed(now: now))
        var frame = InboxFrame(shot: InboxShot(
            center: center, inputs: InboxInputs(capability: "on", hubName: DemoSeed.macName, grants: .all, now: now)
        ))
        let waiting = Seed.waitingForMe
        let ping = "inbox_item:301"
        let quick = "inbox_item:302"
        switch slug {
        case "inbox-owner-folder":
            frame.path = [.folder(Seed.releaseID)]
        case "inbox-waiting-swiped":
            frame.path = [.card(waiting)]
            frame.shot.revealed = [quick: .trailing]
        case "inbox-row-busy-failed":
            frame.path = [.card(waiting)]
            let done = ActRequest(
                requestID: "r1", target: waiting, verb: .ref, params: ActParams(refKind: .inboxItem, refID: 301, refVerb: .resolve))
            let snooze = ActRequest(
                requestID: "r2", target: waiting, verb: .ref, params: ActParams(refKind: .inboxItem, refID: 302, refVerb: .snooze))
            center.showForTour(feed: Seed.feed(now: now), rows: [
                ping: .busy(done),
                quick: .refused("Couldn't snooze: the item was already closed on the Mac.", .resend(snooze, dismiss: nil))
            ])
        case "inbox-row-detail":
            frame.path = [.card(waiting), .row(cardID: waiting, row: ping)]
        case "inbox-reply-sheet":
            let card = Seed.feed(now: now).cards.first { $0.id == waiting }
            let model = card.map { InboxCardModel(card: $0, platform: .phone, grants: .all, blocksReadable: true, now: now) }
            if let row = model?.refRows.first {
                frame.alone = AnyView(InboxReplySheet(
                    center: center, cardID: waiting, row: row, place: "#acme-release",
                    text: "Signing off now — docs link is the only open item, fine to tag after colleague C's fix."
                ))
            }
        case "inbox-approvals":
            frame.path = [.folder(Seed.approvalsID)]
        case "inbox-approve-changed":
            frame.path = [.folder(Seed.approvalsID)]
            let feed = Seed.feed(now: now)
            if let slack = feed.cards.first(where: { $0.id == Seed.slackProposal }), let reply = feed.cards.first(where: { $0.id == Seed.replyProposal }) {
                let sending = ActRequest(requestID: "r3", target: slack.id, verb: .approval, params: ActParams(approvalVerb: .approve))
                let changed = ActRequest(requestID: "r4", target: reply.id, verb: .approval, params: ActParams(approvalVerb: .approve))
                center.showForTour(feed: feed, rows: [
                    slack.id: .busy(sending),
                    reply.id: .refused("This proposal changed on the Mac — look again before approving.", .resend(changed, dismiss: nil))
                ])
            }
        case "inbox-artifact":
            frame.path = [.card(Seed.roundup)]
        case "inbox-artifact-table":
            frame.path = [.folder(Seed.releaseID), .card(Seed.checklist)]
        case "inbox-card-menu":
            frame.path = [.card(Seed.roundup)]
            frame.shot.showsCardMenu = true
        case "inbox-card-unsupported":
            frame.path = [.folder(Seed.blockersID), .card(Seed.sprintBoard)]
        case "inbox-legacy-brief":
            frame.path = [.card(Seed.brief)]
        case "inbox-legacy-tracks":
            frame.path = [.card(Seed.tracks)]
        case "inbox-legacy-ideas":
            frame.path = [.card(Seed.ideas)]
        case "inbox-loading":
            center.showForTour(feed: nil)
        case "inbox-empty":
            let root = Seed.folder(Seed.rootID, .root, "Inbox", parent: nil, position: 0, count: 0)
            center.showForTour(feed: Feed(v: 1, builtAt: "", folders: [root], cards: []))
        case "inbox-empty-folder":
            frame.path = [.folder(Seed.teamID)]
        case "inbox-mac-away":
            frame.shot.inputs.macAway = now.addingTimeInterval(-2_400)
            center.showForTour(
                feed: Seed.feed(now: now),
                outbox: InboxOutboxModel(
                    waitingTitle: InboxPhoneText.waitingToSend(2),
                    waitingLine: InboxPhoneText.appliesWhenAwake(verbs: [InboxText.done, InboxText.approve], hub: DemoSeed.macName),
                    undeliveredTitle: InboxPhoneText.notDeliveredCount(1)
                )
            )
        case "inbox-too-old":
            frame.shot.inputs.capability = nil
        case "inbox-policy":
            frame.shot.inputs.capability = InboxTabState.policyOffCapability
        case "inbox-didnt-confirm":
            let feed = Seed.reportsFeed(now: now, more: 0)
            frame.path = [.folder(Seed.reportsID)]
            if let report = feed.cards.first(where: { $0.id == Seed.weeklyReport }) {
                center.showForTour(feed: feed, rows: [report.id: .unknown])
            }
        case "inbox-older-cards":
            frame.path = [.folder(Seed.reportsID)]
            center.showForTour(feed: Seed.reportsFeed(now: now, more: 42))
        default:
            break
        }
        return frame
    }
}

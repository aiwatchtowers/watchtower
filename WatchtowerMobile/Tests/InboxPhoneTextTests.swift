import Foundation
import WatchtowerInterface
import WatchtowerKit
@testable import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Every string the phone's Inbox draws on its own (`InboxPhoneText`), and the models that put them together: the
/// card rows' meta lines, the card screen's header, the row detail, the outbox lines and the plan times.
@MainActor
final class InboxPhoneTextTests: XCTestCase {
    private let now = Date()

    func testEveryPhoneString() {
        XCTAssertEqual(InboxPhoneText.tabTitle, "Inbox")
        XCTAssertEqual(InboxPhoneText.rootHeader, "Inbox")
        XCTAssertEqual(InboxPhoneText.needsApproval, "Needs approval")
        XCTAssertEqual(InboxPhoneText.notDelivered(hub: "Acme Mac"), "Not delivered — Acme Mac didn't get it.")
        XCTAssertEqual(InboxPhoneText.notDelivered(hub: ""), "Not delivered — your tower didn't get it.")
        XCTAssertEqual(InboxPhoneText.refusedFallback, "Watchtower refused this action.")
        XCTAssertEqual(InboxPhoneText.notOnThePhone, "This isn't available on the phone.")
        XCTAssertEqual(InboxPhoneText.messageLink, "Open the message")
        XCTAssertEqual(InboxPhoneText.asOf("40 min ago"), "as of 40 min ago")
        XCTAssertEqual(InboxPhoneText.more, "More")
        XCTAssertEqual(InboxPhoneText.macOnlyLabel("Chat"), "Chat — on your Mac")
        XCTAssertEqual(InboxPhoneText.macOnlyLabel("Chat", note: nil), "Chat")
        XCTAssertEqual(InboxPhoneText.openInDetail("Open in Slack"), "Open in Slack ↗")
        XCTAssertEqual(InboxPhoneText.runNowTitle("Weekly report"), "Run “Weekly report” now")
        XCTAssertEqual(InboxPhoneText.waitingToSend(2), "Waiting to send · 2")
        XCTAssertEqual(InboxPhoneText.notDeliveredCount(1), "Not delivered · 1")
        XCTAssertEqual(
            InboxPhoneText.appliesWhenAwake(verbs: ["Done", "Approve"], hub: "Acme Mac"), "Done · Approve. They apply when Acme Mac wakes.")
        XCTAssertEqual(InboxPhoneText.appliesWhenAwake(verbs: [], hub: ""), "They apply when your tower wakes.")
        XCTAssertEqual(InboxPhoneText.approvalsSummary(["Send a Slack message"]), "Send a Slack message")
        XCTAssertEqual(
            InboxPhoneText.approvalsSummary(["Send a Slack message", "Create a Jira issue", "Reply", "Remind"]),
            "Send a Slack message · Create a Jira issue · 2 more"
        )
        let at = now.addingTimeInterval(-7_200)
        XCTAssertEqual(
            InboxPhoneText.cardHeader(automation: "Weekly mail roundup", run: 12, at: at, living: false, now: now),
            "ϟ Weekly mail roundup · run #12 · 2 h ago"
        )
        XCTAssertEqual(
            InboxPhoneText.cardHeader(automation: "Release checklist", run: 3, at: now.addingTimeInterval(-720), living: true, now: now),
            "ϟ Release checklist · Updated 12 min ago"
        )
    }

    func testTheOutboxLineNamesEachQueuedVerb() throws {
        func queued(_ request: ActRequest) throws -> PendingAction {
            PendingAction(
                id: request.requestID,
                action: ActionRequestPayload(
                    id: request.requestID, kind: .inboxAct, entityID: nil, params: try HubTransport.wireParams(request), createdAt: now,
                    deviceID: "phone"),
                entityRecordName: nil, createdAt: now, state: .pending, errorMessage: nil, reason: nil, result: nil, echoStatus: nil,
                actionSeq: 1, epoch: 1, delivery: .queued, undeliveredReason: nil
            )
        }
        let done = ActRequest(requestID: "a", target: "o201", verb: .ref, params: ActParams(refKind: .inboxItem, refID: 1, refVerb: .resolve))
        let approve = ActRequest(requestID: "b", target: "a101", verb: .approval, params: ActParams(approvalVerb: .approve))
        let read = ActRequest(requestID: "c", target: "o205", verb: .read, params: ActParams(contentHash: "h"))
        let model = InboxOutboxModel(queued: [try queued(done), try queued(approve), try queued(read)], undelivered: [], hubName: "Acme Mac")
        XCTAssertEqual(model.waitingTitle, "Waiting to send · 3")
        XCTAssertEqual(model.waitingLine, "Done · Approve. They apply when Acme Mac wakes.")
        XCTAssertNil(model.undeliveredTitle)
        XCTAssertEqual(InboxOutboxModel(queued: [], undelivered: [], hubName: ""), InboxOutboxModel(waitingLine: "They apply when your tower wakes."))
        // The Not delivered list names an Inbox press by its verb.
        let item = OutboxItem(
            id: "a", kind: .inboxAct, entityRecordName: nil, params: try HubTransport.wireParams(done), createdAt: now, seq: 1,
            delivery: .undelivered, reason: .refused)
        XCTAssertEqual(ActionSummary.text(for: item, snapshot: WorkbenchReplicaSnapshot()), "Done in the Inbox")
        XCTAssertEqual(InboxPhoneText.inboxAction, "An Inbox action")
    }

    func testCardRowsMetaLines() throws {
        let feed = DemoSeed.Inbox.feed(now: now)
        func row(_ id: String, preview: Bool = false) throws -> InboxCardRowModel {
            let card = try XCTUnwrap(feed.cards.first { $0.id == id })
            let model = InboxCardModel(card: card, platform: .phone, grants: .all, blocksReadable: true, now: now)
            return InboxCardRowModel(model, now: now, showsPreview: preview)
        }
        let waiting = try row(DemoSeed.Inbox.waitingForMe)
        XCTAssertEqual(waiting.meta, "3 waiting · updated 6 min ago")
        XCTAssertEqual(waiting.waiting, 3)
        XCTAssertTrue(waiting.unread)
        XCTAssertEqual(try row(DemoSeed.Inbox.roundup).meta, "ϟ run #12 · 2 h ago")
        XCTAssertEqual(try row(DemoSeed.Inbox.checklist).meta, "Updated 12 min ago · living")
        XCTAssertNil(try row(DemoSeed.Inbox.checklist).preview, "the root shows no preview")
        XCTAssertEqual(try row(DemoSeed.Inbox.checklist, preview: true).preview, "4 of 9 items green · 2 blockers")
        XCTAssertNil(try row(DemoSeed.Inbox.roundup).waiting)
    }

    func testPlanTimesAreThePhonesOwn() throws {
        var card = try XCTUnwrap(DemoSeed.Inbox.feed(now: now).cards.first { $0.id == DemoSeed.Inbox.brief })
        card.legacy = LegacySection(kind: .morningBrief, items: [
            LegacyItem(refKind: .planItem, id: 7, title: "Standup", subtitle: "", preview: "", stamp: "2026-11-16T08:30:00Z", end: "",
                       unread: false, high: false, stopped: false, done: false, date: "")
        ], attention: [])
        XCTAssertEqual(InboxPlanTime.start(of: 7, in: card, timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))), "09:30")
        XCTAssertEqual(InboxPlanTime.start(of: 7, in: card, timeZone: try XCTUnwrap(TimeZone(identifier: "America/New_York"))), "03:30")
        XCTAssertNil(InboxPlanTime.start(of: 8, in: card, timeZone: .current))
    }

    func testRowDetailReadsTheDrawnRow() throws {
        let feed = DemoSeed.Inbox.feed(now: now)
        let card = try XCTUnwrap(feed.cards.first { $0.id == DemoSeed.Inbox.waitingForMe })
        let model = InboxCardModel(card: card, platform: .phone, grants: .all, blocksReadable: true, now: now)
        let row = try XCTUnwrap(model.refRows.first)
        guard case let .document(document) = ArtifactDocument.decode(card.blocks) else { return XCTFail("the demo card reads") }
        let detail = InboxRowDetailModel(row: row, document: document)
        XCTAssertEqual(detail.who, "Colleague A")
        XCTAssertEqual(detail.initials, "CA")
        XCTAssertEqual(detail.place, "#acme-release")
        XCTAssertEqual(detail.badge?.text, "26 h")
        XCTAssertEqual(detail.openTitle, "Open in Slack ↗")
        XCTAssertTrue(detail.text.hasPrefix("Can you sign off"))
    }

    func testSnoozeEndsAreUTCSeconds() {
        let start = Date(timeIntervalSince1970: 1_763_280_000) // 2025-11-16T08:00:00Z
        XCTAssertEqual(InboxSnooze.hour.until(from: start), "2025-11-16T09:00:00Z")
        XCTAssertEqual(InboxSnooze.day.until(from: start), "2025-11-17T08:00:00Z")
        XCTAssertEqual(InboxSnooze.menu.map(\.label), ["1 day", "3 days", "1 week"])
        XCTAssertEqual(InboxSnooze.hour.label, "Snooze 1h")
    }
}

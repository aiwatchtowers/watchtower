import WatchtowerInterface
import XCTest

final class InboxRefRowModelTests: XCTestCase {
    private typealias Fix = InboxFixtures

    private func row(_ kind: RefKind, platform: Platform = .phone, grants: Grants = .all, reply: Bool = false) -> InboxRefRowModel {
        InboxRefRowModel(facts: Fix.ref(kind, 7, reply: reply), platform: platform, grants: grants)
    }

    func testSwipesPerKind() {
        let item = row(.inboxItem)
        XCTAssertEqual(item.leadingSwipe, [.dismiss])
        XCTAssertEqual(item.trailingSwipe, [.resolve, .snooze])
        XCTAssertEqual(item.trailingSwipe.map { InboxRefRowModel.label($0, kind: .inboxItem) }, ["Done", "Snooze"])
        XCTAssertEqual(InboxRefRowModel.label(.dismiss, kind: .inboxItem), "Hide")

        let track = row(.track)
        XCTAssertEqual(track.leadingSwipe, [])
        XCTAssertEqual(track.trailingSwipe, [.done, .stop])
        XCTAssertEqual(track.trailingSwipe.map { InboxRefRowModel.label($0, kind: .track) }, ["Done", "Stop watching"])

        let reminder = row(.reminder)
        XCTAssertEqual(reminder.trailingSwipe, [.done, .snooze])
        XCTAssertEqual(reminder.trailingSwipe.map { InboxRefRowModel.label($0, kind: .reminder) }, ["Done", "Snooze 1h"])

        let idea = row(.idea)
        XCTAssertEqual(idea.leadingSwipe, [.reject])
        XCTAssertEqual(idea.trailingSwipe, [.approve, .notNow])

        let plan = row(.planItem)
        XCTAssertEqual(plan.trailingSwipe, [.check])
        XCTAssertEqual(plan.leadingSwipe, [])
    }

    func testMenuHoldsEveryVerbIncludingMakeATask() {
        XCTAssertEqual(row(.inboxItem).menu, [.resolve, .snooze, .dismiss])
        XCTAssertEqual(row(.track).menu, [.done, .stop, .makeTask])
        XCTAssertEqual(InboxRefRowModel.label(.makeTask, kind: .track), "Make a Task")
        XCTAssertEqual(row(.reminder).menu, [.done, .snooze])
        XCTAssertEqual(row(.idea).menu, [.approve, .notNow, .reject])
        XCTAssertEqual(row(.planItem).menu, [.check, .uncheck])
        // Make a Task is an owner gesture: without permissions the phone leaves it out.
        XCTAssertEqual(row(.track, grants: Grants(permissions: false, typing: true)).menu, [.done, .stop])
        XCTAssertEqual(row(.track, platform: .mac, grants: Grants(permissions: false, typing: false)).menu, [.done, .stop, .makeTask])
    }

    func testRequestCarriesRefKindIDAndVerb() {
        let request = row(.inboxItem).request(.snooze, cardID: "o1", requestID: "r1", until: "2026-11-17T09:00:00Z")
        XCTAssertEqual(request, ActRequest(
            requestID: "r1", target: "o1", verb: .ref,
            params: ActParams(refKind: .inboxItem, refID: 7, refVerb: .snooze, until: "2026-11-17T09:00:00Z")
        ))
        let task = row(.track).request(.makeTask, cardID: "tracks", requestID: "r2", eventID: 42)
        XCTAssertEqual(task.params.eventID, 42)
        XCTAssertEqual(task.params.refKind, .track)
    }

    func testReplyNeedsTypingOnThePhone() {
        XCTAssertTrue(row(.inboxItem, reply: true).canReply)
        XCTAssertFalse(row(.inboxItem, grants: Grants(permissions: true, typing: false), reply: true).canReply)
        XCTAssertFalse(row(.inboxItem).canReply)
        let request = row(.inboxItem, reply: true).replyRequest(text: "On it", cardID: "o1", requestID: "r3")
        XCTAssertEqual(request, ActRequest(
            requestID: "r3", target: "o1", verb: .replyPropose, params: ActParams(text: "On it", refID: 7)
        ))
    }
}

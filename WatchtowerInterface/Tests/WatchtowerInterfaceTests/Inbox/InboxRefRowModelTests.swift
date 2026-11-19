import Foundation
import WatchtowerInterface
import XCTest

final class InboxRefRowModelTests: XCTestCase {
    private typealias Fix = InboxFixtures
    private let noGrants = Grants(permissions: false, typing: false)

    private func row(
        _ facts: RefFacts,
        platform: Platform = .phone,
        grants: Grants = .all
    ) -> InboxRefRowModel {
        InboxRefRowModel(facts: facts, platform: platform, grants: grants)
    }

    private func idea(_ kind: String, _ status: String, waits: Bool = false) -> RefFacts {
        Fix.ref(.idea, 7, waits: waits) {
            $0.ideaKind = kind
            $0.ideaStatus = status
        }
    }

    func testSwipesPerKind() {
        let item = row(Fix.ref(.inboxItem, 7))
        XCTAssertEqual(item.leadingSwipe, [.dismiss])
        XCTAssertEqual(item.trailingSwipe, [.resolve, .snooze])

        let track = row(Fix.ref(.track, 7))
        XCTAssertEqual(track.leadingSwipe, [])
        XCTAssertEqual(track.trailingSwipe, [.done, .stop])

        let reminder = row(Fix.ref(.reminder, 7))
        XCTAssertEqual(reminder.trailingSwipe, [.done, .snooze])
        XCTAssertEqual(reminder.buttons.map(\.label), ["Done", "Snooze 1h"])

        let judged = row(idea("idea", "proposed", waits: true))
        XCTAssertEqual(judged.leadingSwipe, [.reject])
        XCTAssertEqual(judged.trailingSwipe, [.approve, .notNow])
        // A note awaiting a verdict has no Not now.
        XCTAssertEqual(row(idea("note", "proposed", waits: true)).trailingSwipe, [.approve])

        XCTAssertEqual(row(Fix.ref(.planItem, 7)).trailingSwipe, [.check])
    }

    /// The Mac's `InboxRowActionsView` buttons, in its order.
    func testButtonsAreTheMacRowButtons() {
        var item = Fix.ref(.inboxItem, 7, reply: true)
        item.link = "https://acme.example.com/browse/ACME-1"
        item.triggerType = "jira_assigned"
        XCTAssertEqual(
            row(item, platform: .mac).buttons.map(\.label),
            ["Open in Jira", "Reply…", "Done", "Hide", "Snooze", "Discuss in Chat", "Hand to Agent…"]
        )
        XCTAssertEqual(row(Fix.ref(.inboxItem, 7), platform: .mac).buttons.map(\.label),
                       ["Done", "Hide", "Snooze", "Discuss in Chat", "Hand to Agent…"])

        XCTAssertEqual(row(Fix.ref(.track, 7), platform: .mac).buttons.map(\.label), ["Done", "Stop watching", "Make a Task"])
        let custom = Fix.ref(.track, 7) {
            $0.custom = true
            $0.linkedTargetID = 4
        }
        XCTAssertEqual(row(custom, platform: .mac).buttons.map(\.label), ["Done", "Stop watching", "Go to Target", "Delete…"])
        XCTAssertEqual(row(custom, platform: .mac).buttons.map(\.inMore), [false, true, true, true])
        let unlinked = Fix.ref(.track, 7) { $0.custom = true }
        XCTAssertEqual(row(unlinked, platform: .mac).buttons.map(\.label), ["Done", "Stop watching", "Delete…"])
    }

    /// `InboxRowActionsContent.ideaButtons`, case by case.
    func testIdeaButtonsFollowTheMac() {
        func labels(_ kind: String, _ status: String, waits: Bool = false) -> [String] {
            row(idea(kind, status, waits: waits), platform: .mac).buttons.map(\.label)
        }
        XCTAssertEqual(labels("idea", "proposed", waits: true), ["Approve", "Make a Task", "Not now", "Reject"])
        XCTAssertEqual(labels("note", "proposed", waits: true), ["Approve", "Reject"])
        XCTAssertEqual(labels("decision", "proposed", waits: true), ["Approve", "Not now", "Reject"])
        XCTAssertEqual(labels("decision", "rejected"), ["Activate"])
        XCTAssertEqual(labels("decision", "active"), [])
        XCTAssertEqual(labels("idea", "active"), ["Make a Task", "Not now", "Drop"])
        XCTAssertEqual(labels("idea", "not_now"), ["Activate", "Make a Task", "Drop"])
        XCTAssertEqual(labels("note", "active"), ["Drop"])
        XCTAssertEqual(labels("note", "dropped"), ["Activate"])
        XCTAssertEqual(labels("idea", "merged"), [])
    }

    func testMacOnlyPressesAreDisabledOnThePhone() {
        let phone = row(idea("idea", "active"))
        XCTAssertEqual(phone.buttons.map(\.enabled), [false, true, false])
        XCTAssertEqual(phone.buttons.map(\.note), ["On your Mac", nil, "On your Mac"])
        XCTAssertEqual(phone.menu, [.notNow])
        XCTAssertEqual(row(idea("idea", "active"), platform: .mac).buttons.map(\.enabled), [true, true, true])
        let item = row(Fix.ref(.inboxItem, 7))
        XCTAssertEqual(item.buttons.filter { !$0.enabled }.map(\.label), ["Discuss in Chat", "Hand to Agent…"])
    }

    func testMenuHoldsEveryVerbIncludingMakeATask() {
        XCTAssertEqual(row(Fix.ref(.inboxItem, 7)).menu, [.resolve, .dismiss, .snooze])
        XCTAssertEqual(row(Fix.ref(.track, 7)).menu, [.done, .stop, .makeTask])
        XCTAssertEqual(row(Fix.ref(.reminder, 7)).menu, [.done, .snooze])
        XCTAssertEqual(row(idea("idea", "proposed", waits: true)).menu, [.approve, .notNow, .reject])
        XCTAssertEqual(row(idea("idea", "rejected")).menu, [.approve])
        XCTAssertEqual(row(Fix.ref(.planItem, 7)).menu, [.check, .uncheck])
        // Make a Task is an owner gesture: without permissions the phone draws it disabled.
        XCTAssertEqual(row(Fix.ref(.track, 7), grants: Grants(permissions: false, typing: true)).menu, [.done, .stop])
        XCTAssertEqual(row(Fix.ref(.track, 7), platform: .mac, grants: noGrants).menu, [.done, .stop, .makeTask])
    }

    func testRequestCarriesRefKindIDAndVerb() {
        let request = row(Fix.ref(.inboxItem, 7)).request(.snooze, cardID: "o1", requestID: "r1", until: "2026-11-17T09:00:00Z")
        XCTAssertEqual(request, ActRequest(
            requestID: "r1", target: "o1", verb: .ref,
            params: ActParams(refKind: .inboxItem, refID: 7, refVerb: .snooze, until: "2026-11-17T09:00:00Z")
        ))
        let task = row(Fix.ref(.track, 7)).request(.makeTask, cardID: "tracks", requestID: "r2", eventID: 42)
        XCTAssertEqual(task.params.eventID, 42)
        XCTAssertEqual(task.params.refKind, .track)
    }

    func testReplyNeedsTypingOnThePhone() {
        XCTAssertTrue(row(Fix.ref(.inboxItem, 7, reply: true)).canReply)
        XCTAssertFalse(row(Fix.ref(.inboxItem, 7, reply: true), grants: Grants(permissions: true, typing: false)).canReply)
        XCTAssertFalse(row(Fix.ref(.inboxItem, 7)).canReply)
        var waiting = Fix.ref(.inboxItem, 7, reply: true)
        waiting.replyWaiting = true
        XCTAssertFalse(row(waiting, platform: .mac).canReply)
        let request = row(Fix.ref(.inboxItem, 7, reply: true)).replyRequest(text: "On it", cardID: "o1", requestID: "r3")
        XCTAssertEqual(request, ActRequest(
            requestID: "r3", target: "o1", verb: .replyPropose,
            params: ActParams(text: "On it", refKind: .inboxItem, refID: 7)
        ))
    }

    /// The wire form Go's `inbox.act` reply_propose accepts
    /// (`inboxfeed.replyPropose`: ref_kind inbox_item, ref_id > 0, text),
    /// as `act_owner_test.go` sends it, and nothing else.
    func testReplyRequestCarriesWhatGoRequires() throws {
        let request = row(Fix.ref(.inboxItem, 41, reply: true))
            .replyRequest(text: "Sounds good", cardID: "o1", requestID: "6f1c2d3e-0000-4000-8000-000000000008")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(object["request_id"] as? String, "6f1c2d3e-0000-4000-8000-000000000008")
        XCTAssertEqual(object["target"] as? String, "o1")
        XCTAssertEqual(object["verb"] as? String, "reply_propose")
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(Set(params.keys), ["ref_kind", "ref_id", "text"])
        XCTAssertEqual(params["ref_kind"] as? String, "inbox_item")
        XCTAssertEqual(params["ref_id"] as? Int, 41)
        XCTAssertEqual(params["text"] as? String, "Sounds good")
    }
}

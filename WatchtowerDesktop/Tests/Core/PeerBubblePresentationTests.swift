import Foundation
@testable import WatchtowerCore
import XCTest

/// The peer cards of a Workchat feed (spec 2026-11-18 §6.6): every string, the waiting reasons, an unknown kind.
final class PeerBubblePresentationTests: XCTestCase {
    private let title = "PDF export API"

    private func entry(_ peer: SessionFeedPeer, text: String = "body") -> SessionFeedEntry {
        SessionFeedEntry(id: "p1", kind: "peer", text: text, peer: peer)
    }

    func testDecodesPeerEntry() throws {
        let json = #"{"id":"p","kind":"peer","text":"hi","peer":{"direction":"in","kind":"message","session_id":7,"#
            + #""title":"API","folder":"hub","worktree":""}}"#
        let e = try JSONDecoder().decode(SessionFeedEntry.self, from: Data(json.utf8))
        XCTAssertEqual(e.peer, SessionFeedPeer(direction: "in", kind: "message", sessionID: 7, title: "API", folder: "hub"))
        XCTAssertTrue(SessionFeedEntry.knownKinds.contains("peer"))
        XCTAssertFalse(SessionFeedEntry.phoneKinds.contains("peer"))
    }

    func testIncomingMessageHeader() {
        let b = PeerBubblePresentation.bubble(for: entry(.init(direction: "in", kind: "message", sessionID: 7, title: title, folder: "hub"),
                                                         text: "Done."))
        XCTAssertEqual(b, .init(header: "↘ From “PDF export API” · hub", body: "Done.", tone: .peer))
    }

    func testFinishedHeader() {
        let b = PeerBubblePresentation.bubble(for: entry(.init(direction: "in", kind: "finished", sessionID: 7, title: title, folder: "hub"),
                                                         text: "PR #41"))
        XCTAssertEqual(b, .init(header: "✓ Sub-session “PDF export API” finished · hub", body: "PR #41", tone: .success))
    }

    func testStartedHeaderWithAndWithoutWorktree() {
        let with = PeerBubblePresentation.bubble(for: entry(.init(direction: "out", kind: "started", sessionID: 9, title: "PDF export API",
                                                                  folder: "hub", worktree: "/work/hub/export-api")))
        XCTAssertEqual(with, .init(header: "↗ Sub-session “PDF export API” started · hub · ⑂ export-api", body: "Brief sent.", tone: .peer))
        let without = PeerBubblePresentation.bubble(for: entry(.init(direction: "out", kind: "started", sessionID: 9, title: "T", folder: "hub")))
        XCTAssertEqual(without?.header, "↗ Sub-session “T” started · hub")
    }

    func testOutgoingMessageHeader() {
        let b = PeerBubblePresentation.bubble(for: entry(.init(direction: "out", kind: "message", sessionID: 7, title: title, folder: "hub"),
                                                         text: "Cap at 20 MB."))
        XCTAssertEqual(b, .init(header: "↗ To “PDF export API” · hub", body: "Cap at 20 MB.", tone: .peer))
    }

    func testUntitledReceiverNamesItsID() {
        let b = PeerBubblePresentation.bubble(for: entry(.init(direction: "out", kind: "message", sessionID: 7)))
        XCTAssertEqual(b?.header, "↗ To “#7” · ")
    }

    func testUnknownKindStillDropped() {
        XCTAssertNil(PeerBubblePresentation.bubble(for: entry(.init(direction: "in", kind: "future", sessionID: 1))))
        XCTAssertNil(PeerBubblePresentation.bubble(for: entry(.init(direction: "sideways", kind: "message", sessionID: 1))))
        XCTAssertNil(PeerBubblePresentation.bubble(for: SessionFeedEntry(id: "o", kind: "owner", text: "hi")))
        XCTAssertNil(PeerBubblePresentation.bubble(for: SessionFeedEntry(id: "p", kind: "peer")), "no payload, no card")
        XCTAssertNil(WorkchatFeedAdapter.role(for: "future_kind"))
        XCTAssertEqual(WorkchatFeedAdapter.role(for: "peer"), "system")
    }

    func testWaitingBubbleReasonPerHold() {
        let cases: [(PeerBubblePresentation.Hold, String)] = [
            (.permissionPrompt, "The session is at a permission prompt; the message goes once it is answered."),
            (.busy, "The session is busy; the message goes when it is idle."),
            (.ownerTyping, "The owner is typing in this session; the message goes after that."),
            (.unknown, "The message goes when the session can take it.")
        ]
        for (hold, reason) in cases {
            XCTAssertEqual(PeerBubblePresentation.waiting(title: "Download PDF button", hold: hold, daemonRunning: true),
                           .init(header: "⏸ Message to “Download PDF button” is waiting", body: reason, tone: .waiting, action: "Open"))
        }
    }

    func testWaitingReasonWhenTheDaemonIsStopped() {
        for hold in [PeerBubblePresentation.Hold.permissionPrompt, .busy, .ownerTyping, .unknown] {
            XCTAssertEqual(PeerBubblePresentation.waitingReason(hold: hold, daemonRunning: false),
                           "Watchtower's background sync is stopped; the message goes when it runs.")
        }
    }

    func testHoldOfReceiver() {
        XCTAssertEqual(PeerBubblePresentation.Hold.of(receiverNeedsApproval: true, receiverWorking: true), .permissionPrompt)
        XCTAssertEqual(PeerBubblePresentation.Hold.of(receiverNeedsApproval: false, receiverWorking: true), .busy)
        XCTAssertEqual(PeerBubblePresentation.Hold.of(receiverNeedsApproval: false, receiverWorking: false), .unknown,
                       "an idle receiver gives no evidence of the hold")
    }

    func testRefusedCallsNeverReadAsStartedOrSent() {
        let refusedStart = PeerBubblePresentation.bubble(for: entry(
            .init(direction: "out", kind: "started", title: title, folder: "hub", error: "limit: too many")))
        XCTAssertEqual(refusedStart, .init(header: "↗ Sub-session “PDF export API” not started: limit: too many", body: "", tone: .failed))
        let untitled = PeerBubblePresentation.bubble(for: entry(.init(direction: "out", kind: "started", folder: "hub", error: "not_installed")))
        XCTAssertEqual(untitled?.header, "↗ Sub-session not started: not_installed")
        let refusedSend = PeerBubblePresentation.bubble(for: entry(
            .init(direction: "out", kind: "message", sessionID: 7, title: title, folder: "hub", error: "session 7 is not running"), text: "hi"))
        XCTAssertEqual(refusedSend, .init(header: "↗ To “PDF export API” — not sent: session 7 is not running", body: "hi", tone: .failed))
    }

    func testStartWithoutAnswerYetIsStarting() {
        let b = PeerBubblePresentation.bubble(for: entry(.init(direction: "out", kind: "started", title: title, folder: "hub")))
        XCTAssertEqual(b, .init(header: "↗ Sub-session “PDF export API” starting · hub", body: "", tone: .peer))
    }
}

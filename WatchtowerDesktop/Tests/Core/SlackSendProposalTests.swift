import GRDB
import XCTest
@testable import WatchtowerCore

/// The `send_slack_message` card's pure half (spec 2026-10-02 §7): what the
/// card reads from the pinned args, when Approve may run, and the
/// `--patch` it sends — Go's `reviseSlackSend`/`slackSendReady` are the twins.
final class SlackSendProposalTests: XCTestCase {
    private func action(args: String, status: String = "pending", error: String = "", tool: String = "send_slack_message") -> AgentAction {
        AgentAction(row: Row([
            "id": 7, "tool": tool, "external": true, "args_json": args, "reason": "asked", "surface": "main",
            "conversation_id": 1, "context_type": "", "context_id": "", "turn_id": "t", "status": status,
            "trust_at_create": "ask", "result_json": "", "error": error,
            "created_at": "", "decided_at": "", "applied_at": ""
        ]))
    }

    private let channelTarget = ##"{"account_id":1,"workspace":"Acme","channel_id":"CGEN","label":"#general"}"##

    func testReadsAPinnedChannelTarget() throws {
        let p = try XCTUnwrap(SlackSendProposal(action: action(args: ##"{"text":"hi","target":\##(channelTarget)}"##)))
        XCTAssertEqual(p.text, "hi")
        XCTAssertEqual(p.target, .init(accountID: 1, workspace: "Acme", label: "#general", threadTS: "", isDM: false))
        XCTAssertTrue(p.candidates.isEmpty)
        XCTAssertEqual(p.recipientLine, "To: #general in Acme")
    }

    func testThreadAndDMLines() throws {
        let thread = try XCTUnwrap(SlackSendProposal(action: action(args:
            ##"{"text":"x","target":{"account_id":1,"workspace":"Acme","channel_id":"C1","label":"#ops","thread_ts":"1700000000.000001"}}"##)))
        XCTAssertEqual(thread.recipientLine, "To: a thread in #ops in Acme")
        let dm = try XCTUnwrap(SlackSendProposal(action: action(args:
            ##"{"text":"x","target":{"account_id":2,"workspace":"Beta","user_id":"U1","label":"@Alice"}}"##)))
        XCTAssertEqual(dm.recipientLine, "To: @Alice in Beta")
        XCTAssertTrue(dm.target?.isDM == true)
    }

    func testOtherToolsAndUnreadableArgsAreNotSlackProposals() {
        XCTAssertNil(SlackSendProposal(action: action(args: "{}", tool: "create_target")))
        XCTAssertNil(SlackSendProposal(action: action(args: ##"{"text":"hi"}"##)), "no target, no candidates: raw-args card")
        XCTAssertNil(SlackSendProposal(action: action(args: "not json")))
    }

    func testCandidatesNeedAPickBeforeApprove() throws {
        let args = ##"{"text":"hi","candidates":[\##(channelTarget),{"account_id":2,"workspace":"Beta","channel_id":"CB","label":"#general"}]}"##
        let p = try XCTUnwrap(SlackSendProposal(action: action(args: args)))
        XCTAssertNil(p.target)
        XCTAssertEqual(p.candidates.map(\.workspace), ["Acme", "Beta"])
        XCTAssertEqual(p.recipientLine, "To: #general — exists in 2 workspaces, choose one")
        XCTAssertFalse(p.canApprove(text: "hi", pick: nil))
        XCTAssertFalse(p.canApprove(text: "hi", pick: 2))
        XCTAssertTrue(p.canApprove(text: "hi", pick: 1))
        XCTAssertEqual(try p.patch(text: "hi", pick: 1), ##"{"candidate":1}"##)
        XCTAssertEqual(try p.approval(text: "hi", pick: 1), .edited(patch: ##"{"candidate":1}"##))
    }

    func testTextRules() throws {
        let p = try XCTUnwrap(SlackSendProposal(action: action(args: ##"{"text":"hi","target":\##(channelTarget)}"##)))
        XCTAssertTrue(p.canApprove(text: "hi", pick: nil))
        XCTAssertFalse(p.canApprove(text: "  \n", pick: nil))
        XCTAssertFalse(p.canApprove(text: String(repeating: "я", count: SlackSendProposal.maxCharacters + 1), pick: nil))
        XCTAssertNil(try p.patch(text: "hi", pick: nil), "nothing edited → a plain approve")
        XCTAssertEqual(try p.approval(text: "hi", pick: nil), .plain)
        XCTAssertEqual(try p.approval(text: "hi!", pick: nil), .edited(patch: ##"{"text":"hi!"}"##),
                       "an edited text is what Approve sends, never the original draft")
        XCTAssertEqual(try p.patch(text: "hi \"there\"", pick: nil), ##"{"text":"hi \"there\""}"##)
        XCTAssertNil(try p.patch(text: "hi", pick: 0), "a pinned target takes no pick")
    }

    func testReconnectOnlyForAScopeFailure() {
        let args = ##"{"text":"hi","target":\##(channelTarget)}"##
        let scope = "slack workspace Acme has not granted Watchtower permission to send messages — sign in again to grant send (…)"
        XCTAssertEqual(SlackSendProposal.reconnectAccountID(action(args: args, status: "failed", error: scope)), 1)
        XCTAssertNil(SlackSendProposal.reconnectAccountID(action(args: args, status: "failed", error: "slack chat.postMessage: not_in_channel")))
        XCTAssertNil(SlackSendProposal.reconnectAccountID(action(args: args, status: "pending", error: scope)))
    }
}

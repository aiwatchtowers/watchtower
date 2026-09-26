import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// Where an Inbox strip card links to: the thing an applied action produced
/// (`AgentActionDestination`) and the Slack message a reaction came from
/// (`SlackMessageRef`).
final class AgentActionDestinationTests: XCTestCase {
    private func action(
        tool: String,
        status: String = "applied",
        resultJSON: String = "",
        contextType: String = "",
        contextID: String = ""
    ) throws -> AgentAction {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try TestDatabase.insertAgentAction(
                db, tool: tool, contextType: contextType, contextID: contextID,
                status: status, resultJSON: resultJSON
            )
        }
        return try queue.read { db in try AgentActionQueries.fetchByConversation(db, conversationID: 1) }[0]
    }

    // MARK: - Destination per tool

    func testAppliedCreateIdeaOpensTheIdea() throws {
        XCTAssertEqual(try action(tool: "create_idea", resultJSON: #"{"idea_id":42}"#).destination, .idea(42))
    }

    func testAppliedCreateTargetOpensTheTarget() throws {
        XCTAssertEqual(try action(tool: "create_target", resultJSON: #"{"target_id":7}"#).destination, .target(7))
    }

    func testAppliedCreateTrackOpensTheTrack() throws {
        XCTAssertEqual(try action(tool: "create_track", resultJSON: #"{"track_id":3}"#).destination, .track(3))
    }

    func testAppliedJiraIssueOpensItsURL() throws {
        let result = #"{"key":"ABC-7","url":"https://acme.atlassian.net/browse/ABC-7"}"#
        XCTAssertEqual(
            try action(tool: "create_jira_issue", resultJSON: result).destination,
            .url(try XCTUnwrap(URL(string: "https://acme.atlassian.net/browse/ABC-7")))
        )
    }

    func testAppliedConnectJiraBoardOpensBoards() throws {
        let result = #"{"board_id":5,"board_name":"Core"}"#
        XCTAssertEqual(try action(tool: "connect_jira_board", resultJSON: result).destination, .boards)
    }

    func testBriefContextAndRemindMeHaveNoDestination() throws {
        XCTAssertNil(try action(tool: "brief_context", resultJSON: #"{"summary":"s"}"#).destination)
        XCTAssertNil(try action(tool: "remind_me", resultJSON: #"{"reminder_id":9}"#).destination)
    }

    func testUnknownToolHasNoDestination() throws {
        XCTAssertNil(try action(tool: "frobnicate", resultJSON: #"{"idea_id":1}"#).destination)
    }

    // MARK: - Only an applied row links anywhere

    func testNonAppliedRowsHaveNoDestinationEvenWithAResult() throws {
        for status in ["pending", "approved", "executing", "failed", "rejected"] {
            XCTAssertNil(
                try action(tool: "create_idea", status: status, resultJSON: #"{"idea_id":42}"#).destination,
                "status \(status) must not link"
            )
            XCTAssertNil(
                try action(tool: "connect_jira_board", status: status, resultJSON: #"{"board_name":"Core"}"#).destination,
                "status \(status) must not link"
            )
        }
    }

    // MARK: - Missing / malformed results

    func testMissingOrMalformedResultHasNoDestination() throws {
        XCTAssertNil(try action(tool: "create_idea").destination, "empty result_json")
        XCTAssertNil(try action(tool: "create_idea", resultJSON: "not json").destination)
        XCTAssertNil(try action(tool: "create_idea", resultJSON: #"{"target_id":1}"#).destination, "wrong key")
        XCTAssertNil(try action(tool: "create_idea", resultJSON: #"{"idea_id":"abc"}"#).destination)
        XCTAssertNil(try action(tool: "create_target", resultJSON: #"{"target_id":0}"#).destination, "no row 0")
        XCTAssertNil(try action(tool: "create_track", resultJSON: #"{"track_id":-2}"#).destination)
        XCTAssertNil(try action(tool: "create_jira_issue", resultJSON: #"{"key":"ABC-7"}"#).destination, "no url")
        XCTAssertNil(try action(tool: "create_jira_issue", resultJSON: #"{"url":""}"#).destination)
        XCTAssertNil(
            try action(tool: "create_jira_issue", resultJSON: #"{"url":"javascript:alert(1)"}"#).destination,
            "only a web URL opens in the browser"
        )
    }

    // MARK: - Source Slack message

    func testReactionActionLinksItsSlackMessage() throws {
        let row = try action(tool: "create_idea", status: "pending", contextType: "reaction", contextID: "1:C0ABC@1740000000.123456")
        XCTAssertEqual(row.sourceMessageURL?.absoluteString, "https://slack.com/archives/C0ABC/p1740000000123456")
    }

    func testNonReactionActionHasNoSourceLinkEvenWithARefShapedContext() throws {
        let row = try action(tool: "create_target", contextType: "target", contextID: "C0ABC@1740000000.1")
        XCTAssertNil(row.sourceMessageURL)
    }

    // MARK: - Ref parsing

    func testParsesANamespacedRef() throws {
        let parsed = try XCTUnwrap(SlackMessageRef.parse("1:C0ABC@1740000000.123456"))
        XCTAssertEqual(parsed.channelID, "1:C0ABC")
        XCTAssertEqual(parsed.messageTS, "1740000000.123456")
    }

    func testParsesABareRef() throws {
        let parsed = try XCTUnwrap(SlackMessageRef.parse("C0ABC@1740000000.1"))
        XCTAssertEqual(parsed.channelID, "C0ABC")
        XCTAssertEqual(parsed.messageTS, "1740000000.1")
        XCTAssertEqual(SlackMessageRef.url("C0ABC@1740000000.1")?.absoluteString, "https://slack.com/archives/C0ABC/p17400000001")
    }

    func testSplitsOnTheLastAt() throws {
        let parsed = try XCTUnwrap(SlackMessageRef.parse("C@weird@1740000000.1"))
        XCTAssertEqual(parsed.channelID, "C@weird")
        XCTAssertEqual(parsed.messageTS, "1740000000.1")
    }

    func testRejectsRefsWithoutBothHalves() {
        for ref in ["", "@", "abc", "C1@", "@1740000000.1", "1740000000.1"] {
            XCTAssertNil(SlackMessageRef.parse(ref), "\(ref.debugDescription) must not parse")
            XCTAssertNil(SlackMessageRef.url(ref), "\(ref.debugDescription) must not link")
        }
    }
}

import XCTest
@testable import WatchtowerChatText

/// `SessionFeedLive` decodes the same snake_case JSON with a plain decoder
/// (the Mac reading the CLI) and with `.convertFromSnakeCase` (the phone's
/// RelayCoder reading the hub's `activity_live`).
final class SessionFeedLiveDecodingTests: XCTestCase {
    private let json = """
    {"observed_at":"2027-01-15T08:00:05Z","conversation":"conv-1","turn_at":"2027-01-15T08:00:00Z",
     "turn_active":true,"agents_state":"known","agents_more":2,"steps_more":3,
     "current":{"id":"t2","tool":"Bash","summary":"go test","started_at":"2027-01-15T08:00:02Z",
                "completed_at":"0001-01-01T00:00:00Z","more":1},
     "steps":[{"id":"t2","tool":"Bash","summary":"go test","started_at":"2027-01-15T08:00:02Z",
               "completed_at":"0001-01-01T00:00:00Z"}],
     "agents":[{"ref":{"tool_use_id":"tu1","agent_id":"a1","type":"Explore","description":"d",
                       "status":"running","started_at":"2027-01-15T08:00:01Z"},
                "started_at":"2027-01-15T08:00:01Z","can_open":true}]}
    """

    private let base = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15T08:00:00Z

    private func decode(snakeConverting: Bool) throws -> SessionFeedLive {
        let decoder = JSONDecoder()
        if snakeConverting { decoder.keyDecodingStrategy = .convertFromSnakeCase }
        return try decoder.decode(SessionFeedLive.self, from: Data(json.utf8))
    }

    func testBothKeyStrategiesDecodeTheSameValue() throws {
        let plain = try decode(snakeConverting: false)
        XCTAssertEqual(plain.observedAt, base + 5)
        XCTAssertEqual(plain.turnAt, base)
        XCTAssertTrue(plain.turnActive)
        XCTAssertEqual(plain.agentsState, "known")
        XCTAssertEqual(plain.agentsMore, 2)
        XCTAssertEqual(plain.stepsMore, 3)
        XCTAssertEqual(plain.current?.startedAt, base + 2)
        XCTAssertNil(plain.current?.completedAt, "Go's zero time is an open step")
        XCTAssertEqual(plain.current?.more, 1)
        let agent = try XCTUnwrap(plain.agents.first)
        XCTAssertEqual(agent.ref.toolUseID, "tu1")
        XCTAssertEqual(agent.ref.agentID, "a1")
        XCTAssertEqual(agent.ref.startedAt, base + 1)
        XCTAssertEqual(agent.startedAt, base + 1)
        XCTAssertTrue(agent.canOpen)

        XCTAssertEqual(try decode(snakeConverting: true), plain)
    }

    func testCamelSpelling() {
        XCTAssertEqual(FeedWireKey.camel("tool_use_id"), "toolUseId")
        XCTAssertEqual(FeedWireKey.camel("observed_at"), "observedAt")
        XCTAssertEqual(FeedWireKey.camel("steps"), "steps")
    }
}

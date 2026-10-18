import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

final class SessionChatPayloadTests: XCTestCase {
    private func feed(_ entries: [SessionFeedEntry]) throws -> SessionFeedPayload {
        struct Wire: Encodable {
            let session_id: Int64
            let entries: [Item]
            struct Item: Encodable {
                let id: String
                let kind: String
                let at: String?
                let text: String
                let title: String?
                let subagent: Sub?
            }
            struct Sub: Encodable {
                let tool_use_id: String
                let agent_id: String
                let description: String
            }
        }
        let iso = ISO8601DateFormatter()
        let wire = Wire(session_id: 7, entries: entries.map {
            .init(id: $0.id, kind: $0.kind, at: $0.at.map(iso.string), text: $0.text, title: $0.title,
                  subagent: $0.subagent.map { .init(tool_use_id: $0.toolUseID, agent_id: $0.agentID, description: $0.description) })
        })
        return try JSONDecoder().decode(SessionFeedPayload.self, from: JSONEncoder().encode(wire))
    }

    private func entry(_ index: Int, text: String = "hi", title: String? = nil) -> SessionFeedEntry {
        SessionFeedEntry(id: "e\(index)", kind: "agent", at: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)), text: text, title: title)
    }

    private func encode(_ entries: [SessionFeedEntry], agentID: String? = nil) throws -> (data: Data, json: [String: Any]) {
        let data = try SessionChatPayload.encode(try feed(entries), sessionID: 7, agentID: agentID, live: true)
        return (data, try SliceJSON.object(data))
    }

    private func items(_ json: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(json["entries"] as? [[String: Any]])
    }

    func testKeepsNewest300() throws {
        let json = try encode((0..<350).map { entry($0) }).json
        let list = try items(json)
        XCTAssertEqual(list.count, 300)
        XCTAssertEqual(list.first?["id"] as? String, "e50", "oldest first, the newest 300 kept")
        XCTAssertEqual(list.last?["id"] as? String, "e349")
        XCTAssertEqual(json["entries_more"] as? Int, 50)
    }

    func testClipsText() throws {
        let list = try items(try encode([entry(0, text: String(repeating: "a", count: 5000))]).json)
        XCTAssertEqual((list[0]["text"] as? String)?.count, 4000)
        XCTAssertEqual(list[0]["text_clipped"] as? Bool, true)
    }

    func testClipsLabels() throws {
        let long = String(repeating: "b", count: 500)
        let withSub = SessionFeedEntry(
            id: "s", kind: "subagent",
            subagent: SessionFeedSubagent(toolUseID: "t", agentID: "a1", type: "Explore", description: long, status: "running")
        )
        let list = try items(try encode([entry(0, title: long), withSub]).json)
        XCTAssertEqual((list[0]["title"] as? String)?.count, 200)
        let sub = try XCTUnwrap(list[1]["subagent"] as? [String: Any])
        XCTAssertEqual((sub["description"] as? String)?.count, 200)
        XCTAssertEqual(sub["tool_use_id"] as? String, "t", "the selector for --subagent rides along")
    }

    func testTrimsToByteBudget() throws {
        let big = String(repeating: "x", count: 4000)
        let (data, json) = try encode((0..<300).map { entry($0, text: big) })
        XCTAssertLessThanOrEqual(data.count, SessionChatPayload.maxBytes)
        let list = try items(json)
        XCTAssertLessThan(list.count, 300)
        XCTAssertEqual(list.last?["id"] as? String, "e299", "the oldest are dropped")
        XCTAssertEqual(json["entries_more"] as? Int, 300 - list.count)
    }

    func testMatchesKitFixtureKeys() throws {
        let fixture = try SliceJSON.kitFixture("workbench/session_chat.json")
        let json = try encode([entry(0)]).json
        XCTAssertEqual(Set(json.keys), Set(fixture.keys).subtracting(["agent_id"]))
        let sub = try SliceJSON.kitFixture("workbench/session_chat_subagent.json")
        XCTAssertEqual(Set(try encode([entry(0)], agentID: "a1b2").json.keys), Set(sub.keys))
        let fixtureEntry = try XCTUnwrap((fixture["entries"] as? [[String: Any]])?.first)
        XCTAssertTrue(Set(try items(json)[0].keys).isSubset(of: Set(fixtureEntry.keys).union(["text_clipped", "title", "via", "ask_id", "subagent"])))
    }

    func testDatesAreUnixSeconds() throws {
        let json = try encode([entry(5)]).json
        XCTAssertNil(json["updated_at"])
        XCTAssertEqual(try items(json)[0]["at"] as? Double, 1_700_000_005)
    }

    func testNilAtAndOptionalsAreOmitted() throws {
        let sep = SessionFeedEntry(id: "sep", kind: "separator", text: "Context compacted")
        let item = try items(try encode([sep]).json)[0]
        XCTAssertEqual(Set(item.keys), ["id", "kind", "text"])
    }

    func testOnlyFeedKindsPublished() throws {
        let kinds = ["owner", "tool_use", "agent", "thinking", "hologram", "subagent"]
        let entries = kinds.enumerated().map { index, kind in
            SessionFeedEntry(id: "k\(index)", kind: kind, at: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)), text: kind)
        }
        let json = try encode(entries).json
        XCTAssertEqual(try items(json).compactMap { $0["kind"] as? String }, ["owner", "agent", "subagent"])
        XCTAssertEqual(json["entries_more"] as? Int ?? 0, 0, "dropped kinds are not counted as older entries")

        let many = (0..<350).flatMap { [entry($0), SessionFeedEntry(id: "t\($0)", kind: "tool_use", text: "x")] }
        let capped = try encode(many).json
        XCTAssertEqual(try items(capped).count, 300)
        XCTAssertEqual(capped["entries_more"] as? Int, 50)
    }

    func testIdenticalFetchesAreByteIdentical() throws {
        let entries = (0..<5).map { entry($0) }
        XCTAssertEqual(try encode(entries).data, try encode(entries).data)
    }
}

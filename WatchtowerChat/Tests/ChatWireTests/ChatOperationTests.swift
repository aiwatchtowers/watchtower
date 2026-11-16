import ChatWire
import XCTest

/// The chat.sock operations (unified chat spec §5.2; the protocol doc in `internal/chatengine/server.go`): each
/// case's op name and params as the engine's handlers read them, and the echo results.
final class ChatOperationTests: XCTestCase {
    private func params(_ op: ChatOperation) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try op.wireParams()) as? NSDictionary)
    }

    func testTurnRequestWireKeys() throws {
        let request = ChatTurnRequest(
            conversationID: 4, mode: .send, text: "Hi @Ann", attachmentIDs: [7],
            compose: ChatCompose(skill: "plan", mentions: [.init(kind: "person", id: "U1", label: "Ann")],
                                 quotes: [.init(messageID: 2, text: "the plan", comment: "why?")]),
            screenContext: "Inbox", artifactCommentIDs: [11], clientKey: "K1"
        )
        let data = try ChatWireCoder.makeEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            ["conversation_id", "mode", "text", "attachment_ids", "compose", "screen_context", "artifact_comment_ids",
             "client_key"]
        )
        XCTAssertEqual(object["conversation_id"] as? Int, 4)
        XCTAssertEqual(object["client_key"] as? String, "K1")
        XCTAssertEqual(object["artifact_comment_ids"] as? [Int], [11])
        XCTAssertEqual(object["screen_context"] as? String, "Inbox")
        let compose = try XCTUnwrap(object["compose"] as? [String: Any])
        XCTAssertEqual(compose["skill"] as? String, "plan")
        let quote = try XCTUnwrap((compose["quotes"] as? [[String: Any]])?.first)
        XCTAssertEqual(quote["message_id"] as? Int, 2)
        XCTAssertEqual(try ChatWireCoder.makeDecoder().decode(ChatTurnRequest.self, from: data), request)

        let edit = ChatTurnRequest(conversationID: 4, mode: .continue, messageID: 9, text: "", routing: ChatRouting(mode: "auto"),
                                   clientKey: "K2")
        let editObject = try params(.turn(edit))
        XCTAssertEqual(editObject["mode"] as? String, "continue")
        XCTAssertEqual(editObject["message_id"] as? Int, 9)
        XCTAssertEqual(editObject["routing"] as? NSDictionary, ["mode": "auto"])
        XCTAssertNil(editObject["compose"])
    }

    func testOpNamesMatchTheEngine() {
        let cases: [(ChatOperation, String)] = [
            (.new(projectID: nil, routing: ChatRouting(mode: "auto")), "chat_new"),
            (.turn(ChatTurnRequest(conversationID: 1, mode: .send, text: "x", clientKey: "k")), "chat_turn"),
            (.cancel(conversationID: 1, turnID: "t"), "chat_cancel"),
            (.page(conversationID: 1, beforeMessageID: 2), "chat_page"),
            (.search(query: "q"), "chat_search"),
            (.read(conversationID: 1, messageID: 2), "chat_read"),
            (.branchSelect(messageID: 2), "chat_branch_select"),
            (.manage(conversationID: 1, op: .pin, title: nil, projectID: nil), "chat_manage"),
            (.project(ChatProjectRequest(op: .create)), "project_manage"),
            (.artifact(ChatArtifactRequest(op: .keep, conversationID: 1, key: "k")), "artifact_manage"),
            (.attach(conversationID: 1, source: .path("/tmp/a.png")), "attach"),
            (.attachDiscard(conversationID: 1, attachmentID: 3), "attach_discard"),
            (.entitySearch(query: "a", kinds: []), "entity_search"),
            (.skillsList, "skills_list"),
            (.shutdown, "chat_shutdown")
        ]
        for (op, name) in cases {
            XCTAssertEqual(op.wireOp, name)
        }
    }

    func testParams() throws {
        XCTAssertEqual(try params(.new(projectID: 5, routing: ChatRouting(mode: "pinned", provider: "claude", model: "opus"))),
                       ["project_id": 5, "routing": ["mode": "pinned", "provider": "claude", "model": "opus"]])
        XCTAssertEqual(try params(.cancel(conversationID: 1, turnID: "t")), ["conversation_id": 1, "turn_id": "t"])
        XCTAssertEqual(try params(.page(conversationID: 1, beforeMessageID: 2)), ["conversation_id": 1, "before_message_id": 2])
        XCTAssertEqual(try params(.search(query: "q")), ["query": "q"])
        XCTAssertEqual(try params(.read(conversationID: 1, messageID: 2)), ["conversation_id": 1, "message_id": 2])
        XCTAssertEqual(try params(.branchSelect(messageID: 2)), ["message_id": 2])
        XCTAssertEqual(try params(.manage(conversationID: 1, op: .move, title: nil, projectID: 4)),
                       ["conversation_id": 1, "op": "move", "project_id": 4])
        XCTAssertEqual(try params(.manage(conversationID: 1, op: .rename, title: "T", projectID: nil)),
                       ["conversation_id": 1, "op": "rename", "title": "T"])
        XCTAssertEqual(try params(.project(ChatProjectRequest(
            op: .sourceAdd, projectID: 2, sources: [.init(kind: "slack_channel", ref: "C1", label: "#general")]))),
            ["op": "source_add", "project_id": 2, "sources": [["kind": "slack_channel", "ref": "C1", "label": "#general"]]])
        XCTAssertEqual(try params(.project(ChatProjectRequest(op: .update, projectID: 2, name: "N", instructions: ""))),
                       ["op": "update", "project_id": 2, "name": "N", "instructions": ""])
        XCTAssertEqual(try params(.artifact(ChatArtifactRequest(
            op: .commentAdd, conversationID: 1, key: "q3", version: 2,
            comment: .init(body: "why", anchorQuote: "x", anchorPrefix: "a", anchorSuffix: "b", anchorHeading: "H")))),
            ["op": "comment_add", "conversation_id": 1, "key": "q3", "version": 2,
             "comment": ["body": "why", "anchor_quote": "x", "anchor_prefix": "a", "anchor_suffix": "b", "anchor_heading": "H"]])
        XCTAssertEqual(try params(.artifact(ChatArtifactRequest(op: .commentReanchor, conversationID: 1, key: "q3", version: 3,
                                                                moved: [1], lost: [2]))),
                       ["op": "comment_reanchor", "conversation_id": 1, "key": "q3", "version": 3, "moved": [1], "lost": [2]])
        XCTAssertEqual(try params(.attach(conversationID: 1, source: .path("/tmp/a.png"))),
                       ["conversation_id": 1, "path": "/tmp/a.png"])
        XCTAssertEqual(try params(.attachDiscard(conversationID: 1, attachmentID: 3)), ["conversation_id": 1, "attachment_id": 3])
        XCTAssertEqual(try params(.entitySearch(query: "pay", kinds: ["jira"])), ["query": "pay", "kinds": ["jira"]])
        XCTAssertEqual(try params(.skillsList), [:])
        XCTAssertEqual(try params(.shutdown), [:])
    }

    /// A sealed upload goes through the hub (`chat_attachment`), never chat.sock.
    func testASealedUploadHasNoSocketParams() {
        let upload = ChatSealedUpload(uploadID: "U", name: "a.png", mime: "image/png", size: 3, file: URL(fileURLWithPath: "/tmp/a"))
        XCTAssertThrowsError(try ChatOperation.attach(conversationID: 1, source: .sealedUpload(upload)).wireParams())
    }

    func testResults() throws {
        func result(_ op: ChatOperation, _ json: String) throws -> ChatEchoResult {
            try op.decodeResult(Data(json.utf8))
        }
        XCTAssertEqual(try result(.new(projectID: nil, routing: ChatRouting(mode: "auto")), #"{"conversation_id":9}"#),
                       .conversation(id: 9))
        XCTAssertEqual(
            try result(.turn(ChatTurnRequest(conversationID: 1, mode: .send, text: "x", clientKey: "k")),
                       #"{"user_message_id":3,"assistant_message_id":4,"turn_id":"t1"}"#),
            .turn(ChatTurnStarted(userMessageID: 3, assistantMessageID: 4, turnID: "t1"))
        )
        XCTAssertEqual(
            try result(.entitySearch(query: "a", kinds: []), #"{"hits":[{"kind":"person","id":"U1","label":"Ann","detail":"PM"}]}"#),
            .entities([ChatEntityHit(kind: "person", id: "U1", label: "Ann", detail: "PM")])
        )
        XCTAssertEqual(try result(.skillsList, #"{"skills":[{"name":"plan","description":"Plan it"}]}"#),
                       .skills([ChatSkill(name: "plan", description: "Plan it")]))
        XCTAssertEqual(try result(.project(ChatProjectRequest(op: .create)), #"{"id":12}"#), .id(12))
        XCTAssertEqual(try result(.attach(conversationID: 1, source: .path("/a")), #"{"attachment_id":5}"#), .attachment(id: 5))
        XCTAssertEqual(try result(.read(conversationID: 1, messageID: 2), "{}"), .none)
        let search = try result(.search(query: "pay"),
                                #"{"query":"pay","hits":[{"conversation_id":1,"title":"T","snippet":"s","date":7}]}"#)
        XCTAssertEqual(search, .search(ChatSearch(query: "pay", hits: [
            .init(conversationID: 1, title: "T", snippet: "s", date: Date(timeIntervalSince1970: 7))
        ])))
        let page = try result(.page(conversationID: 3, beforeMessageID: 10),
                              #"{"conversation":{"id":3,"title":"T"},"messages":[{"id":4,"role":"user","text":"a","created_at":1}],"has_more":true}"#)
        guard case .page(let older) = page else { return XCTFail("not a page: \(page)") }
        XCTAssertEqual(older.messages.map(\.id), [4])
        XCTAssertTrue(older.hasMore)
    }
}

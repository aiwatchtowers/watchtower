import XCTest
@testable import WatchtowerKit

/// URLProtocol stub registered on an ephemeral URLSessionConfiguration.
/// Serves one canned (status, headers, body) response per request and records
/// the last request + its body for wire-format assertions.
final class AnthropicStubProtocol: URLProtocol {
    struct Stub {
        var statusCode: Int
        var headers: [String: String] = [:]
        var body: Data
    }

    static var stub: Stub?
    static var lastRequest: URLRequest?
    static var lastRequestBody: Data?

    static func reset() {
        stub = nil
        lastRequest = nil
        lastRequestBody = nil
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastRequestBody = Self.bodyData(of: request)
        guard let stub = Self.stub,
              let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession moves `httpBody` into `httpBodyStream` before the protocol
    /// sees the request — drain the stream to recover the encoded bytes.
    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

final class AnthropicClientTests: XCTestCase {
    private let apiKey = "sk-ant-test-key-123"

    override func tearDown() {
        AnthropicStubProtocol.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeClient() -> AnthropicClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnthropicStubProtocol.self]
        return AnthropicClient(apiKey: apiKey, session: URLSession(configuration: config))
    }

    private func makeRequest() -> AnthropicRequest {
        AnthropicRequest(
            model: .sonnet5,
            system: "You are Watchtower on iPhone.",
            messages: [APIMessage(role: .user, content: [.text("List my targets")])],
            tools: []
        )
    }

    /// Builds an SSE body from `event:`/`data:` line pairs.
    private func sse(_ pairs: [(event: String, data: String)]) -> Data {
        Data(pairs.map { "event: \($0.event)\ndata: \($0.data)\n\n" }.joined().utf8)
    }

    private func stubStream(_ pairs: [(event: String, data: String)]) {
        AnthropicStubProtocol.stub = .init(statusCode: 200, body: sse(pairs))
    }

    private func collectEvents(_ request: AnthropicRequest) async throws -> [AnthropicEvent] {
        var events: [AnthropicEvent] = []
        for try await event in makeClient().streamMessage(request: request) {
            events.append(event)
        }
        return events
    }

    private func assertStreamThrows(
        _ expected: AnthropicClientError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            for try await _ in makeClient().streamMessage(request: makeRequest()) {}
            XCTFail("expected \(expected), stream completed cleanly", file: file, line: line)
        } catch let error as AnthropicClientError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected AnthropicClientError, got \(error)", file: file, line: line)
        }
    }

    private let happyEnding: [(event: String, data: String)] = [
        ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":12}}"#),
        ("message_stop", #"{"type":"message_stop"}"#)
    ]

    // MARK: - Request wire format (THE freeze)

    func testRequestBodyMatchesFrozenFixture() async throws {
        stubStream(happyEnding)
        let request = AnthropicRequest(
            model: .sonnet5,
            system: "You are Watchtower on iPhone.",
            messages: [
                APIMessage(role: .user, content: [.text("List my targets")]),
                APIMessage(role: .assistant, content: [
                    .text("Checking."),
                    .toolUse(id: "tu_1", name: "list_targets", input: .object(["status": .string("active")]))
                ]),
                APIMessage(role: .user, content: [.toolResult(toolUseID: "tu_1", content: "[]")])
            ],
            tools: [
                APITool(
                    name: "list_targets",
                    description: "List targets from the replica.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object(["status": .object(["type": .string("string")])])
                    ])
                )
            ]
        )
        _ = try await collectEvents(request)

        let body = try XCTUnwrap(AnthropicStubProtocol.lastRequestBody)
        let json = try XCTUnwrap(String(data: body, encoding: .utf8))
        // BYOK wire-format freeze: sortedKeys byte-literal. Changing this JSON
        // changes what every phone sends to api.anthropic.com — owner approval required.
        // swiftlint:disable:next line_length
        XCTAssertEqual(json, #"{"max_tokens":8192,"messages":[{"content":[{"text":"List my targets","type":"text"}],"role":"user"},{"content":[{"text":"Checking.","type":"text"},{"id":"tu_1","input":{"status":"active"},"name":"list_targets","type":"tool_use"}],"role":"assistant"},{"content":[{"content":"[]","tool_use_id":"tu_1","type":"tool_result"}],"role":"user"}],"model":"claude-sonnet-5","stream":true,"system":"You are Watchtower on iPhone.","tools":[{"description":"List targets from the replica.","input_schema":{"properties":{"status":{"type":"string"}},"type":"object"},"name":"list_targets"}]}"#)
    }

    func testHeadersCarryKeyAndVersion() async throws {
        stubStream(happyEnding)
        _ = try await collectEvents(makeRequest())

        let request = try XCTUnwrap(AnthropicStubProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), apiKey)
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")
    }

    // MARK: - SSE streaming

    func testStreamsTextDeltas() async throws {
        stubStream([
            ("message_start", #"{"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[]}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            ("ping", #"{"type":"ping"}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#)
        ] + happyEnding)

        let events = try await collectEvents(makeRequest())
        XCTAssertEqual(events, [
            .textDelta("Hello"),
            .textDelta(" world"),
            .finished(stopReason: "end_turn")
        ])
    }

    func testStreamsToolUseWithInputDeltas() async throws {
        stubStream([
            ("message_start", #"{"type":"message_start","message":{"id":"msg_2","role":"assistant","content":[]}}"#),
            // swiftlint:disable:next line_length
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu_1","name":"list_targets","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"sta"}}"#),
            // swiftlint:disable:next line_length
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"tus\":\"active\"}"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":30}}"#),
            ("message_stop", #"{"type":"message_stop"}"#)
        ])

        let events = try await collectEvents(makeRequest())
        XCTAssertEqual(events, [
            .toolUseStarted(id: "tu_1", name: "list_targets"),
            .toolInputDelta(#"{"sta"#),
            .toolInputDelta(#"tus":"active"}"#),
            .toolUseFinished,
            .finished(stopReason: "tool_use")
        ])
    }

    func testSkipsThinkingBlocksSilently() async throws {
        // sonnet 5 runs adaptive thinking by default — thinking blocks may
        // appear anywhere in the stream and must be dropped without surfacing.
        stubStream([
            ("message_start", #"{"type":"message_start","message":{"id":"msg_3","role":"assistant","content":[]}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Before"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"thinking","thinking":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"thinking_delta","thinking":"pondering"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"signature_delta","signature":"sig=="}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
            ("content_block_start", #"{"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"After"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":2}"#)
        ] + happyEnding)

        let events = try await collectEvents(makeRequest())
        XCTAssertEqual(events, [
            .textDelta("Before"),
            .textDelta("After"),
            .finished(stopReason: "end_turn")
        ])
    }

    func testStreamErrorEventThrows() async {
        stubStream([
            ("message_start", #"{"type":"message_start","message":{"id":"msg_4","role":"assistant","content":[]}}"#),
            ("error", #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        ])
        await assertStreamThrows(.overloaded)
    }

    // MARK: - HTTP error mapping

    func testHTTPErrorsMapToTypedCases() async {
        AnthropicStubProtocol.stub = .init(
            statusCode: 401,
            body: Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        )
        await assertStreamThrows(.invalidKey)

        AnthropicStubProtocol.stub = .init(
            statusCode: 429,
            headers: ["Retry-After": "30"],
            body: Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"rate limited"}}"#.utf8)
        )
        await assertStreamThrows(.rateLimited(retryAfter: 30))

        AnthropicStubProtocol.stub = .init(
            statusCode: 529,
            body: Data(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8)
        )
        await assertStreamThrows(.overloaded)

        let serverErrorBody = #"{"type":"error","error":{"type":"api_error","message":"internal server error"}}"#
        AnthropicStubProtocol.stub = .init(statusCode: 500, body: Data(serverErrorBody.utf8))
        await assertStreamThrows(.http(status: 500, body: serverErrorBody))
    }

    func test429BodyNeverContainsKey() async {
        AnthropicStubProtocol.stub = .init(
            statusCode: 429,
            body: Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"rate limited"}}"#.utf8)
        )
        do {
            for try await _ in makeClient().streamMessage(request: makeRequest()) {}
            XCTFail("expected rateLimited error")
        } catch {
            XCTAssertFalse(String(describing: error).contains(apiKey), "API key leaked into error: \(error)")
            XCTAssertEqual(error as? AnthropicClientError, .rateLimited(retryAfter: nil))
        }
    }

    // MARK: - AgentModel

    func testAgentModelRawValuesAreExactAPIStrings() {
        XCTAssertEqual(
            AgentModel.allCases.map(\.rawValue),
            ["claude-sonnet-5", "claude-opus-4-8", "claude-haiku-4-5"]
        )
        XCTAssertEqual(AgentModel.sonnet5.displayName, "Claude Sonnet 5")
        XCTAssertEqual(AgentModel.opus48.displayName, "Claude Opus 4.8")
        XCTAssertEqual(AgentModel.haiku45.displayName, "Claude Haiku 4.5")
    }
}

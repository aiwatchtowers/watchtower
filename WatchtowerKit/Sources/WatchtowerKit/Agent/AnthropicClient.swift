import Foundation

/// Stream events surfaced by `AnthropicClient`. The client is a dumb event
/// mapper — tool input JSON accumulation happens in the caller (agent loop).
public enum AnthropicEvent: Equatable, Sendable {
    case textDelta(String)
    case toolUseStarted(id: String, name: String)
    case toolInputDelta(String)
    case toolUseFinished
    case finished(stopReason: String)
}

/// Typed failures. Error bodies come from the server response only —
/// the API key is never embedded in any case payload.
public enum AnthropicClientError: Error, Equatable {
    case http(status: Int, body: String)
    case overloaded
    case rateLimited(retryAfter: Int?)
    case invalidKey
    case cancelled
}

/// Anthropic Messages API over URLSession SSE (`POST /v1/messages`,
/// `stream: true`). No retries here — the agent loop decides. Thinking
/// blocks (sonnet 5 adaptive default) are skipped silently: we don't
/// render reasoning. Request bytes are frozen by AnthropicClientTests.
public struct AnthropicClient: Sendable {
    private static let endpoint: URL = {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            preconditionFailure("static Anthropic endpoint must parse")
        }
        return url
    }()

    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func streamMessage(request: AnthropicRequest) -> AsyncThrowingStream<AnthropicEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeURLRequest(for: request)
                    try await Self.stream(urlRequest, session: session, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AnthropicClientError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request build

    private func makeURLRequest(for request: AnthropicRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try AnthropicWireCoder.makeEncoder().encode(request)
        return urlRequest
    }

    // MARK: - Response streaming

    private static func stream(
        _ urlRequest: URLRequest,
        session: URLSession,
        into continuation: AsyncThrowingStream<AnthropicEvent, Error>.Continuation
    ) async throws {
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicClientError.http(status: -1, body: "non-HTTP response")
        }
        guard http.statusCode == 200 else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
            }
            throw mapHTTPError(
                status: http.statusCode,
                body: String(bytes: body, encoding: .utf8) ?? "",
                retryAfter: http.value(forHTTPHeaderField: "retry-after")
            )
        }

        var parser = SSEParser()
        for try await line in bytes.lines {
            for event in try parser.consume(line: line) {
                continuation.yield(event)
                if case .finished = event { return }
            }
        }
    }

    private static func mapHTTPError(status: Int, body: String, retryAfter: String?) -> AnthropicClientError {
        switch status {
        case 401: .invalidKey
        case 429: .rateLimited(retryAfter: retryAfter.flatMap(Int.init))
        case 529: .overloaded
        default: .http(status: status, body: body)
        }
    }
}

// MARK: - SSE state machine

/// Parses `event:`/`data:` line pairs into `AnthropicEvent`s. Content blocks
/// arrive strictly sequentially (start → deltas → stop), so a single
/// current-block state suffices; unknown block types (thinking et al.)
/// are marked ignored and their deltas dropped.
private struct SSEParser {
    private enum OpenBlock {
        case text
        case toolUse
        case ignored
    }

    private let decoder = JSONDecoder()
    private var currentEventName = ""
    private var openBlock: OpenBlock?
    private var stopReason: String?

    mutating func consume(line: String) throws -> [AnthropicEvent] {
        if line.hasPrefix("event:") {
            currentEventName = Self.value(ofField: line, prefix: "event:")
            return []
        }
        guard line.hasPrefix("data:") else { return [] } // blank lines / comments
        let payload = Data(Self.value(ofField: line, prefix: "data:").utf8)
        return try handle(eventName: currentEventName, payload: payload)
    }

    private static func value(ofField line: String, prefix: String) -> String {
        String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private mutating func handle(eventName: String, payload: Data) throws -> [AnthropicEvent] {
        switch eventName {
        case "error":
            let envelope = try decoder.decode(ErrorEnvelope.self, from: payload)
            throw Self.map(streamError: envelope.error)
        case "content_block_start":
            return try handleBlockStart(payload: payload)
        case "content_block_delta":
            return try handleBlockDelta(payload: payload)
        case "content_block_stop":
            defer { openBlock = nil }
            return openBlock == .toolUse ? [.toolUseFinished] : []
        case "message_delta":
            let event = try decoder.decode(MessageDelta.self, from: payload)
            if let reason = event.delta.stopReason {
                stopReason = reason
            }
            return []
        case "message_stop":
            return [.finished(stopReason: stopReason ?? "end_turn")]
        default:
            // message_start, ping, and any future event types: ignore.
            return []
        }
    }

    private mutating func handleBlockStart(payload: Data) throws -> [AnthropicEvent] {
        let event = try decoder.decode(BlockStart.self, from: payload)
        switch event.contentBlock.type {
        case "text":
            openBlock = .text
            return []
        case "tool_use":
            guard let id = event.contentBlock.id, let name = event.contentBlock.name else {
                throw AnthropicClientError.http(status: 200, body: "malformed tool_use content_block_start")
            }
            openBlock = .toolUse
            return [.toolUseStarted(id: id, name: name)]
        default:
            // Thinking blocks (adaptive default on sonnet 5) and any future
            // block types: skip silently — we don't render reasoning.
            openBlock = .ignored
            return []
        }
    }

    private func handleBlockDelta(payload: Data) throws -> [AnthropicEvent] {
        guard openBlock != .ignored else { return [] }
        let event = try decoder.decode(BlockDelta.self, from: payload)
        switch event.delta.type {
        case "text_delta":
            return event.delta.text.map { [.textDelta($0)] } ?? []
        case "input_json_delta":
            return event.delta.partialJSON.map { [.toolInputDelta($0)] } ?? []
        default:
            // thinking_delta / signature_delta / future delta types: ignore.
            return []
        }
    }

    private static func map(streamError error: ErrorEnvelope.APIError) -> AnthropicClientError {
        switch error.type {
        case "overloaded_error": .overloaded
        case "rate_limit_error": .rateLimited(retryAfter: nil)
        case "authentication_error": .invalidKey
        default: .http(status: 200, body: "\(error.type): \(error.message)")
        }
    }
}

// MARK: - SSE payload shapes

private struct ErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let type: String
        let message: String
    }

    let error: APIError
}

private struct BlockStart: Decodable {
    struct Block: Decodable {
        let type: String
        let id: String?
        let name: String?
    }

    private enum CodingKeys: String, CodingKey {
        case contentBlock = "content_block"
    }

    let contentBlock: Block
}

private struct BlockDelta: Decodable {
    struct Delta: Decodable {
        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case partialJSON = "partial_json"
        }

        let type: String
        let text: String?
        let partialJSON: String?
    }

    let delta: Delta
}

private struct MessageDelta: Decodable {
    struct Delta: Decodable {
        private enum CodingKeys: String, CodingKey {
            case stopReason = "stop_reason"
        }

        let stopReason: String?
    }

    let delta: Delta
}

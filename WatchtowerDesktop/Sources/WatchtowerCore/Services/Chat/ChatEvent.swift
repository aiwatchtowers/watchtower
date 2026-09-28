import Foundation

/// Wire error codes — raw values mirror `internal/chat/events.go`'s `Code*`.
package enum ChatErrorCode: String, Equatable, Sendable {
    case auth
    case rateLimit = "rate_limit"
    case providerUnavailable = "provider_unavailable"
    case sessionLost = "session_lost"
    case attachmentUnsupported = "attachment_unsupported"
    case interrupted
    case internalError = "internal"
}

package enum ChatTurnStatus: String, Equatable, Sendable {
    case complete
    case interrupted
}

package struct ChatToolStart: Equatable, Sendable {
    package let turnID: String
    package let id: String
    package let name: String
    /// The `args` object re-serialized with sorted keys ("{}" when absent).
    package let argsJSON: String

    package init(turnID: String, id: String, name: String, argsJSON: String) {
        self.turnID = turnID
        self.id = id
        self.name = name
        self.argsJSON = argsJSON
    }
}

/// `tool_end` carries no `name`: it is matched to its start by `id`.
package struct ChatToolEnd: Equatable, Sendable {
    package let turnID: String
    package let id: String
    package let ok: Bool
    package let summary: String
    package let sources: [ChatSource]

    package init(turnID: String, id: String, ok: Bool, summary: String, sources: [ChatSource]) {
        self.turnID = turnID
        self.id = id
        self.ok = ok
        self.summary = summary
        self.sources = sources
    }
}

package struct ChatUsage: Equatable, Sendable {
    package let turnID: String
    package let tokensIn: Int
    package let tokensOut: Int
    package let model: String

    package init(turnID: String, tokensIn: Int, tokensOut: Int, model: String) {
        self.turnID = turnID
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.model = model
    }
}

package struct ChatSessionError: Error, Equatable, Sendable {
    /// Non-nil = the turn's terminal event; nil = a session-level error.
    package let turnID: String?
    package let code: ChatErrorCode
    package let message: String
    package let retryable: Bool

    package init(turnID: String?, code: ChatErrorCode, message: String, retryable: Bool) {
        self.turnID = turnID
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

/// One `watchtower ai session` protocol-v2 event (spec §1.1). There is no
/// `reset` in v2: text already shown is never wiped (CHAT-02).
package enum ChatEvent: Equatable, Sendable {
    case sessionReady(sessionID: String?, provider: String, model: String)
    case turnStart(turnID: String)
    case textDelta(turnID: String, text: String)
    case toolStart(ChatToolStart)
    case toolEnd(ChatToolEnd)
    case usage(ChatUsage)
    case turnDone(turnID: String, status: ChatTurnStatus, sessionID: String?)
    case error(ChatSessionError)
    /// Synthesized by the process wrapper when the session process exits.
    case exited(status: Int32, stderrTail: String)

    /// Decodes one NDJSON line; nil for anything that is not a known v2 event.
    /// Omitted (`omitempty`) fields decode to their zero value.
    package static func parse(_ line: String) -> Self? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        let fields = Fields(json: json)
        switch type {
        case "session_ready":
            return .sessionReady(sessionID: fields.optional("session_id"), provider: fields.string("provider"),
                                 model: fields.string("model"))
        case "turn_start":
            return .turnStart(turnID: fields.string("turn_id"))
        case "text_delta":
            return .textDelta(turnID: fields.string("turn_id"), text: fields.string("text"))
        case "tool_start":
            return .toolStart(ChatToolStart(turnID: fields.string("turn_id"), id: fields.string("id"),
                                            name: fields.string("name"), argsJSON: fields.object("args")))
        case "tool_end":
            return .toolEnd(ChatToolEnd(turnID: fields.string("turn_id"), id: fields.string("id"),
                                        ok: fields.bool("ok"), summary: fields.string("summary"),
                                        sources: fields.sources()))
        case "usage":
            return .usage(ChatUsage(turnID: fields.string("turn_id"), tokensIn: fields.int("tokens_in"),
                                    tokensOut: fields.int("tokens_out"), model: fields.string("model")))
        case "turn_done":
            // An unknown status keeps the text as partial (Continue offered) rather than claiming completion.
            let status = ChatTurnStatus(rawValue: fields.string("status")) ?? .interrupted
            return .turnDone(turnID: fields.string("turn_id"), status: status,
                             sessionID: fields.optional("session_id"))
        case "error":
            return .error(ChatSessionError(turnID: fields.optional("turn_id"),
                                           code: ChatErrorCode(rawValue: fields.string("code")) ?? .internalError,
                                           message: fields.string("message"), retryable: fields.bool("retryable")))
        default:
            return nil
        }
    }
}

private struct Fields {
    let json: [String: Any]

    func string(_ key: String) -> String { json[key] as? String ?? "" }

    func optional(_ key: String) -> String? {
        guard let value = json[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    func int(_ key: String) -> Int { (json[key] as? NSNumber)?.intValue ?? 0 }

    func bool(_ key: String) -> Bool { json[key] as? Bool ?? false }

    func object(_ key: String) -> String {
        guard let value = json[key], JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }

    func sources() -> [ChatSource] {
        let items = json["sources"] as? [[String: Any]] ?? []
        return items.map { item in
            let field = Self(json: item)
            return ChatSource(kind: field.string("kind"), title: field.string("title"), url: field.optional("url"),
                              ref: field.string("ref"), group: field.optional("group"),
                              snippet: field.optional("snippet"), date: field.optional("date"))
        }
    }
}

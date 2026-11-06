import Foundation

/// Wire error codes — raw values mirror `internal/chat/events.go`'s `Code*`.
package enum ChatErrorCode: String, Equatable, Sendable {
    case auth
    case rateLimit = "rate_limit"
    /// Durable semantic code: a started tool turn must never be replayed.
    case quotaExhausted = "quota_exhausted"
    case providerUnavailable = "provider_unavailable"
    case sessionLost = "session_lost"
    case attachmentUnsupported = "attachment_unsupported"
    case interrupted
    case internalError = "internal"
    case workDirUnsafe = "workdir_unsafe"
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

/// `tool_wait` (spec 2026-10-16-chat-claude-ai-tools-design §3.1): the
/// permission gate holds step `id` until the owner answers the
/// `agent_actions` row `actionID` (`claude_ai_connector_call`). Live only —
/// the row is the durable state; the step's `tool_end` ends the wait.
package struct ChatToolWait: Equatable, Sendable {
    package let turnID: String
    package let id: String
    package let actionID: Int64
    package let message: String

    package init(turnID: String, id: String, actionID: Int64, message: String) {
        self.turnID = turnID
        self.id = id
        self.actionID = actionID
        self.message = message
    }
}

/// A turn's usage. `tokensIn` is every input token (CHAT-01); the split
/// beside it (fresh input, cache reads, cache writes, the provider's own cost,
/// an estimate flag) is additive: a line without it decodes to zeros, no
/// cost and not estimated.
package struct ChatUsage: Equatable, Sendable {
    package let turnID: String
    package let tokensIn: Int
    package let tokensOut: Int
    package let model: String
    package let freshIn: Int
    package let cacheRead: Int
    package let cacheWrite: Int
    package let costUSD: Double?
    package let estimated: Bool

    package init(turnID: String, tokensIn: Int, tokensOut: Int, model: String,
                 freshIn: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, costUSD: Double? = nil,
                 estimated: Bool = false) {
        self.turnID = turnID
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.model = model
        self.freshIn = freshIn
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.costUSD = costUSD
        self.estimated = estimated
    }
}

package struct ChatSessionError: Error, Equatable, Sendable {
    /// Non-nil = the turn's terminal event; nil = a session-level error.
    package let turnID: String?
    package let code: ChatErrorCode
    package let message: String
    package let retryable: Bool
    package let reason: String?
    package var persistenceCode: String {
        switch reason {
        case "quota_exhausted": ChatErrorCode.quotaExhausted.rawValue
        case "required_capability_missing": ChatErrorCode.attachmentUnsupported.rawValue
        default: code.rawValue
        }
    }

    package init(turnID: String?, code: ChatErrorCode, message: String, retryable: Bool, reason: String? = nil) {
        self.turnID = turnID
        self.code = code
        self.message = message
        self.retryable = retryable
        self.reason = reason
    }
}

/// Content-free routing metadata; actual selection can be empty before the first automatic turn.
package struct ChatRoutingMetadata: Equatable, Sendable {
    package let preferredProvider: String
    package let mode: String
    package let reason: String?

    package init(preferredProvider: String, mode: String, reason: String?) {
        self.preferredProvider = preferredProvider
        self.mode = mode
        self.reason = reason
    }

    package static func parse(_ json: [String: Any]) -> Self? {
        guard let mode = json["routing_mode"] as? String else { return nil }
        return Self(preferredProvider: json["preferred_provider"] as? String ?? "", mode: mode,
                    reason: json["reason"] as? String)
    }
}

/// One `watchtower ai session` protocol-v2 event (spec §1.1). There is no
/// `reset` in v2: text already shown is never wiped (CHAT-02).
package enum ChatEvent: Equatable, Sendable {
    // The wire's session_ready fields, as decoded; a struct would rename
    // every existing construction for one optional field.
    // swiftlint:disable:next enum_case_associated_values_count
    case sessionReady(sessionID: String?, provider: String, model: String, routing: ChatRoutingMetadata? = nil,
                      capabilities: ProviderCapabilities? = nil)
    case turnStart(turnID: String)
    case textDelta(turnID: String, text: String)
    case toolStart(ChatToolStart)
    case toolEnd(ChatToolEnd)
    case toolWait(ChatToolWait)
    case usage(ChatUsage)
    case turnDone(turnID: String, status: ChatTurnStatus, sessionID: String?)
    case error(ChatSessionError)
    /// Synthesized by the process wrapper when the session process exits.
    case exited(status: Int32, stderrTail: String)

    /// The session_ready's capability row (the actual provider's); nil when
    /// absent (the routing placeholder, an older CLI) or unreadable.
    private static func capabilities(_ value: Any?) -> ProviderCapabilities? {
        guard let object = value as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(ProviderCapabilities.self, from: data)
    }

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
                                 model: fields.string("model"), routing: ChatRoutingMetadata.parse(json),
                                 capabilities: Self.capabilities(json["capabilities"]))
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
        case "tool_wait":
            // All four fields are always sent; one missing means a broken
            // line, never a waiting step without the row the owner answers.
            guard let turnID = fields.optional("turn_id"), let id = fields.optional("id"),
                  let message = fields.optional("message"), let actionID = fields.positiveInt64("action_id")
            else { return nil }
            return .toolWait(ChatToolWait(turnID: turnID, id: id, actionID: actionID, message: message))
        case "usage":
            return .usage(ChatUsage(turnID: fields.string("turn_id"), tokensIn: fields.int("tokens_in"),
                                    tokensOut: fields.int("tokens_out"), model: fields.string("model"),
                                    freshIn: fields.int("fresh_in"), cacheRead: fields.int("cache_read"),
                                    cacheWrite: fields.int("cache_write"), costUSD: fields.double("cost_usd"),
                                    estimated: fields.bool("estimated")))
        case "turn_done":
            // An unknown status keeps the text as partial (Continue offered) rather than claiming completion.
            let status = ChatTurnStatus(rawValue: fields.string("status")) ?? .interrupted
            return .turnDone(turnID: fields.string("turn_id"), status: status,
                             sessionID: fields.optional("session_id"))
        case "error":
            return .error(ChatSessionError(turnID: fields.optional("turn_id"),
                                           code: ChatErrorCode(rawValue: fields.string("code")) ?? .internalError,
                                           message: fields.string("message"), retryable: fields.bool("retryable"),
                                           reason: fields.optional("reason")))
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

    /// A JSON number; nil when absent, a bool or anything else.
    func double(_ key: String) -> Double? {
        guard let number = json[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    /// A JSON integer > 0 that fits Int64; nil for a bool, a fraction, a
    /// string or anything out of range.
    func positiveInt64(_ key: String) -> Int64? {
        guard let number = json[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.compare(NSNumber(value: number.int64Value)) == .orderedSame,
              number.int64Value > 0 else { return nil }
        return number.int64Value
    }

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

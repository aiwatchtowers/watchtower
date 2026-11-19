import Foundation

/// An approval card's action (the `approval` part payload, Go `chatengine.approvalPart`, or a feed action of a Mac one
/// version behind). The card fields past `reason` are optional on the wire: a payload from a daemon one version behind
/// decodes with their defaults (D22).
public struct ChatApprovalPayload: Decodable, Hashable, Sendable {
    public let id: Int64
    public let tool: String
    public let title: String
    /// The action's arguments as indented JSON (Go `tools` display text), clipped past 4000 characters.
    public let argsDisplay: String
    /// The hash the owner approves: an approval binds to exactly these arguments.
    public let argsSHA256: String
    /// pending, approved, executing, applied, rejected or failed.
    public let status: String
    public let reason: String?
    /// An External tool (it writes outside Watchtower).
    public let external: Bool
    /// The row's error; "" when none.
    public let error: String
    /// The result keys the card shows (`url`, `label`, `key`, `target_id`, `board_name`, `version`, `warning`), each
    /// value at most 512 bytes; empty when none.
    public let result: [String: String]
    /// The turn that proposed the action; "" when unknown.
    public let turnID: String
    /// False when `argsDisplay` was clipped (or the daemon did not say): no editor and no Confluence diff.
    public let argsComplete: Bool

    public init(
        id: Int64,
        tool: String,
        title: String,
        argsDisplay: String,
        argsSHA256: String,
        status: String,
        reason: String? = nil,
        external: Bool = false,
        error: String = "",
        result: [String: String] = [:],
        turnID: String = "",
        argsComplete: Bool = false
    ) {
        self.id = id
        self.tool = tool
        self.title = title
        self.argsDisplay = argsDisplay
        self.argsSHA256 = argsSHA256
        self.status = status
        self.reason = reason
        self.external = external
        self.error = error
        self.result = result
        self.turnID = turnID
        self.argsComplete = argsComplete
    }

    public init(action: ChatFeed.Action) {
        self.init(id: action.id, tool: action.tool, title: action.title, argsDisplay: action.argsDisplay,
                  argsSHA256: action.argsSHA256, status: action.status, reason: action.reason,
                  external: action.external, error: action.error, result: action.result, turnID: action.turnID,
                  argsComplete: action.argsComplete)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        tool = try c.decode(String.self, forKey: .tool)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        argsDisplay = try c.decodeIfPresent(String.self, forKey: .argsDisplay) ?? ""
        argsSHA256 = try c.decodeIfPresent(String.self, forKey: .argsSHA256) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        external = try c.decodeIfPresent(Bool.self, forKey: .external) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
        result = try c.decodeIfPresent([String: String].self, forKey: .result) ?? [:]
        turnID = try c.decodeIfPresent(String.self, forKey: .turnID) ?? ""
        argsComplete = try c.decodeIfPresent(Bool.self, forKey: .argsComplete) ?? false
    }

    // convertFromSnakeCase maps "args_sha256" -> "argsSha256", "turn_id" -> "turnId".
    enum CodingKeys: String, CodingKey {
        case id, tool, title, argsDisplay, status, reason, external, error, result, argsComplete
        case argsSHA256 = "argsSha256"
        case turnID = "turnId"
    }

    /// The arguments as a JSON object; empty when the display text is not one.
    public var args: [String: Any] {
        guard let data = argsDisplay.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    public var isPending: Bool { status == "pending" }
}

import Foundation

/// Commands mobile can enqueue; the desktop applies them through its
/// existing Queries. Closed set — rawValues are wire format, never rename.
public enum ActionKind: String, Codable, CaseIterable {
    case targetDone = "target_done"
    case targetSnooze = "target_snooze"
    case inboxResolve = "inbox_resolve"
    case inboxDismiss = "inbox_dismiss"
    case inboxSnooze = "inbox_snooze"
    case taskCreate = "task_create"
    case trackRead = "track_read"
    case situationDone = "situation_done"
    case situationDismiss = "situation_dismiss"
    case situationSnooze = "situation_snooze"
    case situationKeepOpen = "situation_keep_open"
    case dayPlanItemDone = "day_plan_item_done"
    case dayPlanItemSkip = "day_plan_item_skip"
    case digestRead = "digest_read"
    case streamDigestRead = "stream_digest_read"
    /// Link check (mobile POC spec §5.2): params `{nonce}`, hub-only,
    /// idempotent; `applied` carries `result = {nonce, hub_id}`.
    case probe
}

/// Wire status of one action record (spec §5.2). Only the Mac moves a record
/// out of `pending`.
public enum ActionStatus: String, Codable, CaseIterable {
    case pending
    /// The hub dequeued the record and started work (written before any work
    /// for the kinds whose sheets show a "Mac picked it up" stage).
    case received
    /// The hub holds the request (for example, waiting for the owner).
    case held
    case applied
    case failed
    case expired
    case cancelled

    /// A status this build does not know decodes as `pending`, so an echo
    /// from a newer Mac never fails the whole record.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .pending
    }
}

public struct ActionRequestPayload: Codable, Equatable {
    public let id: String
    public let kind: ActionKind
    public let entityID: String?
    public let params: [String: JSONValue]
    public let createdAt: Date
    public var status: ActionStatus
    public var errorMessage: String?
    /// The linked phone that created the request (spec §5.2 rule 4). nil
    /// encodes to an absent key, like every optional below.
    public let deviceID: String?
    /// Closed code the Mac writes on a failure, hold or expiry. A code this
    /// build does not know decodes as nil (the echo still decodes).
    public var reason: ActionReason?
    /// Object the Mac writes on `applied` (for `probe`: `{nonce, hub_id}`).
    /// Its keys are verbatim: the coder's key strategy never rewrites
    /// dictionary keys.
    public var result: [String: JSONValue]?

    public var recordName: String { "action-\(id)" }

    // Explicit CodingKeys are required because:
    // - convertToSnakeCase encodes "entityID" as "entity_id" correctly.
    // - convertFromSnakeCase maps "entity_id" -> "entityId" (lowercase d),
    //   not "entityID", so the CodingKey stringValue must be "entityId" to match.
    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case entityID = "entityId"
        case params
        case createdAt
        case status
        case errorMessage
        case deviceID = "deviceId"
        case reason
        case result
    }

    public init(
        id: String,
        kind: ActionKind,
        entityID: String?,
        params: [String: JSONValue] = [:],
        createdAt: Date,
        deviceID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.entityID = entityID
        self.params = params
        self.createdAt = createdAt
        self.status = .pending
        self.errorMessage = nil
        self.deviceID = deviceID
        self.reason = nil
        self.result = nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(ActionKind.self, forKey: .kind)
        entityID = try container.decodeIfPresent(String.self, forKey: .entityID)
        params = try container.decode([String: JSONValue].self, forKey: .params)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        status = try container.decode(ActionStatus.self, forKey: .status)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        reason = try container.decodeIfPresent(String.self, forKey: .reason).flatMap(ActionReason.init(rawValue:))
        result = try container.decodeIfPresent([String: JSONValue].self, forKey: .result)
    }
}

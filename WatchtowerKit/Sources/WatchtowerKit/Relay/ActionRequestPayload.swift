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
}

public enum ActionStatus: String, Codable {
    case pending
    case applied
    case failed
}

public struct ActionRequestPayload: Codable, Equatable {
    public let id: String
    public let kind: ActionKind
    public let entityID: String?
    public let params: [String: JSONValue]
    public let createdAt: Date
    public var status: ActionStatus
    public var errorMessage: String?

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
    }

    public init(
        id: String,
        kind: ActionKind,
        entityID: String?,
        params: [String: JSONValue] = [:],
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.entityID = entityID
        self.params = params
        self.createdAt = createdAt
        self.status = .pending
        self.errorMessage = nil
    }
}

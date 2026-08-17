import Foundation

/// The product-slice entity kinds synced through DataZone.
/// rawValue is part of the wire format — never rename existing cases.
public enum SliceKind: String, Codable, CaseIterable, Sendable {
    case briefing
    case inboxItem = "inbox_item"
    case target
    case track
    case digest
    case digestTopic = "digest_topic"
    case calendarEvent = "calendar_event"
    case personCard = "person_card"
    case situation
    case meetingTranscript = "meeting_transcript"
    case dayPlan = "day_plan"
    case dayPlanItem = "day_plan_item"
    /// Desktop Feature Manager satellite state: one record per registry
    /// feature id, payload `{id, enabled}`. The phone only READS it —
    /// features are never toggled from the phone (owner decision,
    /// 2026-08-17 reanimation plan Workstream 3).
    case featureState = "feature_state"

    public func recordName(id: String) -> String {
        "\(rawValue)-\(id)"
    }
}

/// One synced slice row: identity + row payload (RowPayloadCoder JSON).
public struct SliceRecord: Equatable {
    public let kind: SliceKind
    public let id: String
    public let modifiedAt: Date
    public let payload: Data
    /// Desktop-computed notification tag (Plan 6 Decision 3): "urgent"
    /// (inbox item that is priority high AND status pending) or "briefing"
    /// (today's briefing row on its first publish into the sync generation).
    /// Record-level metadata like `modifiedAt` — never a row-payload key.
    /// nil (everything else) is omitted from the wire — the `isError`
    /// discipline — so pre-Plan-6 records and untagged records are
    /// indistinguishable and old/new versions interoperate. The phone never
    /// re-derives importance from row contents; this field is the only channel.
    public let notifyLevel: String?

    public var recordName: String { kind.recordName(id: id) }

    public init(kind: SliceKind, id: String, modifiedAt: Date, payload: Data, notifyLevel: String? = nil) {
        self.kind = kind
        self.id = id
        self.modifiedAt = modifiedAt
        self.payload = payload
        self.notifyLevel = notifyLevel
    }
}

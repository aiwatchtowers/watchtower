import Foundation

/// The product-slice entity kinds synced through DataZone.
/// rawValue is part of the wire format — never rename existing cases.
public enum SliceKind: String, Codable, CaseIterable {
    case briefing
    case inboxItem = "inbox_item"
    case target
    case track
    case digest
    case digestTopic = "digest_topic"
    case calendarEvent = "calendar_event"
    case personCard = "person_card"

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

    public var recordName: String { kind.recordName(id: id) }

    public init(kind: SliceKind, id: String, modifiedAt: Date, payload: Data) {
        self.kind = kind
        self.id = id
        self.modifiedAt = modifiedAt
        self.payload = payload
    }
}

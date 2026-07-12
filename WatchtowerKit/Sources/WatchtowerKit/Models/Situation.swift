import Foundation
import GRDB

// MARK: - Situation

/// A cluster of related inbox signals composed into a single narrative unit
/// for the secretary dashboard — the mobile mirror of the desktop's
/// `Situation` model over the `situations` table (see
/// `internal/inbox/compose.go` on the Go side). The slice payload also
/// carries `signal_ids` — a JSON array of member inbox-item ids the
/// publisher joins in from `situation_signals`, so the phone can render
/// member signals from its own inbox slice without syncing the join table.
public struct Situation: FetchableRecord, Identifiable, Equatable {
    public let id: Int
    public let title: String
    public let kindRaw: String        // column: kind
    public let statusRaw: String      // column: status
    public let priority: String
    public let rank: Double
    public let aiReason: String       // column: ai_reason
    public let summary: String
    public let whyMatters: String     // column: why_matters
    public let chronology: String
    public let cardStatusRaw: String  // column: card_status
    public let targetID: Int?         // column: target_id
    public let trackID: Int?          // column: track_id
    public let convertedTargetID: Int?  // column: converted_target_id
    public let convertedTrackID: Int?   // column: converted_track_id
    public let lastSignalAt: String     // column: last_signal_at
    public let snoozeUntil: String      // column: snooze_until
    public let suggestedResolution: String  // column: suggested_resolution
    public let signalIDs: String        // column: signal_ids (publisher-joined JSON array)
    public let createdAt: String
    public let updatedAt: String

    public enum Kind: String {
        case external
        case targetUpdate = "target_update"
        case trackUpdate = "track_update"
        case mixed
    }

    public enum Status: String {
        case open
        case done
        case dismissed
        case converted
        case stale
        case snoozed
    }

    public enum CardStatus: String {
        case none
        case ready
        case failed
    }

    public init(row: Row) {
        id = row["id"]
        title = row["title"] ?? ""
        kindRaw = row["kind"] ?? "external"
        statusRaw = row["status"] ?? "open"
        priority = row["priority"] ?? "medium"
        rank = row["rank"] ?? 0
        aiReason = row["ai_reason"] ?? ""
        summary = row["summary"] ?? ""
        whyMatters = row["why_matters"] ?? ""
        chronology = row["chronology"] ?? ""
        cardStatusRaw = row["card_status"] ?? "none"
        targetID = row["target_id"]
        trackID = row["track_id"]
        convertedTargetID = row["converted_target_id"]
        convertedTrackID = row["converted_track_id"]
        lastSignalAt = row["last_signal_at"] ?? ""
        snoozeUntil = row["snooze_until"] ?? ""
        suggestedResolution = row["suggested_resolution"] ?? ""
        signalIDs = row["signal_ids"] ?? "[]"
        createdAt = row["created_at"] ?? ""
        updatedAt = row["updated_at"] ?? ""
    }

    // MARK: - Typed accessors

    public var kind: Kind { Kind(rawValue: kindRaw) ?? .external }
    public var status: Status { Status(rawValue: statusRaw) ?? .open }
    public var cardStatus: CardStatus { CardStatus(rawValue: cardStatusRaw) ?? .none }

    /// True when a secretary card has been successfully generated for this situation.
    public var hasCard: Bool { cardStatus == .ready }

    /// True when the secretary has marked this situation as looking resolved (DASH-07).
    public var hasSuggestedResolution: Bool { !suggestedResolution.isEmpty }

    /// Member inbox-item ids from the publisher-joined `signal_ids` array.
    public var decodedSignalIDs: [Int] {
        guard !signalIDs.isEmpty, signalIDs != "[]",
              let data = signalIDs.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Int].self, from: data)) ?? []
    }

    // MARK: - Date helpers

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    private static let iso8601Standard: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    private static func parseDate(_ raw: String) -> Date? {
        if let date = iso8601WithFractional.date(from: raw) { return date }
        return iso8601Standard.date(from: raw)
    }

    public var updatedDate: Date? { Self.parseDate(updatedAt) }

    /// The real time of the newest member signal composed into this
    /// situation, for display in place of `created_at`/`updated_at`. Falls
    /// back to `updatedAt` for bare target/track-update situations with no
    /// member signals (mirrors the desktop's `lastSignalDate`).
    public var lastSignalDate: Date? {
        Self.parseDate(lastSignalAt) ?? updatedDate
    }

    public var lastSignalAgo: String {
        guard let date = lastSignalDate else { return "" }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        let days = Int(interval / 86400)
        return days == 1 ? "1d ago" : "\(days)d ago"
    }

    // MARK: - Priority helpers

    public var priorityOrder: Int {
        switch priority {
        case "high": return 0
        case "medium": return 1
        case "low": return 2
        default: return 1
        }
    }
}

import Foundation
import GRDB

// MARK: - Situation

/// A cluster of related inbox signals composed into a single narrative unit for the
/// secretary dashboard — see `internal/inbox/compose.go` on the Go side (table `situations`).
struct Situation: FetchableRecord, Identifiable, Equatable {
    let id: Int
    let title: String
    let kindRaw: String        // column: kind
    let statusRaw: String      // column: status
    let priority: String
    let rank: Double
    let aiReason: String       // column: ai_reason
    let summary: String
    let whyMatters: String     // column: why_matters
    let chronology: String
    let cardStatusRaw: String  // column: card_status
    let targetID: Int?         // column: target_id
    let trackID: Int?          // column: track_id
    let convertedTargetID: Int?  // column: converted_target_id
    let convertedTrackID: Int?   // column: converted_track_id
    let lastSignalAt: String     // column: last_signal_at
    let snoozeUntil: String      // column: snooze_until
    let suggestedResolution: String   // column: suggested_resolution
    let createdAt: Date?         // column: created_at (ISO8601)
    let updatedAt: Date?         // column: updated_at (ISO8601)

    enum Kind: String {
        case external
        case targetUpdate = "target_update"
        case trackUpdate = "track_update"
        case mixed
    }

    enum Status: String {
        case open
        case done
        case dismissed
        case converted
        case stale
        case snoozed
    }

    enum CardStatus: String {
        case none
        case ready
        case failed
    }

    /// Typed kind derived from the `kind` column.
    var kind: Kind {
        Kind(rawValue: kindRaw) ?? .external
    }

    /// Typed status derived from the `status` column.
    var status: Status {
        Status(rawValue: statusRaw) ?? .open
    }

    /// Typed card status derived from the `card_status` column.
    var cardStatus: CardStatus {
        CardStatus(rawValue: cardStatusRaw) ?? .none
    }

    /// True when a secretary card has been successfully generated for this situation.
    var hasCard: Bool { cardStatus == .ready }

    /// True when the secretary has marked this situation as looking resolved (DASH-07).
    var hasSuggestedResolution: Bool { !suggestedResolution.isEmpty }

    /// Parsed `last_signal_at` — the real time of the newest member signal (or
    /// work-update event) composed into this situation, for display in place of
    /// `created_at`/`updated_at`. Falls back to `updatedAt` when empty, which
    /// happens for bare target/track-update situations with no member signals
    /// (`AddSituationSignals` is what sets `last_signal_at` on the Go side).
    var lastSignalDate: Date? {
        Self.parseDate(lastSignalAt) ?? updatedAt
    }

    init(row: Row) {
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
        targetID = row["target_id"] as Int?
        trackID = row["track_id"] as Int?
        convertedTargetID = row["converted_target_id"] as Int?
        convertedTrackID = row["converted_track_id"] as Int?
        lastSignalAt = row["last_signal_at"] ?? ""
        snoozeUntil = row["snooze_until"] ?? ""
        suggestedResolution = row["suggested_resolution"] ?? ""
        createdAt = Self.parseDate(row["created_at"])
        updatedAt = Self.parseDate(row["updated_at"])
    }

    // MARK: - Date Helpers

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

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return iso8601WithFractional.date(from: value) ?? iso8601Standard.date(from: value)
    }
}

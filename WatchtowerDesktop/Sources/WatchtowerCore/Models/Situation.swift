import Foundation
import GRDB

// MARK: - Situation

/// A cluster of related inbox signals composed into a single narrative unit for the
/// secretary dashboard — see `internal/inbox/compose.go` on the Go side (table `situations`).
package struct Situation: FetchableRecord, Identifiable, Equatable {
    package let id: Int
    package let title: String
    package let kindRaw: String        // column: kind
    package let statusRaw: String      // column: status
    package let priority: String
    package let rank: Double
    package let aiReason: String       // column: ai_reason
    package let summary: String
    package let whyMatters: String     // column: why_matters
    package let chronology: String
    package let cardStatusRaw: String  // column: card_status
    package let targetID: Int?         // column: target_id
    package let trackID: Int?          // column: track_id
    package let convertedTargetID: Int?  // column: converted_target_id
    package let convertedTrackID: Int?   // column: converted_track_id
    package let lastSignalAt: String     // column: last_signal_at
    package let snoozeUntil: String      // column: snooze_until
    package let suggestedResolution: String   // column: suggested_resolution
    package let createdAt: Date?         // column: created_at (ISO8601)
    package let updatedAt: Date?         // column: updated_at (ISO8601)

    package enum Kind: String {
        case external
        case targetUpdate = "target_update"
        case trackUpdate = "track_update"
        case mixed
    }

    package enum Status: String {
        case open
        case done
        case dismissed
        case converted
        case stale
        case snoozed
    }

    package enum CardStatus: String {
        case none
        case ready
        case failed
    }

    /// Typed kind derived from the `kind` column.
    package var kind: Kind {
        Kind(rawValue: kindRaw) ?? .external
    }

    /// Typed status derived from the `status` column.
    package var status: Status {
        Status(rawValue: statusRaw) ?? .open
    }

    /// Typed card status derived from the `card_status` column.
    package var cardStatus: CardStatus {
        CardStatus(rawValue: cardStatusRaw) ?? .none
    }

    /// True when a situation card has been successfully generated for this situation.
    package var hasCard: Bool { cardStatus == .ready }

    /// True when the assistant has marked this situation as looking resolved (DASH-07).
    package var hasSuggestedResolution: Bool { !suggestedResolution.isEmpty }

    /// Parsed `last_signal_at` — the real time of the newest member signal (or
    /// work-update event) composed into this situation, for display in place of
    /// `created_at`/`updated_at`. Falls back to `updatedAt` when empty, which
    /// happens for bare target/track-update situations with no member signals
    /// (`AddSituationSignals` is what sets `last_signal_at` on the Go side).
    package var lastSignalDate: Date? {
        Self.parseDate(lastSignalAt) ?? updatedAt
    }

    package init(row: Row) {
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

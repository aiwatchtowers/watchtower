import Foundation

/// The daemon's live sync heartbeat (`sync_progress.json` in the workspace
/// directory, written by `internal/sync/heartbeat.go`). A dual-path contract
/// with the Go writer: field names, the staleness window, and the "active but
/// stale means not syncing" rule must move together on both sides.
///
/// `last_sync.json` says when a sync last *finished*; this says whether one is
/// running right now and how far along — the question the tray could not answer
/// before, since sync progress lived only in the daemon's memory.
package struct SyncProgress: Decodable, Equatable {
    package let active: Bool
    package let phase: String
    package let detail: String?
    package let messagesFetched: Int
    package let startedAt: String?
    package let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case active, phase, detail
        case messagesFetched = "messages_fetched"
        case startedAt = "started_at"
        case updatedAt = "updated_at"
    }

    /// Mirrors `sync.StaleAfter` in Go. A daemon killed mid-sync leaves
    /// `active: true` in the file forever, so freshness — not the flag — is
    /// what decides whether a sync is really running.
    package static let staleAfter: TimeInterval = 120

    package var updatedDate: Date? { Self.parseTimestamp(updatedAt) }

    package func isSyncing(now: Date = Date()) -> Bool {
        guard active, let updated = updatedDate else { return false }
        return now.timeIntervalSince(updated) <= Self.staleAfter
    }

    /// One short line for the menu bar: the phase, plus its counter when the
    /// phase has one ("Messages · 34/105 channels").
    package var summary: String {
        guard let detail, !detail.isEmpty else { return phase }
        return "\(phase) · \(detail)"
    }

    /// Go writes RFC3339 with fractional seconds; `ISO8601DateFormatter`'s
    /// default options reject those, so both spellings are tried.
    package static func parseTimestamp(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

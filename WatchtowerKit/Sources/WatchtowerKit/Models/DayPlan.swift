import Foundation
import GRDB

// MARK: - DayPlan

/// The AI-generated plan for one day — the mobile mirror of the desktop's
/// `DayPlan` over `day_plans` (see `internal/dayplan` on the Go side).
///
/// Only TODAY's plan is published (the publisher's window), so the phone never
/// has to pick among plans: at most one row exists.
public struct DayPlan: FetchableRecord, Identifiable, Equatable {
    public let id: Int
    public let planDate: String          // column: plan_date, "yyyy-MM-dd"
    public let statusRaw: String         // column: status
    public let hasConflicts: Bool        // column: has_conflicts
    /// Free text describing overlapping blocks; empty when there are none.
    public let conflictSummary: String   // column: conflict_summary
    public let generatedAt: String       // column: generated_at

    public enum Status: String {
        case active
        case archived
    }

    public init(row: Row) {
        id = row["id"]
        planDate = row["plan_date"] ?? ""
        statusRaw = row["status"] ?? "active"
        hasConflicts = (row["has_conflicts"] as Int? ?? 0) != 0
        conflictSummary = row["conflict_summary"] ?? ""
        generatedAt = row["generated_at"] ?? ""
    }

    public var status: Status { Status(rawValue: statusRaw) ?? .active }
}

// MARK: - DayPlanItem

/// One block or backlog entry of a day plan — the mobile mirror of the
/// desktop's `DayPlanItem` over `day_plan_items`.
public struct DayPlanItem: FetchableRecord, Identifiable, Equatable {
    public let id: Int
    public let dayPlanID: Int            // column: day_plan_id
    public let kindRaw: String           // column: kind
    public let sourceTypeRaw: String     // column: source_type
    public let sourceID: String          // column: source_id
    public let title: String
    /// column: description — `details` here, mirroring the desktop model's
    /// rename away from the `description` clash.
    public let details: String
    /// Why the planner put this here — the AI's own justification.
    public let rationale: String
    public let startTime: String         // column: start_time (ISO8601, empty when unscheduled)
    public let endTime: String           // column: end_time
    public let durationMin: Int          // column: duration_min
    public let priority: String
    public let statusRaw: String         // column: status
    public let orderIndex: Int           // column: order_index

    public enum Kind: String {
        case timeblock
        case backlog
    }

    public enum Status: String {
        case pending
        case done
        case skipped
    }

    public init(row: Row) {
        id = row["id"]
        dayPlanID = row["day_plan_id"] ?? 0
        kindRaw = row["kind"] ?? "timeblock"
        sourceTypeRaw = row["source_type"] ?? "manual"
        sourceID = row["source_id"] ?? ""
        title = row["title"] ?? ""
        details = row["description"] ?? ""
        rationale = row["rationale"] ?? ""
        startTime = row["start_time"] ?? ""
        endTime = row["end_time"] ?? ""
        durationMin = row["duration_min"] ?? 0
        priority = row["priority"] ?? ""
        statusRaw = row["status"] ?? "pending"
        orderIndex = row["order_index"] ?? 0
    }

    public var kind: Kind { Kind(rawValue: kindRaw) ?? .timeblock }
    public var status: Status { Status(rawValue: statusRaw) ?? .pending }
    public var isPending: Bool { status == .pending }

    /// Calendar-sourced blocks are read-only everywhere — the desktop's
    /// `isReadOnly` rule, mirrored so the phone offers no action that the Mac
    /// would refuse to honor.
    public var isReadOnly: Bool { sourceTypeRaw == "calendar" }

    /// "HH:mm–HH:mm" for a scheduled block; nil when either bound is missing
    /// (backlog entries, unscheduled blocks).
    public var timeRange: String? {
        guard let start = Self.parseDate(startTime), let end = Self.parseDate(endTime) else { return nil }
        return "\(Self.hourMinute.string(from: start))–\(Self.hourMinute.string(from: end))"
    }

    /// Start instant for ordering/agenda math; nil when unscheduled.
    public var startDate: Date? { Self.parseDate(startTime) }

    // MARK: - Date helpers

    private static let hourMinute: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    private static let iso8601Standard = ISO8601DateFormatter()

    private static func parseDate(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        return iso8601Standard.date(from: raw) ?? iso8601WithFractional.date(from: raw)
    }
}

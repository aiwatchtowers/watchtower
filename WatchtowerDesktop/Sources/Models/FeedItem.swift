import Foundation
import GRDB

// MARK: - FeedItem

/// One row of the dashboard feed index (table `feed_items`) — chronology plus
/// per-item user state. Content is joined live from the source table named by
/// `itemType`; see `FeedItemQueries.fetchFeed` and `internal/feed` on the Go side.
struct FeedItem: FetchableRecord, Identifiable, Equatable {
    let id: Int64
    let itemTypeRaw: String    // column: item_type
    let sourceID: String       // column: source_id
    let eventTs: String        // column: event_ts (ISO8601)
    let importance: Int
    let hiddenAt: String?      // column: hidden_at
    let seenAt: String?        // column: seen_at

    enum ItemType: String, CaseIterable {
        case situation
        case meeting
        case briefing
        case meetingRecap = "meeting_recap"
        case dayPlan = "day_plan"

        /// Filter-chip / badge label.
        var label: String {
            switch self {
            case .situation: return "Situations"
            case .meeting: return "Meetings"
            case .briefing: return "Briefings"
            case .meetingRecap: return "Recaps"
            case .dayPlan: return "Plans"
            }
        }
    }

    var itemType: ItemType { ItemType(rawValue: itemTypeRaw) ?? .situation }
    var isSeen: Bool { seenAt != nil }

    init(row: Row) {
        id = row["id"]
        itemTypeRaw = row["item_type"] ?? "situation"
        sourceID = row["source_id"] ?? ""
        eventTs = row["event_ts"] ?? ""
        importance = row["importance"] ?? 50
        hiddenAt = row["hidden_at"] as String?
        seenAt = row["seen_at"] as String?
    }

    private static let iso8601: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    var eventDate: Date? { Self.iso8601.date(from: eventTs) }
}

// MARK: - FeedContent / FeedEntry

/// The live-joined source content behind a feed item.
enum FeedContent: Equatable {
    case situation(Situation)
    case meeting(CalendarEvent, prep: MeetingPrepResult?)
    case briefing(Briefing)
    case meetingRecap(MeetingRecap, event: CalendarEvent?)
    case dayPlan(DayPlan)
}

extension MeetingRecap: Equatable {
    // Swift can only auto-synthesize `==` for a struct within its declaring
    // file; MeetingRecap.swift doesn't declare Equatable, so it's spelled
    // out manually here (all stored properties are simple Strings).
    static func == (lhs: MeetingRecap, rhs: MeetingRecap) -> Bool {
        lhs.eventID == rhs.eventID
            && lhs.sourceText == rhs.sourceText
            && lhs.recapJSON == rhs.recapJSON
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
    }
}

/// A feed index row plus its resolved content — one entry of the wall.
struct FeedEntry: Identifiable, Equatable {
    let item: FeedItem
    let content: FeedContent
    var id: Int64 { item.id }
}

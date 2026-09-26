import Foundation
import GRDB

// MARK: - Catch-Up absence-recap models
//
// These mirror the Go side: the `catchup_recaps` row (internal/db/catchup_store.go)
// and the `catchup.compose` body / coverage JSON (internal/catchup/types.go).
// Every body and coverage field decodes tolerantly — the JSON is model output
// persisted verbatim, so a missing key must read as an empty value, never as a
// decode failure that blanks the whole recap.

/// One source row a recap item was built from. Mirrors the Go `CatchupRef`
/// ({area,id,label}); `id` decodes from the JSON key `id`.
package struct CatchUpRef: Codable, Identifiable, Equatable {
    package let area: String
    package let id: Int
    package let label: String

    /// Stable identity for SwiftUI lists: the row `id` is per-table autoincrement,
    /// so two refs in different areas can share it — key by area+id instead.
    package var compositeID: String { "\(area):\(id)" }

    package enum CodingKeys: String, CodingKey {
        case area, id, label
    }

    package init(area: String, id: Int, label: String) {
        self.area = area
        self.id = id
        self.label = label
    }

    // Tolerate missing fields from older payloads / partial model output.
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        area = try container.decodeIfPresent(String.self, forKey: .area) ?? ""
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
    }
}

/// One narrative topic — the recap's main unit. Mirrors the Go `catchup.Topic`.
package struct CatchUpTopic: Codable, Equatable {
    package let title: String
    package let narrative: String
    package let priority: String
    package let refs: [CatchUpRef]

    package enum CodingKeys: String, CodingKey {
        case title, narrative, priority, refs
    }

    package init(title: String = "", narrative: String = "", priority: String = "", refs: [CatchUpRef] = []) {
        self.title = title
        self.narrative = narrative
        self.priority = priority
        self.refs = refs
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        narrative = try container.decodeIfPresent(String.self, forKey: .narrative) ?? ""
        priority = try container.decodeIfPresent(String.self, forKey: .priority) ?? ""
        refs = try container.decodeIfPresent([CatchUpRef].self, forKey: .refs) ?? []
    }
}

/// One decision line. Mirrors the Go `catchup.Entry`.
package struct CatchUpEntry: Codable, Equatable {
    package let text: String
    package let refs: [CatchUpRef]

    package enum CodingKeys: String, CodingKey {
        case text, refs
    }

    package init(text: String = "", refs: [CatchUpRef] = []) {
        self.text = text
        self.refs = refs
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        refs = try container.decodeIfPresent([CatchUpRef].self, forKey: .refs) ?? []
    }
}

/// One meeting the operator missed. Mirrors the Go `catchup.MeetingEntry`.
package struct CatchUpMeeting: Codable, Equatable {
    package let title: String
    package let summary: String
    package let refs: [CatchUpRef]

    package enum CodingKeys: String, CodingKey {
        case title, summary, refs
    }

    package init(title: String = "", summary: String = "", refs: [CatchUpRef] = []) {
        self.title = title
        self.summary = summary
        self.refs = refs
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        refs = try container.decodeIfPresent([CatchUpRef].self, forKey: .refs) ?? []
    }
}

/// One thing waiting on the operator. Mirrors the Go `catchup.NeedEntry`.
package struct CatchUpNeed: Codable, Equatable {
    package let text: String
    package let kind: String
    package let refs: [CatchUpRef]

    package enum CodingKeys: String, CodingKey {
        case text, kind, refs
    }

    package init(text: String = "", kind: String = "", refs: [CatchUpRef] = []) {
        self.text = text
        self.kind = kind
        self.refs = refs
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        refs = try container.decodeIfPresent([CatchUpRef].self, forKey: .refs) ?? []
    }
}

/// The parsed `catchup_recaps.body_json`. Mirrors the Go `catchup.RecapBody`.
package struct CatchUpRecapBody: Codable, Equatable {
    package let topics: [CatchUpTopic]
    package let decisions: [CatchUpEntry]
    package let meetings: [CatchUpMeeting]
    package let needsYou: [CatchUpNeed]

    package enum CodingKeys: String, CodingKey {
        case topics, decisions, meetings
        case needsYou = "needs_you"
    }

    package init(
        topics: [CatchUpTopic] = [],
        decisions: [CatchUpEntry] = [],
        meetings: [CatchUpMeeting] = [],
        needsYou: [CatchUpNeed] = []
    ) {
        self.topics = topics
        self.decisions = decisions
        self.meetings = meetings
        self.needsYou = needsYou
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        topics = try container.decodeIfPresent([CatchUpTopic].self, forKey: .topics) ?? []
        decisions = try container.decodeIfPresent([CatchUpEntry].self, forKey: .decisions) ?? []
        meetings = try container.decodeIfPresent([CatchUpMeeting].self, forKey: .meetings) ?? []
        needsYou = try container.decodeIfPresent([CatchUpNeed].self, forKey: .needsYou) ?? []
    }

    /// True for the "nothing happened while you were away" recap — the Go
    /// pipeline short-circuits an empty gather to a ready, empty-bodied row.
    package var isEmpty: Bool {
        topics.isEmpty && decisions.isEmpty && meetings.isEmpty && needsYou.isEmpty
    }
}

/// The parsed `catchup_recaps.coverage_json` — how far each source pipeline had
/// actually summarised when the recap was composed. Mirrors the Go
/// `catchup.Coverage`; `slackTo`/`streamsTo` are unix seconds, 0 = no coverage.
package struct CatchUpCoverage: Codable, Equatable {
    package let slackTo: Double
    package let streamsTo: Double
    package let meetings: Int
    /// `ok` | `skipped` | `failed` — the coverage top-up's outcome (CATCHUP-03).
    package let topup: String
    package let topupError: String

    package enum CodingKeys: String, CodingKey {
        case slackTo = "slack_to"
        case streamsTo = "streams_to"
        case meetings, topup
        case topupError = "topup_error"
    }

    package init(
        slackTo: Double = 0,
        streamsTo: Double = 0,
        meetings: Int = 0,
        topup: String = "",
        topupError: String = ""
    ) {
        self.slackTo = slackTo
        self.streamsTo = streamsTo
        self.meetings = meetings
        self.topup = topup
        self.topupError = topupError
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slackTo = try container.decodeIfPresent(Double.self, forKey: .slackTo) ?? 0
        streamsTo = try container.decodeIfPresent(Double.self, forKey: .streamsTo) ?? 0
        meetings = try container.decodeIfPresent(Int.self, forKey: .meetings) ?? 0
        topup = try container.decodeIfPresent(String.self, forKey: .topup) ?? ""
        topupError = try container.decodeIfPresent(String.self, forKey: .topupError) ?? ""
    }

    /// The recap footer, e.g. `"Slack to 17:40 · Jira/Gmail to 14:00 · 3 meetings"`.
    /// `formatter` renders a unix second as the caller wants it (the view passes a
    /// locale-aware time formatter). A failed top-up is appended so a partially
    /// covered window never reads as a complete one.
    package func summaryLine(formatter: (Double) -> String) -> String {
        var parts: [String] = []
        if slackTo > 0 {
            parts.append("Slack to \(formatter(slackTo))")
        }
        if streamsTo > 0 {
            parts.append("Jira/Gmail to \(formatter(streamsTo))")
        }
        if meetings > 0 {
            parts.append(meetings == 1 ? "1 meeting" : "\(meetings) meetings")
        }
        if parts.isEmpty {
            parts.append("No summaries in this window")
        }
        if topup == "failed" {
            parts.append("top-up failed")
        }
        return parts.joined(separator: " · ")
    }
}

/// One persisted absence recap (`catchup_recaps` row). Mirrors the Go
/// `db.CatchupRecap`; token/cost columns are written by Go and unread here.
package struct CatchUpRecap: FetchableRecord, Identifiable, Equatable {
    package let id: Int
    package let periodFrom: Double
    package let periodTo: Double
    package let status: String
    package let tldr: String
    package let bodyJSON: String
    package let coverageJSON: String
    package let error: String
    /// The recap this one regenerates, when it was produced by `--regen`.
    package let regenOfID: Int?
    package let acknowledgedAt: String?
    package let model: String
    package let createdAt: String
    package let updatedAt: String

    package init(row: Row) {
        id = row["id"]
        periodFrom = row["period_from"] ?? 0
        periodTo = row["period_to"] ?? 0
        status = row["status"] ?? ""
        tldr = row["tldr"] ?? ""
        bodyJSON = row["body_json"] ?? "{}"
        coverageJSON = row["coverage_json"] ?? "{}"
        error = row["error"] ?? ""
        regenOfID = row["regen_of_id"]
        acknowledgedAt = row["acknowledged_at"]
        model = row["model"] ?? ""
        createdAt = row["created_at"] ?? ""
        updatedAt = row["updated_at"] ?? ""
    }

    // MARK: - Status predicates

    package var isBuilding: Bool { status == "building" }
    package var isReady: Bool { status == "ready" }
    package var isFailed: Bool { status == "failed" }
    package var isAcknowledged: Bool { acknowledgedAt != nil }

    // MARK: - JSON payloads

    private static let decoder = JSONDecoder()

    /// Parsed body; an undecodable payload reads as an empty recap rather than
    /// taking the whole row down (the model wrote this JSON).
    package var decodedBody: CatchUpRecapBody {
        guard let data = bodyJSON.data(using: .utf8),
              let body = try? Self.decoder.decode(CatchUpRecapBody.self, from: data) else {
            return CatchUpRecapBody()
        }
        return body
    }

    package var decodedCoverage: CatchUpCoverage {
        guard let data = coverageJSON.data(using: .utf8),
              let coverage = try? Self.decoder.decode(CatchUpCoverage.self, from: data) else {
            return CatchUpCoverage()
        }
        return coverage
    }

    // MARK: - Window label

    /// The window headline: `"Fri 4 Sep, 09:00 → 18:30"` within one calendar day,
    /// `"4 Sep 09:00 – 6 Sep 09:15"` across days. The calendar is injectable so
    /// tests are deterministic; formatting is pinned to `en_US_POSIX` and the
    /// calendar's own time zone.
    package static func windowLabel(from: Date, to: Date, calendar: Calendar = .current) -> String {
        let time = Self.formatter("HH:mm", calendar)
        if calendar.isDate(from, inSameDayAs: to) {
            let weekday = Self.formatter("EEE d MMM", calendar)
            return "\(weekday.string(from: from)), \(time.string(from: from)) → \(time.string(from: to))"
        }
        let day = Self.formatter("d MMM", calendar)
        return "\(day.string(from: from)) \(time.string(from: from)) – \(day.string(from: to)) \(time.string(from: to))"
    }

    private static func formatter(_ format: String, _ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
}

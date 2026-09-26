import Foundation
import WatchtowerCore

/// One day bucket of the Digests segment's cross-source feed.
struct DigestFeedDaySection: Identifiable, Equatable {
    /// Start of day (per the grouping calendar) — also the section id, the
    /// `MeetingDaySection` precedent.
    let day: Date
    let entries: [DigestFeedEntry]

    var id: Date { day }
}

/// The Digests feed's pure presentation logic — search matching, day
/// bucketing, and day-header labeling — lifted out of `DigestListView` so it
/// is testable without instantiating a SwiftUI view (the `MeetingListBuilder`
/// precedent). No wall-clock or locale reads of its own: `calendar`/`locale`
/// are injected, production passing `.current` exactly as the view did
/// inline.
enum DigestFeedList {
    /// Cross-source search. Each case searches the fields that source
    /// actually surfaces in its row: a Slack digest by summary, channel
    /// name, and topics; a stream digest by scope and per-topic
    /// title/summary; a meeting by title, snippet, and linked event title.
    /// `query` is expected already lowercased (the caller lowercases once
    /// per keystroke rather than once per entry).
    static func matches(
        _ entry: DigestFeedEntry,
        query: String,
        channelName: (Digest) -> String?
    ) -> Bool {
        switch entry {
        case .slack(let digest):
            if digest.summary.lowercased().contains(query) { return true }
            if let name = channelName(digest),
               name.lowercased().contains(query) { return true }
            if digest.parsedTopics.contains(
                where: { $0.lowercased().contains(query) }
            ) { return true }
            return false
        case .stream(let digest):
            if digest.scope.lowercased().contains(query) { return true }
            for topic in digest.parsedTopics {
                if topic.title.lowercased().contains(query) { return true }
                if let summary = topic.summary, summary.lowercased().contains(query) { return true }
            }
            return false
        case .meeting(let recording):
            if recording.title.lowercased().contains(query) { return true }
            if recording.snippet.lowercased().contains(query) { return true }
            if let eventTitle = recording.eventTitle, eventTitle.lowercased().contains(query) { return true }
            return false
        }
    }

    /// Buckets entries into day sections **in encounter order** — the caller
    /// has already sorted the feed per `DigestViewModel.sortOrder`, so the
    /// grouping must not impose an order of its own (the
    /// `MeetingListBuilder`/`MeetingDaySection` day-grouping precedent).
    static func group(
        _ entries: [DigestFeedEntry],
        calendar: Calendar = .current
    ) -> [DigestFeedDaySection] {
        var order: [Date] = []
        var buckets: [Date: [DigestFeedEntry]] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            if buckets[day] == nil {
                buckets[day] = []
                order.append(day)
            }
            buckets[day]?.append(entry)
        }
        return order.map { DigestFeedDaySection(day: $0, entries: buckets[$0] ?? []) }
    }

    /// Day-header label. `locale`/`calendar` are injectable for deterministic
    /// tests; production passes `.current` for both, matching the formatter
    /// this replaced.
    static func dayLabel(
        for date: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.locale = locale
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = "EEEE, d MMM"
        return fmt.string(from: date)
    }
}

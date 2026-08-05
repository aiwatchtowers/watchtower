import Foundation

/// Identifies one row in the unified Meetings list — either a calendar event
/// or a standalone recording (ad-hoc, or one whose linked event was pruned).
enum MeetingSelection: Hashable {
    case event(String)      // calendar_events.id
    case recording(Int64)   // meeting_transcripts.id
}

struct MeetingListEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case event(CalendarEvent, recordings: [RecordingListItem])
        case recording(RecordingListItem)
    }
    let kind: Kind
    var id: MeetingSelection
    var sortDate: Date
    var recordingCount: Int
}

struct MeetingDaySection: Identifiable, Equatable {
    let id: Date
    let label: String
    let entries: [MeetingListEntry]
}

/// Builds the day-sectioned Meetings list by merging calendar days with
/// recordings — folding a recording into its linked event when that event is
/// present, and demoting it to a standalone entry otherwise (ad-hoc, or the
/// event was pruned by sync retention).
enum MeetingListBuilder {
    static func build(
        days: [DayEvents],
        recordings: [RecordingListItem],
        now: Date,
        calendar: Calendar,
        locale: Locale = .current
    ) -> [MeetingDaySection] {
        let todayStart = calendar.startOfDay(for: now)
        let eventIDs = Set(days.flatMap { $0.events.map(\.id) })

        var recordingsByEvent: [String: [RecordingListItem]] = [:]
        var standaloneByDay: [Date: [RecordingListItem]] = [:]
        var unparseable: [RecordingListItem] = []

        for recording in recordings {
            if let eventID = recording.eventID, eventIDs.contains(eventID) {
                recordingsByEvent[eventID, default: []].append(recording)
                continue
            }
            guard let created = recording.createdDate else {
                unparseable.append(recording)
                continue
            }
            standaloneByDay[calendar.startOfDay(for: created), default: []].append(recording)
        }
        for key in recordingsByEvent.keys {
            recordingsByEvent[key]?.sort { ($0.createdDate ?? .distantPast) < ($1.createdDate ?? .distantPast) }
        }

        var sectionsByDay: [Date: (label: String, entries: [MeetingListEntry])] = [:]
        for day in days {
            let entries = day.events.map { event -> MeetingListEntry in
                let folded = recordingsByEvent[event.id] ?? []
                return MeetingListEntry(
                    kind: .event(event, recordings: folded),
                    id: .event(event.id),
                    sortDate: event.startDate,
                    recordingCount: folded.count)
            }
            sectionsByDay[day.id] = (day.label, entries)
        }

        for (dayStart, items) in standaloneByDay {
            var section = sectionsByDay[dayStart] ?? (label(for: dayStart, calendar: calendar, locale: locale), [])
            for item in items {
                section.entries.append(MeetingListEntry(
                    kind: .recording(item), id: .recording(item.id),
                    sortDate: item.createdDate ?? .distantPast, recordingCount: 1))
            }
            sectionsByDay[dayStart] = section
        }

        if !unparseable.isEmpty {
            let pastKeys = sectionsByDay.keys.filter { $0 < todayStart }
            let targetKey = pastKeys.min() ?? sectionsByDay.keys.min() ?? todayStart
            var section = sectionsByDay[targetKey] ?? (label(for: targetKey, calendar: calendar, locale: locale), [])
            for item in unparseable {
                section.entries.append(MeetingListEntry(
                    kind: .recording(item), id: .recording(item.id),
                    sortDate: .distantPast, recordingCount: 1))
            }
            sectionsByDay[targetKey] = section
        }

        let entriesByDay = sectionsByDay.map { (key: $0.key, section: $0.value) }
        let upcoming = entriesByDay.filter { $0.key >= todayStart }.sorted { $0.key < $1.key }
        let past = entriesByDay.filter { $0.key < todayStart }.sorted { $0.key > $1.key }

        return (upcoming + past).map { key, section in
            let isPast = key < todayStart
            let entries = section.entries.sorted { isPast ? $0.sortDate > $1.sortDate : $0.sortDate < $1.sortDate }
            return MeetingDaySection(id: key, label: section.label, entries: entries)
        }
    }

    /// Longest recording wins (the real one beats a 1-second test blip);
    /// ties broken by newest createdAt.
    static func defaultRecordingID(_ recordings: [RecordingListItem]) -> Int64? {
        recordings.max { lhs, rhs in
            if lhs.durationSec != rhs.durationSec { return lhs.durationSec < rhs.durationSec }
            return (lhs.createdDate ?? .distantPast) < (rhs.createdDate ?? .distantPast)
        }?.id
    }

    /// Mirrors `CalendarViewModel.label(for:calendar:)` exactly (same
    /// dateFormat + locale) so a recording-only day section reads no
    /// differently from an event day section in the same list. `locale` is
    /// injectable for deterministic tests; production always passes
    /// `.current`, matching `CalendarViewModel`'s hardcoded `Locale.current`.
    private static func label(for date: Date, calendar: Calendar, locale: Locale) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.locale = locale
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = "EEEE, d MMM"
        return fmt.string(from: date)
    }
}

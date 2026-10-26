import SwiftUI

/// Where an event stands against now: on now, the next one, or another.
enum CalendarRowState: Equatable {
    case now, next, other
}

/// What a calendar row shows, the Desktop's `CalendarEventRow` (mockup 7):
/// the start time and duration in a right-aligned column (the time green
/// while the meeting runs), the title, a detail line ("in 25 min" for the
/// next one within the hour, the location, "1 rec"), and the attendees. The
/// plate is green on now, accent on the next one, `Fill.rest` otherwise.
struct CalendarRowModel: Equatable {
    let timeText: String
    let durationText: String
    let title: String
    let detail: String?
    let attendeesText: String?
    let state: CalendarRowState
    /// Green while the meeting runs; nil draws primary.
    let timeTone: PhoneTone?

    /// `isNext` comes from the agenda (the first event still ahead).
    init(
        start: Date,
        end: Date,
        title: String,
        location: String = "",
        attendees: Int = 0,
        recordings: Int = 0,
        isNext: Bool,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        timeText = formatter.string(from: start)
        durationText = Self.duration(minutes: max(0, Int(end.timeIntervalSince(start)) / 60))
        self.title = title
        if start <= now && now < end {
            state = .now
        } else {
            state = isNext ? .next : .other
        }
        timeTone = state == .now ? .green : nil
        var parts: [String] = []
        let minutesAhead = Int(start.timeIntervalSince(now) / 60)
        if state == .next, minutesAhead > 0, minutesAhead < 60 {
            parts.append("in \(minutesAhead) min")
        }
        if !location.isEmpty { parts.append(location) }
        if recordings > 0 { parts.append("\(recordings) rec") }
        detail = parts.isEmpty ? nil : parts.joined(separator: " · ")
        attendeesText = attendees > 0 ? "\(attendees)" : nil
    }

    /// "45m", "1h", "1h 30m".
    static func duration(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    static func plate(_ state: CalendarRowState) -> Color {
        switch state {
        case .now: PhoneTone.green.color.opacity(Fill.selectedOpacity)
        case .next: PhoneTone.accent.color.opacity(Fill.selectedOpacity)
        case .other: Fill.rest
        }
    }

    var toneUses: [ToneUse] {
        switch state {
        case .now: [ToneUse(element: "calendar row \(title) now", tone: .green, role: .info)]
        case .next: [ToneUse(element: "calendar row \(title) next", tone: .accent, role: .info)]
        case .other: []
        }
    }
}

///     CalendarRow(model: CalendarRowModel(start: event.start, end: event.end, title: event.title,
///                                         location: event.location, isNext: isNext, now: context.date))
struct CalendarRow: View {
    let model: CalendarRowModel

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.medium) {
            VStack(alignment: .trailing, spacing: Spacing.tight) {
                Text(model.timeText)
                    .fontWeight(.semibold)
                    .foregroundStyle(model.timeTone?.color ?? Color.primary)
                Text(model.durationText).foregroundStyle(.secondary)
            }
            .font(TypeScale.time)
            .frame(minWidth: PhoneMetrics.minTouch, alignment: .trailing)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(model.title).font(TypeScale.rowTitle).lineLimit(2)
                if let detail = model.detail {
                    Text(detail).font(TypeScale.meta).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.small)
            if let attendees = model.attendeesText {
                Label(attendees, systemImage: "person.2")
                    .font(TypeScale.meta)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("\(attendees) people")
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.regular)
        .frame(minHeight: PhoneMetrics.minTouch)
        .background(CalendarRowModel.plate(model.state), in: RoundedRectangle(cornerRadius: Radius.container, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

import SwiftUI
import WatchtowerCore

struct CalendarEventRow: View {
    let event: CalendarEvent
    /// Number of recordings folded into this event by `MeetingListBuilder`;
    /// 0 renders no badge.
    var recordingCount: Int = 0

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            timeColumn
            detailColumn
            Spacer()
            trailingInfo
        }
        .padding(8)
        .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 8))
    }

    private var timeColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(event.formattedTimeRange)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(event.isHappeningNow ? .green : .primary)

            Text(event.durationText)
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Relative countdown next to the absolute range for events starting
            // soon; `.relative` keeps it ticking without a timer. The explicit
            // TimelineView schedule re-evaluates the gate exactly at startDate, so
            // the countdown disappears the moment the meeting begins instead of
            // counting UP until the next external re-render.
            if event.isUpcoming {
                TimelineView(.explicit([event.startDate])) { context in
                    if context.date < event.startDate {
                        HStack(spacing: 3) {
                            Text("in")
                            Text(event.startDate, style: .relative)
                        }
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    }
                }
            }
        }
        .frame(width: 80, alignment: .trailing)
    }

    private var detailColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(event.title)
                .font(.callout)
                .lineLimit(2)

            if !event.location.isEmpty {
                Label(event.location, systemImage: "mappin")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var trailingInfo: some View {
        VStack(alignment: .trailing, spacing: 4) {
            let count = event.parsedAttendees.count
            if count > 0 {
                Label("\(count)", systemImage: "person.2")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if recordingCount > 0 {
                Text("\(recordingCount) rec")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var backgroundStyle: Color {
        if event.isHappeningNow {
            return Color.green.opacity(0.08)
        }
        if event.isUpcoming {
            return Color.blue.opacity(0.06)
        }
        return Color.secondary.opacity(0.04)
    }
}

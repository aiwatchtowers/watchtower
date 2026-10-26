import SwiftUI
import WatchtowerKit

/// The Calendar tab (mockup 7): the week strip (seven days from today, the
/// selected day filled in the accent colour), the selected day's agenda as
/// the Desktop's calendar rows (`CalendarRow`: now green, next blue) with the
/// red now line on today, the current or next meeting with Record and Prep, a red mic button for a voice note, and the
/// waveform button (with a new-recap badge) to the Recordings list.
struct AgendaView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    /// The day the agenda last scrolled for (`AgendaScroll`).
    @State private var scrolledDay: Date?

    var body: some View {
        @Bindable var navigation = env.navigation
        NavigationStack(path: $navigation.calendarPath) {
            // The now line moves and past cards grey by the clock alone.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(now: context.date)
            }
            .navigationTitle("Calendar")
            .navigationDestination(for: CalendarRoute.self) { route in
                switch route {
                case let .event(id): EventDetailView(eventID: id)
                case .recordings: RecordingsListView()
                case let .recap(id): RecapView(transcriptID: id)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { recordingsButton }
            }
            .refreshable { await env.refresh(.pull) }
        }
    }

    /// C1: the waveform icon, with an accent badge counting new recaps. It
    /// speaks "Recordings · 1 new".
    private var recordingsButton: some View {
        let newCount = RecordingsListModel.newCount(
            transcripts: env.calendarReplica.snapshot.transcripts,
            seen: env.recordingsSeen.value
        )
        return Button {
            env.navigation.calendarPath.append(.recordings)
        } label: {
            Image(systemName: "waveform")
                .frame(minWidth: PhoneMetrics.minTouch, minHeight: PhoneMetrics.minTouch)
                .overlay(alignment: .topTrailing) {
                    if newCount > 0 {
                        CountBadge(count: newCount, tone: .accent).offset(x: Spacing.tight, y: Spacing.small)
                    }
                }
                .contentShape(Rectangle())
        }
        .accessibilityLabel(RecordingsListModel.pillText(newCount: newCount))
    }

    private func content(now: Date) -> some View {
        let calendar = Calendar.current
        let snapshot = env.calendarReplica.snapshot
        let strip = WeekStripModel(
            selected: selectedDay,
            today: now,
            eventDays: WeekStripModel.eventDays(snapshot.events, calendar: calendar),
            calendar: calendar
        )
        let agenda = AgendaDayModel(
            day: selectedDay, snapshot: snapshot, recordings: env.phoneRecordings.snapshot, now: now, calendar: calendar
        )
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.regular) {
                    WeekStripView(strip: strip, select: { selectedDay = $0 }, shiftWeek: shiftWeek)
                    if let empty = agenda.emptyText {
                        Text(empty).foregroundStyle(.secondary).padding(.horizontal, Spacing.small)
                    }
                    ForEach(agenda.rows) { row in
                        switch row {
                        case let .event(card):
                            AgendaEventRow(card: card, now: now) { env.navigation.calendarPath.append(.event(card.id)) }
                        case let .nowLine(time):
                            NowLineView(time: time)
                        }
                    }
                }
                .padding(.horizontal, Spacing.large)
            }
            // The mic button takes room at the bottom: the list's last row
            // ends above it.
            .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                voiceNoteButton
                    .padding(.trailing, Spacing.large)
                    .padding(.bottom, Spacing.medium)
            }
            .task(id: AgendaScrollKey(day: selectedDay, rowID: agenda.highlightedRowID)) {
                // The current or next meeting sits mid-screen, never under
                // the button at rest; without one the day stays at the top.
                let key = AgendaScrollKey(day: selectedDay, rowID: agenda.highlightedRowID)
                guard let row = AgendaScroll.target(for: key, scrolledDay: scrolledDay) else { return }
                scrolledDay = key.day
                proxy.scrollTo(row, anchor: .center)
            }
        }
    }

    private func shiftWeek(_ weeks: Int) {
        selectedDay = Calendar.current.date(byAdding: .day, value: 7 * weeks, to: selectedDay) ?? selectedDay
    }

    private var voiceNoteButton: some View {
        Button {
            Task { await env.recorder.recordVoiceNote() }
        } label: {
            Image(systemName: "mic.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: AgendaMetrics.voiceButton, height: AgendaMetrics.voiceButton)
                .background(PhoneTone.red.color, in: Circle())
                .shadow(color: FloatingShadow.color, radius: FloatingShadow.radius, y: FloatingShadow.y)
        }
        // One microphone: off while any hub's capture runs.
        .disabled(!env.canStartCapture)
        .opacity(env.canStartCapture ? 1 : PhoneOpacity.dimmed)
        .accessibilityLabel("Record a voice note")
    }
}

/// The agenda's own sizes, beside the parts' `PhoneMetrics`.
private enum AgendaMetrics {
    /// The round voice-note button.
    static let voiceButton: CGFloat = 56
    /// The event dot under a day.
    static let eventDot: CGFloat = 4
    /// The now line's rule.
    static let nowRule: CGFloat = 1.5
}

/// Seven days from the page start, with chevrons to the previous and next
/// seven (mockup 7's `.week`): the selected day is an accent plate with
/// white text, today without a selection is accent text.
private struct WeekStripView: View {
    let strip: WeekStripModel
    let select: (Date) -> Void
    let shiftWeek: (Int) -> Void

    var body: some View {
        HStack(spacing: Spacing.tight) {
            Button { shiftWeek(-1) } label: { chevron("chevron.left") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Previous week")
            ForEach(strip.days) { day in
                Button { select(day.date) } label: { dayCell(day) }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(day.spokenLabel)
                    .accessibilityAddTraits(day.isSelected ? .isSelected : [])
            }
            Button { shiftWeek(1) } label: { chevron("chevron.right") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Next week")
        }
    }

    /// A 44 × 44 hit target.
    private func chevron(_ name: String) -> some View {
        Image(systemName: name)
            .frame(width: PhoneMetrics.minTouch, height: PhoneMetrics.minTouch)
            .contentShape(Rectangle())
    }

    private func dayCell(_ day: WeekStripModel.Day) -> some View {
        VStack(spacing: Spacing.tight) {
            Text(day.letter).font(TypeScale.badge)
            Text(day.number).font(.callout.weight(day.isToday || day.isSelected ? .semibold : .regular))
            Circle()
                .fill(day.hasEvents ? (day.isSelected ? Color.white : Color.secondary) : Color.clear)
                .frame(width: AgendaMetrics.eventDot, height: AgendaMetrics.eventDot)
        }
        .foregroundStyle(day.isSelected ? Color.white : day.isToday ? PhoneTone.accent.color : Color.primary)
        .frame(maxWidth: .infinity, minHeight: PhoneMetrics.minTouch)
        .background {
            if day.isSelected {
                RoundedRectangle(cornerRadius: Radius.container, style: .continuous).fill(PhoneTone.accent.color)
            }
        }
        .contentShape(Rectangle())
    }
}

/// One event: the Desktop's calendar row (an all-day event, a plate with
/// "All day" in the time column), the recording pills and, on the current
/// or next meeting, Record and Prep under it, aligned with the title.
private struct AgendaEventRow: View {
    @Environment(AppEnvironment.self) private var env
    let card: EventCardModel
    let now: Date
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            if let meeting = card.meetingEvent {
                CalendarRow(model: CalendarRowModel(
                    start: meeting.start, end: meeting.end, title: card.title, location: card.venue ?? "",
                    attendees: card.attendeeCount, isNext: card.isHighlighted, now: now
                ))
            } else {
                AllDayRow(title: card.title, detail: card.venue)
            }
            if !card.pills.isEmpty || card.isHighlighted {
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    if !card.pills.isEmpty {
                        FlowRow {
                            ForEach(card.pills) { Pill(text: $0.text, tone: $0.tone) }
                        }
                    }
                    if card.isHighlighted {
                        // Leading-aligned; the 44 pt Record of Now (Global Constraints).
                        HStack(spacing: Spacing.regular) {
                            if let meeting = card.meetingEvent {
                                RecordButton {
                                    Task { await env.recorder.recordMeeting(meeting) }
                                }
                                .disabled(!env.canStartCapture)
                            }
                            Button("Prep", action: open)
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                        }
                    }
                }
                .padding(.horizontal, Spacing.medium)
            }
        }
        .opacity(card.isPast ? PhoneOpacity.pending : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityElement(children: .contain)
    }
}

/// An all-day event: the calendar row's plate with "All day" where the
/// time goes.
private struct AllDayRow: View {
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.medium) {
            Text("All day")
                .font(TypeScale.time)
                .foregroundStyle(.secondary)
                .frame(minWidth: PhoneMetrics.minTouch, alignment: .trailing)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(title).font(TypeScale.rowTitle).lineLimit(2)
                if let detail {
                    Text(detail).font(TypeScale.meta).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.small)
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.regular)
        .frame(minHeight: PhoneMetrics.minTouch)
        .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.container, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The red now line with its time.
private struct NowLineView: View {
    let time: String

    var body: some View {
        HStack(spacing: Spacing.compact) {
            Text(time)
                .font(TypeScale.badge.monospacedDigit())
                .foregroundStyle(PhoneTone.red.color)
                .frame(minWidth: PhoneMetrics.minTouch, alignment: .trailing)
            Circle().fill(PhoneTone.red.color).frame(width: PhoneMetrics.macDot, height: PhoneMetrics.macDot)
            Rectangle().fill(PhoneTone.red.color).frame(height: AgendaMetrics.nowRule)
        }
        .padding(.horizontal, Spacing.medium)
        .accessibilityLabel("Now, \(time)")
    }
}

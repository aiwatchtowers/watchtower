import SwiftUI
import WatchtowerKit

/// The Calendar tab: the week strip (seven days from today, today filled in the
/// accent colour), the selected day's agenda as "time | card" rows with the
/// red now line on today, the current or next meeting highlighted with
/// Record and Prep, a red mic button for a voice note, and the
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
                .frame(minWidth: 44, minHeight: 44)
                .overlay(alignment: .topTrailing) {
                    if newCount > 0 {
                        CountBadge(count: newCount, tone: .accent).offset(x: 2, y: 4)
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
            List {
                Section {
                    WeekStripView(strip: strip, select: { selectedDay = $0 }, shiftWeek: shiftWeek)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                }
                Section {
                    if let empty = agenda.emptyText {
                        Text(empty).foregroundStyle(.secondary)
                    }
                    ForEach(agenda.rows) { row in
                        switch row {
                        case let .event(card):
                            AgendaEventRow(card: card) { env.navigation.calendarPath.append(.event(card.id)) }
                                .listRowInsets(RowInsets.card)
                        case let .nowLine(time):
                            NowLineView(time: time)
                        }
                    }
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
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
                .frame(width: 56, height: 56)
                .background(PhoneTone.red.color, in: Circle())
                .shadow(radius: 3, y: 1)
        }
        // One microphone: off while any hub's capture runs.
        .disabled(!env.canStartCapture)
        .opacity(env.canStartCapture ? 1 : 0.4)
        .accessibilityLabel("Record a voice note")
    }
}

/// Seven days from the page start, with chevrons to the previous and next seven.
private struct WeekStripView: View {
    let strip: WeekStripModel
    let select: (Date) -> Void
    let shiftWeek: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
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
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private func dayCell(_ day: WeekStripModel.Day) -> some View {
        VStack(spacing: 3) {
            Text(day.letter).font(.caption2).foregroundStyle(.secondary)
            Text(day.number)
                .font(.callout.weight(day.isToday || day.isSelected ? .semibold : .regular))
                .foregroundStyle(day.isToday ? Color.white : Color.primary)
                .frame(width: 32, height: 32)
                .background {
                    if day.isToday {
                        Circle().fill(PhoneTone.accent.color)
                    } else if day.isSelected {
                        Circle().stroke(PhoneTone.accent.color, lineWidth: 1.5)
                    }
                }
            Circle()
                .fill(day.hasEvents ? Color.secondary : Color.clear)
                .frame(width: 4, height: 4)
        }
        .contentShape(Rectangle())
    }
}

/// "time | card".
private struct AgendaEventRow: View {
    @Environment(AppEnvironment.self) private var env
    let card: EventCardModel
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(card.timeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
                .padding(.top, 10)
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(card.title).font(.subheadline.weight(.semibold))
                Text(card.detailLine).font(TypeScale.meta).foregroundStyle(.secondary)
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
            .card(card.cardStyle)
            .opacity(card.isPast ? 0.75 : 1)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
        }
    }
}

/// The red now line with its time.
private struct NowLineView: View {
    let time: String

    var body: some View {
        HStack(spacing: 6) {
            Text(time)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(PhoneTone.red.color)
                .frame(width: 48, alignment: .leading)
            Circle().fill(PhoneTone.red.color).frame(width: 7, height: 7)
            Rectangle().fill(PhoneTone.red.color).frame(height: 1.5)
        }
        .accessibilityLabel("Now, \(time)")
    }
}

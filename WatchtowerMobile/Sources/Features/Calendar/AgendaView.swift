import SwiftUI
import WatchtowerKit

/// The Calendar tab: the week strip (Monday to Sunday, today filled in the
/// accent colour), the selected day's agenda as "time | card" rows with the
/// red now line on today, the current or next meeting highlighted with
/// Record and Prep, a red mic button for a voice note, and the
/// "Recordings · 1 new" pill to the Recordings list.
struct AgendaView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())

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
                ToolbarItem(placement: .topBarTrailing) { recordingsPill }
            }
            .refreshable { await env.refresh() }
            .overlay(alignment: .bottomTrailing) { voiceNoteButton }
        }
    }

    private var recordingsPill: some View {
        let newCount = RecordingsListModel.newCount(
            transcripts: env.calendarReplica.snapshot.transcripts,
            seen: env.recordingsSeen.value
        )
        return Button {
            env.navigation.calendarPath.append(.recordings)
        } label: {
            Text(RecordingsListModel.pillText(newCount: newCount))
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Color.secondary.opacity(0.14), in: Capsule().inset(by: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        return List {
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
                    case let .nowLine(time):
                        NowLineView(time: time)
                    }
                }
                .listRowSeparator(.hidden)
            }
            // Room above the mic button.
            Color.clear.frame(height: 64).listRowBackground(Color.clear)
        }
        .listStyle(.plain)
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
        .accessibilityLabel("Record a voice note")
        .padding(20)
    }
}

/// Monday to Sunday with chevrons to the previous and next week.
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
            VStack(alignment: .leading, spacing: 6) {
                Text(card.title).font(.subheadline.weight(.semibold))
                Text(card.detailLine).font(.caption).foregroundStyle(.secondary)
                if !card.pills.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(card.pills) { EventPillView(pill: $0) }
                    }
                }
                if card.isHighlighted {
                    HStack(spacing: 8) {
                        if let meeting = card.meetingEvent {
                            Button {
                                Task { await env.recorder.recordMeeting(meeting) }
                            } label: {
                                Label("Record", systemImage: "record.circle")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(PhoneTone.red.color)
                        }
                        Button("Prep", action: open).buttonStyle(.bordered)
                    }
                    // Large size: the button itself is at least 44 pt tall.
                    .controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                card.isHighlighted ? PhoneTone.accent.color.opacity(0.1) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                if card.isHighlighted {
                    RoundedRectangle(cornerRadius: 10).stroke(PhoneTone.accent.color, lineWidth: 1.5)
                }
            }
            .opacity(card.isPast ? 0.75 : 1)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
        }
    }
}

struct EventPillView: View {
    let pill: EventPill

    var body: some View {
        Text(pill.text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(pill.tone.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(pill.tone.color.opacity(0.14), in: Capsule())
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

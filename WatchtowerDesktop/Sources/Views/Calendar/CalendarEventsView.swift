import SwiftUI

enum CalendarMode: String, CaseIterable {
    case events, recordings

    var title: String {
        switch self {
        case .events: return "Events"
        case .recordings: return "Recordings"
        }
    }
}

struct CalendarEventsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("transcription.provider") private var transcriptionProvider = "whisperkit"
    @AppStorage("transcription.model") private var transcriptionModel = "large-v3-v20240930"
    @State private var meetingPrepVM = MeetingPrepViewModel()
    @State private var selectedEventID: String?
    private let google = GoogleConnectFlow.shared
    @State private var expandedAllDayDates: Set<Date> = []
    @State private var expandedEventID: String?
    @State private var userNotes: String = ""
    @State private var mode: CalendarMode = .events
    @State private var showAddEmailAccountSheet = false
    @State private var showAddCalendarAccountSheet = false

    /// True once ANY calendar source is connected — Google OAuth OR at least
    /// one healthy CalDAV/ICS account — so connecting only e.g. an iCloud
    /// calendar (without ever touching Google) unlocks the events UI too.
    /// Mirrors InboxFeedView.hasEmailSource.
    private var hasCalendarSource: Bool {
        google.calendar.isConnected
            || (appState.calendarAccountsViewModel?.accounts.contains { $0.isOK } ?? false)
    }

    var body: some View {
        Group {
            if hasCalendarSource, !google.isRunning, let calVM = appState.calendarViewModel {
                VStack(spacing: 0) {
                    Picker("", selection: $mode) {
                        ForEach(CalendarMode.allCases, id: \.self) { m in
                            Text(m.title).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    .padding(.top, 10)

                    switch mode {
                    case .events:
                        eventsSplitView(calVM)
                    case .recordings:
                        RecordingsView()
                    }
                }
            } else {
                notConnectedView
            }
        }
    }

    private func eventsSplitView(_ vm: CalendarViewModel) -> some View {
        HStack(spacing: 0) {
            eventsList(vm)
                .frame(minWidth: 300, idealWidth: 350)

            if let eventID = selectedEventID {
                Divider()
                MeetingPrepDetailView(
                    eventID: eventID,
                    viewModel: meetingPrepVM,
                    userNotes: $userNotes
                ) { selectedEventID = nil }
                .id(eventID)
                .frame(minWidth: 400, idealWidth: 500)
                .transition(
                    .move(edge: .trailing).combined(with: .opacity)
                )
            }
        }
        .animation(.easeInOut(duration: 0.25), value: selectedEventID)
        .onAppear {
            vm.loadEvents()
            appState.transcriptionModelProvisioner.ensureDownloaded(providerID: transcriptionProvider, model: transcriptionModel)
        }
    }

    private func eventsList(_ vm: CalendarViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    ForEach(vm.dailyEvents) { day in
                        daySection(day: day)
                            .id(day.id)
                    }

                    if vm.dailyEvents.isEmpty {
                        emptyState
                    }
                }
                .padding()
            }
            .onAppear { scrollToToday(vm, proxy: proxy) }
        }
    }

    /// With past days in the list, land on "Today" (or the first future day
    /// when today has no events) instead of two weeks of history.
    private func scrollToToday(_ vm: CalendarViewModel, proxy: ScrollViewProxy) {
        let today = Calendar.current.startOfDay(for: Date())
        guard let target = vm.dailyEvents.first(where: { $0.id >= today })?.id else { return }
        proxy.scrollTo(target, anchor: .top)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .foregroundStyle(.blue)
            Text("Calendar")
                .font(.title2)
                .fontWeight(.bold)
            Spacer()
            recordButton(eventID: nil, title: nil)
        }
    }

    // MARK: - Record Button

    /// Record/Stop control for a calendar event (or ad-hoc when `eventID` is nil).
    /// Shows "Stop" only while THIS target is the one being recorded; disabled
    /// when another run is in flight or system-audio capture is unsupported.
    @ViewBuilder
    private func recordButton(eventID: String?, title: String?) -> some View {
        let center = appState.meetingRecorderCenter
        let isRecordingThis: Bool = {
            if case .recording = center.phase { return center.currentEventID == eventID }
            return false
        }()
        Button {
            if isRecordingThis {
                stopRecording()
            } else {
                Task { await center.startRecording(eventID: eventID, title: title, config: .fromDefaults()) }
            }
        } label: {
            Label(isRecordingThis ? "Stop" : "Record",
                  systemImage: isRecordingThis ? "stop.circle" : "record.circle")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isRecordingThis ? .red : nil)
        .disabled((center.isBusy && !isRecordingThis) || !SystemAudioRecorder.isSupported)
        .help(SystemAudioRecorder.isSupported ? "" : "Recording requires macOS 14.4+")
    }

    // MARK: - Join Button

    /// Opens the event's conference link and (per the "Auto-record on join"
    /// setting) starts an event-linked recording via the shared
    /// `JoinMeetingAction`. Prominent while the meeting is imminent/ongoing.
    @ViewBuilder
    private func joinButton(_ event: CalendarEvent) -> some View {
        let prominent = event.isUpcoming || event.isHappeningNow
        Button {
            Task { await JoinMeetingAction.join(event: event, center: appState.meetingRecorderCenter) }
        } label: {
            Label("Join", systemImage: "video")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(prominent ? Color.accentColor : nil)
        .help("Open the meeting link")
    }

    private func stopRecording() {
        // No CLI-runner guard here: stopping capture must never depend on the
        // watchtower binary resolving — the Center fails visibly at the save
        // step instead, with the audio kept.
        Task {
            await appState.meetingRecorderCenter.stopAndProcess(config: .fromDefaults())
        }
    }

    // MARK: - Day Section

    private func daySection(day: DayEvents) -> some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(day.id)
        let isPast = day.id < cal.startOfDay(for: Date())
        let timed = day.events.filter { !$0.isAllDay }
        let allDay = day.events.filter { $0.isAllDay }

        return VStack(alignment: .leading, spacing: 8) {
            Text(day.label)
                .font(.headline)
                .foregroundStyle(isToday ? .primary : .secondary)

            if !allDay.isEmpty {
                allDayChip(allDay, date: day.id)
            }

            ForEach(timed) { event in
                eventRow(event)
            }
        }
        // Past days are browsable history, visually receded; their events
        // never carry the upcoming/now highlight anyway (both are start-time
        // based), so dimming the whole section is enough.
        .opacity(isPast ? 0.55 : 1)
    }

    // MARK: - All-Day Chip

    private func allDayChip(_ events: [CalendarEvent], date: Date) -> some View {
        let isExpanded = expandedAllDayDates.contains(date)
        let previewTitles = events.prefix(3).map(\.title).joined(separator: " · ")
        let extra = events.count - min(3, events.count)
        let preview = extra > 0 ? "\(previewTitles) · +\(extra)" : previewTitles

        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedAllDayDates.remove(date)
                    } else {
                        expandedAllDayDates.insert(date)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sun.horizon")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(events.count) all-day")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(events.map(\.title).joined(separator: "\n"))

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(.secondary.opacity(0.3))
                                    .frame(width: 6, height: 6)
                                Text(event.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.leading, 12)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    expandedEventID = expandedEventID == event.id ? nil : event.id
                                }
                            }

                            if expandedEventID == event.id {
                                eventDetail(event)
                                    .padding(.leading, 24)
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Event Row

    private func eventRow(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                CalendarEventRow(event: event)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            expandedEventID = expandedEventID == event.id ? nil : event.id
                        }
                    }
                Button {
                    if selectedEventID == event.id {
                        selectedEventID = nil
                    } else {
                        selectedEventID = event.id
                        meetingPrepVM.generate(eventID: event.id)
                    }
                } label: {
                    Label("Prepare", systemImage: "doc.text.magnifyingglass")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedEventID == event.id ? Color.accentColor : .blue)

                if event.conferenceLink != nil {
                    joinButton(event)
                }

                recordButton(eventID: event.id, title: event.title)
            }

            if expandedEventID == event.id {
                eventDetail(event)
                    .padding(.leading, 88)
            }
        }
    }

    // MARK: - Event Detail

    private func eventDetail(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !event.location.isEmpty {
                Label(event.location, systemImage: "mappin")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !event.organizerEmail.isEmpty {
                Label(event.organizerEmail, systemImage: "person")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let attendees = event.parsedAttendees
            if !attendees.isEmpty {
                Label("\(attendees.count) attendees", systemImage: "person.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(attendees) { a in
                    HStack(spacing: 4) {
                        Image(systemName: responseIcon(a.responseStatus))
                            .font(.caption2)
                            .foregroundStyle(responseColor(a.responseStatus))
                        Text(a.displayName.isEmpty ? a.email : a.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 20)
                }
            }

            let plain = event.plainDescription
            if !plain.isEmpty {
                Text(plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .padding(.top, 2)
            }

            if let eventURL = URL(string: event.htmlLink), !event.htmlLink.isEmpty {
                Link(destination: eventURL) {
                    Label("Open in Google Calendar", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func responseIcon(_ status: String) -> String {
        switch status {
        case "accepted": return "checkmark.circle.fill"
        case "tentative": return "questionmark.circle"
        case "declined": return "xmark.circle"
        default: return "circle"
        }
    }

    private func responseColor(_ status: String) -> Color {
        switch status {
        case "accepted": return .green
        case "tentative": return .orange
        case "declined": return .red
        default: return .secondary
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No upcoming events")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var notConnectedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No calendar connected")
                .font(.headline)
            Text("Connect a calendar to see your meetings, prep, and briefings here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if google.isRunning {
                ProgressView("Connecting Google...")
                    .padding(.top, 4)
                Button("Cancel") {
                    google.cancel()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                // Two equally-visible paths — a barely-there caption link is
                // not discoverable enough for the primary alternative.
                Button {
                    google.includeGmail = false
                    google.includeCalendar = true
                    google.connect()
                } label: {
                    Label("Connect Google Calendar", systemImage: "calendar.badge.plus")
                        .frame(width: 280)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)

                Button {
                    showAddCalendarAccountSheet = true
                } label: {
                    Label("Connect iCloud / CalDAV / ICS calendar", systemImage: "link.badge.plus")
                        .frame(width: 280)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            if let err = google.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button("Add an IMAP or Outlook mailbox instead…") {
                showAddEmailAccountSheet = true
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            google.refresh()
            appState.calendarAccountsViewModel?.refresh()
        }
        .sheet(isPresented: $showAddEmailAccountSheet) {
            AddEmailAccountView()
                .environment(appState)
        }
        .sheet(isPresented: $showAddCalendarAccountSheet) {
            AddCalendarAccountView()
                .environment(appState)
        }
    }
}

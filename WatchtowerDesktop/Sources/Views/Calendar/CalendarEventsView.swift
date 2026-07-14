import SwiftUI

struct CalendarEventsView: View {
    @Environment(AppState.self) private var appState
    @State private var meetingPrepVM = MeetingPrepViewModel()
    @State private var selectedEventID: String?
    @State private var googleAuth = GoogleAuthService()
    @State private var expandedAllDayDates: Set<Date> = []
    @State private var expandedEventID: String?
    @State private var userNotes: String = ""
    @State private var adHocTranscripts: [MeetingTranscript] = []
    @State private var linkTarget: MeetingTranscript?

    var body: some View {
        Group {
            if googleAuth.isConnected, let calVM = appState.calendarViewModel {
                HStack(spacing: 0) {
                    eventsList(calVM)
                        .frame(minWidth: 300, idealWidth: 350)

                    if let eventID = selectedEventID {
                        Divider()
                        MeetingPrepDetailView(
                            eventID: eventID,
                            viewModel: meetingPrepVM,
                            userNotes: $userNotes
                        )                            { selectedEventID = nil }
                        .id(eventID)
                        .frame(minWidth: 400, idealWidth: 500)
                        .transition(
                            .move(edge: .trailing).combined(with: .opacity)
                        )
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: selectedEventID)
                .onAppear { calVM.loadEvents() }
            } else {
                notConnectedView
            }
        }
    }

    private func eventsList(_ vm: CalendarViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                ForEach(vm.dailyEvents) { day in
                    daySection(day: day, isToday: day.label == "Today")
                }

                if vm.dailyEvents.isEmpty {
                    emptyState
                }

                recordingsSection
            }
            .padding()
        }
        .onAppear(perform: loadAdHocTranscripts)
        .onChange(of: appState.meetingRecorderCenter.phase) { _, phase in
            if case .idle = phase { loadAdHocTranscripts() }
        }
        .sheet(item: $linkTarget) { transcript in
            LinkTranscriptSheet(transcript: transcript, onLinked: loadAdHocTranscripts)
                .environment(appState)
        }
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

    private func stopRecording() {
        // No CLI-runner guard here: stopping capture must never depend on the
        // watchtower binary resolving — the Center fails visibly at the save
        // step instead, with the audio kept.
        Task {
            await appState.meetingRecorderCenter.stopAndProcess(config: .fromDefaults())
        }
    }

    // MARK: - Day Section

    private func daySection(day: DayEvents, isToday: Bool) -> some View {
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

    // MARK: - Recordings (ad-hoc)

    @ViewBuilder
    private var recordingsSection: some View {
        if !adHocTranscripts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recordings")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                ForEach(adHocTranscripts) { transcript in
                    adHocRow(transcript)
                }
            }
        }
    }

    private func adHocRow(_ transcript: MeetingTranscript) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(transcript.title)
                    .font(.callout)
                    .fontWeight(.medium)
                HStack(spacing: 8) {
                    Text(formattedDate(transcript.createdAt))
                    Text(formatDuration(transcript.durationSec))
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let summary = transcript.parsedSummary?.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button {
                linkTarget = transcript
            } label: {
                Label("Link to event…", systemImage: "link")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func loadAdHocTranscripts() {
        guard let db = appState.databaseManager else { return }
        do {
            adHocTranscripts = try db.dbPool.read { conn in
                try MeetingTranscriptQueries.fetchAdHoc(conn)
            }
        } catch {
            // Silent: table may not exist yet on older DB schema versions.
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return minutes > 0 ? "\(minutes)m \(secs)s" : "\(secs)s"
    }

    private func formattedDate(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) else { return iso }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
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
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Google Calendar not connected")
                .font(.headline)
            Text("Connect your Google Calendar to see upcoming meetings and prepare for them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if googleAuth.isAuthenticating {
                ProgressView("Connecting...")
                    .padding(.top, 4)
                Button("Cancel") {
                    googleAuth.cancelConnect()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                Button {
                    googleAuth.connect()
                } label: {
                    Label("Connect Google Calendar", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }

            if let err = googleAuth.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

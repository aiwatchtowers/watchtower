import SwiftUI

/// Lets the user attach an ad-hoc recording to one of the calendar events on the
/// day it was recorded. Confirming runs the dual-path `linkToEvent` write, which
/// also seeds `meeting_recaps` when the transcript already carries a summary.
struct LinkTranscriptSheet: View {
    let transcript: MeetingTranscript
    let onLinked: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var events: [CalendarEvent] = []
    @State private var selectedEventID: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Link recording to event")
                .font(.headline)
            Text(transcript.title)
                .font(.callout)
                .foregroundStyle(.secondary)

            if events.isEmpty {
                Text("No calendar events on \(dayLabel).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Event", selection: $selectedEventID) {
                    Text("Select an event…").tag(String?.none)
                    ForEach(events) { event in
                        Text(eventLabel(event)).tag(String?.some(event.id))
                    }
                }
                .labelsHidden()
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Link") { link() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedEventID == nil)
            }
        }
        .padding()
        .frame(width: 440)
        .onAppear(perform: load)
    }

    private var dayLabel: String {
        guard let date = recordedDate() else { return "that day" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    private func eventLabel(_ event: CalendarEvent) -> String {
        let time = formattedTime(event.startTime)
        return time.isEmpty ? event.title : "\(time) · \(event.title)"
    }

    // MARK: - Data

    private func load() {
        guard let db = appState.databaseManager, let date = recordedDate() else { return }
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: startOfDay) else { return }
        do {
            events = try db.dbPool.read { conn in
                try CalendarQueries.fetchEvents(conn, from: startOfDay, to: endOfDay)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func link() {
        guard let eventID = selectedEventID, let id = transcript.id,
              let db = appState.databaseManager else { return }
        do {
            try db.dbPool.write { conn in
                try MeetingTranscriptQueries.linkToEvent(conn, id: id, eventID: eventID)
            }
            onLinked()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func recordedDate() -> Date? {
        ISO8601DateFormatter().date(from: transcript.createdAt)
    }

    private func formattedTime(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) else { return "" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

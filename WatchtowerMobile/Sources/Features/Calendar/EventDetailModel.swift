import Foundation
import WatchtowerKit
import WatchtowerSync

/// The event detail (spec §13 C1): time, attendees, prep bullets, linked
/// targets read-only, the Recording section, Join and Record this meeting.
/// Targets are never made from the phone here (hidden until D).
struct EventDetailModel {
    struct Attendee: Identifiable, Equatable {
        let id: String
        let initials: String
    }

    struct LinkedTargetRow: Identifiable, Equatable {
        let id: Int
        let text: String
        let status: String
    }

    static let avatarLimit = 5
    static let noPrepText = "No prep yet — it is prepared on your Mac"

    let id: String
    let title: String
    /// "Wed, Oct 7 · 14:00–14:45 · Google Meet".
    let whenLine: String
    let attendees: [Attendee]
    /// "5 people · 4 accepted"; nil without attendees.
    let attendeesLine: String?
    let prepBullets: [String]
    /// "N more on your Mac" when the hub dropped bullets.
    let prepMoreText: String?
    let prepEmptyText: String?
    let description: String?
    let linkedTargets: [LinkedTargetRow]
    let linkedTargetsMoreText: String?
    /// The Recording section: the recap or the Mac's progress.
    let recordingText: String
    let recordingPills: [EventPill]
    /// Join opens this; nil (no Join) without a usable meeting link.
    let joinURL: URL?
    /// nil for an all-day event: no Record this meeting.
    let meetingEvent: MeetingEvent?

    var showsRecord: Bool { meetingEvent != nil }

    /// The bottom bar's buttons, in order.
    var actionTitles: [String] {
        (joinURL != nil ? ["Join"] : []) + (showsRecord ? ["Record this meeting"] : [])
    }

    /// Every string the screen shows (the "Make target" guard reads it).
    var allStrings: [String] {
        [title, whenLine, attendeesLine, prepMoreText, prepEmptyText, description, linkedTargetsMoreText, recordingText]
            .compactMap { $0 }
            + prepBullets + linkedTargets.flatMap { [$0.text, $0.status] } + recordingPills.map(\.text) + actionTitles
    }

    init?(
        eventID: String,
        snapshot: CalendarReplicaSnapshot,
        recordings: PhoneRecordingsSnapshot,
        now: Date,
        calendar: Calendar
    ) {
        guard let event = snapshot.event(eventID) else { return nil }
        let format = CalendarFormat(calendar: calendar)
        id = event.id
        title = event.title
        whenLine = ([format.day(event.localStart(in: calendar)), format.timeRange(event)]
            + [CalendarFormat.venue(event)].compactMap { $0 }).joined(separator: " · ")

        attendees = event.attendees.prefix(Self.avatarLimit).map {
            Attendee(id: $0.email, initials: Self.initials($0.displayName.isEmpty ? $0.email : $0.displayName))
        }
        let accepted = event.attendees.filter { $0.responseStatus == "accepted" }.count
        attendeesLine = CalendarFormat.people(event).map { "\($0) · \(accepted) accepted" }

        prepBullets = event.prepBullets
        prepMoreText = (event.prepBulletsMore ?? 0) > 0 ? "\(event.prepBulletsMore ?? 0) more on your Mac" : nil
        prepEmptyText = event.prepBullets.isEmpty ? Self.noPrepText : nil
        let text = event.description.trimmingCharacters(in: .whitespacesAndNewlines)
        description = text.isEmpty ? nil : text

        linkedTargets = event.linkedTargets.map { LinkedTargetRow(id: $0.id, text: $0.text, status: Self.statusLabel($0.status)) }
        linkedTargetsMoreText = (event.linkedTargetsMore ?? 0) > 0 ? "\(event.linkedTargetsMore ?? 0) more on your Mac" : nil

        let status = EventRecordingStatus(event: event, snapshot: snapshot, recordings: recordings, now: now)
        recordingText = status.text ?? EventRecordingStatus.notRecordedText
        recordingPills = status.pills
        joinURL = event.conferenceLink
        meetingEvent = event.isAllDay
            ? nil
            : MeetingEvent(id: event.id, title: event.title, start: event.startDate, end: event.endDate)
    }

    static func initials(_ name: String) -> String {
        let words = name.split { $0 == " " || $0 == "." || $0 == "@" }.prefix(2)
        return words.compactMap(\.first).map { String($0).uppercased() }.joined()
    }

    static func statusLabel(_ status: LinkedTargetStatus) -> String {
        switch status {
        case .todo: "To do"
        case .inProgress: "In progress"
        case .blocked: "Blocked"
        case .done: "Done"
        case .dismissed: "Dismissed"
        case .snoozed: "Snoozed"
        default: status.rawValue
        }
    }

    var toneUses: [ToneUse] {
        recordingPills.map { ToneUse(element: "recording \($0.text)", tone: $0.tone, role: $0.role) }
            + (showsRecord ? [ToneUse(element: "record this meeting", tone: .red, role: .recording)] : [])
    }
}

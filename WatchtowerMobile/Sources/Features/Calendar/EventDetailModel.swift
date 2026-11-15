import Foundation
import WatchtowerKit
import WatchtowerSync

/// A button of the event detail's bottom bar (design pass C4).
enum EventAction: Hashable {
    case join
    case record
    /// A finished event with a recap: the one button, which opens it.
    case openRecap(Int)
    /// A finished event recorded on this phone whose transcript has not
    /// reached the replica yet: opens the Recordings list, where the
    /// recording's row shows its progress or Retry (#1789).
    case openRecording

    var title: String {
        switch self {
        case .join: "Join"
        case .record: "Record"
        case .openRecap: "Open recap"
        case .openRecording: "Open recording"
        }
    }
}

/// The event detail (spec §13 C1, design pass C4): time, attendees, prep bullets, linked
/// targets read-only, the Recording section, and Join and Record, or Open recap once it is over.
/// Targets are never made from the phone here (hidden until D).
struct EventDetailModel {
    struct Attendee: Identifiable, Equatable {
        let id: String
        let initials: String
        /// From `attendeeTones` by a stable hash of the name; never red or orange.
        let tone: PhoneTone
    }

    struct LinkedTargetRow: Identifiable, Equatable {
        let id: Int
        let text: String
        let status: String
    }

    static let avatarLimit = 5
    static let noPrepText = "No prep yet — it is prepared on your tower"
    static let transcribingTitle = "Transcribing on your tower"
    /// Attendee initials' tones (design pass C4): never red (recording) or
    /// orange (waiting).
    static let attendeeTones: [PhoneTone] = [.blue, .green, .teal, .purple]

    /// A pick that is the same on every launch and device, unlike
    /// `hashValue`, which Swift seeds per process.
    static func attendeeTone(_ name: String) -> PhoneTone {
        let hash = name.utf8.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1) }
        return attendeeTones[Int(hash % UInt64(attendeeTones.count))]
    }

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
    /// The Recording section's progress row; nil without one.
    let transcribingPercent: Int?
    /// Join opens this; nil (no Join) without a usable meeting link.
    let joinURL: URL?
    /// nil for an all-day event: no Record.
    let meetingEvent: MeetingEvent?

    /// The bottom bar's buttons, in order: Join (with a usable link) and
    /// Record (not all-day) until the event ends; then a recap's Open recap
    /// alone, or Join and Open recording for a phone recording still on its
    /// way; an unrecorded event keeps Record for `overrunGrace` after its
    /// end, then has none (#1789).
    let actions: [EventAction]

    var showsRecord: Bool { actions.contains(.record) }

    /// Every string the screen shows (the "Make target" guard reads it).
    var allStrings: [String] {
        [title, whenLine, attendeesLine, prepMoreText, prepEmptyText, description, linkedTargetsMoreText, recordingText]
            .compactMap { $0 }
            + prepBullets + linkedTargets.flatMap { [$0.text, $0.status] } + recordingPills.map(\.text) + actions.map(\.title)
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
            let name = $0.displayName.isEmpty ? $0.email : $0.displayName
            return Attendee(id: $0.email, initials: Self.initials(name), tone: Self.attendeeTone(name))
        }
        let accepted = event.attendees.filter { $0.responseStatus == "accepted" }.count
        attendeesLine = CalendarFormat.people(event).map { "\($0) · \(accepted) accepted" }

        prepBullets = event.prepBullets
        prepMoreText = (event.prepBulletsMore ?? 0) > 0 ? "\(event.prepBulletsMore ?? 0) more on your tower" : nil
        prepEmptyText = event.prepBullets.isEmpty ? Self.noPrepText : nil
        let text = event.description.trimmingCharacters(in: .whitespacesAndNewlines)
        description = text.isEmpty ? nil : text

        linkedTargets = event.linkedTargets.map { LinkedTargetRow(id: $0.id, text: $0.text, status: Self.statusLabel($0.status)) }
        linkedTargetsMoreText = (event.linkedTargetsMore ?? 0) > 0 ? "\(event.linkedTargetsMore ?? 0) more on your tower" : nil

        let status = EventRecordingStatus(event: event, snapshot: snapshot, recordings: recordings, now: now)
        recordingText = status.text ?? EventRecordingStatus.notRecordedText
        recordingPills = status.pills
        transcribingPercent = status.transcribingPercent
        joinURL = event.conferenceLink
        meetingEvent = event.isAllDay
            ? nil
            : MeetingEvent(id: event.id, title: event.title, start: event.startDate, end: event.endDate)
        let join: [EventAction] = joinURL != nil ? [.join] : []
        if event.endDate > now {
            actions = join + (meetingEvent != nil ? [.record] : [])
        } else if let recap = snapshot.transcript(forEvent: event.id) {
            actions = [.openRecap(recap.id)]
        } else if recordings.recordings.contains(where: { $0.eventID == event.id }) {
            // Over: no Record (#1789) — a second recording of a finished
            // meeting would only hide the first one's progress.
            actions = join + [.openRecording]
        } else if meetingEvent != nil, now < event.endDate.addingTimeInterval(Self.overrunGrace) {
            // A meeting that runs past its calendar end, not recorded yet.
            actions = join + [.record]
        } else {
            actions = join
        }
    }

    /// How long after its calendar end an event with no recording or
    /// transcript still offers Record: meetings overrun.
    static let overrunGrace: TimeInterval = 30 * 60

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
            + (transcribingPercent != nil ? [ToneUse(element: "transcribing on mac", tone: .purple, role: .progress)] : [])
            + attendees.map { ToneUse(element: "attendee \($0.id)", tone: $0.tone, role: .info) }
            + (showsRecord ? [ToneUse(element: "record button", tone: .red, role: .recording)] : [])
    }
}

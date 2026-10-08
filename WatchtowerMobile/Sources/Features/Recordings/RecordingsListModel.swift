import Foundation
import Observation
import WatchtowerKit
import WatchtowerSync

// MARK: - One list entry

/// Where one recording stands, as its row on the Recordings list says it.
enum RecordingEntryState: Equatable {
    case recordingOnPhone
    case sending
    case waitingForMac
    case sendFailed(String, retryable: Bool)
    /// The Mac has it and is working on it ("Queued on your Mac",
    /// "Transcribing on Mac · 37%", …).
    case onMac(String)
    case macFailed(String)
    case ready

    init(upload: PhoneUploadStage) {
        switch upload {
        case .recording: self = .recordingOnPhone
        case .sending: self = .sending
        case .waitingForMac: self = .waitingForMac
        case .delivered: self = .onMac("Sent to your Mac")
        case let .failed(message, retryable): self = .sendFailed(message, retryable: retryable)
        }
    }

    var label: String {
        switch self {
        case .recordingOnPhone: "Recording on the phone"
        case .sending: "Sending"
        case .waitingForMac: "Waiting for the Mac to wake"
        case let .sendFailed(message, _), let .macFailed(message), let .onMac(message): message
        case .ready: "Ready"
        }
    }

    var tone: PhoneTone {
        switch self {
        case .recordingOnPhone, .sendFailed, .macFailed: .red
        case .sending, .waitingForMac: .secondary
        case .onMac: .purple
        case .ready: .green
        }
    }

    var isReady: Bool { self == .ready }
}

/// One row: a phone recording on its way, or a ready transcript (made on
/// the phone or on the Mac).
struct RecordingEntry: Identifiable, Equatable {
    /// "phone-<ledger id>" or "transcript-<id>".
    let id: String
    let title: String
    /// "Today 10:00 · 14:32 · from this phone".
    let subtitle: String
    let state: RecordingEntryState
    /// The transcript the row opens; nil while there is none on the phone.
    let transcriptID: Int?
    /// The ledger row a failed upload retries.
    let phoneRecordingID: String?
    /// A ready recap the owner has not opened.
    let isNew: Bool
    let sortDate: Date

    var statusText: String { state.label }
    var tone: PhoneTone { state.tone }
    var offersRetry: Bool {
        if case let .sendFailed(_, retryable) = state { return retryable }
        return false
    }

    var accessibilityLabel: String {
        var parts = [title, subtitle, statusText]
        if isNew { parts.append("New") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Seen recaps

/// Which ready recaps count as new: created after the phone's first launch
/// (`baseline`, so a fresh install does not flag the Mac's whole history)
/// and not opened yet.
struct RecordingsSeen: Equatable {
    var baseline: Date
    var opened: Set<Int>

    func isNew(_ transcript: MeetingTranscript) -> Bool {
        guard !opened.contains(transcript.id), let created = TranscriptDates.parse(transcript.createdAt) else { return false }
        return created > baseline
    }
}

/// The seen state, kept in the phone's UserDefaults: it is the owner's
/// reading position on this phone only, never synced.
@MainActor
@Observable
final class RecordingsSeenStore {
    private(set) var value: RecordingsSeen
    @ObservationIgnored private let defaults: UserDefaults

    private static let baselineKey = "recordings.seenBaseline"
    private static let openedKey = "recordings.openedTranscripts"

    init(defaults: UserDefaults, now: Date = Date()) {
        self.defaults = defaults
        let baseline: Date
        if let stored = defaults.object(forKey: Self.baselineKey) as? Double {
            baseline = Date(timeIntervalSinceReferenceDate: stored)
        } else {
            baseline = now
            defaults.set(now.timeIntervalSinceReferenceDate, forKey: Self.baselineKey)
        }
        let opened = (defaults.array(forKey: Self.openedKey) as? [Int]) ?? []
        value = RecordingsSeen(baseline: baseline, opened: Set(opened))
    }

    func markOpened(_ transcriptID: Int) {
        guard value.opened.insert(transcriptID).inserted else { return }
        defaults.set(value.opened.sorted(), forKey: Self.openedKey)
    }
}

// MARK: - The list

/// The Recordings list (spec §13 C3): phone recordings still on their way
/// or on the Mac under "In progress", ready transcripts under "Earlier",
/// newest first. A phone recording and its transcript are one entry.
struct RecordingsListModel {
    let inProgress: [RecordingEntry]
    let earlier: [RecordingEntry]
    let emptyText: String?

    var newCount: Int { earlier.filter(\.isNew).count }

    /// The Calendar's pill: "Recordings · 1 new", or "Recordings".
    static func pillText(newCount: Int) -> String {
        newCount > 0 ? "Recordings · \(newCount) new" : "Recordings"
    }

    init(
        recordings: PhoneRecordingsSnapshot,
        replica: CalendarReplicaSnapshot,
        seen: RecordingsSeen,
        now: Date,
        calendar: Calendar
    ) {
        let format = RecordingsFormat(calendar: calendar, now: now)
        var byPhoneID: [String: MeetingTranscript] = [:]
        for transcript in replica.transcripts {
            if let phoneID = recordings.phoneRecordingID(forTranscript: transcript) {
                byPhoneID[phoneID] = transcript
            }
        }
        var entries: [RecordingEntry] = []
        var claimed = Set<Int>()
        for recording in recordings.recordings {
            let transcript = byPhoneID[recording.id]
            if let transcript { claimed.insert(transcript.id) }
            entries.append(Self.entry(recording, transcript: transcript, recordings: recordings, seen: seen, now: now, format: format))
        }
        for transcript in replica.transcripts where !claimed.contains(transcript.id) {
            entries.append(Self.entry(transcript, origin: "recorded on Mac", seen: seen, format: format))
        }
        let newestFirst: (RecordingEntry, RecordingEntry) -> Bool = { lhs, rhs in
            lhs.sortDate != rhs.sortDate ? lhs.sortDate > rhs.sortDate : lhs.id < rhs.id
        }
        inProgress = entries.filter { !$0.state.isReady }.sorted(by: newestFirst)
        earlier = entries.filter(\.state.isReady).sorted(by: newestFirst)
        emptyText = entries.isEmpty ? "No recordings yet" : nil
    }

    private static func entry(
        _ recording: PhoneRecording,
        transcript: MeetingTranscript?,
        recordings: PhoneRecordingsSnapshot,
        seen: RecordingsSeen,
        now: Date,
        format: RecordingsFormat
    ) -> RecordingEntry {
        let origin = recording.eventID == nil ? "voice note" : "from this phone"
        if let transcript {
            return entry(transcript, origin: origin, seen: seen, format: format, phoneRecordingID: recording.id)
        }
        let state: RecordingEntryState
        if let job = recordings.jobs[recording.id] {
            switch PhoneTranscriptStage(job: job) {
            case let .inProgress(label): state = .onMac(label)
            case .ready: state = .ready
            case let .failed(message): state = .macFailed(message)
            case .notStarted: state = .onMac("Sent to your Mac")
            }
        } else {
            state = RecordingEntryState(upload: PhoneUploadStage(recording: recording, heartbeat: recordings.heartbeat, now: now))
        }
        return RecordingEntry(
            id: "phone-\(recording.id)",
            title: recording.titleHint ?? "Recording",
            subtitle: [format.when(recording.startedAt), format.duration(recording.durationSec), origin].joined(separator: " · "),
            state: state,
            transcriptID: nil,
            phoneRecordingID: recording.id,
            isNew: false,
            sortDate: recording.startedAt
        )
    }

    private static func entry(
        _ transcript: MeetingTranscript,
        origin: String,
        seen: RecordingsSeen,
        format: RecordingsFormat,
        phoneRecordingID: String? = nil
    ) -> RecordingEntry {
        let created = TranscriptDates.parse(transcript.createdAt) ?? .distantPast
        var parts = [format.when(created), format.duration(transcript.durationSec), origin]
        if transcript.summary != nil { parts.append("recap") }
        return RecordingEntry(
            id: "transcript-\(transcript.id)",
            title: transcript.title,
            subtitle: parts.joined(separator: " · "),
            state: .ready,
            transcriptID: transcript.id,
            phoneRecordingID: phoneRecordingID,
            isNew: seen.isNew(transcript),
            sortDate: created
        )
    }
}

extension PhoneRecordingsSnapshot {
    /// The phone recording a transcript came from: the hub's sidecar
    /// `phone_recording_id`, else the `recording_job` that names it (the
    /// job id is the upload id). nil for a recording made on the Mac.
    func phoneRecordingID(forTranscript transcript: MeetingTranscript) -> String? {
        if let id = transcript.phoneRecordingID { return id }
        return jobs.values.filter { $0.transcriptID == transcript.id }.map(\.id).min()
    }
}

// MARK: - Formatting

/// Recording strings on the phone's clock.
struct RecordingsFormat {
    let calendar: Calendar
    let now: Date
    private let clock: DateFormatter
    private let day: DateFormatter

    init(calendar: Calendar, now: Date) {
        self.calendar = calendar
        self.now = now
        clock = Self.formatter("HH:mm", calendar)
        day = Self.formatter("EEE, MMM d", calendar)
    }

    private static func formatter(_ format: String, _ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// "Today 10:00", "Yesterday 10:00", or "Mon, Oct 5".
    func when(_ date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(clock.string(from: date))" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday \(clock.string(from: date))"
        }
        return day.string(from: date)
    }

    /// "14:32", or "1:02:10".
    func duration(_ seconds: Int) -> String {
        Self.offset(seconds)
    }

    /// An offset into the audio: "2:05", or "1:02:05".
    static func offset(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        let hours = seconds / 3_600
        let minutes = seconds % 3_600 / 60
        let secs = seconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    /// "2 minutes 5 seconds", for VoiceOver.
    static func spokenOffset(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        let parts: [(Int, String)] = [(seconds / 3_600, "hour"), (seconds % 3_600 / 60, "minute"), (seconds % 60, "second")]
        let spoken = parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return spoken.isEmpty ? "0 seconds" : spoken.joined(separator: " ")
    }
}

/// The transcript's stored ISO8601 timestamps.
enum TranscriptDates {
    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parse(_ value: String) -> Date? {
        plain.date(from: value) ?? fractional.date(from: value)
    }
}

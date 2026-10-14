import Foundation
import WatchtowerKit
import WatchtowerSync

/// A small coloured label on an event card.
struct EventPill: Equatable, Identifiable {
    let text: String
    let tone: PhoneTone
    let role: ToneRole
    var id: String { text }
}

/// What the Mac and the phone know about recording one event: the recap,
/// the Mac's progress on a phone recording, or the upload on its way.
struct EventRecordingStatus: Equatable {
    let pills: [EventPill]
    /// The event detail's Recording section text; nil = not recorded yet.
    let text: String?
    /// The Mac's percent, clamped to 0…100, while a phone recording of
    /// this event is on its way and its job is transcribing; nil otherwise
    /// (design pass C4's row).
    let transcribingPercent: Int?

    static let notRecordedText =
        "Not recorded yet. A recording here is attached to this event; the Mac transcribes it and writes the recap."

    init(event: CalendarEvent, snapshot: CalendarReplicaSnapshot, recordings: PhoneRecordingsSnapshot, now: Date) {
        // The newest phone recording made for this event (the ledger is
        // newest first). While it is on its way or on the Mac, its state
        // wins over an older recap of the same event.
        let newest = recordings.recordings.first { $0.eventID == event.id }
        let phone = newest.map { Self.phonePill($0, recordings: recordings, now: now) }
        if let phone, phone.inFlight {
            pills = [phone.pill]
            text = phone.pill.text
            transcribingPercent = newest.flatMap { recordings.jobs[$0.id] }.flatMap(Self.transcribingPercent)
        } else if let transcript = snapshot.transcript(forEvent: event.id) {
            var pills: [EventPill] = []
            let recap = transcript.summary != nil
            pills.append(EventPill(text: recap ? "Recap ready" : "Transcript ready", tone: .green, role: .status))
            let items = transcript.actionItems.count + (transcript.actionItemsMore ?? 0)
            if items > 0 {
                pills.append(EventPill(text: items == 1 ? "1 action item" : "\(items) action items", tone: .secondary, role: .info))
            }
            self.pills = pills
            text = transcript.summary ?? "Transcript ready"
            transcribingPercent = nil
        } else if let phone {
            pills = [phone.pill]
            text = phone.pill.text
            transcribingPercent = nil
        } else {
            pills = []
            text = nil
            transcribingPercent = nil
        }
    }

    /// The job's percent while it transcribes, clamped to 0…100; nil in any
    /// other job state.
    static func transcribingPercent(_ job: RecordingJob) -> Int? {
        job.status == .transcribing ? PhoneTranscriptStage.clampedPercent(job.percent) : nil
    }

    /// One phone recording's pill; `inFlight` while the upload or the Mac's
    /// job is still running (a delivered recording without a job yet, or
    /// one whose job aged out, defers to the transcript).
    private static func phonePill(
        _ recording: PhoneRecording,
        recordings: PhoneRecordingsSnapshot,
        now: Date
    ) -> (pill: EventPill, inFlight: Bool) {
        if let job = recordings.jobs[recording.id] {
            switch PhoneTranscriptStage(job: job) {
            case let .inProgress(label): return (EventPill(text: label, tone: .purple, role: .progress), true)
            case .ready, .notStarted: return (EventPill(text: "Transcript ready", tone: .green, role: .status), false)
            case let .failed(message): return (EventPill(text: message, tone: .red, role: .status), false)
            }
        }
        let stage = PhoneUploadStage(recording: recording, heartbeat: recordings.heartbeat, now: now)
        switch stage {
        case .failed: return (EventPill(text: stage.label, tone: .red, role: .status), true)
        case .delivered: return (EventPill(text: stage.label, tone: .secondary, role: .info), false)
        case .recording, .sending, .waitingForMac: return (EventPill(text: stage.label, tone: .secondary, role: .info), true)
        }
    }
}

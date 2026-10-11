import Foundation
import WatchtowerKit
import WatchtowerSync

/// The calendar part of the demo replica (spec §13 C1): today's agenda with
/// a past meeting whose recap is ready, a past meeting the Mac is
/// transcribing, the next meeting with prep and linked targets, a later
/// one without prep, an all-day event, and one tomorrow. Times are relative
/// to `now`; records are built as the JSON the hub would publish.
extension DemoSeed {
    /// The demo event a phone recording was made for; the Mac is
    /// transcribing it.
    static let recordedEventID = "demo-evt-design"

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func calendarRecords(now: Date) throws -> [CloudRecord] {
        try calendarSlices(now: now).map { kind, json in
            guard let id = json["id"].map({ "\($0)" }) else { throw DemoSeedError.missingID }
            let payload = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            let record = CloudRecordFactory.record(for: SliceRecord(kind: kind, id: id, modifiedAt: now, payload: payload))
            guard kind == .meetingTranscript else { return record }
            // The transcript body rides as the record's segments.json asset,
            // as the hub publishes it. A fixed file name: one file however
            // often the demo relaunches.
            let asset = FileManager.default.temporaryDirectory.appendingPathComponent("demo-segments-\(id).json")
            try RelayCoder.makeEncoder().encode(demoSegments).write(to: asset, options: .atomic)
            return CloudRecord(
                recordName: record.recordName, zone: record.zone, kind: record.kind,
                modifiedAt: record.modifiedAt, payload: record.payload, assetFileURL: asset
            )
        }
    }

    /// The demo standup's speaker transcript.
    static let demoSegments: [TranscriptSegment] = [
        TranscriptSegment(startSec: 0, endSec: 42, speaker: "Colleague A", text: "Quick round: the release is still on for Friday."),
        TranscriptSegment(startSec: 42, endSec: 118, speaker: "Colleague B", text: "The board archive migration lands first; I will check it today."),
        TranscriptSegment(startSec: 118, endSec: 260, speaker: "Colleague A", text: "Then the release notes go out, and we book the review."),
        TranscriptSegment(startSec: 260, endSec: 900, speaker: "Colleague B", text: "Agreed. Nothing else blocks Friday.")
    ]

    /// Every calendar slice payload of the demo, in publish order.
    static func calendarSlices(now: Date) -> [(SliceKind, [String: Any])] {
        let at: (TimeInterval) -> String = { iso.string(from: now.addingTimeInterval($0)) }
        let people = ["Colleague A", "Colleague B", "Colleague C", "Colleague D", "Colleague E"]
        let attendees: [[String: Any]] = people.enumerated().map { index, name in
            [
                "email": "colleague-\(index + 1)@example.com", "display_name": name,
                "response_status": index == 4 ? "needsAction" : "accepted"
            ]
        }
        let events: [[String: Any]] = [
            event("demo-evt-standup", start: at(-14_400), end: at(-13_500), [
                "title": "Acme standup", "conference_url": "https://meet.google.com/aaa-bbbb-ccc",
                "attendees": Array(attendees.prefix(3))
            ]),
            event(recordedEventID, start: at(-7_200), end: at(-4_500), [
                "title": "Board lanes design review", "location": "Room 2"
            ]),
            event("demo-evt-roadmap", start: at(1_500), end: at(4_200), [
                "title": "Acme roadmap review", "conference_url": "https://meet.google.com/ddd-eeee-fff",
                "attendees": attendees,
                "description": "Quarterly roadmap: what ships next and what waits.",
                "prep_bullets": [
                    "Ask whether the board archive is ready for the release",
                    "Bring the session report numbers",
                    "Agree who owns the phone recorder follow-ups"
                ],
                "prep_generated_at": at(-3_600),
                "linked_targets": [
                    ["id": 401, "text": "Send the roadmap notes", "status": "in_progress"],
                    ["id": 402, "text": "Book the release review", "status": "todo"]
                ]
            ]),
            event("demo-evt-1on1", start: at(10_800), end: at(12_600), [
                "title": "1:1 with colleague A", "location": "Room 1",
                "attendees": Array(attendees.prefix(1))
            ]),
            allDay("demo-evt-release", on: now, title: "Release day"),
            event("demo-evt-planning", start: at(86_400), end: at(90_000), [
                "title": "Sprint planning", "conference_url": "https://acme.zoom.us/j/123456"
            ])
        ]
        let transcripts: [[String: Any]] = [
            [
                "id": 501, "event_id": "demo-evt-standup", "title": "Acme standup", "duration_sec": 900,
                "created_at": at(-13_400), "updated_at": at(-13_000),
                "speakers": ["Colleague A", "Colleague B"],
                "summary": "The release stays on Friday; the board archive lands first.",
                "key_decisions": ["Ship on Friday"],
                "action_items": ["Send the release notes", "Check the archive migration", "Book the review"],
                "open_questions": []
            ]
        ]
        return events.map { (.calendarEvent, $0) } + transcripts.map { (.meetingTranscript, $0) }
    }

    private static func event(_ id: String, start: String, end: String, _ overrides: [String: Any]) -> [String: Any] {
        [
            "id": id, "start_time": start, "end_time": end, "is_all_day": false, "is_recurring": false,
            "event_status": "confirmed", "organizer_email": "colleague-1@example.com", "html_link": "",
            "conference_url": "", "title": "Event", "location": "", "description": "", "attendees": [[String: Any]](),
            "prep_bullets": [String](), "linked_targets": [[String: Any]]()
        ].merging(overrides) { _, new in new }
    }

    /// An all-day event stored the hub's way: UTC midnight of the local
    /// calendar day.
    private static func allDay(_ id: String, on day: Date, title: String) -> [String: Any] {
        let calendar = Calendar.current
        let stamp: (Date) -> String = { date in
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02dT00:00:00Z", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        return event(id, start: stamp(day), end: stamp(next), ["title": title, "is_all_day": true])
    }

    // MARK: - The phone recording the Mac is transcribing

    /// The demo recording's fixed ledger id: one row and one job record
    /// across relaunches.
    static let recordingID = "demo-phone-recording"

    /// A delivered phone recording for `recordedEventID` and its
    /// `recording_job` at `percent`. The ledger row is made once and reused
    /// on every relaunch. The audio stand-in is deleted by the `received`
    /// echo, as for a real upload, or here when the uploader refuses it.
    static func loadRecordingDemo(
        uploader: RecordingUploader,
        store: ReplicaStore,
        transport: any CloudSyncTransport,
        now: Date,
        percent: Int = 60
    ) async throws {
        // A replica from before the fixed id holds the demo row under a
        // random id: replace it rather than adding a second one.
        for stale in try store.phoneRecordings() where stale.eventID == recordedEventID && stale.id != recordingID {
            try store.removePhoneRecording(id: stale.id)
        }
        let recording: PhoneRecording
        if let existing = try store.phoneRecording(id: recordingID) {
            recording = existing
        } else {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString).m4a")
            try Data([0]).write(to: file)
            guard let row = try await uploader.register(
                id: recordingID,
                fileURL: file,
                startedAt: now.addingTimeInterval(-7_200),
                endedAt: now.addingTimeInterval(-4_500),
                titleHint: "Board lanes design review",
                eventID: recordedEventID
            ) else {
                // Best effort: register already deletes a degenerate file.
                try? FileManager.default.removeItem(at: file)
                throw DemoSeedError.recordingNotRegistered
            }
            try await uploader.applyEcho(RecordingUploadPayload(
                id: row.id, startedAt: row.startedAt, endedAt: row.endedAt, durationSec: row.durationSec,
                sampleFormat: row.sampleFormat, status: .received, errorMessage: nil, deviceID: device.deviceID
            ))
            recording = row
        }
        let job = RecordingJob(id: recording.id, status: .transcribing, percent: percent, updatedAt: now)
        let payload = try RelayCoder.makeEncoder().encode(job)
        try await transport.save([
            CloudRecordFactory.record(for: SliceRecord(kind: .recordingJob, id: job.id, modifiedAt: now, payload: payload))
        ])
    }
}

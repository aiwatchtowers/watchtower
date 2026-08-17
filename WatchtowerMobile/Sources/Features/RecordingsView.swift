import GRDB
import Observation
import os
import SwiftUI
import WatchtowerKit

// MARK: - View model

/// The Recordings screen: every meeting the Mac recorded, newest first, with a
/// read-only detail per recording. Reached from Today (no seventh tab — the
/// iPhone tab bar already folds two of the existing six under "More", and
/// recordings are meeting-shaped, so Today's calendar section owns the link).
///
/// READ-ONLY by construction: the phone holds the publisher's projection
/// (resolved recap + notes + chapters + a 200-character snippet). No delete,
/// no rename, no notes editing, no playback — the transcript text and the
/// audio never leave the Mac, and the detail screen says so instead of
/// offering a button that cannot work.
@MainActor
@Observable
final class RecordingsViewModel {
    /// Cheap list projections, built ONCE per observation delivery. The
    /// desktop's perf rule (`fetchRecordingList`: never select the text,
    /// never decode in a row builder) applies verbatim here, because
    /// `MeetingTranscript.recap` re-decodes JSON on every access — the rows
    /// carry booleans, and only the open detail decodes.
    private(set) var rows: [RecordingRow] = []
    /// Local captures on their way to the Mac (the `phone_recordings`
    /// ledger), newest first — the "On this phone" section.
    private(set) var phoneRows: [PhoneRecording] = []
    private var transcriptsByID: [Int: MeetingTranscript] = [:]
    private var cancellable: AnyDatabaseCancellable?
    private var phoneCancellable: AnyDatabaseCancellable?
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "RecordingsViewModel")

    func start(store: ReplicaStore) {
        guard cancellable == nil else { return }
        phoneCancellable = ValueObservation
            .tracking { db in try store.phoneRecordings(from: db) }
            .start(
                in: store.reader,
                scheduling: .async(onQueue: .main),
                onError: { error in
                    Self.logger.error("phone recordings observation error: \(error.localizedDescription, privacy: .public)")
                },
                onChange: { [weak self] value in
                    MainActor.assumeIsolated { self?.phoneRows = value }
                }
            )
        cancellable = ReplicaObserver.observe(
            MeetingTranscript.self, kind: .meetingTranscript, in: store
        ) { [weak self] items in
            // Publisher order (SlicePublisher's meeting_transcript SQL, and
            // the Kit toolbox's `transcriptOrder`): created_at DESC, id DESC.
            let ordered = items.sorted {
                $0.createdAt == $1.createdAt ? $0.id > $1.id : $0.createdAt > $1.createdAt
            }
            self?.rows = ordered.map(RecordingRow.init)
            self?.transcriptsByID = Dictionary(ordered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// The live record behind an open detail screen; nil once the recording
    /// left the slice (deleted on the Mac, or aged out of the publisher's
    /// window).
    func transcript(id: Int) -> MeetingTranscript? {
        transcriptsByID[id]
    }
}

// MARK: - Row projection

/// One list row. Every field is a plain string or Bool computed at build time,
/// so nothing decodes JSON while the list scrolls.
struct RecordingRow: Identifiable, Equatable {
    let id: Int
    /// The recording's own title, the linked event's title when the recording
    /// has none, and a placeholder when neither is set (an ad-hoc recording
    /// saved without a name).
    let title: String
    /// The linked event, shown as a subtitle only when it is not already the
    /// title. nil for an ad-hoc recording and for a link whose event row sync
    /// retention pruned.
    let eventTitle: String?
    let isAdHoc: Bool
    let dateLabel: String
    let durationLabel: String
    /// From `recap_json`/`notes_md` being non-empty — a boolean, never a
    /// decode (see the view model's projection note).
    let hasRecap: Bool
    let hasNotes: Bool
    let snippet: String

    init(_ transcript: MeetingTranscript) {
        let own = transcript.title.trimmedText
        let event = (transcript.eventTitle ?? "").trimmedText
        let resolvedTitle = own.isEmpty ? (event.isEmpty ? "Untitled recording" : event) : own

        id = transcript.id
        title = resolvedTitle
        eventTitle = (event.isEmpty || event == resolvedTitle) ? nil : event
        isAdHoc = transcript.eventID == nil
        dateLabel = RecordingFormatting.date(transcript.createdAt)
        durationLabel = RecordingFormatting.duration(transcript.durationSec)
        hasRecap = !transcript.recapJSON.isEmpty
        hasNotes = !transcript.notesMD.trimmedText.isEmpty
        snippet = transcript.snippet
    }

    /// "12 Aug 2026 at 15:04 · 45m 32s", dropping either half when the stored
    /// value was unusable (an empty `created_at`).
    var metaLabel: String {
        [dateLabel, durationLabel].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Detail projection

/// Everything the detail screen renders, decoded ONCE per transcript version
/// (`RecordingDetailView` rebuilds it in a `.task` keyed on `updated_at`, the
/// desktop's `RecordingDetailView.load` shape).
struct RecordingDetail: Equatable {
    /// A recap is absent, present, or unreadable. The third case matters: the
    /// list badge already promised a recap when `recap_json` is non-empty, so
    /// a payload the phone cannot decode must say so rather than render as
    /// "no recap yet". (`absent` rather than `none`: a case named `none`
    /// shadows `Optional.none` at every inference site.)
    enum Recap: Equatable {
        case absent
        case unreadable
        case present(MeetingTranscript.Recap)
    }

    let recap: Recap
    let chapters: [RecordingChapter]
    let speakers: [String]
    let notes: String
    let snippet: String

    init(_ transcript: MeetingTranscript) {
        if transcript.recapJSON.isEmpty {
            recap = .absent
        } else if let decoded = transcript.recap {
            recap = .present(decoded)
        } else {
            recap = .unreadable
        }
        chapters = RecordingChapter.decode(transcript.chaptersJSON)
        speakers = transcript.decodedSpeakers
        notes = transcript.notesMD.trimmedText
        snippet = transcript.snippet.trimmedText
    }

    /// True when the Mac has produced nothing for this recording — no recap
    /// (or an entirely blank one), no chapters, no notes. Reachable whenever
    /// the recap/notes passes failed or never ran: the audio is saved and the
    /// row exists regardless.
    var hasNoGeneratedContent: Bool {
        guard chapters.isEmpty, notes.isEmpty else { return false }
        switch recap {
        case .absent:
            return true
        case .unreadable:
            return false
        case .present(let recap):
            return recap.summary.isEmpty
                && recap.keyDecisions.isEmpty
                && recap.actionItems.isEmpty
                && recap.openQuestions.isEmpty
        }
    }
}

/// One chapter of the breakdown the Mac's `meeting.chapters` pass produced —
/// a UI-shaped subset of the desktop's `MeetingChapters`: the phone shows the
/// outline and leaves per-chapter action-item conversion (a write) on the Mac.
struct RecordingChapter: Identifiable, Equatable {
    /// Position in the payload — chapters carry no id of their own.
    let id: Int
    let title: String
    let timeRange: String
    let summary: String

    /// Tolerant decode of `chapters_json` (Go's `meeting.ChaptersResult`):
    /// missing keys default, and a malformed payload yields no chapters —
    /// bad JSON must never hide the rest of the recording.
    static func decode(_ json: String) -> [RecordingChapter] {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return []
        }
        return payload.chapters.enumerated().map { idx, chapter in
            let title = chapter.title.trimmedText
            return RecordingChapter(
                id: idx,
                title: title.isEmpty ? "Chapter \(idx + 1)" : title,
                timeRange: "\(RecordingFormatting.timecode(chapter.startSec))"
                    + " – \(RecordingFormatting.timecode(chapter.endSec))",
                summary: chapter.summary.trimmedText
            )
        }
    }

    private struct Payload: Decodable {
        let chapters: [Chapter]

        enum CodingKeys: String, CodingKey {
            case chapters
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            chapters = try values.decodeIfPresent([Chapter].self, forKey: .chapters) ?? []
        }

        struct Chapter: Decodable {
            let title: String
            let startSec: Double
            let endSec: Double
            let summary: String

            enum CodingKeys: String, CodingKey {
                case title
                case startSec = "start_sec"
                case endSec = "end_sec"
                case summary
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
                startSec = try values.decodeIfPresent(Double.self, forKey: .startSec) ?? 0
                endSec = try values.decodeIfPresent(Double.self, forKey: .endSec) ?? 0
                summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
            }
        }
    }
}

// MARK: - Formatting

/// Display formatting for a recording, kept identical to the desktop's
/// `TranscriptFormatting` so the same meeting reads the same on both screens.
enum RecordingFormatting {
    /// Locale-formatted date + time, or the raw stored value when it cannot be
    /// parsed (never swallow a value we failed to read); "" stays "".
    static func date(_ iso: String) -> String {
        guard let date = parse(iso) else { return iso }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func duration(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let minutes = total / 60
        let secs = total % 60
        return minutes > 0 ? "\(minutes)m \(secs)s" : "\(secs)s"
    }

    /// `m:ss` (or `h:mm:ss` past an hour) chapter timecode.
    static func timecode(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Both ISO shapes the DB carries (Go writes second precision; some rows
    /// carry fractional seconds) — the `Situation.parseDate` precedent.
    private static func parse(_ raw: String) -> Date? {
        if let date = isoWithFractional.date(from: raw) { return date }
        return isoStandard.date(from: raw)
    }

    private static let isoWithFractional: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    private static let isoStandard: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()
}

fileprivate extension String {
    var trimmedText: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - List

/// Pushed inside Today's navigation stack — deliberately no `NavigationStack`
/// of its own (nesting one inside the pushed view breaks the back stack).
struct RecordingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = RecordingsViewModel()

    var body: some View {
        List {
            Section("On this phone") {
                RecordButtonView(recorder: env.phoneRecorder)
                ForEach(model.phoneRows) { row in
                    PhoneRecordingRowView(row: row)
                }
            }
            Section("Transcripts") {
                if model.rows.isEmpty {
                    ContentUnavailableView(
                        "No recordings",
                        systemImage: "waveform.slash",
                        description: Text("Meetings you record on your Mac — and transcripts of phone recordings — show up here.")
                    )
                }
                ForEach(model.rows) { row in
                    NavigationLink {
                        RecordingDetailView(recordingID: row.id, model: model)
                    } label: {
                        RecordingRowView(row: row)
                    }
                }
            }
        }
        .navigationTitle("Recordings")
        .onAppear { model.start(store: env.store) }
    }
}

// MARK: - Phone capture

/// The voice-memo-style Record toggle (owner default: this tab only, no
/// Today quick action). Elapsed time ticks while recording; a denied mic
/// permission or a start failure reads inline instead of failing silently.
struct RecordButtonView: View {
    let recorder: PhoneRecorderController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await recorder.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.title2)
                        .foregroundStyle(.red)
                    if case .recording(let startedAt) = recorder.state {
                        Text("Recording")
                            .font(.subheadline.weight(.semibold))
                        ElapsedLabel(since: startedAt)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Record")
                            .font(.subheadline.weight(.semibold))
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            if case .denied = recorder.state {
                Text("Microphone access is off. Enable it in Settings → Privacy → Microphone.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = recorder.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Elapsed-time ticker for the active capture.
private struct ElapsedLabel: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            Text(RecordingFormatting.duration(seconds))
        }
    }
}

/// One local capture with its upload state: recorded (waiting) → uploading →
/// sent to Mac (delivered) / failed (+ retry). Delivered rows disappear into
/// the Transcripts section once the Mac finishes transcribing.
struct PhoneRecordingRowView: View {
    @Environment(AppEnvironment.self) private var env
    let row: PhoneRecording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "iphone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(row.titleHint ?? "Phone recording")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(RecordingFormatting.duration(row.durationSec))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                stateBadge
            }
            if row.state == .failed, let message = row.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { try? await env.recordingUploader.discard(id: row.id) }
            } label: {
                Label("Remove", systemImage: "trash")
            }
            if row.state == .failed {
                Button {
                    Task { try? await env.recordingUploader.retryFailed(id: row.id) }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    @ViewBuilder private var stateBadge: some View {
        switch row.state {
        case .waiting:
            Badge(text: "waiting to upload", color: .gray)
        case .uploading:
            Badge(text: "uploading", color: .blue)
        case .delivered:
            Badge(text: "sent to Mac", color: .green)
        case .failed:
            Badge(text: "failed", color: .red)
        }
    }
}

struct RecordingRowView: View {
    let row: RecordingRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: row.isAdHoc ? "waveform" : "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(row.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
            if let eventTitle = row.eventTitle {
                Text(eventTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(row.metaLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if row.hasRecap {
                    Badge(text: "recap", color: .purple)
                }
                if row.hasNotes {
                    Badge(text: "notes", color: .gray)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

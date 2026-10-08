import Foundation
import GRDB
import Observation
import os
import WatchtowerKit
import WatchtowerSync

// MARK: - Transcript body

/// The transcript text as the phone holds it: the `segments.json` asset of
/// the `meeting_transcript` record (spec §4.11). A missing or unreadable
/// asset is said so on screen, never drawn as an empty transcript.
enum TranscriptBody: Equatable {
    case segments([TranscriptSegment])
    /// The record carries no asset (yet).
    case notArrived
    case unreadable(String)

    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "TranscriptBody")

    static func load(asset: SliceAsset?) -> Self {
        switch asset {
        case nil:
            return .notArrived
        case let .unreadable(reason):
            return .unreadable(reason)
        case let .data(data):
            do {
                return .segments(try TranscriptSegment.decodeAsset(data))
            } catch {
                logger.error("segments.json undecodable: \(error.localizedDescription, privacy: .public)")
                return .unreadable(error.localizedDescription)
            }
        }
    }
}

/// Reads one transcript's body and its phone recording's marks.
enum RecapLoader {
    struct Loaded: Equatable {
        let body: TranscriptBody
        /// Whole-second offsets of the phone's mark-moment taps; empty for a
        /// recording made on the Mac.
        let marks: [Int]
    }

    static func load(
        transcript: MeetingTranscript,
        recordings: PhoneRecordingsSnapshot,
        store: ReplicaStore
    ) async throws -> Loaded {
        let phoneID = recordings.phoneRecordingID(forTranscript: transcript)
        let recordName = transcript.recordName
        return try await store.reader.read { db in
            try read(recordName: recordName, phoneRecordingID: phoneID, store: store, from: db)
        }
    }

    /// Reads from an ALREADY-OPEN database, so it runs inside a
    /// ValueObservation tracking closure.
    static func read(recordName: String, phoneRecordingID: String?, store: ReplicaStore, from db: Database) throws -> Loaded {
        let body = TranscriptBody.load(asset: try store.sliceAsset(forRecordName: recordName, from: db))
        let marks = try phoneRecordingID.map { try store.phoneRecordingMarks(id: $0, from: db) } ?? []
        return Loaded(body: body, marks: marks)
    }
}

/// The open recap's body and marks, observed: a republished record (new
/// segments under the same `updated_at`) or a new mark re-reads them.
@MainActor
@Observable
final class RecapBodyModel {
    private(set) var loaded: RecapLoader.Loaded?
    @ObservationIgnored private var cancellable: AnyDatabaseCancellable?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "RecapBodyModel")

    func observe(transcript: MeetingTranscript, phoneRecordingID: String?, store: ReplicaStore) {
        cancellable?.cancel()
        loaded = nil
        let recordName = transcript.recordName
        let observation = ValueObservation.tracking { db in
            try RecapLoader.read(recordName: recordName, phoneRecordingID: phoneRecordingID, store: store, from: db)
        }
        cancellable = observation.start(
            in: store.reader,
            scheduling: .async(onQueue: .main),
            onError: { [weak self] error in
                Self.logger.error("recap observation failed: \(error.localizedDescription, privacy: .public)")
                MainActor.assumeIsolated {
                    self?.loaded = RecapLoader.Loaded(body: .unreadable(error.localizedDescription), marks: [])
                }
            },
            onChange: { [weak self] value in
                MainActor.assumeIsolated { self?.loaded = value }
            }
        )
    }
}

// MARK: - Recap screen model

/// One recap list: action items, decisions or open questions.
struct RecapSection: Identifiable, Equatable {
    let title: String
    let items: [String]
    /// "3 more on your Mac" when the hub dropped entries.
    let moreText: String?
    var id: String { title }
}

/// One transcript block.
struct TranscriptLine: Identifiable, Equatable {
    /// The segment's index: the scroll target of a jump point.
    let id: Int
    /// nil when the recording was not diarized (and for a legacy block).
    let speaker: String?
    let speakerTone: PhoneTone
    /// "2:05".
    let time: String
    let text: String
}

/// A mark-moment tap, shown as a jump point into the transcript.
struct JumpPoint: Identifiable, Equatable {
    let offsetSec: Int
    /// "2:05".
    let label: String
    let accessibilityLabel: String
    /// The transcript line the mark falls in; nil without a transcript.
    let lineID: Int?
    var id: Int { offsetSec }
}

/// The recap and transcript of one recording (spec §13 C3): summary, the
/// recap lists that have entries, the speaker transcript and the phone's
/// marks. "Make target" from action items stays hidden until D.
struct RecapModel {
    let title: String
    /// "Today 10:00 · 14:32 · 2 speakers".
    let subtitle: String
    let summary: String?
    let sections: [RecapSection]
    /// Shown when there is neither a summary nor a list.
    let recapEmptyText: String?
    let lines: [TranscriptLine]
    let clippedNotice: String?
    let transcriptError: String?
    /// Segments that decoded to nothing (every one deleted on the Mac).
    let emptyTranscriptText: String?
    let jumpPoints: [JumpPoint]

    static let clippedText = "Transcript shortened — the full text is on the Mac"
    private static let speakerTones: [PhoneTone] = [.blue, .purple, .green, .secondary]

    init(transcript: MeetingTranscript, body: TranscriptBody, marks: [Int], calendar: Calendar, now: Date) {
        title = transcript.title
        let format = RecordingsFormat(calendar: calendar, now: now)
        var parts = [format.duration(transcript.durationSec)]
        if let created = TranscriptDates.parse(transcript.createdAt) {
            parts.insert(format.when(created), at: 0)
        }
        let speakers = transcript.speakers.count + (transcript.speakersMore ?? 0)
        if speakers > 0 {
            parts.append(speakers == 1 ? "1 speaker" : "\(speakers) speakers")
        }
        subtitle = parts.joined(separator: " · ")

        summary = transcript.summary ?? transcript.overview
        sections = [
            Self.section("Action items", transcript.actionItems, more: transcript.actionItemsMore),
            Self.section("Decisions", transcript.keyDecisions, more: transcript.keyDecisionsMore),
            Self.section("Open questions", transcript.openQuestions, more: transcript.openQuestionsMore)
        ].compactMap { $0 }
        recapEmptyText = summary == nil && sections.isEmpty
            ? "No recap yet — your Mac writes it after the transcript"
            : nil

        let segments: [TranscriptSegment]
        switch body {
        case let .segments(list):
            segments = list
            transcriptError = nil
        case .notArrived:
            segments = []
            transcriptError = "The transcript has not reached this phone yet."
        case .unreadable:
            segments = []
            transcriptError = "The transcript could not be read on this phone."
        }
        // Each speaker keeps one colour, in order of first appearance.
        var toneBySpeaker: [String: PhoneTone] = [:]
        var lines: [TranscriptLine] = []
        for (index, segment) in segments.enumerated() {
            let name = segment.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            var tone = PhoneTone.secondary
            if !name.isEmpty {
                tone = toneBySpeaker[name] ?? Self.speakerTones[toneBySpeaker.count % Self.speakerTones.count]
                toneBySpeaker[name] = tone
            }
            lines.append(TranscriptLine(
                id: index,
                speaker: name.isEmpty ? nil : name,
                speakerTone: tone,
                time: RecordingsFormat.offset(Int(segment.startSec)),
                text: segment.text
            ))
        }
        self.lines = lines
        emptyTranscriptText = lines.isEmpty && transcriptError == nil ? "No transcript text" : nil
        clippedNotice = transcript.segmentsClipped == true ? Self.clippedText : nil
        jumpPoints = Set(marks).sorted().map { offset in
            JumpPoint(
                offsetSec: offset,
                label: RecordingsFormat.offset(offset),
                accessibilityLabel: "Jump to the mark at \(RecordingsFormat.spokenOffset(offset))",
                lineID: Self.lineIndex(for: offset, in: segments)
            )
        }
    }

    /// The segment a mark falls in: the last one starting at or before it,
    /// so a mark past the end lands on the last segment and one in a gap
    /// on the segment before the gap.
    static func lineIndex(for offset: Int, in segments: [TranscriptSegment]) -> Int? {
        guard !segments.isEmpty else { return nil }
        return segments.lastIndex { $0.startSec <= Double(offset) } ?? 0
    }

    private static func section(_ title: String, _ items: [String], more: Int?) -> RecapSection? {
        let dropped = more ?? 0
        guard !items.isEmpty || dropped > 0 else { return nil }
        return RecapSection(title: title, items: items, moreText: dropped > 0 ? "\(dropped) more on your Mac" : nil)
    }

    /// Every visible string, for the tests.
    var allStrings: [String] {
        [title, subtitle] + [summary, recapEmptyText, clippedNotice, transcriptError, emptyTranscriptText].compactMap { $0 }
            + sections.flatMap { [$0.title] + $0.items + [$0.moreText].compactMap { $0 } }
            + lines.flatMap { [$0.speaker, $0.time, $0.text].compactMap { $0 } }
            + jumpPoints.map(\.label)
    }
}

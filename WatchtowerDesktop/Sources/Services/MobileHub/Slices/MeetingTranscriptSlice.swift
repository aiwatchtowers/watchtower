import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

/// The `meeting_transcript` slice (mobile POC spec §4.11), record name
/// `meeting_transcript-<meeting_transcripts.id>`: the recap fields in the
/// payload, the transcript body as the record's `segments.json` asset.
///
/// Window: created in the last 30 days, or its event is in the calendar
/// window (`CalendarEventSlice.windowEventIDs`); at most 200, newest first.
/// Recap: `meeting_recaps` joined by `transcript_id` first, then by the
/// transcript's `event_id` (the Recap tab's precedence,
/// `MeetingRecapQueries.fetchForRecording`); otherwise the transcript's own
/// `summary_json` (ad-hoc recordings). Never read, so never published:
/// `audio_path`, `speakers_json` (voice embeddings), `notes_md` and the
/// chapters other than `overall_summary`.
///
/// Wire shape: the Kit mirrors `WatchtowerKit.MeetingTranscript` (payload)
/// and `TranscriptSegment` (asset), RelayCoder JSON; times are the stored
/// ISO8601 strings.
struct MeetingTranscriptSlice: AssetSliceSource {
    let kind = SliceKind.meetingTranscript

    static let maxTranscripts = 200
    static let windowDays = 30
    static let maxRecapEntries = 50
    static let maxRecapEntryLength = 500
    static let maxSpeakers = 20
    /// The `segments.json` cap: 20 MB.
    static let maxAssetBytes = 20 * 1024 * 1024
    static let assetFileName = "segments.json"

    let now: @Sendable () -> Date
    let calendar: @Sendable () -> Calendar
    /// The phone upload a transcript came from (the hub's recording-upload
    /// sidecar map); nil for a recording made on the Mac.
    let phoneRecordingID: @Sendable (_ transcriptID: Int64) -> String?

    init(
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: @escaping @Sendable () -> Calendar = { Calendar.current },
        phoneRecordingID: @escaping @Sendable (_ transcriptID: Int64) -> String? = { _ in nil }
    ) {
        self.now = now
        self.calendar = calendar
        self.phoneRecordingID = phoneRecordingID
    }

    struct Payload: Encodable, Equatable {
        let id: Int64
        let eventID: String?
        let title: String
        let titleClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let durationSec: Int
        let createdAt: String
        let updatedAt: String
        let phoneRecordingID: String?
        let speakers: [String]
        let speakersMore: Int?
        let summary: String?
        let keyDecisions: [String]
        let keyDecisionsMore: Int?
        let actionItems: [String]
        let actionItemsMore: Int?
        let openQuestions: [String]
        let openQuestionsMore: Int?
        let overview: String?
        let overviewClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let segmentsClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean

        enum CodingKeys: String, CodingKey {
            case id
            case eventID = "event_id"
            case title, titleClipped, durationSec, createdAt, updatedAt
            case phoneRecordingID = "phone_recording_id"
            case speakers, speakersMore, summary
            case keyDecisions, keyDecisionsMore, actionItems, actionItemsMore, openQuestions, openQuestionsMore
            case overview, overviewClipped, segmentsClipped
        }
    }

    /// One `segments.json` entry: `{start_sec, end_sec, speaker, text}`.
    struct Segment: Encodable, Equatable {
        let startSec: Double
        let endSec: Double
        let speaker: String
        let text: String
    }

    func assetRecords(_ db: Database) throws -> [AssetSliceRecord] {
        let stamp = now()
        let rows = try Self.windowRows(db, now: stamp, calendar: calendar())
        let recaps = try Self.recaps(db, rows: rows)
        let encoder = RelayCoder.makeEncoder()
        return try rows.map { row in
            let segments = Self.segments(row)
            let asset = try Self.encodeAsset(segments, encoder: encoder)
            let recap = recaps.byTranscript[row.id] ?? row.eventID.flatMap { recaps.byEvent[$0] } ?? row.ownSummary
            let payload = makePayload(row, recap: recap, speakers: Self.speakers(segments), segmentsClipped: asset.clipped)
            return AssetSliceRecord(
                record: SliceRecord(kind: kind, id: String(row.id), modifiedAt: stamp, payload: try encoder.encode(payload)),
                asset: SliceAsset(fileName: Self.assetFileName, data: asset.data)
            )
        }
    }

    // MARK: - Window

    private struct TranscriptRow {
        let id: Int64
        let eventID: String?
        let title: String
        let durationSec: Int
        let transcriptText: String
        let segmentsJSON: String?
        let chaptersJSON: String?
        let createdAt: String
        let updatedAt: String
        /// The decoded `summary_json`; nil when absent or unreadable.
        let ownSummary: MeetingRecap.Content?
    }

    private static func windowRows(_ db: Database, now: Date, calendar: Calendar) throws -> [TranscriptRow] {
        let since = SliceDate.stamp(now.addingTimeInterval(-Double(windowDays) * 86_400))
        let eventIDs = Array(try CalendarEventSlice.windowEventIDs(db, now: now, calendar: calendar))
        let eventClause = eventIDs.isEmpty ? "" : " OR event_id IN (\(placeholders(eventIDs.count)))"
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, event_id, title, duration_sec, transcript_text, summary_json, segments_json, chapters_json,
                   created_at, updated_at
            FROM meeting_transcripts
            WHERE created_at >= ?\(eventClause)
            ORDER BY created_at DESC, id DESC
            LIMIT \(maxTranscripts)
            """, arguments: StatementArguments([since] + eventIDs))
        return rows.map { row in
            let id: Int64 = row["id"]
            return TranscriptRow(
                id: id,
                eventID: row["event_id"],
                title: row["title"],
                durationSec: row["duration_sec"],
                transcriptText: row["transcript_text"],
                segmentsJSON: row["segments_json"],
                chaptersJSON: row["chapters_json"],
                createdAt: row["created_at"],
                updatedAt: row["updated_at"],
                ownSummary: decodeRecap(row["summary_json"], what: "summary_json of transcript \(id)")
            )
        }
    }

    // MARK: - Recap

    private struct Recaps {
        var byTranscript: [Int64: MeetingRecap.Content] = [:]
        var byEvent: [String: MeetingRecap.Content] = [:]
    }

    /// The `meeting_recaps` rows of the window's transcripts, by
    /// `transcript_id` and by `event_id` (the join `r.transcript_id = t.id
    /// OR (r.event_id IS NOT NULL AND r.event_id = t.event_id)`).
    private static func recaps(_ db: Database, rows: [TranscriptRow]) throws -> Recaps {
        guard !rows.isEmpty else { return Recaps() }
        let ids = rows.map(\.id)
        let eventIDs = Array(Set(rows.compactMap(\.eventID)))
        let eventClause = eventIDs.isEmpty ? "" : " OR event_id IN (\(placeholders(eventIDs.count)))"
        var out = Recaps()
        // Newest first; the first row seen per key wins.
        for row in try Row.fetchAll(db, sql: """
            SELECT id, event_id, transcript_id, recap_json FROM meeting_recaps
            WHERE transcript_id IN (\(placeholders(ids.count)))\(eventClause)
            ORDER BY updated_at DESC, id DESC
            """, arguments: StatementArguments(ids) + StatementArguments(eventIDs)) {
            let recapID: Int64 = row["id"]
            guard let content = decodeRecap(row["recap_json"], what: "meeting recap \(recapID)") else { continue }
            if let transcriptID: Int64 = row["transcript_id"], out.byTranscript[transcriptID] == nil {
                out.byTranscript[transcriptID] = content
            }
            if let eventID: String = row["event_id"], out.byEvent[eventID] == nil {
                out.byEvent[eventID] = content
            }
        }
        return out
    }

    /// nil for a NULL or empty column; an unreadable one is logged and left
    /// out.
    private static func decodeRecap(_ json: String?, what: String) -> MeetingRecap.Content? {
        guard let json, !json.isEmpty else { return nil }
        guard let content = try? JSONDecoder().decode(MeetingRecap.Content.self, from: Data(json.utf8)) else {
            logger.warning("unreadable \(what, privacy: .public) left out")
            return nil
        }
        return content
    }

    // MARK: - Segments

    /// The non-deleted segments; a legacy row (no or unreadable
    /// `segments_json`) is one segment holding `transcript_text`.
    private static func segments(_ row: TranscriptRow) -> [Segment] {
        if let utterances = row.segmentsJSON.flatMap(TranscriptSegments.decode) {
            return utterances.filter { !$0.deleted }.map {
                Segment(startSec: $0.startSec, endSec: $0.endSec, speaker: $0.speaker, text: $0.text)
            }
        }
        if row.segmentsJSON != nil {
            logger.warning("unreadable segments_json of transcript \(row.id, privacy: .public); published as one segment")
        }
        guard !row.transcriptText.isEmpty else { return [] }
        return [Segment(startSec: 0, endSec: Double(row.durationSec), speaker: "", text: row.transcriptText)]
    }

    /// Display names in order of first appearance; "" (not diarized) is no
    /// speaker.
    private static func speakers(_ segments: [Segment]) -> [String] {
        var seen: Set<String> = []
        return segments.map(\.speaker).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The asset's JSON array, cut after the last whole segment that fits
    /// `maxAssetBytes`. Assembled element by element: the same bytes as
    /// encoding the array (sorted keys, no whitespace).
    static func encodeAsset(
        _ segments: [Segment],
        encoder: JSONEncoder,
        maxBytes: Int = maxAssetBytes
    ) throws -> (data: Data, clipped: Bool?) { // swiftlint:disable:this discouraged_optional_boolean
        var data = Data("[".utf8)
        var clipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        for (index, segment) in segments.enumerated() {
            let element = try encoder.encode(segment)
            let separator = index == 0 ? 0 : 1
            // +1 for the closing bracket.
            guard data.count + separator + element.count + 1 <= maxBytes else {
                clipped = true
                break
            }
            if separator == 1 { data.append(contentsOf: Array(",".utf8)) }
            data.append(element)
        }
        data.append(contentsOf: Array("]".utf8))
        return (data, clipped)
    }

    // MARK: - Payload

    private func makePayload(
        _ row: TranscriptRow,
        recap: MeetingRecap.Content?,
        speakers: [String],
        segmentsClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    ) -> Payload {
        let title = SliceClip.text(row.title, limit: 300)
        let speakerList = SliceClip.list(speakers, limit: Self.maxSpeakers)
        let decisions = Self.recapList(recap?.keyDecisions)
        let actions = Self.recapList(recap?.actionItems)
        let questions = Self.recapList(recap?.openQuestions)
        let overview = Self.overview(row).map { SliceClip.text($0, limit: 2000) }
        return Payload(
            id: row.id,
            eventID: row.eventID,
            title: title.text, titleClipped: title.clipped,
            durationSec: row.durationSec,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            phoneRecordingID: phoneRecordingID(row.id),
            speakers: speakerList.items, speakersMore: speakerList.more,
            summary: recap?.summary,
            keyDecisions: decisions.items, keyDecisionsMore: decisions.more,
            actionItems: actions.items, actionItemsMore: actions.more,
            openQuestions: questions.items, openQuestionsMore: questions.more,
            overview: overview?.text, overviewClipped: overview?.clipped,
            segmentsClipped: segmentsClipped
        )
    }

    /// At most 50 entries of at most 500.
    private static func recapList(_ entries: [String]?) -> (items: [String], more: Int?) {
        let list = SliceClip.list(entries ?? [], limit: maxRecapEntries)
        return (list.items.map { SliceClip.text($0, limit: maxRecapEntryLength).text }, list.more)
    }

    /// `chapters_json.overall_summary`; nil when absent, empty or
    /// unreadable (logged).
    private static func overview(_ row: TranscriptRow) -> String? {
        guard let json = row.chaptersJSON, !json.isEmpty else { return nil }
        guard let chapters = try? JSONDecoder().decode(MeetingChapters.self, from: Data(json.utf8)) else {
            logger.warning("unreadable chapters_json of transcript \(row.id, privacy: .public); no overview")
            return nil
        }
        return chapters.overallSummary.isEmpty ? nil : chapters.overallSummary
    }

    // MARK: - Helpers

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    private static let logger = Logger(subsystem: Constants.bundleID, category: "MeetingTranscriptSlice")
}

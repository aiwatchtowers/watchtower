import CryptoKit
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

    /// Each transcript's derived record, kept while its fingerprint holds:
    /// an unchanged transcript whose staged file still holds its asset is
    /// neither decoded nor encoded again.
    let cache = BuildCache()

    /// Assets built so far (the test seam for "an unchanged cycle builds
    /// nothing").
    var assetBuilds: Int { cache.builds }

    /// Inside the read: the window, the chosen recaps and each row's
    /// fingerprint (SHA-256 of the raw columns, the chosen recap's id and
    /// `updated_at`, and the phone recording id). Outside it (the returned
    /// build): the asset and payload of every row whose fingerprint changed
    /// or whose staged file no longer holds its asset.
    func assetRecords(
        _ db: Database,
        stagedDigest: @escaping (_ recordName: String, _ fileName: String) -> Data?
    ) throws -> () throws -> [AssetSliceRecord] {
        let stamp = now()
        let window = try Self.window(db, now: stamp, calendar: calendar())
        let recaps = try Self.recaps(db, window: window)
        var planned: [Planned] = []
        for row in try Self.rows(db, ids: window.map(\.id)) {
            let recap = recaps.byTranscript[row.id] ?? row.eventID.flatMap { recaps.byEvent[$0] }
            let phone = phoneRecordingID(row.id)
            let fingerprint = Self.fingerprint(row, recap: recap, phone: phone)
            let name = kind.recordName(id: String(row.id))
            if let hit = cache.entry(row.id), hit.fingerprint == fingerprint,
               stagedDigest(name, Self.assetFileName) == hit.digest {
                planned.append(.ready(AssetSliceRecord(
                    record: SliceRecord(kind: kind, id: String(row.id), modifiedAt: stamp, payload: hit.payload),
                    asset: SliceAsset(fileName: Self.assetFileName, digest: hit.digest, data: nil)
                )))
            } else {
                planned.append(.build(row, recap: recap?.content, phone: phone, fingerprint: fingerprint))
            }
        }
        let ids = Set(window.map(\.id))
        return { [self] in
            let records = try planned.map { try build($0, stamp: stamp) }
            cache.prune(keeping: ids)
            return records
        }
    }

    private enum Planned {
        case ready(AssetSliceRecord)
        case build(TranscriptRow, recap: MeetingRecap.Content?, phone: String?, fingerprint: Data)
    }

    private func build(_ planned: Planned, stamp: Date) throws -> AssetSliceRecord {
        switch planned {
        case .ready(let record):
            return record
        case let .build(row, recap, phone, fingerprint):
            let encoder = RelayCoder.makeEncoder()
            let segments = Self.segments(row)
            let asset = try Self.encodeAsset(segments, encoder: encoder)
            let ownSummary = Self.decodeRecap(row.summaryJSON, what: "summary_json of transcript \(row.id)")
            let payload = try encoder.encode(makePayload(
                row, recap: recap ?? ownSummary, phone: phone, speakers: Self.speakers(segments), segmentsClipped: asset.clipped
            ))
            let digest = SliceAsset.digest(of: asset.data)
            cache.store(row.id, BuildCache.Entry(fingerprint: fingerprint, payload: payload, digest: digest))
            return AssetSliceRecord(
                record: SliceRecord(kind: kind, id: String(row.id), modifiedAt: stamp, payload: payload),
                asset: SliceAsset(fileName: Self.assetFileName, digest: digest, data: asset.data)
            )
        }
    }

    /// `@unchecked Sendable`: every field is guarded by `lock`.
    final class BuildCache: @unchecked Sendable {
        struct Entry {
            let fingerprint: Data
            let payload: Data
            let digest: Data
        }

        private let lock = NSLock()
        private var entries: [Int64: Entry] = [:]
        private var buildCount = 0

        var builds: Int { lock.withLock { buildCount } }

        func entry(_ id: Int64) -> Entry? {
            lock.withLock { entries[id] }
        }

        func store(_ id: Int64, _ entry: Entry) {
            lock.withLock {
                entries[id] = entry
                buildCount += 1
            }
        }

        /// Forgets transcripts that left the window.
        func prune(keeping ids: Set<Int64>) {
            lock.withLock { entries = entries.filter { ids.contains($0.key) } }
        }
    }

    // MARK: - Window

    private struct TranscriptRow {
        let id: Int64
        let eventID: String?
        let title: String
        let durationSec: Int
        let segmentsJSON: String?
        /// `transcript_text`, read only when `segments_json` is NULL or not
        /// valid JSON (the legacy fallback).
        let legacyText: String?
        let summaryJSON: String?
        let chaptersJSON: String?
        let createdAt: String
        let updatedAt: String
    }

    /// The window's transcripts, newest first: id and event id only.
    private static func window(_ db: Database, now: Date, calendar: Calendar) throws -> [(id: Int64, eventID: String?)] {
        let since = SliceDate.stamp(now.addingTimeInterval(-Double(windowDays) * 86_400))
        let eventIDs = Array(try CalendarEventSlice.windowEventIDs(db, now: now, calendar: calendar))
        let eventClause = eventIDs.isEmpty ? "" : " OR event_id IN (\(placeholders(eventIDs.count)))"
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, event_id FROM meeting_transcripts
            WHERE created_at >= ?\(eventClause)
            ORDER BY created_at DESC, id DESC
            LIMIT \(maxTranscripts)
            """, arguments: StatementArguments([since] + eventIDs))
        return rows.map { (id: $0["id"], eventID: $0["event_id"]) }
    }

    /// The columns the projection reads, in the window's order.
    private static func rows(_ db: Database, ids: [Int64]) throws -> [TranscriptRow] {
        guard !ids.isEmpty else { return [] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, event_id, title, duration_sec, segments_json, summary_json, chapters_json, created_at, updated_at,
                   CASE WHEN segments_json IS NULL OR NOT json_valid(segments_json) THEN transcript_text END AS legacy_text
            FROM meeting_transcripts
            WHERE id IN (\(placeholders(ids.count)))
            ORDER BY created_at DESC, id DESC
            """, arguments: StatementArguments(ids))
        return rows.map { row in
            TranscriptRow(
                id: row["id"],
                eventID: row["event_id"],
                title: row["title"],
                durationSec: row["duration_sec"],
                segmentsJSON: row["segments_json"],
                legacyText: row["legacy_text"],
                summaryJSON: row["summary_json"],
                chaptersJSON: row["chapters_json"],
                createdAt: row["created_at"],
                updatedAt: row["updated_at"]
            )
        }
    }

    /// SHA-256 over everything the record is derived from; each field is
    /// tagged (nil vs present) and length-prefixed, so no two inputs collide.
    private static func fingerprint(_ row: TranscriptRow, recap: ChosenRecap?, phone: String?) -> Data {
        var hasher = SHA256()
        let fields: [String?] = [
            String(row.id), row.eventID, row.title, String(row.durationSec), row.createdAt, row.updatedAt,
            row.segmentsJSON, row.legacyText, row.summaryJSON, row.chaptersJSON,
            recap.map { String($0.id) }, recap?.updatedAt, phone
        ]
        for field in fields {
            guard let field else {
                hasher.update(data: Data([0]))
                continue
            }
            let bytes = Data(field.utf8)
            let length = withUnsafeBytes(of: UInt64(bytes.count).littleEndian) { Data($0) }
            hasher.update(data: Data([1]) + length)
            hasher.update(data: bytes)
        }
        return Data(hasher.finalize())
    }

    // MARK: - Recap

    private struct ChosenRecap {
        let id: Int64
        let updatedAt: String
        let content: MeetingRecap.Content
    }

    private struct Recaps {
        var byTranscript: [Int64: ChosenRecap] = [:]
        var byEvent: [String: ChosenRecap] = [:]
    }

    /// The readable `meeting_recaps` rows of the window's transcripts, by
    /// `transcript_id` and by `event_id` (the join `r.transcript_id = t.id
    /// OR (r.event_id IS NOT NULL AND r.event_id = t.event_id)`).
    private static func recaps(_ db: Database, window: [(id: Int64, eventID: String?)]) throws -> Recaps {
        guard !window.isEmpty else { return Recaps() }
        let ids = window.map(\.id)
        let eventIDs = Array(Set(window.compactMap(\.eventID)))
        let eventClause = eventIDs.isEmpty ? "" : " OR event_id IN (\(placeholders(eventIDs.count)))"
        var out = Recaps()
        // Newest first; the first readable row seen per key wins.
        for row in try Row.fetchAll(db, sql: """
            SELECT id, event_id, transcript_id, recap_json, updated_at FROM meeting_recaps
            WHERE transcript_id IN (\(placeholders(ids.count)))\(eventClause)
            ORDER BY updated_at DESC, id DESC
            """, arguments: StatementArguments(ids) + StatementArguments(eventIDs)) {
            let recapID: Int64 = row["id"]
            guard let content = decodeRecap(row["recap_json"], what: "meeting recap \(recapID)") else { continue }
            let chosen = ChosenRecap(id: recapID, updatedAt: row["updated_at"], content: content)
            if let transcriptID: Int64 = row["transcript_id"], out.byTranscript[transcriptID] == nil {
                out.byTranscript[transcriptID] = chosen
            }
            if let eventID: String = row["event_id"], out.byEvent[eventID] == nil {
                out.byEvent[eventID] = chosen
            }
        }
        return out
    }

    /// nil for a NULL or empty column; an unreadable one is logged once and
    /// left out.
    private static func decodeRecap(_ json: String?, what: String) -> MeetingRecap.Content? {
        guard let json, !json.isEmpty else { return nil }
        guard let content = try? JSONDecoder().decode(MeetingRecap.Content.self, from: Data(json.utf8)) else {
            if warned.withLock({ $0.insert(what).inserted }) {
                logger.warning("unreadable \(what, privacy: .public) left out")
            }
            return nil
        }
        return content
    }

    private static let warned = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    // MARK: - Segments

    /// The non-deleted segments; a legacy row (no or unreadable
    /// `segments_json`) is one segment holding `transcript_text`. Valid JSON
    /// of another shape has no text to fall back on and publishes `[]`.
    private static func segments(_ row: TranscriptRow) -> [Segment] {
        if let utterances = row.segmentsJSON.flatMap(TranscriptSegments.decode) {
            return utterances.filter { !$0.deleted }.map {
                Segment(startSec: $0.startSec, endSec: $0.endSec, speaker: $0.speaker, text: $0.text)
            }
        }
        // Logged per build, i.e. once per change of the row.
        if let raw = row.segmentsJSON, raw != "[]" {
            logger.warning("unreadable segments_json of transcript \(row.id, privacy: .public); published from the flat text")
        }
        guard let text = row.legacyText, !text.isEmpty else { return [] }
        return [Segment(startSec: 0, endSec: Double(row.durationSec), speaker: "", text: text)]
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
        phone: String?,
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
            phoneRecordingID: phone,
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

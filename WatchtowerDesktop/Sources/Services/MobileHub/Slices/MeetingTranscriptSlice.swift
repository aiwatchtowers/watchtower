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

    /// Rows whose big columns were read and hashed so far (the test seam for
    /// "an unchanged cycle reads only the light key").
    var fullReads: Int { cache.fullReads }

    /// `recap_json` columns read so far (the test seam for "an unchanged
    /// cycle reads no recap").
    var recapReads: Int { cache.recapReads }

    /// A row whose `updated_at` is this recent may still change within the
    /// same stored second (the column has whole seconds), so its light key
    /// is not trusted: it takes the full read until it is older.
    static let settleTime: TimeInterval = 2

    /// Inside the read: the window, each row's candidate recaps (id and
    /// `updated_at` only) and its light key (`lightKey`: the small columns,
    /// the big columns' lengths, the candidate recaps and the phone
    /// recording id). A row whose light key matches the cached one (and
    /// settled), with its staged file intact, reuses the cached record
    /// without reading its big columns. Every other row is read in full and
    /// fingerprinted (SHA-256 of the raw columns): a matching fingerprint
    /// still reuses the record. The `recap_json` of the rows left to build
    /// is read last. Outside the read (the returned build): the recap
    /// decode, the asset and the payload of every row whose fingerprint
    /// changed or whose staged file no longer holds its asset.
    func assetRecords(
        _ db: Database,
        stagedDigest: @escaping (_ recordName: String, _ fileName: String) -> Data?
    ) throws -> () throws -> [AssetSliceRecord] {
        let stamp = now()
        let window = try Self.window(db, now: stamp, calendar: calendar())
        let recaps = try Self.recaps(db, window: window)
        var planned: [Int64: Planned] = [:]
        var unread: [Int64] = []
        for key in try Self.lightKeys(db, ids: window.map(\.id)) {
            let phone = phoneRecordingID(key.id)
            let light = Self.lightFingerprint(key, recaps: recaps.candidates(key.id, eventID: key.eventID), phone: phone)
            let settled = SliceDate.parse(key.updatedAt).map { stamp.timeIntervalSince($0) >= Self.settleTime } ?? false
            if let hit = cache.entry(key.id), settled, hit.light == light,
               let ready = reuse(hit, id: key.id, stamp: stamp, stagedDigest: stagedDigest) {
                planned[key.id] = .ready(ready)
            } else {
                unread.append(key.id)
            }
        }
        cache.countFullReads(unread.count)
        var builds: [Build] = []
        for row in try Self.rows(db, ids: unread) {
            let candidates = recaps.candidates(row.id, eventID: row.eventID)
            let phone = phoneRecordingID(row.id)
            let fingerprint = Self.fingerprint(row, recaps: candidates, phone: phone)
            // A row still settling keeps no light key: the next cycle reads
            // it in full again.
            let settled = SliceDate.parse(row.updatedAt).map { stamp.timeIntervalSince($0) >= Self.settleTime } ?? false
            let light = settled ? Self.lightFingerprint(LightKey(row), recaps: candidates, phone: phone) : nil
            if let hit = cache.entry(row.id), hit.fingerprint == fingerprint,
               let ready = reuse(hit, id: row.id, stamp: stamp, stagedDigest: stagedDigest) {
                cache.setLight(light, for: row.id)
                planned[row.id] = .ready(ready)
            } else {
                builds.append(Build(row: row, recaps: candidates, phone: phone, fingerprint: fingerprint, light: light))
            }
        }
        let recapJSON = try Self.recapJSON(db, ids: Set(builds.flatMap { $0.recaps.map(\.id) }))
        cache.countRecapReads(recapJSON.count)
        for var job in builds {
            job.recapJSON = job.recaps.compactMap { ref in recapJSON[ref.id].map { (id: ref.id, json: $0) } }
            planned[job.row.id] = .build(job)
        }
        let ordered = window.compactMap { planned[$0.id] }
        let ids = Set(window.map(\.id))
        return { [self] in
            let records = try ordered.map { try build($0, stamp: stamp) }
            cache.prune(keeping: ids)
            return records
        }
    }

    /// The cached record when its staged file still holds its asset.
    private func reuse(
        _ hit: BuildCache.Entry,
        id: Int64,
        stamp: Date,
        stagedDigest: (_ recordName: String, _ fileName: String) -> Data?
    ) -> AssetSliceRecord? {
        guard stagedDigest(kind.recordName(id: String(id)), Self.assetFileName) == hit.digest else { return nil }
        return AssetSliceRecord(
            record: SliceRecord(kind: kind, id: String(id), modifiedAt: stamp, payload: hit.payload),
            asset: SliceAsset(fileName: Self.assetFileName, digest: hit.digest, data: nil)
        )
    }

    private enum Planned {
        case ready(AssetSliceRecord)
        case build(Build)
    }

    /// A row to decode and encode in the build.
    private struct Build {
        let row: TranscriptRow
        /// The candidate recaps, in precedence order.
        let recaps: [RecapRef]
        /// Their `recap_json`, same order (read after the light pass).
        var recapJSON: [(id: Int64, json: String)] = []
        let phone: String?
        let fingerprint: Data
        /// The row's light key, nil while it settles.
        let light: Data?
    }

    private func build(_ planned: Planned, stamp: Date) throws -> AssetSliceRecord {
        switch planned {
        case .ready(let record):
            return record
        case .build(let job):
            let row = job.row
            let encoder = RelayCoder.makeEncoder()
            let segments = Self.segments(row)
            let asset = try Self.encodeAsset(segments, encoder: encoder)
            // The first readable candidate wins, else the transcript's own summary.
            let recap = job.recapJSON.lazy.compactMap { Self.decodeRecap($0.json, what: "meeting recap \($0.id)") }.first
                ?? Self.decodeRecap(row.summaryJSON, what: "summary_json of transcript \(row.id)")
            let payload = try encoder.encode(makePayload(
                row, recap: recap, phone: job.phone, speakers: Self.speakers(segments), segmentsClipped: asset.clipped
            ))
            let digest = SliceAsset.digest(of: asset.data)
            cache.store(row.id, BuildCache.Entry(fingerprint: job.fingerprint, light: job.light, payload: payload, digest: digest))
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
            /// The row's light key when it had settled; nil: read it in full.
            var light: Data?
            let payload: Data
            let digest: Data
        }

        private let lock = NSLock()
        private var entries: [Int64: Entry] = [:]
        private var buildCount = 0
        private var fullReadCount = 0
        private var recapReadCount = 0

        var builds: Int { lock.withLock { buildCount } }
        var fullReads: Int { lock.withLock { fullReadCount } }
        var recapReads: Int { lock.withLock { recapReadCount } }

        func entry(_ id: Int64) -> Entry? {
            lock.withLock { entries[id] }
        }

        func setLight(_ light: Data?, for id: Int64) {
            lock.withLock { entries[id]?.light = light }
        }

        func countFullReads(_ count: Int) {
            lock.withLock { fullReadCount += count }
        }

        func countRecapReads(_ count: Int) {
            lock.withLock { recapReadCount += count }
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
        /// The big columns' lengths, as `lightKeys` reads them.
        let lengths: [Int?]
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

    /// What the light key covers: every column the record is derived from,
    /// the big ones by their length only. A writer that changes a big
    /// column bumps `updated_at` (Go's `SetMeetingTranscript*` and the
    /// Desktop's `MeetingTranscriptQueries`), and a same-second rewrite of
    /// the same length is caught by `settleTime`.
    private struct LightKey {
        let id: Int64
        let eventID: String?
        let title: String
        let durationSec: Int
        let createdAt: String
        let updatedAt: String
        let lengths: [Int?]

        init(id: Int64, eventID: String?, title: String, durationSec: Int, createdAt: String, updatedAt: String, lengths: [Int?]) {
            self.id = id
            self.eventID = eventID
            self.title = title
            self.durationSec = durationSec
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.lengths = lengths
        }

        /// The same key from a full row.
        init(_ row: TranscriptRow) {
            self.init(
                id: row.id, eventID: row.eventID, title: row.title, durationSec: row.durationSec,
                createdAt: row.createdAt, updatedAt: row.updatedAt, lengths: row.lengths
            )
        }
    }

    /// The big columns' byte lengths, in `LightKey.lengths`' order.
    /// `octet_length` (SQLite 3.43+) reads a text's size from its record
    /// header without loading the text itself; NULL stays NULL.
    private static let lengthColumns = """
        octet_length(segments_json) AS segments_length, octet_length(transcript_text) AS text_length,
        octet_length(summary_json) AS summary_length, octet_length(chapters_json) AS chapters_length
        """

    private static func lengths(_ row: Row) -> [Int?] {
        [row["segments_length"], row["text_length"], row["summary_length"], row["chapters_length"]]
    }

    /// The window rows' light keys: no big column leaves SQLite.
    private static func lightKeys(_ db: Database, ids: [Int64]) throws -> [LightKey] {
        guard !ids.isEmpty else { return [] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, event_id, title, duration_sec, created_at, updated_at, \(lengthColumns)
            FROM meeting_transcripts
            WHERE id IN (\(placeholders(ids.count)))
            """, arguments: StatementArguments(ids))
        return rows.map { row in
            LightKey(
                id: row["id"], eventID: row["event_id"], title: row["title"], durationSec: row["duration_sec"],
                createdAt: row["created_at"], updatedAt: row["updated_at"], lengths: lengths(row)
            )
        }
    }

    private static func lightFingerprint(_ key: LightKey, recaps: [RecapRef], phone: String?) -> Data {
        digest([
            String(key.id), key.eventID, key.title, String(key.durationSec), key.createdAt, key.updatedAt
        ] + key.lengths.map { $0.map(String.init) } + recapFields(recaps) + [phone])
    }

    /// The candidate recaps as fingerprint fields: their count, then each
    /// one's id and `updated_at`. Any candidate's change (not only the
    /// chosen one's: which one is readable is known only once decoded)
    /// rebuilds the row.
    private static func recapFields(_ recaps: [RecapRef]) -> [String?] {
        [String(recaps.count)] + recaps.flatMap { [String($0.id), $0.updatedAt] }
    }

    /// The columns the projection reads, in the window's order.
    private static func rows(_ db: Database, ids: [Int64]) throws -> [TranscriptRow] {
        guard !ids.isEmpty else { return [] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, event_id, title, duration_sec, segments_json, summary_json, chapters_json, created_at, updated_at,
                   CASE WHEN segments_json IS NULL OR NOT json_valid(segments_json) THEN transcript_text END AS legacy_text,
                   \(lengthColumns)
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
                lengths: lengths(row),
                summaryJSON: row["summary_json"],
                chaptersJSON: row["chapters_json"],
                createdAt: row["created_at"],
                updatedAt: row["updated_at"]
            )
        }
    }

    /// SHA-256 over everything the record is derived from; each field is
    /// tagged (nil vs present) and length-prefixed, so no two inputs collide.
    private static func fingerprint(_ row: TranscriptRow, recaps: [RecapRef], phone: String?) -> Data {
        digest([
            String(row.id), row.eventID, row.title, String(row.durationSec), row.createdAt, row.updatedAt,
            row.segmentsJSON, row.legacyText, row.summaryJSON, row.chaptersJSON
        ] + recapFields(recaps) + [phone])
    }

    /// SHA-256 over `fields`, each tagged (nil vs present) and
    /// length-prefixed.
    private static func digest(_ fields: [String?]) -> Data {
        var hasher = SHA256()
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

    /// A recap row without its content: the light pass reads no
    /// `recap_json`.
    private struct RecapRef {
        let id: Int64
        let updatedAt: String
    }

    private struct Recaps {
        /// Newest first.
        var byTranscript: [Int64: [RecapRef]] = [:]
        var byEvent: [String: [RecapRef]] = [:]

        /// A transcript's recaps in precedence order: its own (by
        /// `transcript_id`) first, then its event's; the first readable one
        /// wins (decoded in the build).
        func candidates(_ id: Int64, eventID: String?) -> [RecapRef] {
            (byTranscript[id] ?? []) + (eventID.flatMap { byEvent[$0] } ?? [])
        }
    }

    /// The non-empty `meeting_recaps` rows of the window's transcripts (id
    /// and `updated_at` only), by `transcript_id` and by `event_id` (the
    /// join `r.transcript_id = t.id OR (r.event_id IS NOT NULL AND
    /// r.event_id = t.event_id)`).
    private static func recaps(_ db: Database, window: [(id: Int64, eventID: String?)]) throws -> Recaps {
        guard !window.isEmpty else { return Recaps() }
        let ids = window.map(\.id)
        let eventIDs = Array(Set(window.compactMap(\.eventID)))
        let eventClause = eventIDs.isEmpty ? "" : " OR event_id IN (\(placeholders(eventIDs.count)))"
        var out = Recaps()
        for row in try Row.fetchAll(db, sql: """
            SELECT id, event_id, transcript_id, updated_at FROM meeting_recaps
            WHERE (transcript_id IN (\(placeholders(ids.count)))\(eventClause))
              AND recap_json IS NOT NULL AND recap_json != ''
            ORDER BY updated_at DESC, id DESC
            """, arguments: StatementArguments(ids) + StatementArguments(eventIDs)) {
            let ref = RecapRef(id: row["id"], updatedAt: row["updated_at"])
            if let transcriptID: Int64 = row["transcript_id"] { out.byTranscript[transcriptID, default: []].append(ref) }
            if let eventID: String = row["event_id"] { out.byEvent[eventID, default: []].append(ref) }
        }
        return out
    }

    /// `recap_json` by recap id, for the rows the build decodes.
    private static func recapJSON(_ db: Database, ids: Set<Int64>) throws -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        var out: [Int64: String] = [:]
        for row in try Row.fetchAll(
            db, sql: "SELECT id, recap_json FROM meeting_recaps WHERE id IN (\(placeholders(ids.count)))",
            arguments: StatementArguments(Array(ids))
        ) {
            if let json: String = row["recap_json"] { out[row["id"]] = json }
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

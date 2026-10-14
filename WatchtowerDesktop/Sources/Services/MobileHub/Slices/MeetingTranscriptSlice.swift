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

    static let logger = Logger(subsystem: Constants.bundleID, category: "MeetingTranscriptSlice")
}

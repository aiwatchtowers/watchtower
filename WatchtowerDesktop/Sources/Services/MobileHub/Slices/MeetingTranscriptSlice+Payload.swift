import Foundation
import os
import WatchtowerCore
import WatchtowerSync

extension MeetingTranscriptSlice {
    // MARK: - Build

    enum Planned {
        case ready(AssetSliceRecord)
        case build(Build)
    }

    /// A row to decode and encode in the build.
    struct Build {
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

    func build(_ planned: Planned, stamp: Date) throws -> AssetSliceRecord {
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

    // MARK: - Segments

    /// The non-deleted segments; a legacy row (no or unreadable
    /// `segments_json`) is one segment holding `transcript_text`. Valid JSON
    /// of another shape has no text to fall back on and publishes `[]`.
    static func segments(_ row: TranscriptRow) -> [Segment] {
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
    static func speakers(_ segments: [Segment]) -> [String] {
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

    func makePayload(
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
    static func recapList(_ entries: [String]?) -> (items: [String], more: Int?) {
        let list = SliceClip.list(entries ?? [], limit: maxRecapEntries)
        return (list.items.map { SliceClip.text($0, limit: maxRecapEntryLength).text }, list.more)
    }

    /// `chapters_json.overall_summary`; nil when absent, empty or
    /// unreadable (logged).
    static func overview(_ row: TranscriptRow) -> String? {
        guard let json = row.chaptersJSON, !json.isEmpty else { return nil }
        guard let chapters = try? JSONDecoder().decode(MeetingChapters.self, from: Data(json.utf8)) else {
            logger.warning("unreadable chapters_json of transcript \(row.id, privacy: .public); no overview")
            return nil
        }
        return chapters.overallSummary.isEmpty ? nil : chapters.overallSummary
    }
}

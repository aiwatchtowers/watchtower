import Foundation
import WatchtowerSync

// MARK: - MeetingTranscript

/// The `meeting_transcript` DataZone slice (mobile POC spec §4.11), record
/// name `meeting_transcript-<meeting_transcripts.id>`: a capped projection
/// with the recap resolved by the hub. The transcript body is not in the
/// payload; it rides as the record's `segments.json` asset
/// (`TranscriptSegment`). Never published: `audio_path`, `speakers_json`
/// (voice embeddings), `notes_md` and chapters other than the overview.
///
/// Wire: snake_case, sorted keys (decoded with `RelayCoder`); timestamps
/// are the stored ISO8601 strings. A nil optional is an absent key:
/// `<field>_clipped` is present only when the hub clipped the field,
/// `<list>_more` only when it dropped entries.
public struct MeetingTranscript: Codable, Identifiable, Equatable, Sendable {
    public let id: Int
    /// nil for an ad-hoc recording: never linked to an event, or its event
    /// was deleted (the column is ON DELETE SET NULL).
    public let eventID: String?
    /// At most 300.
    public let title: String
    public let titleClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    public let durationSec: Int
    /// ISO8601, as stored.
    public let createdAt: String
    /// ISO8601, as stored.
    public let updatedAt: String
    /// The phone upload this transcript came from (the hub's sidecar map);
    /// nil for a recording made on the Mac.
    public let phoneRecordingID: String?
    /// Display names only, at most 20.
    public let speakers: [String]
    public let speakersMore: Int?

    // Recap: `meeting_recaps.recap_json`, else `summary_json` (ad-hoc).
    /// nil while the recording has no recap.
    public let summary: String?
    /// Each recap list: at most 50 entries of at most 500.
    public let keyDecisions: [String]
    public let keyDecisionsMore: Int?
    public let actionItems: [String]
    public let actionItemsMore: Int?
    public let openQuestions: [String]
    public let openQuestionsMore: Int?

    /// `chapters_json.overall_summary`, at most 2000; nil when absent.
    public let overview: String?
    public let overviewClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// True when the `segments.json` asset was clipped to its 20 MB cap.
    public let segmentsClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean

    public var recordName: String { SliceKind.meetingTranscript.recordName(id: String(id)) }

    // convertFromSnakeCase maps "event_id" -> "eventId" (lowercase d), so
    // the id-suffixed keys' stringValues use that form.
    enum CodingKeys: String, CodingKey {
        case id
        case eventID = "eventId"
        case title, titleClipped, durationSec, createdAt, updatedAt
        case phoneRecordingID = "phoneRecordingId"
        case speakers, speakersMore, summary
        case keyDecisions, keyDecisionsMore, actionItems, actionItemsMore, openQuestions, openQuestionsMore
        case overview, overviewClipped, segmentsClipped
    }

    public init(
        id: Int,
        eventID: String? = nil,
        title: String,
        titleClipped: Bool? = nil, // swiftlint:disable:this discouraged_optional_boolean
        durationSec: Int,
        createdAt: String,
        updatedAt: String,
        phoneRecordingID: String? = nil,
        speakers: [String],
        speakersMore: Int? = nil,
        summary: String? = nil,
        keyDecisions: [String],
        keyDecisionsMore: Int? = nil,
        actionItems: [String],
        actionItemsMore: Int? = nil,
        openQuestions: [String],
        openQuestionsMore: Int? = nil,
        overview: String? = nil,
        overviewClipped: Bool? = nil, // swiftlint:disable:this discouraged_optional_boolean
        segmentsClipped: Bool? = nil // swiftlint:disable:this discouraged_optional_boolean
    ) {
        self.id = id
        self.eventID = eventID
        self.title = title
        self.titleClipped = titleClipped
        self.durationSec = durationSec
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.phoneRecordingID = phoneRecordingID
        self.speakers = speakers
        self.speakersMore = speakersMore
        self.summary = summary
        self.keyDecisions = keyDecisions
        self.keyDecisionsMore = keyDecisionsMore
        self.actionItems = actionItems
        self.actionItemsMore = actionItemsMore
        self.openQuestions = openQuestions
        self.openQuestionsMore = openQuestionsMore
        self.overview = overview
        self.overviewClipped = overviewClipped
        self.segmentsClipped = segmentsClipped
    }
}

// MARK: - Segments asset

/// One non-deleted transcript segment in the `segments.json` asset
/// (spec §4.11), which holds `[{start_sec, end_sec, speaker, text}]`. A
/// legacy transcript without segments arrives as one segment.
public struct TranscriptSegment: Codable, Equatable, Sendable {
    public let startSec: Double
    public let endSec: Double
    /// "" when the recording was not diarized.
    public let speaker: String
    public let text: String

    public init(startSec: Double, endSec: Double, speaker: String, text: String) {
        self.startSec = startSec
        self.endSec = endSec
        self.speaker = speaker
        self.text = text
    }

    /// Decodes the asset's bytes; an empty array is an empty transcript.
    public static func decodeAsset(_ data: Data) throws -> [Self] {
        try RelayCoder.makeDecoder().decode([Self].self, from: data)
    }
}

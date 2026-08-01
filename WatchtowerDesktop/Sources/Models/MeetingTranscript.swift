import Foundation
import GRDB

/// A locally-transcribed meeting recording (WhisperKit in the Desktop app).
/// `eventID` is nil for ad-hoc recordings and survives calendar event deletion.
/// `audioPath` is NULLed by the daemon retention phase once the audio file is
/// deleted; the transcript text is kept forever. `summaryJSON` holds the recap
/// for ad-hoc recordings only — event-linked recaps live in `meeting_recaps`.
/// `notesMD` holds user-editable publishable markdown notes. `segmentsJSON`
/// is the per-utterance segment array (nil for legacy rows); when set, the
/// invariant `transcriptText = TranscriptSegments.render(non-deleted)` holds.
/// `speakersJSON` is the per-cluster voice-embedding array keyed by rendered
/// speaker label (nil when the diarizer produced no embeddings).
/// `chaptersJSON` is the AI chapter breakdown (nil until generated).
struct MeetingTranscript: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meeting_transcripts"

    var id: Int64?
    let eventID: String?
    let title: String
    let audioPath: String?
    let durationSec: Int
    let langStats: String
    let transcriptText: String
    let summaryJSON: String?
    let notesMD: String?
    let segmentsJSON: String?
    let speakersJSON: String?
    let chaptersJSON: String?
    let createdAt: String
    let updatedAt: String

    /// Decodes `summaryJSON` (snake_case keys, same shape as a meeting recap).
    var parsedSummary: MeetingRecap.Content? {
        guard let json = summaryJSON, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MeetingRecap.Content.self, from: data)
    }

    /// Decodes `segmentsJSON` into utterances; nil for legacy rows or a
    /// malformed payload (the UI then falls back to the flat text). Decode
    /// once per detail load — never in row builders.
    var utterances: [TranscriptUtterance]? {
        guard let segmentsJSON else { return nil }
        return TranscriptSegments.decode(segmentsJSON)
    }

    /// Decodes `speakersJSON` into per-cluster voice embeddings; nil for
    /// legacy/embedding-less rows or a malformed payload (renames then update
    /// the transcript only).
    var speakerEmbeddings: [SpeakerEmbedding]? {
        guard let speakersJSON else { return nil }
        return SpeakerEmbeddings.decode(speakersJSON)
    }

    /// Decodes `chaptersJSON`; nil until generated or for a malformed payload
    /// (the UI then falls back to the flat recap). Decode once per detail
    /// load — never in row builders.
    var parsedChapters: MeetingChapters? {
        guard let chaptersJSON else { return nil }
        return MeetingChapters.decode(chaptersJSON)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case eventID = "event_id"
        case title
        case audioPath = "audio_path"
        case durationSec = "duration_sec"
        case langStats = "lang_stats"
        case transcriptText = "transcript_text"
        case summaryJSON = "summary_json"
        case notesMD = "notes_md"
        case segmentsJSON = "segments_json"
        case speakersJSON = "speakers_json"
        case chaptersJSON = "chapters_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// Identifiable for SwiftUI list/sheet identity; persisted rows always carry an id.
extension MeetingTranscript: Identifiable {}

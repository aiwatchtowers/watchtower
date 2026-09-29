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
/// `speakerNamesChangedAt` is stamped by every speaker relabel.
package struct MeetingTranscript: Codable, FetchableRecord, PersistableRecord {
    package static let databaseTableName = "meeting_transcripts"

    package var id: Int64?
    package let eventID: String?
    package let title: String
    package let audioPath: String?
    package let durationSec: Int
    package let langStats: String
    package let transcriptText: String
    package let summaryJSON: String?
    package let notesMD: String?
    package let segmentsJSON: String?
    package let speakersJSON: String?
    package let chaptersJSON: String?
    package let createdAt: String
    package let updatedAt: String
    /// Stamped by every speaker relabel (`relabelCluster`) — lets derived
    /// artifacts (recap, notes) notice their speaker names are stale. nil
    /// until the first relabel.
    package let speakerNamesChangedAt: String?
    /// When `summaryJSON` (the ad-hoc recap) was last generated — stamped by
    /// Go's recap writer. nil for a recap older than the column. Unlike
    /// `updatedAt`, a relabel never bumps it.
    package let summaryUpdatedAt: String?

    package init(
        id: Int64? = nil,
        eventID: String?,
        title: String,
        audioPath: String?,
        durationSec: Int,
        langStats: String,
        transcriptText: String,
        summaryJSON: String?,
        notesMD: String?,
        segmentsJSON: String?,
        speakersJSON: String?,
        chaptersJSON: String?,
        createdAt: String,
        updatedAt: String,
        speakerNamesChangedAt: String? = nil,
        summaryUpdatedAt: String? = nil
    ) {
        self.id = id
        self.eventID = eventID
        self.title = title
        self.audioPath = audioPath
        self.durationSec = durationSec
        self.langStats = langStats
        self.transcriptText = transcriptText
        self.summaryJSON = summaryJSON
        self.notesMD = notesMD
        self.segmentsJSON = segmentsJSON
        self.speakersJSON = speakersJSON
        self.chaptersJSON = chaptersJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.speakerNamesChangedAt = speakerNamesChangedAt
        self.summaryUpdatedAt = summaryUpdatedAt
    }

    /// Whether speaker names changed (a Voices-window label, relabel or retro
    /// pass) after the recap on screen was generated — the recap can then
    /// quote a stale "Speaker N" (spec §4.1) — and the hint's Regenerate
    /// (`transcript recap <id>`) can refresh it. `shownRecap` is the
    /// `meeting_recaps` row the Recap tab renders (nil when it renders this
    /// row's own `summaryJSON`, or nothing); the caller passes it only when
    /// it decoded, so nothing is parsed here.
    ///
    /// - Another source's event recap (pasted, another recording's) → false:
    ///   this recording's names never fed it, and Go's collision guard never
    ///   overwrites it, so a Regenerate could not change what is shown.
    /// - This recording's own row → compared with the recap's generation
    ///   stamp: `summaryUpdatedAt` when the row also has a `summaryJSON` copy
    ///   (Go refreshes both together; `linkToEvent` copies the summary with
    ///   the LINK time as `updated_at`, so that stamp would hide a relabel
    ///   made before linking), else the row's own `updated_at`.
    /// - No recap at all → false (nothing to regenerate).
    ///
    /// Never compares against `updatedAt` — a relabel bumps it in the same
    /// UPDATE that stamps `speakerNamesChangedAt`. A legacy summary with no
    /// stamp predates every relabel. String compare on the shared ISO format.
    package func recapPredatesSpeakerNames(shownRecap: RecordingRecap?) -> Bool {
        guard let changedAt = speakerNamesChangedAt else { return false }
        if let shownRecap {
            guard shownRecap.ownedByRecording else { return false }
            if summaryJSON == nil { return changedAt > shownRecap.recap.updatedAt }
        } else if summaryJSON == nil {
            return false
        }
        return changedAt > (summaryUpdatedAt ?? "")
    }

    /// Decodes `summaryJSON` (snake_case keys, same shape as a meeting recap).
    package var parsedSummary: MeetingRecap.Content? {
        guard let json = summaryJSON, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MeetingRecap.Content.self, from: data)
    }

    /// Decodes `segmentsJSON` into utterances; nil for legacy rows or a
    /// malformed payload (the UI then falls back to the flat text). Decode
    /// once per detail load — never in row builders.
    package var utterances: [TranscriptUtterance]? {
        guard let segmentsJSON else { return nil }
        return TranscriptSegments.decode(segmentsJSON)
    }

    /// Decodes `speakersJSON` into per-cluster voice embeddings; nil for
    /// legacy/embedding-less rows or a malformed payload (renames then update
    /// the transcript only).
    package var speakerEmbeddings: [SpeakerEmbedding]? {
        guard let speakersJSON else { return nil }
        return SpeakerEmbeddings.decode(speakersJSON)
    }

    /// Decodes `chaptersJSON`; nil until generated or for a malformed payload
    /// (the UI then falls back to the flat recap). Decode once per detail
    /// load — never in row builders.
    package var parsedChapters: MeetingChapters? {
        guard let chaptersJSON else { return nil }
        return MeetingChapters.decode(chaptersJSON)
    }

    package enum CodingKeys: String, CodingKey {
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
        case speakerNamesChangedAt = "speaker_names_changed_at"
        case summaryUpdatedAt = "summary_updated_at"
    }

    package mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// Identifiable for SwiftUI list/sheet identity; persisted rows always carry an id.
extension MeetingTranscript: Identifiable {}

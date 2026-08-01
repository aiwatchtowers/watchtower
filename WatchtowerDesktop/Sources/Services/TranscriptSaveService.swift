import Foundation

// MARK: - TranscriptSaveResult

/// Decoded stdout envelope of `watchtower meeting-prep transcript save|recap`.
/// The CLI exits 0 whenever the transcript row was persisted, even if the
/// recap failed — check `recapOK`/`recapError` for the AI outcome.
/// `segmentsOK == false` means the CLI dropped a provided segments file (the
/// column stayed NULL) — the visible tripwire for Go↔Swift renderer drift.
/// An older-CLI envelope omits the segments fields; absence is not a failure,
/// so `segmentsOK` decodes as `true` when the key is missing.
/// `chapters == .failed` means auto-chapter generation after save failed
/// (chapters_json stayed NULL — retry via the in-UI "Generate chapters"
/// button); `.notAttempted` covers no-segments saves, the recap-retry
/// command, and envelopes from an older CLI without the chapters keys.
struct TranscriptSaveResult: Decodable, Equatable {
    /// Outcome of the auto-chapter generation the CLI attempts after save.
    enum ChaptersOutcome: Equatable {
        case notAttempted
        case succeeded
        case failed
    }

    let transcriptID: Int64
    let recapOK: Bool
    let recapError: String
    let segmentsOK: Bool
    let segmentsError: String?
    let chapters: ChaptersOutcome
    let chaptersError: String?

    enum CodingKeys: String, CodingKey {
        case transcriptID = "transcript_id"
        case recapOK = "recap_ok"
        case recapError = "recap_error"
        case segmentsOK = "segments_ok"
        case segmentsError = "segments_error"
        case chaptersOK = "chapters_ok"
        case chaptersError = "chapters_error"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transcriptID = try container.decode(Int64.self, forKey: .transcriptID)
        recapOK = try container.decode(Bool.self, forKey: .recapOK)
        recapError = try container.decode(String.self, forKey: .recapError)
        segmentsOK = try container.decodeIfPresent(Bool.self, forKey: .segmentsOK) ?? true
        segmentsError = try container.decodeIfPresent(String.self, forKey: .segmentsError)
        if let chaptersOK = try container.decodeIfPresent(Bool.self, forKey: .chaptersOK) {
            chapters = chaptersOK ? .succeeded : .failed
        } else {
            chapters = .notAttempted
        }
        chaptersError = try container.decodeIfPresent(String.self, forKey: .chaptersError)
    }
}

// MARK: - TranscriptNotesResult

/// Decoded stdout envelope of `watchtower meeting-prep transcript notes <id>`.
/// The CLI exits non-zero on any failure (nothing persisted), so decoding
/// only happens on success.
struct TranscriptNotesResult: Decodable, Equatable {
    let transcriptID: Int64
    let notesMD: String

    enum CodingKeys: String, CodingKey {
        case transcriptID = "transcript_id"
        case notesMD = "notes_md"
    }
}

// MARK: - TranscriptChaptersResult

/// Decoded stdout envelope of `watchtower meeting-prep transcript chapters <id>`.
/// The CLI exits non-zero on any failure (nothing persisted), so decoding
/// only happens on success.
struct TranscriptChaptersResult: Decodable, Equatable {
    let transcriptID: Int64
    let chaptersJSON: String

    enum CodingKeys: String, CodingKey {
        case transcriptID = "transcript_id"
        case chaptersJSON = "chapters_json"
    }
}

// MARK: - TranscriptFollowupResult

/// Decoded stdout envelope of `watchtower meeting-prep transcript followup <id>`.
/// `chapter` is nil for a whole-meeting draft. The draft is ephemeral —
/// nothing is persisted or sent.
struct TranscriptFollowupResult: Decodable, Equatable {
    let transcriptID: Int64
    let chapter: Int?
    let draft: String

    enum CodingKeys: String, CodingKey {
        case transcriptID = "transcript_id"
        case chapter
        case draft
    }
}

// MARK: - TranscriptSaveService

/// Bridges the Desktop app to `watchtower meeting-prep transcript`.
/// The CLI is the sole writer to `meeting_transcripts` / `meeting_recaps`;
/// this service only ships the transcript text over and decodes the envelope.
struct TranscriptSaveService {
    let runner: CLIRunnerProtocol

    /// Writes `transcriptText` to a temp file, invokes
    /// `meeting-prep transcript save --transcript-file <tmp> [--segments-file <tmp>]
    /// [--speakers-file <tmp>] --audio <p> --duration <n> [--event-id <id>]
    /// [--title <s>] --lang-stats <json>`,
    /// and decodes the stdout envelope. The temp files are removed in defers,
    /// whether the run succeeds or throws. Non-nil `utterances` travel as a
    /// second temp file next to the transcript; the CLI persists them to
    /// `segments_json` (nil → the column stays NULL, legacy behavior).
    /// Non-nil `speakers` (per-cluster voice embeddings) travel the same way
    /// into `speakers_json`.
    func save(transcriptText: String,
              utterances: [TranscriptUtterance]? = nil,
              speakers: [SpeakerEmbedding]? = nil,
              audioPath: String,
              durationSec: Int,
              eventID: String?,
              title: String?,
              langStatsJSON: String) async throws -> TranscriptSaveResult {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchtower-transcript-\(UUID().uuidString).txt")
        try transcriptText.write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        var segmentsURL: URL?
        if let utterances, !utterances.isEmpty {
            if let segmentsJSON = TranscriptSegments.encode(utterances) {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("watchtower-segments-\(UUID().uuidString).json")
                try segmentsJSON.write(to: url, atomically: true, encoding: .utf8)
                segmentsURL = url
            } else {
                // Should be unreachable for in-memory utterances, but a silent
                // drop here would be invisible — the save then degrades to a
                // legacy segment-less row.
                print("[TranscriptSave] segments encode failed — saving without segments")
            }
        }
        defer { if let segmentsURL { try? FileManager.default.removeItem(at: segmentsURL) } }

        var speakersURL: URL?
        if let speakers, !speakers.isEmpty,
           let speakersJSON = SpeakerEmbeddings.encode(speakers) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("watchtower-speakers-\(UUID().uuidString).json")
            try speakersJSON.write(to: url, atomically: true, encoding: .utf8)
            speakersURL = url
        }
        defer { if let speakersURL { try? FileManager.default.removeItem(at: speakersURL) } }

        var args = [
            "meeting-prep", "transcript", "save",
            "--transcript-file", tmpURL.path
        ]
        if let segmentsURL {
            args += ["--segments-file", segmentsURL.path]
        }
        if let speakersURL {
            args += ["--speakers-file", speakersURL.path]
        }
        args += [
            "--audio", audioPath,
            "--duration", String(durationSec)
        ]
        if let eventID {
            args += ["--event-id", eventID]
        }
        if let title {
            args += ["--title", title]
        }
        args += ["--lang-stats", langStatsJSON]

        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(TranscriptSaveResult.self, from: data)
    }

    /// `meeting-prep transcript recap <id>` — retry a failed recap for an
    /// already-saved transcript. Same envelope as `save`.
    func retryRecap(transcriptID: Int64) async throws -> TranscriptSaveResult {
        let args = ["meeting-prep", "transcript", "recap", String(transcriptID)]
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(TranscriptSaveResult.self, from: data)
    }

    /// `meeting-prep transcript notes <id>` — generate publishable markdown
    /// meeting notes. The CLI persists notes_md itself; the returned markdown
    /// is for immediate display.
    func generateNotes(transcriptID: Int64) async throws -> TranscriptNotesResult {
        let args = ["meeting-prep", "transcript", "notes", String(transcriptID)]
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(TranscriptNotesResult.self, from: data)
    }

    /// `meeting-prep transcript chapters <id>` — generate meeting chapters
    /// (requires persisted segments). The CLI persists chapters_json itself.
    func generateChapters(transcriptID: Int64) async throws -> TranscriptChaptersResult {
        let args = ["meeting-prep", "transcript", "chapters", String(transcriptID)]
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(TranscriptChaptersResult.self, from: data)
    }

    /// `meeting-prep transcript followup <id> [--chapter N]` — draft a
    /// follow-up message in the owner's voice from one chapter (or, with
    /// chapter nil, the whole meeting). Nothing is persisted or sent.
    func generateFollowup(transcriptID: Int64, chapter: Int?) async throws -> TranscriptFollowupResult {
        var args = ["meeting-prep", "transcript", "followup", String(transcriptID)]
        if let chapter {
            args += ["--chapter", String(chapter)]
        }
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(TranscriptFollowupResult.self, from: data)
    }
    /// `meeting-prep transcript speaker-guess <id>` — LLM content hints for
    /// the transcript's unnamed "Speaker N" clusters. Nothing is persisted:
    /// the suggestions render as confirm chips and are only applied through
    /// the manual-rename mechanics.
    func speakerGuess(transcriptID: Int64) async throws -> SpeakerGuessResult {
        let args = ["meeting-prep", "transcript", "speaker-guess", String(transcriptID)]
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(SpeakerGuessResult.self, from: data)
    }
}

// MARK: - SpeakerGuessResult

/// Decoded stdout envelope of `watchtower meeting-prep transcript
/// speaker-guess <id>`. The CLI exits non-zero on any failure, so decoding
/// only happens on success.
struct SpeakerGuessResult: Decodable, Equatable {
    let transcriptID: Int64
    let suggestions: [SpeakerSuggestion]

    enum CodingKeys: String, CodingKey {
        case transcriptID = "transcript_id"
        case suggestions
    }
}

/// One "Speaker N looks like <candidate>" hint (never auto-applied).
struct SpeakerSuggestion: Decodable, Equatable, Identifiable {
    let speaker: String
    let candidate: String
    let confidence: Double
    let evidence: String

    var id: String { speaker }
}

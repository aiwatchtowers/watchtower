import Foundation

// MARK: - TranscriptSaveResult

/// Decoded stdout envelope of `watchtower meeting-prep transcript save|recap`.
/// The CLI exits 0 whenever the transcript row was persisted, even if the
/// recap failed — check `recapOK`/`recapError` for the AI outcome.
struct TranscriptSaveResult: Decodable, Equatable {
    let transcriptID: Int64
    let recapOK: Bool
    let recapError: String

    enum CodingKeys: String, CodingKey {
        case transcriptID = "transcript_id"
        case recapOK = "recap_ok"
        case recapError = "recap_error"
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
        if let utterances, !utterances.isEmpty,
           let segmentsJSON = TranscriptSegments.encode(utterances) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("watchtower-segments-\(UUID().uuidString).json")
            try segmentsJSON.write(to: url, atomically: true, encoding: .utf8)
            segmentsURL = url
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

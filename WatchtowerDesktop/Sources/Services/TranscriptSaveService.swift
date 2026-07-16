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
    /// `meeting-prep transcript save --transcript-file <tmp> --audio <p> --duration <n>
    /// [--event-id <id>] [--title <s>] --lang-stats <json>`,
    /// and decodes the stdout envelope. The temp file is removed in a defer,
    /// whether the run succeeds or throws.
    func save(transcriptText: String,
              audioPath: String,
              durationSec: Int,
              eventID: String?,
              title: String?,
              langStatsJSON: String) async throws -> TranscriptSaveResult {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchtower-transcript-\(UUID().uuidString).txt")
        try transcriptText.write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        var args = [
            "meeting-prep", "transcript", "save",
            "--transcript-file", tmpURL.path,
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
}

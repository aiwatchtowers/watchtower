import Foundation

// MARK: - TranscriptSaveResult

/// Decoded stdout envelope of `watchtower meeting-prep transcript save|recap`.
/// The CLI exits 0 whenever the transcript row was persisted, even if the
/// recap failed — check `recapOK`/`recapError` for the AI outcome.
/// `segmentsOK == false` means the CLI dropped a provided segments file (the
/// column stayed NULL) — the visible tripwire for Go↔Swift renderer drift.
/// Optional so envelopes from an older CLI still decode.
struct TranscriptSaveResult: Decodable, Equatable {
    let transcriptID: Int64
    let recapOK: Bool
    let recapError: String
    let segmentsOK: Bool?
    let segmentsError: String?

    enum CodingKeys: String, CodingKey {
        case transcriptID = "transcript_id"
        case recapOK = "recap_ok"
        case recapError = "recap_error"
        case segmentsOK = "segments_ok"
        case segmentsError = "segments_error"
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
    /// --audio <p> --duration <n> [--event-id <id>] [--title <s>] --lang-stats <json>`,
    /// and decodes the stdout envelope. The temp files are removed in defers,
    /// whether the run succeeds or throws. Non-nil `utterances` travel as a
    /// second temp file next to the transcript; the CLI persists them to
    /// `segments_json` (nil → the column stays NULL, legacy behavior).
    func save(transcriptText: String,
              utterances: [TranscriptUtterance]? = nil,
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

        var args = [
            "meeting-prep", "transcript", "save",
            "--transcript-file", tmpURL.path
        ]
        if let segmentsURL {
            args += ["--segments-file", segmentsURL.path]
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
}

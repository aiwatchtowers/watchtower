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
/// `recapSkipped` means the CLI deliberately skipped recap generation for a
/// too-short transcript (`recapOK` is also false in that case) — an older-CLI
/// envelope omits the key, decoding as `false`. A private save (MEETPRIV-01)
/// skips recap and chapters on purpose; `recapSkippedPrivate` is its
/// affirmative signal (`recap_skipped_reason` = "private"), which the
/// completion notification reads. The too-short skip carries no reason. The
/// envelope's `chapters_skipped*` keys are not decoded: `chapters_ok: false`
/// already reads as `.failed`, and the private notice wins over it.
package struct TranscriptSaveResult: Decodable, Equatable {
    /// Outcome of the auto-chapter generation the CLI attempts after save.
    package enum ChaptersOutcome: Equatable {
        case notAttempted
        case succeeded
        case failed
    }

    package let transcriptID: Int64
    package let recapOK: Bool
    package let recapError: String
    package let recapSkipped: Bool
    package let recapSkippedPrivate: Bool
    package let segmentsOK: Bool
    package let segmentsError: String?
    package let chapters: ChaptersOutcome
    package let chaptersError: String?

    enum CodingKeys: String, CodingKey {
        case transcriptID = "transcript_id"
        case recapOK = "recap_ok"
        case recapError = "recap_error"
        case recapSkipped = "recap_skipped"
        case recapSkippedReason = "recap_skipped_reason"
        case segmentsOK = "segments_ok"
        case segmentsError = "segments_error"
        case chaptersOK = "chapters_ok"
        case chaptersError = "chapters_error"
    }

    /// `recap_skipped_reason` of a private save.
    package static let privateSkipReason = "private"

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transcriptID = try container.decode(Int64.self, forKey: .transcriptID)
        recapOK = try container.decode(Bool.self, forKey: .recapOK)
        recapError = try container.decode(String.self, forKey: .recapError)
        recapSkipped = try container.decodeIfPresent(Bool.self, forKey: .recapSkipped) ?? false
        recapSkippedPrivate = try container.decodeIfPresent(String.self, forKey: .recapSkippedReason)
            == Self.privateSkipReason
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
package struct TranscriptNotesResult: Decodable, Equatable {
    package let transcriptID: Int64
    package let notesMD: String

    enum CodingKeys: String, CodingKey {
        case transcriptID = "transcript_id"
        case notesMD = "notes_md"
    }
}

// MARK: - TranscriptChaptersResult

/// Decoded stdout envelope of `watchtower meeting-prep transcript chapters <id>`.
/// The CLI exits non-zero on any failure (nothing persisted), so decoding
/// only happens on success.
package struct TranscriptChaptersResult: Decodable, Equatable {
    package let transcriptID: Int64
    package let chaptersJSON: String

    enum CodingKeys: String, CodingKey {
        case transcriptID = "transcript_id"
        case chaptersJSON = "chapters_json"
    }
}

// MARK: - TranscriptFollowupResult

/// Decoded stdout envelope of `watchtower meeting-prep transcript followup <id>`.
/// `chapter` is nil for a whole-meeting draft. The draft is ephemeral —
/// nothing is persisted or sent.
package struct TranscriptFollowupResult: Decodable, Equatable {
    package let transcriptID: Int64
    package let chapter: Int?
    package let draft: String

    enum CodingKeys: String, CodingKey {
        case transcriptID = "transcript_id"
        case chapter
        case draft
    }
}

// MARK: - TranscriptPrivateResult

/// Decoded stdout of `watchtower meeting-prep transcript private <id> on|off`.
package struct TranscriptPrivateResult: Decodable, Equatable {
    package let transcriptID: Int64
    package let isPrivate: Bool

    enum CodingKeys: String, CodingKey {
        case transcriptID = "id"
        case isPrivate = "private"
    }
}

// MARK: - TranscriptExportFormat

/// `meeting-prep transcript export --format`: the renderers live in Go only
/// (MEETPRIV-05 — export is local and always allowed, private or not).
package enum TranscriptExportFormat: String, CaseIterable, Sendable {
    case txt, md, srt, json

    /// The Export menu's item title.
    package var menuTitle: String {
        switch self {
        case .txt: return "Save as Text…"
        case .md: return "Save as Markdown…"
        case .srt: return "Save as Subtitles (SRT)…"
        case .json: return "Save as JSON…"
        }
    }

    package var fileExtension: String { rawValue }

    /// SRT cues need the segments' timings; the CLI refuses a row without
    /// segments (`no timed segments`).
    package var needsSegments: Bool { self == .srt }

    /// The save panel's suggested name: the recording's title with the
    /// characters a file name cannot hold replaced, "Recording" when blank.
    package func suggestedFileName(title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.newlines).union(.controlCharacters))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let base = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ".")).isEmpty ? "Recording" : cleaned
        return "\(base).\(fileExtension)"
    }
}

// MARK: - TranscriptSaveService

/// Bridges the Desktop app to `watchtower meeting-prep transcript`.
/// The CLI is the sole writer to `meeting_transcripts` / `meeting_recaps`;
/// this service only ships the transcript text over and decodes the envelope.
package struct TranscriptSaveService {
    package let runner: CLIRunnerProtocol

    package init(runner: CLIRunnerProtocol) {
        self.runner = runner
    }

    /// Invokes `meeting-prep transcript save --stdin --audio <p> --duration <n>
    /// [--event-id <id>] [--title <s>] --lang-stats <json> [--private]` with one JSON
    /// object on stdin — `{"transcript", "segments", "speakers"}` — and decodes
    /// the stdout envelope (#604 S7: no temp file holds the transcript).
    /// Non-nil `utterances` travel as `segments`, which the CLI persists to
    /// `segments_json` (null → the column stays NULL, legacy behavior);
    /// non-nil `speakers` (per-cluster voice embeddings) as `speakers`, into
    /// `speakers_json`.
    package func save(transcriptText: String,
                      utterances: [TranscriptUtterance]? = nil,
                      speakers: [SpeakerEmbedding]? = nil,
                      audioPath: String,
                      durationSec: Int,
                      eventID: String?,
                      title: String?,
                      langStatsJSON: String,
                      isPrivate: Bool = false) async throws -> TranscriptSaveResult {
        var segmentsJSON: String?
        if let utterances, !utterances.isEmpty {
            segmentsJSON = TranscriptSegments.encode(utterances)
            if segmentsJSON == nil {
                // Should be unreachable for in-memory utterances, but a silent
                // drop here would be invisible — the save then degrades to a
                // legacy segment-less row.
                print("[TranscriptSave] segments encode failed — saving without segments")
            }
        }
        var speakersJSON: String?
        if let speakers, !speakers.isEmpty { speakersJSON = SpeakerEmbeddings.encode(speakers) }

        var args = ["meeting-prep", "transcript", "save", "--stdin", "--audio", audioPath,
                    "--duration", String(durationSec)]
        if let eventID {
            args += ["--event-id", eventID]
        }
        if let title {
            args += ["--title", title]
        }
        args += ["--lang-stats", langStatsJSON]
        if isPrivate {
            // MEETPRIV-01: stored private, no recap or chapters generated.
            args.append("--private")
        }

        let payload = try Self.stdinPayload(transcript: transcriptText, segmentsJSON: segmentsJSON,
                                            speakersJSON: speakersJSON)
        let data = try await runner.run(args: args, stdin: payload)
        return try JSONDecoder().decode(TranscriptSaveResult.self, from: data)
    }

    /// `save --stdin`'s object. The segments and speakers JSON are embedded as
    /// they were encoded (the bytes the CLI stores), not re-serialized.
    package static func stdinPayload(transcript: String, segmentsJSON: String?, speakersJSON: String?) throws -> Data {
        let text = String(bytes: try JSONEncoder().encode(transcript), encoding: .utf8) ?? "\"\""
        return Data(#"{"transcript":\#(text),"segments":\#(segmentsJSON ?? "null"),"speakers":\#(speakersJSON ?? "null")}"#.utf8)
    }

    /// `meeting-prep transcript recap <id>` — retry a failed recap for an
    /// already-saved transcript. Same envelope as `save`.
    package func retryRecap(transcriptID: Int64) async throws -> TranscriptSaveResult {
        let args = ["meeting-prep", "transcript", "recap", String(transcriptID)]
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(TranscriptSaveResult.self, from: data)
    }

    /// `meeting-prep transcript notes <id>` — generate publishable markdown
    /// meeting notes. The CLI persists notes_md itself; the returned markdown
    /// is for immediate display.
    package func generateNotes(transcriptID: Int64) async throws -> TranscriptNotesResult {
        let args = ["meeting-prep", "transcript", "notes", String(transcriptID)]
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(TranscriptNotesResult.self, from: data)
    }

    /// `meeting-prep transcript chapters <id>` — generate meeting chapters
    /// (requires persisted segments). The CLI persists chapters_json itself.
    package func generateChapters(transcriptID: Int64) async throws -> TranscriptChaptersResult {
        let args = ["meeting-prep", "transcript", "chapters", String(transcriptID)]
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(TranscriptChaptersResult.self, from: data)
    }

    /// `meeting-prep transcript followup <id> [--chapter N]` — draft a
    /// follow-up message in the owner's voice from one chapter (or, with
    /// chapter nil, the whole meeting). Nothing is persisted or sent.
    package func generateFollowup(transcriptID: Int64, chapter: Int?) async throws -> TranscriptFollowupResult {
        var args = ["meeting-prep", "transcript", "followup", String(transcriptID)]
        if let chapter {
            args += ["--chapter", String(chapter)]
        }
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(TranscriptFollowupResult.self, from: data)
    }

    /// `meeting-prep transcript private <id> on|off` — marks the recording
    /// private (no AI reader sees it from then on, MEETPRIV-02/04) or not.
    package func setPrivate(transcriptID: Int64, _ isPrivate: Bool) async throws -> TranscriptPrivateResult {
        let args = ["meeting-prep", "transcript", "private", String(transcriptID), isPrivate ? "on" : "off"]
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(TranscriptPrivateResult.self, from: data)
    }

    /// `meeting-prep transcript export <id> --format <f>`: the rendering, from
    /// stdout. The app writes any file itself — a file written by the CLI
    /// child into a folder TCC guards would be checked against Watchtower.app
    /// without the save panel's grant.
    package func export(transcriptID: Int64, format: TranscriptExportFormat) async throws -> Data {
        try await runner.run(args: ["meeting-prep", "transcript", "export", String(transcriptID),
                                    "--format", format.rawValue])
    }
}

import Foundation
import WatchtowerCore

// MARK: - DictationMode

/// Where a dictation is headed. Decides the span separator and — via
/// `cleanupMode` — whether the transcript goes through the AI cleanup pass
/// at all.
enum DictationMode: String, Sendable {
    case idea, note, chat

    /// The `watchtower dictate clean --mode` this destination runs, or nil
    /// when the raw transcript IS the deliverable. A chat field feeds the
    /// user's own assistant, which reads speech-shaped text perfectly well —
    /// an extra LLM round trip there only adds latency and rewrites the
    /// user's wording (owner call 2026-08-18). Idea and note keep it: those
    /// destinations need a title/markdown shape the raw transcript hasn't got.
    var cleanupMode: DictationCleanMode? {
        switch self {
        case .idea: return .idea
        case .note: return .note
        case .chat: return nil
        }
    }
}

// MARK: - DictationCleanMode

/// The subset of destinations the `dictate clean` CLI actually serves — the
/// modes it accepts on `--mode`.
enum DictationCleanMode: String, Sendable {
    case idea, note
}

// MARK: - DictationCleanResult

/// Cleaned dictation, shaped for the destination.
struct DictationCleanResult: Equatable, Sendable {
    var title: String?   // idea mode only
    var text: String     // body / markdown / chat text
}

// MARK: - DictationCleanError

enum DictationCleanError: LocalizedError, Equatable {
    /// The envelope was missing (or had empty) the content key for the
    /// requested mode — `body` for idea, `markdown` for note.
    case badEnvelope(mode: DictationCleanMode)

    var errorDescription: String? {
        switch self {
        case .badEnvelope(let mode):
            return "watchtower dictate clean returned an envelope with no \(mode.rawValue) content."
        }
    }
}

// MARK: - DictationCleanService

/// Bridges the Desktop app to `watchtower dictate clean --mode <mode>
/// --transcript-file <path>`. The transcript travels via a temp file (the
/// `TranscriptSaveService.save` precedent), removed whether the run succeeds
/// or throws. The CLI's stdout envelope shape is mode-dependent
/// (idea → title/body, note → markdown); this service decodes all fields as
/// optional and maps the mode's own key into one result shape.
struct DictationCleanService {
    let runner: CLIRunnerProtocol

    private struct Envelope: Decodable {
        let title: String?
        let body: String?
        let markdown: String?
    }

    func clean(transcript: String, mode: DictationCleanMode) async throws -> DictationCleanResult {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-\(UUID().uuidString).txt")
        try transcript.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let args = ["dictate", "clean", "--mode", mode.rawValue, "--transcript-file", url.path]
        let data = try await runner.run(args: args)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)

        switch mode {
        case .idea:
            guard let body = envelope.body, !body.isEmpty else {
                throw DictationCleanError.badEnvelope(mode: mode)
            }
            return DictationCleanResult(title: envelope.title, text: body)
        case .note:
            guard let markdown = envelope.markdown, !markdown.isEmpty else {
                throw DictationCleanError.badEnvelope(mode: mode)
            }
            return DictationCleanResult(title: nil, text: markdown)
        }
    }
}

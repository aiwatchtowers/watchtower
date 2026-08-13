import Foundation
import WatchtowerCore

// MARK: - DictationMode

enum DictationMode: String, Sendable {
    case idea, note, chat
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
    /// requested mode — `body` for idea, `markdown` for note, `text` for chat.
    case badEnvelope(mode: DictationMode)

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
/// (idea → title/body, note → markdown, chat → text); this service decodes
/// all fields as optional and maps the mode's own key into one result shape.
struct DictationCleanService {
    let runner: CLIRunnerProtocol

    private struct Envelope: Decodable {
        let title: String?
        let body: String?
        let markdown: String?
        let text: String?
    }

    func clean(transcript: String, mode: DictationMode) async throws -> DictationCleanResult {
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
        case .chat:
            guard let text = envelope.text, !text.isEmpty else {
                throw DictationCleanError.badEnvelope(mode: mode)
            }
            return DictationCleanResult(title: nil, text: text)
        }
    }
}

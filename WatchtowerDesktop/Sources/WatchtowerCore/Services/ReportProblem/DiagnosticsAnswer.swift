import Foundation

/// The answer of `watchtower diagnostics --json`. The keys are pinned on the
/// Go side by `TestReport_JSONKeys` (internal/diagnostics); `text` is shown
/// verbatim, the rest prefills the GitHub form.
package struct DiagnosticsAnswer: Decodable, Equatable, Sendable {
    package let text: String
    package let version: String
    package let macos: String
    package let chip: String
    package let provider: String
    package let flavor: String
    package let sources: [String]
    package let partial: Bool

    package init(
        text: String,
        version: String,
        macos: String,
        chip: String,
        provider: String,
        flavor: String,
        sources: [String],
        partial: Bool
    ) {
        self.text = text
        self.version = version
        self.macos = macos
        self.chip = chip
        self.provider = provider
        self.flavor = flavor
        self.sources = sources
        self.partial = partial
    }

    package enum DecodeError: Error, Equatable {
        /// No non-empty line, or the output is not UTF-8.
        case noOutput
    }

    /// Decodes the last non-empty stdout line, so a stray line printed
    /// before the JSON (a warning) does not break the answer.
    package static func decode(stdout: Data) throws -> Self {
        guard let output = String(bytes: stdout, encoding: .utf8),
              let line = output
            .split(whereSeparator: \.isNewline)
            .last(where: { !$0.allSatisfy(\.isWhitespace) })
        else {
            throw DecodeError.noOutput
        }
        return try JSONDecoder().decode(Self.self, from: Data(line.utf8))
    }
}

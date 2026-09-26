import Foundation

/// Pure submit logic for the chat-first target-creation composer
/// (`CreateTargetSheet`). Lives in Core so it is testable without the app
/// target — the sheet has no tests, and new logic must not accrete on the
/// View (spec §9.5).
package enum TargetComposerLogic {
    /// Hard cap for a derived provisional title, in characters.
    package static let titleCap = 120

    /// Provisional title for the mechanically-created target row: the first
    /// non-empty line of the composer text, trimmed, hard-capped at
    /// `titleCap` characters on a word boundary (an ellipsis marks the cut).
    /// A single unbroken token longer than the cap falls back to a hard cut.
    package static func deriveTitle(from text: String) -> String {
        let line = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard line.count > titleCap else { return line }
        let hardCut = String(line.prefix(titleCap))
        if let lastSpace = hardCut.lastIndex(where: { $0.isWhitespace }) {
            let wordCut = String(hardCut[..<lastSpace])
                .trimmingCharacters(in: .whitespaces)
            if !wordCut.isEmpty { return wordCut + "…" }
        }
        return hardCut + "…"
    }
}

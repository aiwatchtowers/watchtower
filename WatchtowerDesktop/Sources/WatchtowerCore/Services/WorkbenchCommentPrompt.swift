import Foundation

/// A line typed into a workbench's Claude Code session — today an answered
/// ask's (`OwnerAskPrompt`) — and how it gets there. Pure.
package enum WorkbenchCommentPrompt {
    /// Every control or newline scalar becomes a space: a line carrying
    /// agent-supplied text can never submit early or carry an escape.
    package static func oneLine(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar -> Character in
            isControl(scalar) ? " " : Character(scalar)
        })
    }

    /// How the line reaches Claude Code — never with a trailing Enter.
    package enum TerminalPayload: Equatable {
        /// Bytes to write: `ESC[200~` + line + `ESC[201~`, delivered as one
        /// paste the TUI puts in its input box.
        case paste([UInt8])
        /// Bracketed paste is off: the line goes to the clipboard and the
        /// owner pastes it with ⌘V.
        case clipboard(String)
    }

    /// The line, control scalars dropped, wrapped for delivery. Only the
    /// owner's own keypress submits it: typed keystrokes (or an Enter) could
    /// be consumed by whatever Claude Code is showing — a pending permission
    /// prompt takes a digit or Enter as its answer without the owner ever
    /// seeing it. A bracketed paste is text to the TUI, never a keypress;
    /// without that mode nothing is written at all. Dropping every control
    /// scalar (ESC included) also means the payload can never contain the
    /// `ESC[201~` terminator that would end the paste early.
    ///
    /// `keepingLineBreaks` (a code question handed to Claude Code, spec
    /// 2026-10-02 §9.5): line breaks become LF and tabs stay — text inside a
    /// paste, as SwiftTerm's own ⌘V sends it — while every other control
    /// scalar is still dropped.
    package static func terminalPayload(_ line: String, bracketedPaste: Bool, keepingLineBreaks: Bool = false) -> TerminalPayload {
        var clean = String.UnicodeScalarView()
        let source = keepingLineBreaks ? line.replacingOccurrences(of: "\r\n", with: "\n") : line
        for scalar in source.unicodeScalars {
            if keepingLineBreaks, CharacterSet.newlines.contains(scalar) {
                clean.append("\n")
            } else if !isControl(scalar) || (keepingLineBreaks && scalar == "\t") {
                clean.append(scalar)
            }
        }
        let text = String(clean)
        guard bracketedPaste else { return .clipboard(text) }
        return .paste(pasteStart + Array(text.utf8) + pasteEnd)
    }

    private static let pasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] // ESC[200~
    private static let pasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E] // ESC[201~

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
    }
}

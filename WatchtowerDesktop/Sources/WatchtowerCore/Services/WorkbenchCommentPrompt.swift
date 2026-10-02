import Foundation

/// "Send N comments to Claude" on a workbench document: ONE prompt line typed
/// into the workbench's Claude Code session. The line carries only the
/// document's path and id — Claude reads the open comments themselves through
/// its `list_comments` tool — so the whole batch goes at once. Pure.
package enum WorkbenchCommentPrompt {
    /// Open owner threads on a document — what the button counts.
    package static func openOwnerCount(_ threads: [WorkbenchCommentThread]) -> Int {
        threads.filter { $0.root.isOpen && !$0.root.isAgent }.count
    }

    /// The rel path is agent-supplied, so every control or newline scalar in
    /// it becomes a space: the line can never submit early or carry an escape.
    /// `vocabulary` names the skill the folder has installed (spec 2026-10-02 §5.3).
    package static func line(relPath: String, documentID: Int64, count: Int, vocabulary: WorkbenchVocabulary) -> String {
        let path = String(relPath.unicodeScalars.map { scalar -> Character in
            isControl(scalar) ? " " : Character(scalar)
        })
        let what = count == 1 ? "the open comment" : "the \(count) open comments"
        return "Address \(what) on \(path) (watchtower document \(documentID)) using the \(vocabulary.skillName) skill."
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
    package static func terminalPayload(_ line: String, bracketedPaste: Bool) -> TerminalPayload {
        var clean = String.UnicodeScalarView()
        clean.append(contentsOf: line.unicodeScalars.filter { !isControl($0) })
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

import Foundation

/// "Send N comments to Claude" on a project document: ONE prompt line typed
/// into the project's Claude Code session. The line carries only the
/// document's path and id — Claude reads the open comments themselves through
/// its `list_comments` tool — so the whole batch goes at once. Pure.
package enum ProjectCommentPrompt {
    /// Open owner threads on a document — what the button counts.
    package static func openOwnerCount(_ threads: [ProjectCommentThread]) -> Int {
        threads.filter { $0.root.isOpen && !$0.root.isAgent }.count
    }

    /// The rel path is agent-supplied, so every control or newline scalar in
    /// it becomes a space: the line can never submit early or carry an escape.
    package static func line(relPath: String, documentID: Int64, count: Int) -> String {
        let path = String(relPath.unicodeScalars.map { scalar -> Character in
            isControl(scalar) ? " " : Character(scalar)
        })
        let what = count == 1 ? "the open comment" : "the \(count) open comments"
        return "Address \(what) on \(path) (watchtower document \(documentID)) using the watchtower-project skill."
    }

    /// Bytes for the terminal: the line with any control scalar dropped, then
    /// one carriage return — Enter in Claude Code's raw-mode prompt.
    package static func terminalInput(_ line: String) -> [UInt8] {
        var clean = String.UnicodeScalarView()
        clean.append(contentsOf: line.unicodeScalars.filter { !isControl($0) })
        return Array(String(clean).utf8) + [0x0D]
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
    }
}

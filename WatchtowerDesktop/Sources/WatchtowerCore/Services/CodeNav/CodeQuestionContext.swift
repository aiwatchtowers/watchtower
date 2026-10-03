import Foundation

/// The text the owner selected for a code question. Lines are 1-based.
package struct CodeQuestionSelection: Equatable, Sendable {
    package let startLine: Int
    package let endLine: Int
    package let text: String

    package init(startLine: Int, endLine: Int, text: String) {
        self.startLine = startLine
        self.endLine = endLine
        self.text = text
    }
}

/// Where a code question was asked (spec 2026-10-02 §9.1, §9.4): a file of
/// the workbench, the cursor line, and the selection if there was one.
package struct CodeQuestionOrigin: Equatable, Sendable {
    /// Relative to the workbench folder.
    package let path: String
    /// The cursor line, 1-based.
    package let line: Int
    package let selection: CodeQuestionSelection?

    package init(path: String, line: Int, selection: CodeQuestionSelection?) {
        self.path = path
        self.line = line
        self.selection = selection
    }

    /// `chat_conversations.context_id` of the question:
    /// `<workbench id>:<path>:<line>`.
    package func contextID(workbenchID: Int64) -> String {
        "\(workbenchID):\(path):\(line)"
    }
}

/// A code question's first-turn context (spec 2026-10-02 §9.1), built in
/// Swift and holding no file content beyond this: the workbench folder's
/// name, the file's path and language, the selection (or the cursor line)
/// with `surroundingRadius` lines around it clipped at the file's edges,
/// and up to `maxEntries` index entries (signature + doc) for the names the
/// selection references that the index resolves to exactly one symbol.
package struct CodeQuestionContext: Equatable, Sendable {
    package static let surroundingRadius = 40
    package static let maxEntries = 10
    /// A long doc comment is cut here; the model can read the file.
    package static let docLimit = 400
    /// Each code line is cut here (as `code search` cuts its line text): a
    /// minified one-line file must not fill the prompt.
    package static let contextLineLimit = 400
    /// The whole context block is cut here, in UTF-8 bytes.
    package static let maxPromptBytes = 32 * 1024
    package static let cutNote = "… the context was cut at 32 KB"

    package let folderName: String
    package let path: String
    package let language: String
    /// false: nothing was selected, the focus is the cursor line.
    package let isSelection: Bool
    package let focusLines: ClosedRange<Int>
    /// The selected text, or the cursor line's text.
    package let focusText: String
    package let surroundingLines: ClosedRange<Int>
    /// The file's lines in `surroundingLines`.
    package let surrounding: [String]
    package let entries: [CodeSymbol]
    /// A focus line was longer than `contextLineLimit`.
    package let focusLinesWereCut: Bool

    /// The model never saw the whole selection — a line was cut at
    /// `contextLineLimit`, or the 32 KB cap of `promptBlock` reaches into the
    /// selection (a multibyte one: few characters per line, many bytes) —
    /// so its suggested change cannot replace the real selection.
    package var focusWasCut: Bool {
        // The warning's bytes count too (conservatively): it sits before the selection.
        focusLinesWereCut || (isSelection && header.utf8.count + Self.cutWarning.utf8.count
            + Self.selectionHeader(focusLines).utf8.count + fenced(focusText).utf8.count + 1 > Self.capBudget)
    }

    package static let cutWarning =
        "The selection below is cut (lines over \(contextLineLimit) characters, or the 32 KB limit): suggest no `wt-edit`.\n"
    /// "Where is it used?" (ruling R45): Watchtower's own whole-word search
    /// for the name, attached before that question is sent.
    package var usages: CodeQuestionUsages?

    /// `resolve` is the index lookup by exact name (`WorkbenchCodeIndex.symbols(named:)`).
    package static func build(
        folderName: String,
        origin: CodeQuestionOrigin,
        language: String,
        fileText: String,
        resolve: (String) -> [CodeSymbol]
    ) -> Self {
        let lines = fileLines(fileText)
        let last = max(lines.count, 1)
        let clamp = { (line: Int) in min(max(line, 1), last) }

        let focus: ClosedRange<Int>
        let fullFocusText: String
        let isSelection: Bool
        if let selection = origin.selection, !selection.text.isEmpty {
            let start = clamp(min(selection.startLine, selection.endLine))
            focus = start...max(start, clamp(max(selection.startLine, selection.endLine)))
            fullFocusText = selection.text
            isSelection = true
        } else {
            let line = clamp(origin.line)
            focus = line...line
            fullFocusText = lines.isEmpty ? "" : lines[line - 1]
            isSelection = false
        }
        let focusText = cutLines(fullFocusText)
        let around = max(1, focus.lowerBound - surroundingRadius)...min(last, focus.upperBound + surroundingRadius)
        let surrounding = lines.isEmpty ? [] : lines[(around.lowerBound - 1)...(around.upperBound - 1)].map(cut)

        return Self(
            folderName: folderName,
            path: origin.path,
            language: language,
            isSelection: isSelection,
            focusLines: focus,
            focusText: focusText,
            surroundingLines: around,
            surrounding: surrounding,
            entries: uniqueEntries(referencedIn: focusText, resolve: resolve),
            focusLinesWereCut: focusText != fullFocusText,
            usages: nil
        )
    }

    /// The file's lines as the editor counts them: a trailing newline ends
    /// the last line rather than starting an empty one.
    private static func fileLines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
        }
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// A line longer than `contextLineLimit` characters, cut with "…".
    private static func cut(_ line: String) -> String {
        line.count > contextLineLimit ? String(line.prefix(contextLineLimit)) + "…" : line
    }

    private static func cutLines(_ text: String) -> String {
        guard text.count > contextLineLimit else { return text }
        return text.components(separatedBy: "\n").map(cut).joined(separator: "\n")
    }

    private static let identifier = #/[A-Za-z_][A-Za-z0-9_]{0,}/#

    /// Each name in `text` once, in order, kept when the index resolves it
    /// to exactly one symbol; at most `maxEntries`.
    private static func uniqueEntries(referencedIn text: String, resolve: (String) -> [CodeSymbol]) -> [CodeSymbol] {
        var seen = Set<String>()
        var entries: [CodeSymbol] = []
        for match in text.matches(of: identifier) {
            guard entries.count < maxEntries else { break }
            let name = String(match.output)
            guard seen.insert(name).inserted else { continue }
            let symbols = resolve(name)
            if symbols.count == 1 { entries.append(symbols[0]) }
        }
        return entries
    }

    /// The context as the system prompt carries it. Code lines are numbered
    /// so the answer can cite `path:line`; the focus lines are marked `>`.
    /// Lines are cut at `contextLineLimit` characters and the block at
    /// `maxPromptBytes`.
    package var promptBlock: String {
        Self.capped(fullPromptBlock)
    }

    /// What `capped` keeps of a block over `maxPromptBytes`, in UTF-8 bytes.
    private static var capBudget: Int { maxPromptBytes - cutNote.utf8.count - 2 }

    /// `block` within `maxPromptBytes`, cut on a character boundary.
    private static func capped(_ block: String) -> String {
        guard block.utf8.count > maxPromptBytes else { return block }
        let budget = capBudget
        var bytes = 0
        var end = block.startIndex
        for index in block.indices {
            let size = block[index].utf8.count
            guard bytes + size <= budget else { break }
            bytes += size
            end = block.index(after: index)
        }
        return String(block[..<end]) + "\n" + cutNote + "\n"
    }

    private var header: String {
        """
        === CODE QUESTION CONTEXT ===
        Workbench folder: \(folderName)
        File: \(path)
        Language: \(language.isEmpty ? "unknown" : language)

        """
    }

    private static func selectionHeader(_ lines: ClosedRange<Int>) -> String {
        let range = lines.count == 1 ? "line \(lines.lowerBound)" : "lines \(lines.lowerBound)–\(lines.upperBound)"
        return "Selection (\(range)):\n"
    }

    private var fullPromptBlock: String {
        var b = header
        let width = String(surroundingLines.upperBound).count
        let numberedLines = zip(surroundingLines, surrounding).map { line, text -> String in
            let mark = focusLines.contains(line) ? ">" : " "
            let number = String(line)
            return "\(mark) \(String(repeating: " ", count: width - number.count))\(number) | \(text)"
        }
        let numbered = numberedLines.joined(separator: "\n")
        if isSelection {
            // Before the selection, so a cap cutting into it keeps the line.
            if focusWasCut { b += Self.cutWarning }
            b += Self.selectionHeader(focusLines) + "\(fenced(focusText))\n"
        } else {
            b += "Cursor line: \(focusLines.lowerBound)\n"
        }
        let marked = isSelection ? "selection" : "cursor line"
        b += "\nCode around it (lines \(surroundingLines.lowerBound)–\(surroundingLines.upperBound), "
        b += "> marks the \(marked)):\n\(fenced(numbered))\n"
        if !entries.isEmpty {
            b += "\nDefinitions of names it uses (from the workbench's symbol index):\n"
            for entry in entries {
                b += "- \(entry.name) (\(entry.kind.rawValue)) \(entry.path):\(entry.line)\n"
                if !entry.signature.isEmpty { b += "  \(entry.signature)\n" }
                if !entry.doc.isEmpty {
                    let doc = entry.doc.count > Self.docLimit ? String(entry.doc.prefix(Self.docLimit)) + "…" : entry.doc
                    b += "  " + doc.replacingOccurrences(of: "\n", with: "\n  ") + "\n"
                }
            }
        }
        if let usagesBlock { b += "\n" + usagesBlock }
        return b
    }

    /// The attached usages as the prompt carries them; nil before a search.
    package var usagesBlock: String? {
        guard let usages else { return nil }
        guard !usages.locations.isEmpty else {
            return "No usages of `\(usages.name)` were found in the workbench (whole word, case-sensitive).\n"
        }
        var b = "Usages of `\(usages.name)` in the workbench (Watchtower's whole-word, case-sensitive text search"
        b += usages.truncated ? "; the first \(usages.locations.count), more not shown):\n" : "):\n"
        for location in usages.locations {
            b += "- \(location.path):\(location.line): \(location.text.trimmingCharacters(in: .whitespaces))\n"
        }
        return b
    }

    /// `text` in a fence longer than any backtick run inside it.
    private func fenced(_ text: String) -> String {
        let longest = text.matches(of: #/`+/#).map { $0.output.count }.max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\(language)\n\(text)\n\(fence)"
    }
}

/// The locations a usage search found for one name (ruling R45).
package struct CodeQuestionUsages: Equatable, Sendable {
    package struct Location: Equatable, Sendable {
        package let path: String
        package let line: Int
        package let text: String

        package init(path: String, line: Int, text: String) {
            self.path = path
            self.line = line
            self.text = text
        }
    }

    /// At most this many locations ride with a question.
    package static let limit = 30

    package let name: String
    package let locations: [Location]
    package let truncated: Bool

    package init(name: String, locations: [Location], truncated: Bool) {
        self.name = name
        self.locations = locations
        self.truncated = truncated
    }
}

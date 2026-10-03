import Foundation

/// A range of the editor's text as Monaco counts it: 1-based lines, 1-based
/// UTF-16 columns, the end exclusive.
package struct CodeTextRange: Equatable, Sendable {
    package let startLine: Int
    package let startCol: Int
    package let endLine: Int
    package let endCol: Int

    package init(startLine: Int, startCol: Int, endLine: Int, endCol: Int) {
        self.startLine = startLine
        self.startCol = startCol
        self.endLine = endLine
        self.endCol = endCol
    }

    /// The page's `range` argument (`proposeEdit`, `applyEdit`).
    package var pageArgument: [String: Int] {
        ["startLine": startLine, "startCol": startCol, "endLine": endLine, "endCol": endCol]
    }
}

/// The page's `selection` message: the selection of the file on screen.
/// The page cuts the text at 20 KB (`truncated`); empty text = a caret.
package struct CodeEditorSelection: Equatable, Sendable {
    package static let pageLimit = 20_480

    package let bufferID: String
    package let range: CodeTextRange
    package let text: String
    package let truncated: Bool

    package init(bufferID: String, range: CodeTextRange, text: String, truncated: Bool) {
        self.bufferID = bufferID
        self.range = range
        self.text = text
        self.truncated = truncated
    }

    package var isEmpty: Bool { text.isEmpty && !truncated }
}

/// What a code question is about (spec 2026-10-02 §9.2): the selection, or
/// the cursor line when nothing is selected (⌘I with no selection) — and
/// so the text "Suggest a change" replaces.
package struct CodeQuestionAnchor: Equatable, Sendable {
    package let path: String
    package let range: CodeTextRange
    /// The text in `range` when the question was asked; Apply needs it
    /// unchanged.
    package let originalText: String
    package let isSelection: Bool
    /// false for a selection the page cut at its limit.
    package let canApply: Bool

    package static func make(path: String, selection: CodeEditorSelection?, cursorLine: Int, fileText: String) -> Self {
        if let selection, !selection.isEmpty {
            return Self(path: path, range: selection.range, originalText: selection.text, isSelection: true,
                        canApply: !selection.truncated)
        }
        let lines = lineContents(fileText)
        let line = min(max(cursorLine, 1), max(lines.count, 1))
        let text = lines.isEmpty ? "" : lines[line - 1]
        return Self(path: path, range: CodeTextRange(startLine: line, startCol: 1, endLine: line, endCol: text.utf16.count + 1),
                    originalText: text, isSelection: false, canApply: true)
    }

    /// The anchor once `text` replaced it (Apply): the same start, the end
    /// moved to the end of `text` (UTF-16 columns), so a later suggestion
    /// in the conversation applies over the applied text.
    package func applied(_ text: String) -> Self {
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let endLine = range.startLine + lines.count - 1
        let lastWidth = lines.last?.utf16.count ?? 0
        let endCol = lines.count == 1 ? range.startCol + lastWidth : lastWidth + 1
        return Self(path: path, range: CodeTextRange(startLine: range.startLine, startCol: range.startCol,
                                                     endLine: endLine, endCol: endCol),
                    originalText: text, isSelection: isSelection, canApply: true)
    }

    /// The question's origin for `CodeQuestionContext` and `context_id`.
    package var origin: CodeQuestionOrigin {
        CodeQuestionOrigin(
            path: path, line: range.startLine,
            selection: isSelection ? CodeQuestionSelection(startLine: range.startLine, endLine: range.endLine,
                                                           text: originalText) : nil
        )
    }

    /// Why Apply may not run before the page is asked: the buffer's problem
    /// with the disk version (PROJ-03: conflict, deleted, unreadable), or a
    /// selection the page cut.
    package func applyRefusal(fileProblem: String?) -> CodeEditApplyRefusal? {
        if let fileProblem { return .fileProblem(fileProblem) }
        return canApply ? nil : .selectionTooLarge
    }

    /// The name "Where is it used?" searches (ruling R45): the selection
    /// when it is a single identifier, else the identifier at the cursor
    /// (`cursorCol` on the anchor's line, UTF-16, 1-based; a cursor right
    /// after a name names it); nil when there is none.
    package func usageName(cursorCol: Int?, fileText: String) -> String? {
        let selected = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSelection, selected.wholeMatch(of: Self.identifier) != nil { return selected }
        guard let cursorCol else { return nil }
        let lines = Self.lineContents(fileText)
        let line = isSelection ? range.endLine : range.startLine
        guard line >= 1, line <= lines.count else { return nil }
        let units = Array(lines[line - 1].utf16)
        func isPart(_ index: Int) -> Bool {
            guard index >= 0, index < units.count, let scalar = Unicode.Scalar(units[index]) else { return false }
            return scalar == "_" || (scalar.isASCII && CharacterSet.alphanumerics.contains(scalar))
        }
        var index = cursorCol - 1
        if !isPart(index) { index -= 1 }
        guard isPart(index) else { return nil }
        var start = index
        var end = index
        while isPart(start - 1) { start -= 1 }
        while isPart(end + 1) { end += 1 }
        let name = String(decoding: units[start...end], as: UTF16.self)
        return name.wholeMatch(of: Self.identifier) != nil ? name : nil
    }

    private static let identifier = #/[A-Za-z_][A-Za-z0-9_]*/#

    /// Lines without their line breaks; a trailing break ends the last line.
    private static func lineContents(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
        }
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}

/// The page's answer to `applyEdit`.
package enum CodeEditApplyResult: String, Sendable {
    case applied
    /// The text in the range is not the text of the question any more.
    case changed
    /// The file is not open in the editor.
    case missing
}

/// Why a suggested change was not applied.
package enum CodeEditApplyRefusal: Equatable, Sendable {
    case fileProblem(String)
    case selectionChanged
    case selectionTooLarge
    case editorClosed

    package init?(pageResult: CodeEditApplyResult) {
        switch pageResult {
        case .applied: return nil
        case .changed: self = .selectionChanged
        case .missing: self = .editorClosed
        }
    }

    package var message: String {
        switch self {
        case let .fileProblem(problem): "Not applied: \(problem) Resolve it in the editor first."
        case .selectionChanged: "Not applied: the selected code changed since the question. Ask again for a fresh suggestion."
        case .selectionTooLarge: "Not applied: the selection is too large to replace."
        case .editorClosed: "Not applied: the file is no longer open in the editor."
        }
    }
}

/// The popover's "Pin to inspector" (the Questions tab) and "Hand to Claude
/// Code" with ⌥⌘↩ (spec §9.5); a switch per action, so none ships dead
/// (ruling R35's rule).
package enum CodeQuestionActionsFeature {
    package static let pinToInspector = true
    package static let handToClaudeCode = true
}

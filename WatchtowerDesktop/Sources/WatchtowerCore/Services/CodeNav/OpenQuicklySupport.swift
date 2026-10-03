import Foundation

/// Double Shift opens Open Quickly (spec §8.1): two Shift key-downs within
/// 300 ms with no other key between. A pair fires once — a third Shift
/// starts a new pair.
package struct DoubleShiftDetector: Sendable {
    package static let interval: TimeInterval = 0.3

    private var lastShift: TimeInterval?

    package init() {}

    /// A Shift key went down with no other modifier held, at `time`
    /// (seconds, any monotonic clock). true = the second of a pair.
    package mutating func shiftPressed(at time: TimeInterval) -> Bool {
        // The epsilon keeps exactly 300 ms inside despite floating point.
        if let last = lastShift, time - last <= Self.interval + 1e-9 {
            lastShift = nil
            return true
        }
        lastShift = time
        return false
    }

    /// Any other key or modifier: the pair is broken.
    package mutating func otherKeyPressed() {
        lastShift = nil
    }
}

/// The files a workbench opened most recently, newest first, the last 50
/// (spec §7, ruling R22) — Open Quickly's "recently opened" boost.
/// Persisted per workbench under `key(workbenchID:)`.
package struct CodeRecentFiles: Equatable, Sendable {
    package static let cap = 50

    package private(set) var paths: [String]

    package init(paths: [String] = []) {
        self.paths = Array(paths.prefix(Self.cap))
    }

    package mutating func record(_ path: String) {
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > Self.cap { paths.removeLast(paths.count - Self.cap) }
    }

    /// Drops the files that are gone (`exists` false).
    package mutating func prune(keeping exists: (String) -> Bool) {
        paths = paths.filter(exists)
    }

    package static func key(workbenchID: Int64) -> String { "workbench.files.recent.\(workbenchID)" }
}

// MARK: - Theme colours

/// The colour roles navigation borrows from the editor theme (spec §2
/// decision 2).
package enum CodeTokenRole: Equatable, Sendable {
    case keyword, type, string, comment, number, variable
}

/// `wt-light` / `wt-dark` (CodeEditorWeb/languages.js), which inherit
/// Monaco's `vs` / `vs-dark`: their token colours as 0xRRGGBB.
package struct CodeThemePalette: Equatable, Sendable {
    package let foreground: UInt32
    package let background: UInt32
    private let keyword: UInt32
    private let type: UInt32
    private let string: UInt32
    private let comment: UInt32
    private let number: UInt32
    private let variable: UInt32

    package static let light = Self(
        foreground: 0x000000, background: 0xFFFFFE, keyword: 0x0000FF, type: 0x267F99,
        string: 0xA31515, comment: 0x008000, number: 0x098658, variable: 0x001080
    )
    package static let dark = Self(
        foreground: 0xD4D4D4, background: 0x1E1E1E, keyword: 0x569CD6, type: 0x4EC9B0,
        string: 0xCE9178, comment: 0x6A9955, number: 0xB5CEA8, variable: 0x9CDCFE
    )

    package func rgb(_ role: CodeTokenRole) -> UInt32 {
        switch role {
        case .keyword: keyword
        case .type: type
        case .string: string
        case .comment: comment
        case .number: number
        case .variable: variable
        }
    }
}

extension CodeSymbolKind {
    /// The kind badge's letter (spec §6.1): M method, F function, C class,
    /// S struct, E enum, P protocol/interface, T type alias, K const/var/
    /// field, N module; a macro shows `#`.
    package var badgeLetter: String {
        switch self {
        case .method: "M"
        case .function: "F"
        case .class: "C"
        case .struct: "S"
        case .enum: "E"
        case .protocol, .interface: "P"
        case .type: "T"
        case .const, .var, .field: "K"
        case .module: "N"
        case .macro: "#"
        }
    }

    /// The badge's colour: callables in the keyword colour, types (and
    /// modules) in the type colour, values in the variable colour.
    package var badgeRole: CodeTokenRole {
        switch self {
        case .method, .function, .macro: .keyword
        case .class, .struct, .enum, .protocol, .interface, .type, .module: .type
        case .const, .var, .field: .variable
        }
    }
}

// MARK: - Preview

/// One numbered line of the preview pane.
package struct OpenQuicklyPreviewLine: Equatable, Sendable {
    package let number: Int
    package let text: String

    package init(number: Int, text: String) {
        self.number = number
        self.text = text
    }
}

package enum OpenQuicklyPreviewText {
    /// Lines `from` (1-based) onward, at most `count` of them.
    package static func lines(of text: String, from start: Int, count: Int) -> [OpenQuicklyPreviewLine] {
        guard start >= 1, count > 0 else { return [] }
        var out: [OpenQuicklyPreviewLine] = []
        var number = 0
        text.enumerateLines { line, stop in
            number += 1
            guard number >= start else { return }
            out.append(OpenQuicklyPreviewLine(number: number, text: line))
            if out.count == count { stop = true }
        }
        return out
    }

    /// A text match with one line of context on each side.
    package static func around(_ match: CodeSearchMatch) -> [OpenQuicklyPreviewLine] {
        var out = match.before.suffix(1).map { OpenQuicklyPreviewLine(number: match.line - 1, text: $0) }
        out.append(OpenQuicklyPreviewLine(number: match.line, text: match.text))
        out += match.after.prefix(1).map { OpenQuicklyPreviewLine(number: match.line + 1, text: $0) }
        return out
    }
}

/// A light one-line tokenizer for the preview pane: keywords, strings,
/// numbers and comments in the editor theme's colours. Not a grammar — a
/// block comment or a string spanning lines is coloured per line only.
package enum CodePreviewHighlighter {
    package struct Token: Equatable, Sendable {
        /// UTF-16 offsets in the line.
        package let range: Range<Int>
        package let role: CodeTokenRole
    }

    private static let keywords: Set<String> = [
        "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "def", "default",
        "defer", "do", "elif", "else", "enum", "except", "export", "extension", "false", "final", "fn",
        "for", "from", "func", "function", "go", "guard", "if", "impl", "import", "in", "init", "interface",
        "internal", "is", "lambda", "let", "mut", "new", "nil", "None", "null", "override", "package",
        "private", "protocol", "pub", "public", "raise", "return", "self", "Self", "static", "struct",
        "switch", "this", "throw", "throws", "trait", "true", "True", "False", "try", "type", "typealias",
        "use", "var", "where", "while", "with", "yield",
    ]

    private static let hashCommentExtensions: Set<String> = [
        "py", "rb", "sh", "bash", "zsh", "yaml", "yml", "toml", "pl", "r", "mk", "cmake", "dockerfile",
    ]

    /// Whether `#` starts a comment in this file's language.
    package static func usesHashComments(path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return name == "makefile" || hashCommentExtensions.contains((name as NSString).pathExtension)
    }

    package static func tokens(_ line: String, hashComments: Bool) -> [Token] {
        let units = Array(line.utf16)
        var out: [Token] = []
        var i = 0
        while i < units.count {
            let unit = units[i]
            if isCommentStart(units, at: i, hash: hashComments) {
                out.append(Token(range: i ..< units.count, role: .comment))
                break
            }
            if unit == 0x22 || unit == 0x27 || unit == 0x60 { // " ' `
                let end = stringEnd(units, from: i)
                out.append(Token(range: i ..< end, role: .string))
                i = end
            } else if isDigit(unit), i == 0 || !isWordUnit(units[i - 1]) {
                var end = i + 1
                while end < units.count, isWordUnit(units[end]) || units[end] == 0x2E { end += 1 }
                out.append(Token(range: i ..< end, role: .number))
                i = end
            } else if isWordUnit(unit) {
                var end = i + 1
                while end < units.count, isWordUnit(units[end]) { end += 1 }
                let word = String(utf16CodeUnits: Array(units[i ..< end]), count: end - i)
                if keywords.contains(word), i == 0 || units[i - 1] != 0x2E { out.append(Token(range: i ..< end, role: .keyword)) }
                i = end
            } else {
                i += 1
            }
        }
        return out
    }

    private static func isCommentStart(_ units: [UInt16], at i: Int, hash: Bool) -> Bool {
        if hash, units[i] == 0x23 { return true } // #
        guard units[i] == 0x2F, i + 1 < units.count else { return false } // /
        return units[i + 1] == 0x2F || units[i + 1] == 0x2A // // or /*
    }

    /// Past the closing quote (a backslash escapes), or the line's end.
    private static func stringEnd(_ units: [UInt16], from start: Int) -> Int {
        let quote = units[start]
        var i = start + 1
        while i < units.count {
            if units[i] == 0x5C {
                i += 2
                continue
            }
            if units[i] == quote { return i + 1 }
            i += 1
        }
        return units.count
    }

    private static func isDigit(_ unit: UInt16) -> Bool {
        unit >= 0x30 && unit <= 0x39
    }

    private static func isWordUnit(_ unit: UInt16) -> Bool {
        isDigit(unit) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F
    }
}

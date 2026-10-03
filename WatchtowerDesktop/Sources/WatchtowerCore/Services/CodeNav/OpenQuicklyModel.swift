import Foundation

/// A place Open Quickly opens: a file, at a line for a symbol or a text
/// match (1-based; `col` is the UTF-16 column of the name or the match).
package struct OpenQuicklyTarget: Equatable, Sendable {
    package let path: String
    package let line: Int?
    package let col: Int?

    package init(path: String, line: Int?, col: Int?) {
        self.path = path
        self.line = line
        self.col = col
    }
}

package enum OpenQuicklySectionKind: Equatable, Hashable, Sendable {
    case bestMatch, symbols, files, text
    /// The last row of All: no header.
    case askAI

    package var title: String? {
        switch self {
        case .bestMatch: "Best match"
        case .symbols: "Symbols"
        case .files: "Files"
        case .text: "Text"
        case .askAI: nil
        }
    }
}

/// One row of the results list.
package enum OpenQuicklyRow: Equatable, Identifiable, Sendable {
    /// A file or a symbol from the index.
    case match(CodeQuickResult)
    /// A `code search` hit.
    case text(CodeSearchMatch)
    /// All's Text section holds 20 matches; this row switches to the Text
    /// scope, which shows them all.
    case moreText(hidden: Int)
    case askAI(query: String)

    package var id: String {
        switch self {
        case let .match(result): result.id
        case let .text(match): "text:\(match.path):\(match.line):\(match.col)"
        case .moreText: "more"
        case .askAI: "ask"
        }
    }

    /// What ↩ opens and Space previews; nil for the "more…" and Ask AI rows.
    package var target: OpenQuicklyTarget? {
        switch self {
        case let .match(result):
            switch result.item {
            case let .file(path): OpenQuicklyTarget(path: path, line: nil, col: nil)
            case let .symbol(symbol): OpenQuicklyTarget(path: symbol.path, line: symbol.line, col: symbol.col)
            }
        case let .text(match): OpenQuicklyTarget(path: match.path, line: match.line, col: match.col)
        case .moreText, .askAI: nil
        }
    }

    /// The text of the rows that are a fixed phrase.
    package var label: String? {
        switch self {
        case let .moreText(hidden): "\(hidden) more…"
        case let .askAI(query): "✦ Ask AI: \u{201C}\(query)\u{201D}"
        case .match, .text: nil
        }
    }
}

package struct OpenQuicklySection: Equatable, Identifiable, Sendable {
    package let kind: OpenQuicklySectionKind
    package let rows: [OpenQuicklyRow]

    package var id: OpenQuicklySectionKind { kind }
}

package enum OpenQuicklyArrow: Sendable {
    case up, down
}

/// What a Return asks for.
package enum OpenQuicklyCommand: Equatable, Sendable {
    case none
    /// ↩ a preview tab at the line; ⌥↩ (`beside`) in the other pane.
    case open(OpenQuicklyTarget, beside: Bool)
    /// ⌘↩ or the Ask AI row (spec §9.3).
    case askAI(String)
}

/// What Space does in the search field.
package enum OpenQuicklySpace: Equatable, Sendable {
    /// Typed into the query.
    case insertSpace
    /// Quick Look for this file (relative path), shown or hidden.
    case toggleQuickLook(String)
}

/// Where the Text scope's `code search` stands.
package enum OpenQuicklyTextStatus: Equatable, Sendable {
    /// No query.
    case idle
    case searching
    case finished(truncated: Bool)
    case failed(String)
}

/// Open Quickly's state (spec §8.1), pure: the query and scope, the index's
/// and `code search`'s answers, the sections built from them and the
/// selected row. The panel's view model feeds it; the view draws it.
package struct OpenQuicklyModel: Equatable, Sendable {
    /// All's Symbols and Files sections.
    package static let sectionCap = 8
    /// All's Text section, before "more…".
    package static let textCap = 20

    package private(set) var query = ""
    package private(set) var scope: CodeSearchScope
    package private(set) var files: [CodeQuickResult] = []
    package private(set) var symbols: [CodeQuickResult] = []
    package private(set) var textMatches: [CodeSearchMatch] = []
    package private(set) var textStatus: OpenQuicklyTextStatus = .idle
    /// nil = the first row.
    private var selectedID: String?
    /// The arrows moved the selection since the query last changed: Space
    /// then means Quick Look, not a space in the query.
    package private(set) var navigatedSinceEdit = false

    package init(scope: CodeSearchScope = .all) {
        self.scope = scope
    }

    package var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Input

    /// A new query: its index results and text matches are still to come,
    /// and the first row is selected.
    package mutating func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        files = []
        symbols = []
        textMatches = []
        textStatus = trimmedQuery.isEmpty ? .idle : .searching
        selectedID = nil
        navigatedSinceEdit = false
    }

    /// The query stays; the first row is selected.
    package mutating func setScope(_ newScope: CodeSearchScope) {
        guard newScope != scope else { return }
        scope = newScope
        selectedID = nil
    }

    /// The index's answer for the query (files and symbols ranked, best first).
    package mutating func setIndexResults(files: [CodeQuickResult], symbols: [CodeQuickResult]) {
        self.files = files
        self.symbols = symbols
        keepSelection()
    }

    package mutating func appendTextMatches(_ matches: [CodeSearchMatch]) {
        textMatches += matches
        keepSelection()
    }

    package enum TextOutcome: Equatable, Sendable {
        case finished(truncated: Bool)
        case failed(String)
    }

    package mutating func finishText(_ outcome: TextOutcome) {
        switch outcome {
        case let .finished(truncated): textStatus = .finished(truncated: truncated)
        case let .failed(message): textStatus = .failed(message)
        }
    }

    // MARK: Sections

    package var sections: [OpenQuicklySection] {
        let built: [OpenQuicklySection] = switch scope {
        case .all: allSections
        case .files: [OpenQuicklySection(kind: .files, rows: files.map(OpenQuicklyRow.match))]
        case .symbols: [OpenQuicklySection(kind: .symbols, rows: symbols.map(OpenQuicklyRow.match))]
        case .text: [OpenQuicklySection(kind: .text, rows: textMatches.map(OpenQuicklyRow.text))]
        }
        return built.filter { !$0.rows.isEmpty }
    }

    private var allSections: [OpenQuicklySection] {
        guard !trimmedQuery.isEmpty else {
            return [OpenQuicklySection(kind: .files, rows: files.prefix(Self.sectionCap).map(OpenQuicklyRow.match))]
        }
        let best = bestMatch
        let rest = { (results: [CodeQuickResult]) in
            results.filter { $0.id != best?.id }.prefix(Self.sectionCap).map(OpenQuicklyRow.match)
        }
        var text = textMatches.prefix(Self.textCap).map(OpenQuicklyRow.text)
        if textMatches.count > Self.textCap { text.append(.moreText(hidden: textMatches.count - Self.textCap)) }
        return [
            OpenQuicklySection(kind: .bestMatch, rows: best.map { [.match($0)] } ?? []),
            OpenQuicklySection(kind: .symbols, rows: rest(symbols)),
            OpenQuicklySection(kind: .files, rows: rest(files)),
            OpenQuicklySection(kind: .text, rows: text),
            OpenQuicklySection(kind: .askAI, rows: [.askAI(query: trimmedQuery)])
        ]
    }

    /// The better of the top file and the top symbol; a tie goes to the
    /// symbol (its score already carries the kind order).
    private var bestMatch: CodeQuickResult? {
        switch (files.first, symbols.first) {
        case let (file?, symbol?): file.score > symbol.score ? file : symbol
        case let (file, symbol): file ?? symbol
        }
    }

    package var rows: [OpenQuicklyRow] {
        sections.flatMap(\.rows)
    }

    // MARK: Selection

    package var selectedRow: OpenQuicklyRow? {
        let rows = rows
        return rows.first { $0.id == selectedID } ?? rows.first
    }

    /// A click or a hover.
    package mutating func select(_ id: String) {
        selectedID = id
    }

    /// One row up or down; the ends do not wrap.
    package mutating func move(_ arrow: OpenQuicklyArrow) {
        let rows = rows
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selectedRow?.id } ?? 0
        let next = arrow == .up ? max(0, current - 1) : min(rows.count - 1, current + 1)
        selectedID = rows[next].id
        navigatedSinceEdit = true
    }

    /// New rows: the selected one stays selected while it is still listed.
    private mutating func keepSelection() {
        if let id = selectedID, !rows.contains(where: { $0.id == id }) { selectedID = nil }
    }

    // MARK: Keys

    /// Return on the selected row; `option` = ⌥↩, `command` = ⌘↩. "more…"
    /// switches to the Text scope here and asks nothing of the caller.
    package mutating func activateSelection(option: Bool, command: Bool) -> OpenQuicklyCommand {
        if command { return trimmedQuery.isEmpty ? .none : .askAI(trimmedQuery) }
        switch selectedRow {
        case let .askAI(query)?:
            return .askAI(query)
        case .moreText?:
            setScope(.text)
            return .none
        case let row?:
            return row.target.map { .open($0, beside: option) } ?? .none
        case nil:
            return .none
        }
    }

    /// Space: Quick Look while the owner moves through the rows (or to close
    /// it), else a space in the query.
    package func spaceAction(quickLookShown: Bool) -> OpenQuicklySpace {
        guard quickLookShown || navigatedSinceEdit, let path = selectedRow?.target?.path else { return .insertSpace }
        return .toggleQuickLook(path)
    }
}

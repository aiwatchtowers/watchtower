import Foundation

/// One segment of the jump bar (spec §8.4).
package enum JumpBarSegment: Equatable, Sendable {
    /// `path` is relative to the workbench folder; "" = the folder itself.
    case folder(name: String, path: String)
    case file(path: String)
    case symbol(CodeSymbol)
}

/// The muted note at the end of the jump bar.
package enum JumpBarStatus: Equatable, Sendable {
    /// A language the index does not read: go to definition is a text
    /// search there (spec §6.5).
    case textSearch(language: String)
    /// The index failed: its message (spec §7).
    case indexFailed(String)
    /// The first full run has not reached this file yet.
    case indexing

    package var text: String {
        switch self {
        case let .textSearch(language): "Language \(language): text search"
        case let .indexFailed(message): message
        case .indexing: "Indexing…"
        }
    }
}

/// The owner's rules file was ignored (spec §6.5): "Rules file: <error>",
/// muted after the status. Shown on every file whenever set — once the
/// file failed to load, which extensions it was meant to cover is unknown.
package struct JumpBarRulesNote: Equatable, Sendable {
    /// The longest error the bar shows; the tooltip has all of it.
    package static let maxErrorLength = 80

    /// The bar's text: the error without its leading file path (the
    /// tooltip names it), whitespace collapsed, cut to `maxErrorLength`.
    package let text: String
    /// The tooltip: the whole error as the CLI reported it.
    package let help: String

    package init(error: String) {
        help = "Rules file: " + error
        var short = error.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // The CLI names the file first ("/…/code-languages.yaml: tcl: …").
        if short.hasPrefix("/"), let colon = short.range(of: ": "), !short[colon.upperBound...].isEmpty {
            short = String(short[colon.upperBound...])
        }
        if short.count > Self.maxErrorLength {
            short = short.prefix(Self.maxErrorLength - 1).trimmingCharacters(in: .whitespaces) + "…"
        }
        text = "Rules file: " + short
    }
}

/// The jump bar of the file on screen: folders › file › type › method at
/// the cursor, found in the index by line range (spec §8.4).
package struct JumpBarModel: Equatable, Sendable {
    package let path: String
    package let segments: [JumpBarSegment]
    package let status: JumpBarStatus?
    /// After the status, whatever it is (nil = the rules file is fine).
    package let rulesNote: JumpBarRulesNote?

    /// - Parameters:
    ///   - rootName: the workbench folder's name, the first segment.
    ///   - cursorLine: 1-based; nil = the page has not reported a cursor in
    ///     this file.
    ///   - symbols: the file's symbols from the index.
    ///   - language: as the index reported it ("" = one it does not read);
    ///     nil = the file is not in the index.
    ///   - rulesError: why the index ignored the owner's rules file.
    package init(
        path: String,
        rootName: String,
        cursorLine: Int?,
        symbols: [CodeSymbol],
        language: String?,
        state: CodeIndexState,
        rulesError: String? = nil
    ) {
        self.path = path
        let parts = path.split(separator: "/").map(String.init)
        var segments: [JumpBarSegment] = [.folder(name: rootName, path: "")]
        for depth in 0 ..< max(parts.count - 1, 0) {
            segments.append(.folder(name: parts[depth], path: parts[0 ... depth].joined(separator: "/")))
        }
        segments.append(.file(path: path))
        if let cursorLine {
            segments += JumpBarSymbolRow.chain(at: cursorLine, in: symbols).map(JumpBarSegment.symbol)
        }
        self.segments = segments
        status = Self.status(path: path, language: language, state: state)
        rulesNote = rulesError.map(JumpBarRulesNote.init(error:))
    }

    private static func status(path: String, language: String?, state: CodeIndexState) -> JumpBarStatus? {
        if case let .failed(message) = state { return .indexFailed(message) }
        switch (language, state) {
        case ("", _), (nil, .ready): return .textSearch(language: languageLabel(path))
        case (nil, .indexing): return .indexing
        default: return nil
        }
    }

    /// The file's extension in capitals, or its name when it has none.
    private static func languageLabel(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? name : ext.uppercased()
    }

    /// What the menu of segment `index` lists. The last segment lists the
    /// file's symbols (with a filter, as ⌃6 does) when it has any; a folder
    /// lists its subfolders and files, the file its siblings; a type the
    /// types beside it, any other symbol the members of its type.
    package func menuContent(forSegment index: Int, symbols: [CodeSymbol], files: [String]) -> JumpBarMenuContent? {
        guard segments.indices.contains(index) else { return nil }
        if index == segments.count - 1, !symbols.isEmpty {
            return .fileSymbols(JumpBarSymbolRow.rows(for: symbols))
        }
        switch segments[index] {
        case let .folder(_, folder):
            return .folder(JumpBarFolderListing(folder: folder, files: files))
        case let .file(file):
            let parent = (file as NSString).deletingLastPathComponent
            return .folder(JumpBarFolderListing(folder: parent, files: files))
        case let .symbol(symbol):
            var parent: CodeSymbol?
            if case let .symbol(above) = segments[index - 1] { parent = above }
            return .members(JumpBarSymbolRow.neighbours(of: symbol, parent: parent, in: symbols))
        }
    }
}

/// What a segment's menu lists.
package enum JumpBarMenuContent: Equatable, Sendable {
    case folder(JumpBarFolderListing)
    case members([CodeSymbol])
    /// Every symbol of the file, outline entries included, with a filter.
    case fileSymbols([JumpBarSymbolRow])
}

/// A folder's direct subfolders and files among the workbench's files,
/// each sorted the way Finder sorts names.
package struct JumpBarFolderListing: Equatable, Sendable {
    package let folder: String
    /// Relative paths.
    package let subfolders: [String]
    package let files: [String]

    package init(folder: String, files all: [String]) {
        self.folder = folder
        let prefix = folder.isEmpty ? "" : folder + "/"
        var subfolders = Set<String>()
        var files: [String] = []
        for path in all where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") {
                subfolders.insert(prefix + rest[..<slash])
            } else {
                files.append(path)
            }
        }
        let byName = { (a: String, b: String) in
            (a as NSString).lastPathComponent.localizedStandardCompare((b as NSString).lastPathComponent) == .orderedAscending
        }
        self.subfolders = subfolders.sorted(by: byName)
        self.files = files.sorted(by: byName)
    }
}

/// One row of the file's symbol list: the symbol and how deep it nests.
package struct JumpBarSymbolRow: Equatable, Sendable {
    package let symbol: CodeSymbol
    package let depth: Int

    package init(symbol: CodeSymbol, depth: Int) {
        self.symbol = symbol
        self.depth = depth
    }

    /// The filter field's test: the name contains the text, any case.
    package func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || symbol.name.localizedCaseInsensitiveContains(trimmed)
    }

    /// Every symbol of the file by line, outer before inner, with its depth.
    package static func rows(for symbols: [CodeSymbol]) -> [Self] {
        nested(symbols).map { Self(symbol: $0.symbol, depth: $0.depth) }
    }

    /// The symbols the cursor's line is in, outermost first. Outline
    /// entries (headings, config keys) are left out — unless the file has
    /// nothing else (Markdown), and then only the nearest one counts.
    static func chain(at line: Int, in symbols: [CodeSymbol]) -> [CodeSymbol] {
        let code = symbols.filter { !$0.outline }
        var chain: [CodeSymbol] = []
        for symbol in byRange(code.isEmpty ? symbols : code) where symbol.line <= line && line <= symbol.endLine {
            if chain.last.map({ contains($0, symbol) }) ?? true { chain.append(symbol) }
        }
        if code.isEmpty, let nearest = chain.last { return [nearest] }
        return chain
    }

    /// The symbols directly in `parent` (nil = at the top of the file): the
    /// types among them for a type, all of them for anything else. Outline
    /// entries are left out.
    static func neighbours(of symbol: CodeSymbol, parent: CodeSymbol?, in symbols: [CodeSymbol]) -> [CodeSymbol] {
        let siblings = nested(symbols.filter { !$0.outline }).filter { $0.parent == parent }.map(\.symbol)
        return symbol.kind.isType ? siblings.filter(\.kind.isType) : siblings
    }

    /// One pass over the symbols by range: each one's depth and the
    /// innermost symbol strictly containing it.
    private static func nested(_ symbols: [CodeSymbol]) -> [(symbol: CodeSymbol, depth: Int, parent: CodeSymbol?)] {
        var stack: [CodeSymbol] = []
        return byRange(symbols).map { symbol in
            while let top = stack.last, !contains(top, symbol) { stack.removeLast() }
            defer { stack.append(symbol) }
            return (symbol, stack.count, stack.last)
        }
    }

    /// By first line, the wider range first; ties keep their order.
    private static func byRange(_ symbols: [CodeSymbol]) -> [CodeSymbol] {
        let sorted = symbols.enumerated().sorted { a, b in
            (a.element.line, -a.element.endLine, a.offset) < (b.element.line, -b.element.endLine, b.offset)
        }
        return sorted.map(\.element)
    }

    /// `outer`'s lines hold `inner`'s and are more: an equal range is a
    /// sibling (`var a, b` on one line), not a parent.
    private static func contains(_ outer: CodeSymbol, _ inner: CodeSymbol) -> Bool {
        outer.line <= inner.line && inner.endLine <= outer.endLine && (outer.line, outer.endLine) != (inner.line, inner.endLine)
    }
}

/// The file's save state, as the line above the editor has always said it.
package enum JumpBarSaveState: Equatable, Sendable {
    case notSaved, deleted, edited, saved

    /// - Parameter hasError: a save problem or a failed write.
    package init(hasError: Bool, deletedOnDisk: Bool, isDirty: Bool) {
        self = hasError ? .notSaved : deletedOnDisk ? .deleted : isDirty ? .edited : .saved
    }

    package var text: String {
        switch self {
        case .notSaved: "Not saved"
        case .deleted: "Deleted"
        case .edited: "Edited"
        case .saved: "Saved"
        }
    }
}

extension CodeSymbolKind {
    /// A type: its jump bar menu lists the types beside it.
    package var isType: Bool { rankGroup == 2 }
}

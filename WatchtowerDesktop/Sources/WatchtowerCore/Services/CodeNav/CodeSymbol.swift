import Foundation

/// A symbol's kind — the closed set of `watchtower code index` (spec §6.1).
/// A line carrying any other kind is malformed (the Go side drops captures
/// that map to none of these).
package enum CodeSymbolKind: String, Codable, CaseIterable, Sendable {
    case function, method, `class`, `struct`, `enum`, `protocol`, interface, type, const, `var`, field, module, macro

    /// Open Quickly's order among equally good matches: types, then
    /// callables, then the rest (spec §7).
    package var rankGroup: Int {
        switch self {
        case .class, .struct, .enum, .protocol, .interface, .type: 2
        case .method, .function: 1
        case .const, .var, .field, .module, .macro: 0
        }
    }
}

/// One definition from `watchtower code index` — the Swift mirror of the
/// Go `codeindex.Symbol` (spec §6.1). Lines are 1-based; `col` is the
/// 1-based UTF-16 column of the name.
package struct CodeSymbol: Codable, Equatable, Hashable, Sendable {
    package let name: String
    package let kind: CodeSymbolKind
    /// Relative to the workbench folder, as the CLI was asked for it.
    package let path: String
    package let line: Int
    package let col: Int
    package let endLine: Int
    /// The nearest enclosing type or module, "" at top level.
    package let container: String
    package let signature: String
    package let doc: String
    package let lang: String
    /// A document-outline entry (Markdown heading, config key): the jump
    /// bar shows it, Open Quickly's Symbols scope does not.
    package let outline: Bool

    package init(
        name: String,
        kind: CodeSymbolKind,
        path: String,
        line: Int,
        col: Int,
        endLine: Int,
        container: String = "",
        signature: String = "",
        doc: String = "",
        lang: String = "",
        outline: Bool = false
    ) {
        self.name = name
        self.kind = kind
        self.path = path
        self.line = line
        self.col = col
        self.endLine = endLine
        self.container = container
        self.signature = signature
        self.doc = doc
        self.lang = lang
        self.outline = outline
    }

    private enum CodingKeys: String, CodingKey {
        case name, kind, path, line, col, container, signature, doc, lang, outline
        case endLine = "end_line"
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(CodeSymbolKind.self, forKey: .kind)
        path = try c.decode(String.self, forKey: .path)
        line = try c.decode(Int.self, forKey: .line)
        col = try c.decode(Int.self, forKey: .col)
        endLine = try c.decode(Int.self, forKey: .endLine)
        container = try c.decode(String.self, forKey: .container)
        signature = try c.decode(String.self, forKey: .signature)
        doc = try c.decode(String.self, forKey: .doc)
        lang = try c.decode(String.self, forKey: .lang)
        // `outline,omitempty` on the Go side: absent means false.
        outline = try c.decodeIfPresent(Bool.self, forKey: .outline) ?? false
    }
}

/// Where a workbench's index stands. `total` is the file count of the
/// previous full run (0 before the first one finished: not known yet).
package enum CodeIndexState: Equatable, Sendable {
    case idle
    case indexing(done: Int, total: Int)
    case ready
    case failed(String)
}

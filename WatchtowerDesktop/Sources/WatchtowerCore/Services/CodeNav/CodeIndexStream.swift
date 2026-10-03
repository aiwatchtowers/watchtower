import Foundation

// The JSON-line streams of `watchtower code index` (spec §6.2) and
// `watchtower code search` (spec §5), decoded off the main actor as the
// child's output arrives.

/// One file of an index run. `lang` "" = a language the CLI does not
/// index. `skipped` (ruling R21): a path asked for by name that is not a
/// workbench file — git-ignored, binary, over 2 MB, outside the folder, a
/// directory, unreadable.
package struct CodeIndexFileResult: Equatable, Sendable {
    package let file: String
    package let lang: String
    package let symbols: [CodeSymbol]
    package let skipped: Bool

    package init(file: String, lang: String, symbols: [CodeSymbol], skipped: Bool = false) {
        self.file = file
        self.lang = lang
        self.symbols = symbols
        self.skipped = skipped
    }
}

/// The last line of a finished index run.
package struct CodeIndexDone: Equatable, Sendable {
    package let files: Int
    package let symbols: Int
    package let ms: Int

    package init(files: Int, symbols: Int, ms: Int) {
        self.files = files
        self.symbols = symbols
        self.ms = ms
    }
}

/// A line of `code index`: told apart by `done` first — its `symbols` is a
/// count, a file line's is a list.
package enum CodeIndexLine: Decodable, Equatable, Sendable {
    case file(CodeIndexFileResult)
    /// A path asked for by name that is no longer there (echoed verbatim).
    case deleted(String)
    case done(CodeIndexDone)

    /// The run's last line.
    package var isDone: Bool {
        if case .done = self { return true }
        return false
    }

    private enum CodingKeys: String, CodingKey {
        case done, files, symbols, ms, file, lang, deleted, skipped
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decodeIfPresent(Bool.self, forKey: .done) == true {
            self = try .done(CodeIndexDone(
                files: c.decode(Int.self, forKey: .files),
                symbols: c.decode(Int.self, forKey: .symbols),
                ms: c.decode(Int.self, forKey: .ms)
            ))
            return
        }
        let file = try c.decode(String.self, forKey: .file)
        if try c.decodeIfPresent(Bool.self, forKey: .deleted) == true {
            self = .deleted(file)
            return
        }
        self = try .file(CodeIndexFileResult(
            file: file,
            lang: c.decode(String.self, forKey: .lang),
            symbols: c.decode([CodeSymbol].self, forKey: .symbols),
            // `skipped,omitempty` on the Go side: absent means false.
            skipped: c.decodeIfPresent(Bool.self, forKey: .skipped) ?? false
        ))
    }
}

/// One hit of `code search`: `col` is the match's 1-based UTF-16 column in
/// the full line, `textCol` its column inside `text` (cut to 400 chars).
package struct CodeSearchMatch: Decodable, Equatable, Sendable {
    package let path: String
    package let line: Int
    package let col: Int
    package let text: String
    package let textCol: Int
    package let before: [String]
    package let after: [String]

    package init(path: String, line: Int, col: Int, text: String, textCol: Int, before: [String], after: [String]) {
        self.path = path
        self.line = line
        self.col = col
        self.text = text
        self.textCol = textCol
        self.before = before
        self.after = after
    }

    private enum CodingKeys: String, CodingKey {
        case path, line, col, text, before, after
        case textCol = "text_col"
    }
}

/// The last line of a search that ran to its end. `files` = files searched.
package struct CodeSearchDone: Equatable, Sendable {
    package let files: Int
    package let matches: Int
    /// `--max` stopped the search.
    package let truncated: Bool

    package init(files: Int, matches: Int, truncated: Bool) {
        self.files = files
        self.matches = matches
        self.truncated = truncated
    }
}

package enum CodeSearchLine: Decodable, Equatable, Sendable {
    case match(CodeSearchMatch)
    case done(CodeSearchDone)

    private enum CodingKeys: String, CodingKey {
        case done, files, matches, truncated
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decodeIfPresent(Bool.self, forKey: .done) == true else {
            self = try .match(CodeSearchMatch(from: decoder))
            return
        }
        self = try .done(CodeSearchDone(
            files: c.decode(Int.self, forKey: .files),
            matches: c.decode(Int.self, forKey: .matches),
            truncated: c.decode(Bool.self, forKey: .truncated)
        ))
    }
}

/// Frames a child's stdout on `\n` and decodes each line as `Line`. A line
/// that does not decode is skipped and counted (never a crash, never the
/// end of the stream); a blank line is neither.
package struct CodeJSONLineDecoder<Line: Decodable> {
    private var splitter = NDJSONLineSplitter()
    private let decoder = JSONDecoder()
    package private(set) var malformedCount = 0
    /// The first bad line, cut to 200 characters, for the log.
    package private(set) var firstMalformed: String?

    package init() {}

    package mutating func feed(_ data: Data) -> [Line] {
        splitter.append(data).compactMap { decodeLine($0) }
    }

    /// EOF: the unterminated tail, if it decodes.
    package mutating func finish() -> [Line] {
        splitter.finish().flatMap { decodeLine($0) }.map { [$0] } ?? []
    }

    private mutating func decodeLine(_ text: String) -> Line? {
        guard !text.allSatisfy(\.isWhitespace) else { return nil }
        do {
            return try decoder.decode(Line.self, from: Data(text.utf8))
        } catch {
            malformedCount += 1
            if firstMalformed == nil { firstMalformed = String(text.prefix(200)) }
            return nil
        }
    }
}

/// `watchtower code search` flags (spec §5).
package struct CodeSearchOptions: Equatable, Sendable {
    package var query: String
    package var word = false
    /// Off = smart case (case-insensitive unless the query has an upper-case letter).
    package var caseSensitive = false
    package var regex = false
    package var max = 2000
    package var context = 2

    package init(query: String, word: Bool = false, caseSensitive: Bool = false, regex: Bool = false, max: Int = 2000, context: Int = 2) {
        self.query = query
        self.word = word
        self.caseSensitive = caseSensitive
        self.regex = regex
        self.max = max
        self.context = context
    }

    /// The CLI arguments. The query rides `--query=` so one starting with
    /// `-` is never read as a flag.
    package func arguments(folder: String) -> [String] {
        var args = ["code", "search", "--folder", folder, "--query=\(query)"]
        if word { args.append("--word") }
        if caseSensitive { args.append("--case") }
        if regex { args.append("--regex") }
        args += ["--max", String(max), "--context", String(context), "--json"]
        return args
    }
}

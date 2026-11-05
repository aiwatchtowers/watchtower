import XCTest

/// LLMTRANSPORT-01 — a consumer decides by capability, never by transport
/// identity. The Swift twin of the Go guard in `internal/transporttest`:
/// it scans `WatchtowerDesktop/Sources` and `WatchtowerKit/Sources` for
/// `== "claude"`-style literals, `.claude`/`.codex`/`.ollama` comparisons
/// or cases (the Kit's `.claudeCode`/`.codexCLI` too) and array-literal
/// `.contains` membership tests. Every hit today is listed in
/// `Fixtures/llmtransport_allow_swift.txt`, keyed by file and enclosing
/// function, with its reason; the list only shrinks, and a new entry needs
/// the owner's approval.
final class LLMTransportGuardTests: XCTestCase {
    /// BEHAVIOR LLMTRANSPORT-01 — see docs/inventory/llm-transport.md
    func testLLMTRANSPORT01NoProviderNamesInConsumers() throws {
        let hits = try Self.repoHits()
        let allow = try Self.readAllow()
        for key in hits.keys.sorted() {
            let count = hits[key] ?? 0
            let allowed = allow[key]?.count ?? 0
            XCTAssertLessThanOrEqual(
                count, allowed,
                "\(key): \(count) provider name check(s), baseline allows \(allowed). Decide by a capability "
                    + "from `ai models --json`; a new baseline entry needs the owner's approval (LLMTRANSPORT-01)"
            )
        }
    }

    /// BEHAVIOR LLMTRANSPORT-01 — see docs/inventory/llm-transport.md
    func testLLMTRANSPORT01BaselineOnlyShrinks() throws {
        let hits = try Self.repoHits()
        for (key, entry) in try Self.readAllow() {
            let remaining = hits[key] ?? 0
            XCTAssertGreaterThanOrEqual(
                remaining, entry.count,
                "\(key) (line \(entry.line)) allows \(entry.count) hit(s) but \(remaining) remain: "
                    + "lower the count or delete the entry, the baseline only shrinks"
            )
        }
    }

    func testLLMTRANSPORT01CatchesANewNameCheck() {
        let source = """
        // if provider == "claude" { } is a comment, not a check
        /* provider == "codex" in a block comment
           is not a check either */
        func pick(provider: String, kind: AgentKind) {
            if provider == "codex" { useTools() }
            guard "ollama" != name else { return }
            if kind == .claude || kind != AgentKind.codex { }
            switch provider {
            case .ollama, .codex: break
            case "claude": break
            case AgentKind.claude,
                 .codex:
                break
            case .other: return provider == "ollama"
            default: break
            }
            if case .codex = kind { }
            let url = "https://example.com" // == "claude" after a URL is a comment
            let label = "claude"
            let other = provider == "openai"
            let known = ["claude", "openai"].contains(provider)
        }
        enum Provider: String {
            case claude = "claude"
        }
        var isCodex: Bool {
            kind == .codexCLI
        }
        """
        let got = Self.hits(in: source, file: "X.swift")
        let want: [String: Int] = [
            #"X.swift | pick | "codex""#: 1,
            #"X.swift | pick | "ollama""#: 2,
            #"X.swift | pick | "claude""#: 2,
            "X.swift | pick | .claude": 2,
            "X.swift | pick | .codex": 4,
            "X.swift | pick | .ollama": 1,
            "X.swift | var isCodex | .codexCLI": 1
        ]
        XCTAssertEqual(got, want)
    }

    // MARK: - Checker

    private static let literals = "claude|codex|ollama"
    private static let cases = "claude|codex|ollama|claudeCode|codexCLI"
    private static let enumCase = #"(?:\b[A-Z]\w*(?:\.[A-Z]\w*)*)?\.(\#(cases))\b"#

    // A comparison against a literal or an enum case, either side.
    // swiftlint:disable:next force_try
    private static let comparison = try! NSRegularExpression(
        pattern: #"[=!]=\s*(?:"(\#(literals))"|\#(enumCase))|(?:"(\#(literals))"|\#(enumCase))\s*[=!]="#
    )
    // A literal or an enum case in a `case` pattern (switch, `if case`).
    // swiftlint:disable:next force_try
    private static let caseItem = try! NSRegularExpression(
        pattern: #""(\#(literals))"|(?<![\w.])\#(enumCase)"#
    )
    // An array literal tested with `.contains(`.
    // swiftlint:disable:next force_try
    private static let membership = try! NSRegularExpression(pattern: #"\[[^\[\]]*\]\s*\.contains\("#)
    // The declaration a hit belongs to: a function, an init or a computed var.
    // swiftlint:disable:next force_try
    private static let declaration = try! NSRegularExpression(
        pattern: #"\bfunc\s+([A-Za-z_]\w*)|(?<![\w.])(init)[?!]?\s*[(<]"#
            + #"|^\s*(?:[\w@()]+\s+)*var\s+([A-Za-z_]\w*)\s*:[^=]*\{\s*$"#
    )

    /// Returns "<file> | <func> | <what>" → count for one source file.
    private static func hits(in source: String, file: String) -> [String: Int] {
        var out: [String: Int] = [:]
        var lexer = Lexer()
        var scopes = ScopeStack()
        var inCaseHead = false
        for raw in source.components(separatedBy: "\n") {
            let (line, delta) = lexer.code(raw)
            scopes.enter(declarationName(in: line), depth: lexer.depth - delta)
            for what in matches(in: line, inCaseHead: &inCaseHead) {
                out["\(file) | \(scopes.current) | \(what)", default: 0] += 1
            }
            scopes.leave(depth: lexer.depth)
        }
        return out
    }

    private static func declarationName(in line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = declaration.firstMatch(in: line, range: range) else { return nil }
        for group in 1...3 {
            if let found = Range(match.range(at: group), in: line) {
                return group == 3 ? "var \(line[found])" : String(line[found])
            }
        }
        return nil
    }

    private static func matches(in line: String, inCaseHead: inout Bool) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // `case claude = "claude"` declares a raw value; it compares nothing.
        if trimmed.range(of: #"^case \w+\s*="#, options: .regularExpression) != nil { return [] }
        if trimmed.hasPrefix("case ") || inCaseHead {
            // A case head runs to its `:`, possibly over several lines; the
            // rest of the line is the case body.
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            inCaseHead = parts.count == 1 && trimmed.hasSuffix(",")
            var found = tokens(caseItem, in: String(parts[0]), literalGroups: [1])
            if parts.count == 2 {
                found += comparisons(in: String(parts[1]))
            }
            return found
        }
        if trimmed.range(of: #"\b(if|guard|while|for) case "#, options: .regularExpression) != nil {
            return tokens(caseItem, in: line, literalGroups: [1])
        }
        return comparisons(in: line)
    }

    private static func comparisons(in line: String) -> [String] {
        var found = tokens(comparison, in: line, literalGroups: [1, 3])
        for match in membership.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            guard let list = Range(match.range, in: line) else { continue }
            found += tokens(caseItem, in: String(line[list]), literalGroups: [1])
        }
        return found
    }

    /// Every match of `regex`, named `"claude"` (literal) or `.claude` (enum case).
    private static func tokens(_ regex: NSRegularExpression, in line: String, literalGroups: Set<Int>) -> [String] {
        regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).map { match in
            for group in 1..<match.numberOfRanges {
                guard let range = Range(match.range(at: group), in: line) else { continue }
                return literalGroups.contains(group) ? "\"\(line[range])\"" : ".\(line[range])"
            }
            return "?"
        }
    }

    /// Strips comments (line and block, across lines) and tracks the brace
    /// depth outside string literals.
    private struct Lexer {
        var inBlock = false
        var depth = 0

        /// Returns the line without comments and its brace depth change.
        mutating func code(_ line: String) -> (String, Int) {
            var out = ""
            var inString = false
            var escaped = false
            let start = depth
            let chars = Array(line)
            var index = 0
            while index < chars.count {
                let char = chars[index]
                let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
                if inBlock {
                    if char == "*" && next == "/" { inBlock = false; index += 1 }
                } else if inString {
                    out.append(char)
                    if escaped {
                        escaped = false
                    } else if char == "\\" {
                        escaped = true
                    } else if char == "\"" {
                        inString = false
                    }
                } else if char == "/" && next == "/" {
                    break
                } else if char == "/" && next == "*" {
                    inBlock = true
                    index += 1
                } else {
                    out.append(char)
                    if char == "\"" { inString = true }
                    if char == "{" { depth += 1 }
                    if char == "}" { depth -= 1 }
                }
                index += 1
            }
            return (out, depth - start)
        }
    }

    /// The enclosing declarations; a hit belongs to the innermost one.
    private struct ScopeStack {
        private var stack: [(name: String, depth: Int, opened: Bool)] = []

        var current: String { stack.last?.name ?? "-" }

        /// Pushes a declaration seen at `depth` (the depth before its line);
        /// a body-less one (a protocol requirement) before it is dropped.
        mutating func enter(_ name: String?, depth: Int) {
            guard let name else { return }
            while let last = stack.last, !last.opened, last.depth >= depth { stack.removeLast() }
            stack.append((name, depth, false))
        }

        /// Pops the declarations whose bodies closed by `depth`.
        mutating func leave(depth: Int) {
            if let last = stack.last, depth > last.depth { stack[stack.count - 1].opened = true }
            while let last = stack.last, last.opened, depth <= last.depth { stack.removeLast() }
        }
    }

    // MARK: - Repository

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repository root
    }

    /// The file that declares which capabilities each agent kind has: the
    /// only place outside the decoders where a kind maps to its caps.
    private static let capabilityFiles: Set<String> = [
        "WatchtowerDesktop/Sources/WatchtowerCore/Models/AgentSessionCaps.swift"
    ]

    nonisolated(unsafe) private static var cachedHits: [String: Int]?

    /// Scans both source trees once per test run.
    private static func repoHits() throws -> [String: Int] {
        if let cachedHits { return cachedHits }
        for file in capabilityFiles {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(file).path),
                "\(file) is allowlisted as a capability file but does not exist"
            )
        }
        var out: [String: Int] = [:]
        for dir in ["WatchtowerDesktop/Sources", "WatchtowerKit/Sources"] {
            let files = try swiftFiles(in: dir)
            XCTAssertFalse(files.isEmpty, "\(dir) has no Swift files: the guard would pass vacuously")
            for url in files {
                let rel = String(url.standardizedFileURL.path.dropFirst(repoRoot.standardizedFileURL.path.count + 1))
                if capabilityFiles.contains(rel) { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                out.merge(hits(in: text, file: rel)) { $0 + $1 }
            }
        }
        cachedHits = out
        return out
    }

    private static func swiftFiles(in dir: String) throws -> [URL] {
        let base = repoRoot.appendingPathComponent(dir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: base.path])
        }
        var walkError: Error?
        let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) { _, error in
            walkError = error
            return false
        }
        var out: [URL] = []
        while let url = walker?.nextObject() as? URL {
            if url.pathExtension == "swift" { out.append(url) }
        }
        if let walkError { throw walkError }
        return out
    }

    private struct AllowEntry {
        let count: Int
        let line: Int
    }

    /// "<file> | <func> | <what> | <count> | <reason>" per line; `#` lines
    /// and blank lines are skipped. A missing reason, a bad count or a
    /// duplicate key fails.
    private static func readAllow() throws -> [String: AllowEntry] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/llmtransport_allow_swift.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [String: AllowEntry] = [:]
        for (offset, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.components(separatedBy: " | ")
            let reason = parts.dropFirst(4).joined(separator: " | ").trimmingCharacters(in: .whitespaces)
            guard parts.count >= 5, let count = Int(parts[3]), count > 0, !reason.isEmpty else {
                XCTFail("llmtransport_allow_swift.txt:\(offset + 1): want \"<file> | <func> | <what> | <count> | <reason>\"")
                continue
            }
            let key = parts[0...2].joined(separator: " | ")
            XCTAssertNil(out[key], "\(key) is listed twice")
            out[key] = AllowEntry(count: count, line: offset + 1)
        }
        return out
    }
}

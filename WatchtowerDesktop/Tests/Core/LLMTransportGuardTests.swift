import XCTest

/// LLMTRANSPORT-01 — a consumer decides by capability, never by transport
/// identity. The Swift twin of the Go guard in `internal/transporttest`:
/// it scans `WatchtowerDesktop/Sources` and `WatchtowerKit/Sources` for
/// `== "claude"`-style literals and `.claude`/`.codex`/`.ollama` comparisons
/// or cases. Every hit today is listed in
/// `Fixtures/llmtransport_allow_swift.txt` with its reason; the list only
/// shrinks, and a new entry needs the owner's approval.
final class LLMTransportGuardTests: XCTestCase {
    /// BEHAVIOR LLMTRANSPORT-01 — see docs/inventory/llm-transport.md
    func testLLMTRANSPORT01NoProviderNamesInConsumers() throws {
        let hits = try Self.scanSources()
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
        let hits = try Self.scanSources()
        for (key, entry) in try Self.readAllow() {
            XCTAssertFalse(entry.reason.isEmpty, "\(key) (line \(entry.line)) has no reason")
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
        if provider == "codex" { useTools() }
        guard "ollama" != name else { return }
        if kind == .claude || kind != AgentKind.codex { }
        switch provider {
        case .ollama, .codex: break
        case "claude": break
        default: break
        }
        if case .codex = kind { }
        let url = "https://example.com" // == "claude" after a URL is a comment
        let label = "claude"
        enum Provider: String {
            case claude = "claude"
        }
        let other = provider == "openai"
        """
        let got = Self.hits(in: source, file: "X.swift")
        let want: [String: Int] = [
            #"X.swift | "codex""#: 1,
            #"X.swift | "ollama""#: 1,
            #"X.swift | "claude""#: 1,
            "X.swift | .claude": 1,
            "X.swift | .codex": 3,
            "X.swift | .ollama": 1
        ]
        XCTAssertEqual(got, want)
    }

    // MARK: - Checker

    private static let names = "claude|codex|ollama"

    /// A comparison against a literal or an enum case, either side.
    private static let comparison = try? NSRegularExpression(
        pattern: #"[=!]=\s*(?:"(\#(names))"|\w*\.(\#(names))\b)|(?:"(\#(names))"|\.(\#(names))\b)\s*[=!]="#
    )
    /// A literal or an enum case in a `case` pattern (switch, `if case`).
    private static let caseItem = try? NSRegularExpression(
        pattern: #""(\#(names))"|(?<![\w.])\.(\#(names))\b"#
    )

    /// Returns "<file> | <what>" → count for one source file.
    static func hits(in source: String, file: String) -> [String: Int] {
        var out: [String: Int] = [:]
        for raw in source.components(separatedBy: "\n") {
            let line = stripComment(raw)
            for what in matches(in: line) {
                out["\(file) | \(what)", default: 0] += 1
            }
        }
        return out
    }

    private static func matches(in line: String) -> [String] {
        let range = NSRange(line.startIndex..., in: line)
        var found: [String] = []
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // `case claude = "claude"` declares a raw value; it compares nothing.
        if trimmed.range(of: #"^case \w+\s*="#, options: .regularExpression) != nil { return found }
        let isCase = trimmed.hasPrefix("case ")
            || trimmed.range(of: #"\b(if|guard|while|for) case "#, options: .regularExpression) != nil
        if isCase, let regex = caseItem {
            let head = trimmed.hasPrefix("case ") ? String(line.split(separator: ":", maxSplits: 1).first ?? "") : line
            let headRange = NSRange(head.startIndex..., in: head)
            for match in regex.matches(in: head, range: headRange) {
                found.append(token(match, in: head, literalGroups: [1]))
            }
            return found
        }
        guard let regex = comparison else { return found }
        for match in regex.matches(in: line, range: range) {
            found.append(token(match, in: line, literalGroups: [1, 3]))
        }
        return found
    }

    /// The matched name as `"claude"` (literal) or `.claude` (enum case).
    private static func token(_ match: NSTextCheckingResult, in line: String, literalGroups: Set<Int>) -> String {
        for group in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: group), in: line) else { continue }
            let name = String(line[range])
            return literalGroups.contains(group) ? "\"\(name)\"" : ".\(name)"
        }
        return "?"
    }

    /// Drops a `//` comment that is not inside a string literal.
    private static func stripComment(_ line: String) -> String {
        var inString = false
        var previous: Character = " "
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if char == "\"" && previous != "\\" {
                inString.toggle()
            } else if !inString && char == "/" && previous == "/" {
                return String(line[..<line.index(before: index)])
            }
            previous = char
            index = line.index(after: index)
        }
        return line
    }

    // MARK: - Repository

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repository root
    }

    private static func scanSources() throws -> [String: Int] {
        var out: [String: Int] = [:]
        for dir in ["WatchtowerDesktop/Sources", "WatchtowerKit/Sources"] {
            let base = repoRoot.appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
                XCTFail("cannot walk \(dir)")
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let rel = String(url.standardizedFileURL.path.dropFirst(repoRoot.standardizedFileURL.path.count + 1))
                let text = try String(contentsOf: url, encoding: .utf8)
                out.merge(hits(in: text, file: rel)) { $0 + $1 }
            }
        }
        return out
    }

    struct AllowEntry {
        let count: Int
        let reason: String
        let line: Int
    }

    /// "<file> | <what> | <count> | <reason>" per line; `#` lines and blank
    /// lines are skipped.
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
            guard parts.count >= 4, let count = Int(parts[2]), count > 0 else {
                XCTFail("llmtransport_allow_swift.txt:\(offset + 1): want \"<file> | <what> | <count> | <reason>\"")
                continue
            }
            let key = "\(parts[0]) | \(parts[1])"
            XCTAssertNil(out[key], "\(key) is listed twice")
            out[key] = AllowEntry(count: count, reason: parts[3...].joined(separator: " | "), line: offset + 1)
        }
        return out
    }
}

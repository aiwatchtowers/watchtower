import Foundation
import XCTest

/// PROJ-17 (board #1716, spec 2026-11-10-auto-cleanup-on-session-delete §4):
/// a row the owner deleted (`delete_requested_at` set) leaves every list
/// while its background cleanup runs. The Swift twin of Go's
/// `TestProj17_DeletingRowsLeaveEveryList` (`internal/db/deleting_rows_guard_test.go`).
///
/// A read unit is one SQL string under `WatchtowerDesktop/Sources`: a string
/// literal (one-line or `"""`) together with the literals `+` joins to it.
/// It reads `terminal_sessions` when, with a write's target table taken out
/// (`UPDATE`, `INSERT INTO`, `DELETE FROM terminal_sessions`), it still names
/// the table (never a `terminal_sessions_*` table) and has `SELECT`, `FROM`
/// or `JOIN` anywhere — comma joins and split literals included. It is
/// filtered when it carries `delete_requested_at IS NULL` once per mention
/// of the table, so a unit with two reads needs both filtered. A GRDB
/// query-interface read of `TerminalSession` (`TerminalSession.filter`,
/// `.all()`, `.fetchAll(db)` …) counts as an unfiltered read. Every
/// unfiltered read is on the allowlist with its exact count per function.
final class SwiftDeletingRowsGuardTests: XCTestCase {
    private struct Allowed {
        let count: Int
        let why: String
    }

    /// Key: "<path under WatchtowerDesktop/Sources>:<function>".
    private static let allowlist: [String: Allowed] = [
        "WatchtowerCore/Database/Queries/TerminalSessionQueries.swift:fetch":
            Allowed(count: 1, why: "one row by id"),
        "WatchtowerCore/Database/Queries/TerminalSessionQueries.swift:goStartRow":
            Allowed(count: 1, why: "one row by id: a start's failure and notice"),
        "WatchtowerCore/Database/Queries/TerminalSessionQueries.swift:isFinished":
            Allowed(count: 1, why: "one row by id"),
        "WatchtowerCore/Database/Queries/TerminalSessionQueries.swift:fetchCleanupRecord":
            Allowed(count: 1, why: "one row's cleanup result by id: a Not fully cleaned row's report reads it"),
        "WatchtowerCore/Database/Queries/TerminalSessionQueries.swift:fetchDeleting":
            Allowed(count: 2, why: "reads exactly the deleting rows: the background cleanup and the Not fully cleaned rows"),
        "WatchtowerCore/Database/Queries/AutomationQueries.swift:disownUnattachedSessions":
            Allowed(count: 1, why: "clears the run marker on every unattached row, deleting ones too, so a Resume never makes one adoptable")
    ]

    func testProj17_SwiftDeletingRowsLeaveEveryList() throws {
        var unfiltered: [String: Int] = [:]
        var reads = 0
        for url in try Self.swiftFiles() {
            let rel = String(url.standardizedFileURL.path.dropFirst(Self.sourcesRoot.standardizedFileURL.path.count + 1))
            for read in try Self.reads(in: String(contentsOf: url, encoding: .utf8)) {
                reads += 1
                if !read.filtered { unfiltered["\(rel):\(read.function)", default: 0] += 1 }
            }
        }
        XCTAssertGreaterThanOrEqual(reads, 17, "the scan found too few reads of terminal_sessions: it would pass vacuously")
        for (key, count) in unfiltered.sorted(by: { $0.key < $1.key }) {
            guard let allowed = Self.allowlist[key] else {
                XCTFail("\(key) reads terminal_sessions without `delete_requested_at IS NULL`: filter the deleting rows "
                    + "or, for a by-id lookup, add it to the allowlist with its reason and count")
                continue
            }
            XCTAssertEqual(count, allowed.count, "\(key): \(count) unfiltered reads, the allowlist says \(allowed.count) (\(allowed.why))")
        }
        for key in Self.allowlist.keys where unfiltered[key] == nil {
            XCTFail("\(key) is allowlisted but has no unfiltered read: drop it from the allowlist")
        }
    }

    // MARK: - The scanner on fixtures

    func testScannerAttributesUnitsToTheirFunction() throws {
        let source = #"""
        // SELECT * FROM terminal_sessions in a comment
        func one() {
            let sql = """
                SELECT * FROM terminal_sessions
                WHERE delete_requested_at IS NULL
                """
        }
        func two() { db.execute(sql: "SELECT id FROM terminal_sessions WHERE id = ?") }
        """#
        let reads = try Self.reads(in: source)
        XCTAssertEqual(reads.map(\.function), ["one", "two"])
        XCTAssertEqual(reads.map(\.filtered), [true, false])
    }

    func testSplitLiteralsAreOneUnit() throws {
        let source = #"""
        func split() {
            let sql = "SELECT * FROM " +
                "terminal_sessions WHERE id = ?"
            let ok = "SELECT * FROM terminal_sessions"
                + " WHERE delete_requested_at IS NULL"
        }
        """#
        XCTAssertEqual(try Self.reads(in: source).map(\.filtered), [false, true])
    }

    func testCommaJoinIsARead() throws {
        let source = #"""
        func comma() { _ = "SELECT p.name FROM projects p, terminal_sessions s WHERE s.project_id = p.id" }
        """#
        XCTAssertEqual(try Self.reads(in: source).map(\.filtered), [false])
    }

    func testEveryReadOfAUnitMustBeFiltered() throws {
        let source = #"""
        func twice() {
            _ = """
                SELECT * FROM terminal_sessions WHERE delete_requested_at IS NULL
                UNION SELECT * FROM terminal_sessions WHERE id = ?
                """
        }
        """#
        XCTAssertEqual(try Self.reads(in: source).map(\.filtered), [false], "one filter for two reads")
    }

    func testWritesAndOtherTablesAreNotReads() throws {
        let source = #"""
        func writes() {
            _ = "UPDATE terminal_sessions SET title = ? WHERE id = ?"
            _ = "DELETE FROM terminal_sessions WHERE id = ?"
            _ = "SELECT 1 FROM terminal_session_worktrees WHERE session_id = ?"
            _ = "UPDATE terminal_sessions SET x = 1 WHERE id IN (SELECT id FROM terminal_sessions)"
        }
        """#
        XCTAssertEqual(try Self.reads(in: source).map(\.filtered), [false], "only the subquery is a read")
    }

    func testQueryInterfaceReadIsUnfiltered() throws {
        let source = #"""
        func grdb() throws { _ = try TerminalSession.filter(Column("project_id") == 1).fetchAll(db) }
        """#
        XCTAssertEqual(try Self.reads(in: source).map(\.filtered), [false])
    }

    // MARK: - Scanner

    struct Read {
        let function: String
        let filtered: Bool
    }

    private struct Literal {
        let text: String
        let start: String.Index
        let end: String.Index
        let function: String
    }

    private static let tableWord = #"\bterminal_sessions\b"#
    private static let writeTarget = #"(?i)\b(UPDATE|INSERT\s+(OR\s+\w+\s+)?INTO|DELETE\s+FROM)\s+terminal_sessions\b"#
    private static let readWord = #"(?i)\b(SELECT|FROM|JOIN)\b"#
    private static let filter = #"(?i)\bdelete_requested_at\s+IS\s+NULL\b"#
    private static let queryInterface = #"\bTerminalSession\s*\.\s*(filter|all\s*\(|order|select|including|fetchCount|"#
        + #"fetchAll\s*\(\s*(db|\$0)\s*\)|fetchOne\s*\(\s*(db|\$0)\s*,\s*(key|id)\s*:)"#

    /// Every read unit of `source` (see the type's comment), in order.
    static func reads(in source: String) throws -> [Read] {
        let table = try NSRegularExpression(pattern: tableWord)
        let write = try NSRegularExpression(pattern: writeTarget)
        let read = try NSRegularExpression(pattern: readWord)
        let filter = try NSRegularExpression(pattern: filter)
        var out: [Read] = []
        for unit in try units(in: source) {
            let rest = write.stringByReplacingMatches(
                in: unit.text, range: NSRange(unit.text.startIndex..., in: unit.text), withTemplate: ""
            )
            let tables = count(table, rest)
            guard tables > 0, count(read, rest) > 0 else { continue }
            out.append(Read(function: unit.function, filtered: count(filter, unit.text) >= tables))
        }
        let grdb = try NSRegularExpression(pattern: queryInterface)
        for (function, line) in try codeLines(in: source) where count(grdb, line) > 0 {
            out.append(Read(function: function, filtered: false))
        }
        return out
    }

    /// The literals of `source` joined into units: two literals with only
    /// whitespace and one `+` between them are one unit.
    private static func units(in source: String) throws -> [Literal] {
        var units: [Literal] = []
        for literal in try literals(in: source) {
            if let last = units.last, last.function == literal.function,
               source[last.end..<literal.start].trimmingCharacters(in: .whitespacesAndNewlines) == "+" {
                units[units.count - 1] = Literal(
                    text: last.text + literal.text, start: last.start, end: literal.end, function: last.function
                )
            } else {
                units.append(literal)
            }
        }
        return units
    }

    /// Every string literal of `source` with the function declared last
    /// above it ("-" before any): a `"""` block is one literal, each quoted
    /// run on another line is one. Lines starting with `//` are skipped.
    private static func literals(in source: String) throws -> [Literal] {
        let funcRe = try NSRegularExpression(pattern: #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        let literalRe = try NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)
        var out: [Literal] = []
        var function = "-"
        var block: (text: [String], start: String.Index)?
        var lineStart = source.startIndex
        while lineStart < source.endIndex {
            let lineEnd = source[lineStart...].firstIndex(of: "\n") ?? source.endIndex
            let line = String(source[lineStart..<lineEnd])
            defer { lineStart = lineEnd < source.endIndex ? source.index(after: lineEnd) : source.endIndex }
            let quotes = line.components(separatedBy: "\"\"\"").count - 1
            if let open = block {
                if quotes % 2 == 1 {
                    let text = (open.text + [line]).joined(separator: "\n")
                    out.append(Literal(text: text, start: open.start, end: closingEnd(of: line, from: lineStart, in: source), function: function))
                    block = nil
                } else {
                    block = (open.text + [line], open.start)
                }
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            if let name = firstGroup(funcRe, line) { function = name }
            if quotes % 2 == 1 {
                let offset = line.range(of: "\"\"\"").map { line.distance(from: line.startIndex, to: $0.lowerBound) } ?? 0
                block = ([line], source.index(lineStart, offsetBy: offset))
                continue
            }
            for match in literalRe.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let range = Range(match.range, in: line) else { continue }
                let start = source.index(lineStart, offsetBy: line.distance(from: line.startIndex, to: range.lowerBound))
                let end = source.index(lineStart, offsetBy: line.distance(from: line.startIndex, to: range.upperBound))
                out.append(Literal(text: String(line[range]), start: start, end: end, function: function))
            }
        }
        return out
    }

    /// Where a closing `"""` line's literal ends in `source`.
    private static func closingEnd(of line: String, from lineStart: String.Index, in source: String) -> String.Index {
        guard let range = line.range(of: "\"\"\"", options: .backwards) else { return lineStart }
        return source.index(lineStart, offsetBy: line.distance(from: line.startIndex, to: range.upperBound))
    }

    /// The code lines of `source` (outside `"""` blocks and `//` lines) with
    /// their function.
    private static func codeLines(in source: String) throws -> [(String, String)] {
        let funcRe = try NSRegularExpression(pattern: #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        var out: [(String, String)] = []
        var function = "-"
        var inBlock = false
        for line in source.components(separatedBy: "\n") {
            let quotes = line.components(separatedBy: "\"\"\"").count - 1
            if inBlock {
                if quotes % 2 == 1 { inBlock = false }
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            if let name = firstGroup(funcRe, line) { function = name }
            if quotes % 2 == 1 { inBlock = true }
            out.append((function, line))
        }
        return out
    }

    private static func count(_ regex: NSRegularExpression, _ text: String) -> Int {
        regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func firstGroup(_ regex: NSRegularExpression, _ text: String) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .appendingPathComponent("Sources")
    }

    private static func swiftFiles() throws -> [URL] {
        var walkError: Error?
        let walker = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil) { _, error in
            walkError = error
            return false
        }
        var out: [URL] = []
        while let url = walker?.nextObject() as? URL {
            if url.pathExtension == "swift" { out.append(url) }
        }
        if let walkError { throw walkError }
        XCTAssertFalse(out.isEmpty, "no Swift files under \(sourcesRoot.path)")
        return out
    }
}

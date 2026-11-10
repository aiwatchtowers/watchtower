import Foundation
import XCTest

/// PROJ-17 (board #1716, spec 2026-11-10-auto-cleanup-on-session-delete §4):
/// a row the owner deleted (`delete_requested_at` set) leaves every list
/// while its background cleanup runs. The Swift twin of Go's
/// `TestProj17_DeletingRowsLeaveEveryList` (`internal/db/deleting_rows_guard_test.go`):
/// every string literal under `WatchtowerDesktop/Sources` that reads
/// `terminal_sessions` (`FROM` or `JOIN`) filters the deleting rows out
/// (`delete_requested_at IS NULL`) or is a by-id lookup or a write listed
/// below, with the exact number of unfiltered literals of its function.
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
        "WatchtowerCore/Database/Queries/TerminalSessionQueries.swift:delete":
            Allowed(count: 1, why: "the DELETE statement itself"),
        "WatchtowerCore/Database/Queries/TerminalSessionQueries.swift:fetchDeleting":
            Allowed(count: 2, why: "reads exactly the deleting rows: the background cleanup and the Not fully cleaned rows"),
        "WatchtowerCore/Database/Queries/AutomationQueries.swift:disownUnattachedSessions":
            Allowed(count: 1, why: "clears the run marker on every unattached row, deleting ones too, so a Resume never makes one adoptable")
    ]

    private static let readPattern = #"(?i)\b(FROM|JOIN)\s+terminal_sessions\b"#
    private static let filterPattern = #"(?i)\bdelete_requested_at\s+IS\s+NULL\b"#
    private static let funcPattern = #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#
    private static let literalPattern = #""(?:[^"\\]|\\.)*""#

    func testProj17_SwiftDeletingRowsLeaveEveryList() throws {
        let (readRe, filterRe) = try (NSRegularExpression(pattern: Self.readPattern), NSRegularExpression(pattern: Self.filterPattern))
        var unfiltered: [String: Int] = [:]
        var reads = 0
        for url in try Self.swiftFiles() {
            let rel = String(url.standardizedFileURL.path.dropFirst(Self.sourcesRoot.standardizedFileURL.path.count + 1))
            for literal in try Self.literals(in: String(contentsOf: url, encoding: .utf8))
            where Self.matches(readRe, literal.text) {
                reads += 1
                if Self.matches(filterRe, literal.text) { continue }
                unfiltered["\(rel):\(literal.function)", default: 0] += 1
            }
        }
        XCTAssertGreaterThanOrEqual(reads, 18, "the scan found too few reads of terminal_sessions: it would pass vacuously")
        for (key, count) in unfiltered.sorted(by: { $0.key < $1.key }) {
            guard let allowed = Self.allowlist[key] else {
                XCTFail("\(key) reads terminal_sessions without `delete_requested_at IS NULL`: filter the deleting rows "
                    + "or, for a by-id lookup or a write, add it to the allowlist with its reason")
                continue
            }
            XCTAssertEqual(count, allowed.count, "\(key): \(count) unfiltered reads, the allowlist says \(allowed.count) (\(allowed.why))")
        }
        for key in Self.allowlist.keys where unfiltered[key] == nil {
            XCTFail("\(key) is allowlisted but has no unfiltered read: drop it from the allowlist")
        }
    }

    /// The scanner itself: a multi-line literal and a one-line literal are
    /// each one unit, attributed to the function above them; comments are
    /// not literals.
    func testScannerAttributesLiteralsToTheirFunction() throws {
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
        let (readRe, filterRe) = try (NSRegularExpression(pattern: Self.readPattern), NSRegularExpression(pattern: Self.filterPattern))
        let units = try Self.literals(in: source).filter { Self.matches(readRe, $0.text) }
        XCTAssertEqual(units.map(\.function), ["one", "two"])
        XCTAssertEqual(units.map { Self.matches(filterRe, $0.text) }, [true, false])
    }

    // MARK: - Scanner

    private struct Literal {
        let text: String
        let function: String
    }

    /// Every string literal of `source` with the function declared last
    /// above it ("-" before any): a `"""` block is one literal, and each
    /// quoted run on another line is one. Lines starting with `//` are skipped.
    private static func literals(in source: String) throws -> [Literal] {
        let funcRe = try NSRegularExpression(pattern: funcPattern)
        let literalRe = try NSRegularExpression(pattern: literalPattern)
        var out: [Literal] = []
        var function = "-"
        var block: [String]?
        for line in source.components(separatedBy: "\n") {
            let quotes = line.components(separatedBy: "\"\"\"").count - 1
            if var open = block {
                open.append(line)
                if quotes % 2 == 1 {
                    out.append(Literal(text: open.joined(separator: "\n"), function: function))
                    block = nil
                } else {
                    block = open
                }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            if let name = firstGroup(funcRe, line) { function = name }
            if quotes % 2 == 1 {
                block = [line]
                continue
            }
            let range = NSRange(line.startIndex..., in: line)
            for match in literalRe.matches(in: line, range: range) {
                guard let text = Range(match.range, in: line) else { continue }
                out.append(Literal(text: String(line[text]), function: function))
            }
        }
        return out
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
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

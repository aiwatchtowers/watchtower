import XCTest

/// Mobile Inbox spec §5.2 (stage 1, #1170 Task 12): the Inbox's and the
/// other screens' tables are written only by Go — every Desktop press is a
/// tower command (`TowerClient.act`). This scans every Swift source of the
/// Desktop for a SQL write to a moved table, an `UPDATE targets` that sets
/// `status`, and a GRDB record write on a moved table's record type.
final class MovedTablesWriteGuardTests: XCTestCase {
    /// The tables only Go writes.
    static let movedTables = ["automation_outputs", "briefings", "inbox_items", "tracks", "track_events", "ideas",
                              "reminders", "day_plan_items", "digests", "decision_reads", "stream_digests",
                              "catchup_recaps"]

    /// The columns only Go writes on a table Swift still writes otherwise.
    static let movedColumns = ["targets.status"]

    /// The moved tables' record types.
    static let recordTypes = ["Idea", "Track", "Reminder", "DayPlanItem", "InboxItem", "Briefing",
                              "AutomationOutput", "Digest"]

    /// One SQL write: `INSERT [OR …] INTO`, `REPLACE INTO`, `UPDATE` or
    /// `DELETE FROM` a moved table, any case, across line breaks.
    static let sqlWrite = try? NSRegularExpression(
        pattern: #"\b(?:INSERT(?:\s+OR\s+\w+)?\s+INTO|REPLACE\s+INTO|UPDATE|DELETE\s+FROM)\s+(?:"#
            + movedTables.joined(separator: "|") + #")\b"#,
        options: [.caseInsensitive])

    /// An `UPDATE <table> SET …` naming a moved column before its `WHERE`
    /// (or the statement's end).
    static let columnWrites: [NSRegularExpression] = movedColumns.compactMap { qualified in
        let parts = qualified.split(separator: ".").map(String.init)
        guard parts.count == 2 else { return nil }
        return try? NSRegularExpression(
            pattern: #"\bUPDATE\s+"# + parts[0] + #"\s+SET\b(?:(?!\bWHERE\b)[^";])*?\b"# + parts[1] + #"\s*="#,
            options: [.caseInsensitive])
    }

    /// A GRDB record write on a moved table's record type.
    static let recordWrite = try? NSRegularExpression(
        pattern: #"\b(?:"# + recordTypes.joined(separator: "|")
            + #")\b[^\n;]*?\.(?:insert|update|save|delete|upsert|updateAll|deleteAll|insertAndFetch)\s*\(\s*db\b"#)

    /// The writes `text` holds, as "file:line statement".
    static func writes(in text: String, file: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        let regexes = ([sqlWrite, recordWrite] + columnWrites.map(Optional.some)).compactMap { $0 }
        var found: [String] = []
        for regex in regexes {
            for match in regex.matches(in: text, range: range) {
                guard let span = Range(match.range, in: text) else { continue }
                let lineEnd = text[span.lowerBound...].firstIndex(of: "\n") ?? text.endIndex
                let statement = text[span.lowerBound..<lineEnd].trimmingCharacters(in: .whitespaces)
                let line = text[..<span.lowerBound].filter { $0 == "\n" }.count + 1
                found.append("\(file):\(line) \(statement)")
            }
        }
        return found
    }

    func testNoSwiftWriteToAMovedTable() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sources = tests.deletingLastPathComponent().appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            offenders += Self.writes(in: text, file: url.lastPathComponent)
        }
        XCTAssertTrue(offenders.isEmpty, "Swift writes a table Go owns (send its tower command instead):\n"
                      + offenders.sorted().joined(separator: "\n"))
    }

    /// Pins the matcher on every form it must catch, and on look-alikes it must not.
    func testTheMatcherCatchesEveryForm() {
        let caught = [
            #"try db.execute(sql: "INSERT INTO ideas (title) VALUES (?)")"#,
            #"try db.execute(sql: "insert or replace into decision_reads (a) VALUES (?)")"#,
            #"try db.execute(sql: "INSERT OR IGNORE INTO day_plan_items (a) VALUES (1)")"#,
            #"try db.execute(sql: "REPLACE INTO reminders (a) VALUES (1)")"#,
            "try db.execute(sql: \"\"\"\n    UPDATE\n    automation_outputs SET read_at = ?\n    \"\"\")",
            #"try db.execute(sql: "delete from tracks WHERE id = ?")"#,
            #"try db.execute(sql: "UPDATE track_events SET read_at = 1")"#,
            #"try db.execute(sql: "UPDATE catchup_recaps SET acknowledged_at = 1")"#,
            #"try db.execute(sql: "UPDATE stream_digests SET read_at = 1")"#,
            #"try db.execute(sql: "DELETE FROM briefings")"#,
            #"try db.execute(sql: "UPDATE inbox_items SET read_at = 1")"#,
            #"try db.execute(sql: "UPDATE digests SET read_at = 1")"#,
            #"try db.execute(sql: "UPDATE targets SET status = ? WHERE id = ?")"#,
            "try db.execute(sql: \"\"\"\n    UPDATE targets SET snooze_until = ?,\n    status = 'snoozed'\n    WHERE id = ?\n\"\"\")",
            #"try db.execute(sql: "update targets set priority = ?, status='done' where id = 1")"#,
            "try Idea(id: 1).insert(db)",
            "try Reminder.deleteAll(db)",
            "try Track.filter(key: 1).updateAll(db, [])",
            "try DayPlanItem.save(db)",
            "try record.save(db) // AutomationOutput\nAutomationOutput.update(db"
        ]
        for sample in caught {
            XCTAssertFalse(Self.writes(in: sample, file: "X.swift").isEmpty, sample)
        }
        let ignored = [
            #"try String.fetchAll(db, sql: "SELECT title FROM ideas")"#,
            #"SELECT id, status FROM tracks WHERE updated_at > ?"#,
            #"try db.execute(sql: "UPDATE targets SET priority = ? WHERE status = 'todo'")"#,
            #"try db.execute(sql: "UPDATE targets SET status_actor = 'owner' WHERE id = ?")"#,
            #"try db.execute(sql: "UPDATE ideas_archive SET x = 1")"#,
            #"try db.execute(sql: "UPDATE chat_messages SET text = ?")"#,
            "try Idea.fetchOne(db, sql: \"SELECT * FROM ideas\")",
            "try IdeaMention.deleteAll(db)"
        ]
        for sample in ignored {
            XCTAssertTrue(Self.writes(in: sample, file: "X.swift").isEmpty, sample)
        }
    }
}

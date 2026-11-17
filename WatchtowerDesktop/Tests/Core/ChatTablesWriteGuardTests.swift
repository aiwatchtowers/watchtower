import XCTest

/// Mobile Inbox spec §8 (stage 3): no Swift code writes a chat table any
/// more — a turn's rows are written by `ai session --persist` / `ai query
/// --persist`, every other chat write is a `chat.*` tower command. This
/// scans every Swift source of the Desktop for a SQL write to a `chat_*`
/// table and for a GRDB record write on a chat record type.
final class ChatTablesWriteGuardTests: XCTestCase {
    /// The chat tables' record types.
    static let recordTypes = ["ChatConversation", "ChatMessageRecord", "ChatAttachment", "ChatProject",
                              "ChatProjectSource", "ChatArtifact", "ArtifactComment", "ChatLease", "ChatTurnStep",
                              "ChatPanelRow"]

    /// One SQL write: `INSERT [OR …] INTO`, `REPLACE INTO`, `UPDATE` or
    /// `DELETE FROM` a `chat_*` table, any case, across line breaks.
    static let sqlWrite = try? NSRegularExpression(
        pattern: #"\b(?:INSERT(?:\s+OR\s+\w+)?\s+INTO|REPLACE\s+INTO|UPDATE|DELETE\s+FROM)\s+(chat_[a-z_]+)"#,
        options: [.caseInsensitive])

    /// A GRDB record write on a chat record type.
    static let recordWrite = try? NSRegularExpression(
        pattern: #"\b(?:"# + recordTypes.joined(separator: "|")
            + #")\b[^\n;]*?\.(?:insert|update|save|delete|upsert|updateAll|deleteAll|insertAndFetch)\s*\(\s*db\b"#)

    /// Left for #1170 Task 12: `IdeaQueries.delete` deletes an idea's Discuss
    /// chat with it until Go's `ideas.delete` takes it over; exactly these
    /// two statements are allowed until then.
    static let allowed: Set<String> = [
        "IdeaQueries.swift: DELETE FROM chat_messages WHERE conversation_id = ?",
        "IdeaQueries.swift: DELETE FROM chat_conversations WHERE id = ?"
    ]

    /// The writes `text` holds: "file: statement" (from the verb to its
    /// line's end, quotes and arguments dropped) and "file:line".
    static func writes(in text: String, file: String) -> [(key: String, at: String)] {
        let range = NSRange(text.startIndex..., in: text)
        var found: [(String, String)] = []
        let regexes = [sqlWrite, recordWrite].compactMap { $0 }
        for regex in regexes {
            for match in regex.matches(in: text, range: range) {
                guard let span = Range(match.range, in: text) else { continue }
                let lineEnd = text[span.lowerBound...].firstIndex(of: "\n") ?? text.endIndex
                let unquoted = text[span.lowerBound..<lineEnd].replacingOccurrences(of: "\"", with: "")
                let statement = unquoted.components(separatedBy: ", arguments").first?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                let line = text[..<span.lowerBound].filter { $0 == "\n" }.count + 1
                found.append(("\(file): \(statement)", "\(file):\(line)"))
            }
        }
        return found
    }

    func testNoSwiftWriteToAChatTable() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sources = tests.deletingLastPathComponent().appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var allowedSeen: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for write in Self.writes(in: text, file: url.lastPathComponent) {
                if Self.allowed.contains(write.key) {
                    allowedSeen.insert(write.key)
                } else {
                    offenders.append("\(write.at) \(write.key)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "Swift writes a chat table (send a chat.* command instead):\n"
                      + offenders.sorted().joined(separator: "\n"))
        XCTAssertTrue(allowedSeen.isSubset(of: Self.allowed))
    }

    /// Pins the matcher on every form it must catch, and on look-alikes it must not.
    func testTheMatcherCatchesEveryForm() {
        let caught = [
            #"try db.execute(sql: "INSERT INTO chat_messages (text) VALUES (?)")"#,
            #"try db.execute(sql: "insert or replace into chat_queued_drafts (k) VALUES (?)")"#,
            #"try db.execute(sql: "INSERT OR IGNORE INTO chat_turn_leases (a) VALUES (1)")"#,
            #"try db.execute(sql: "REPLACE INTO chat_artifacts (a) VALUES (1)")"#,
            "try db.execute(sql: \"\"\"\n    UPDATE\n    chat_conversations SET pinned = 1\n    \"\"\")",
            #"try db.execute(sql: "delete from chat_project_sources WHERE id = ?")"#,
            "try ChatConversation(id: 1).insert(db)",
            "try ChatMessageRecord.deleteAll(db)",
            "try ChatProject.filter(key: 1).updateAll(db, [])",
            "try record.save(db) // ChatArtifact\nChatArtifact.update(db"
        ]
        for sample in caught {
            XCTAssertFalse(Self.writes(in: sample, file: "X.swift").isEmpty, sample)
        }
        let ignored = [
            #"try String.fetchAll(db, sql: "SELECT text FROM chat_messages")"#,
            #"SELECT id, context_id, updated_at FROM chat_conversations"#,
            #"try db.execute(sql: "UPDATE ideas SET chat_born = 1")"#,
            "try ChatConversation.fetchOne(db, sql: \"SELECT * FROM chat_conversations\")",
            "try Idea.deleteAll(db)"
        ]
        for sample in ignored {
            XCTAssertTrue(Self.writes(in: sample, file: "X.swift").isEmpty, sample)
        }
    }
}

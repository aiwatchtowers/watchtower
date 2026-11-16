import Foundation
import GRDB
import WatchtowerCore
import WatchtowerTestSupport
import XCTest

/// One writer per Inbox write: the Go writers behind `inbox.act`
/// (`internal/db/inbox_writes.go`) and their Swift twins leave the same rows
/// over the shared fixture `internal/inboxfeed/testdata/inbox_writes.json`
/// (Go runs it in `TestInboxWritesCases`). Each case with a `swift` entry
/// seeds a database, runs the named Swift writer and compares `expect.rows`
/// (`"*"` is any non-empty value, `null` a NULL). The Swift side is deleted
/// with the Swift writers; the fixture stays as the Go golden.
final class InboxWritesFixtureTests: XCTestCase {
    /// …/internal/inboxfeed/testdata, from …/WatchtowerDesktop/Tests/Core/<this file>.
    private static let testdata = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // …/Core
        .deletingLastPathComponent()  // …/Tests
        .deletingLastPathComponent()  // …/WatchtowerDesktop
        .deletingLastPathComponent()  // the repository
        .appendingPathComponent("internal/inboxfeed/testdata")

    private struct WriteCase: Decodable {
        let name: String
        let seed: [String]
        let now: String
        let swift: SwiftWriter?
        let expect: Expect
    }

    private struct SwiftWriter: Decodable {
        let writer: String
        let args: Args
    }

    private struct Args: Decodable {
        let id: Int64?
        let ids: [Int]?
        let contentHash: String?
        let now: String?
        let status: String?
        let until: String?
        let cascade: Bool

        enum CodingKeys: String, CodingKey { case id, ids, contentHash, now, status, until, cascade }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(Int64.self, forKey: .id)
            ids = try c.decodeIfPresent([Int].self, forKey: .ids)
            contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash)
            now = try c.decodeIfPresent(String.self, forKey: .now)
            status = try c.decodeIfPresent(String.self, forKey: .status)
            until = try c.decodeIfPresent(String.self, forKey: .until)
            cascade = try c.decodeIfPresent(Bool.self, forKey: .cascade) ?? false
        }
    }

    private struct Expect: Decodable {
        let rows: [String: [[String: Cell]]]
    }

    /// A fixture cell: a string, a number, a bool or null.
    private enum Cell: Decodable, CustomStringConvertible {
        case text(String), number(Int64), null

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() {
                self = .null
            } else if let b = try? c.decode(Bool.self) {
                self = .number(b ? 1 : 0)
            } else if let n = try? c.decode(Int64.self) {
                self = .number(n)
            } else {
                self = .text(try c.decode(String.self))
            }
        }

        var description: String {
            switch self {
            case let .text(s): return "\"\(s)\""
            case let .number(n): return String(n)
            case .null: return "null"
            }
        }

        func matches(_ value: DatabaseValue) -> Bool {
            switch (self, value.storage) {
            case (.null, .null): return true
            case let (.text("*"), .string(s)): return !s.isEmpty
            case let (.text(w), .string(s)): return w == s
            case let (.number(w), .int64(n)): return w == n
            default: return false
            }
        }
    }

    func testSwiftWritersMatchEveryGoCase() throws {
        let data = try Data(contentsOf: Self.testdata.appendingPathComponent("inbox_writes.json"))
        let cases = try JSONDecoder().decode([WriteCase].self, from: data)
        let swiftCases = cases.filter { $0.swift != nil }
        XCTAssertGreaterThanOrEqual(swiftCases.count, 20)
        for item in swiftCases {
            guard let writer = item.swift else { continue }
            let queue = try TestDatabase.create()
            try queue.write { db in
                for statement in item.seed { try db.execute(sql: statement) }
                try Self.run(writer, db: db, now: item.now, name: item.name)
            }
            try queue.read { db in
                for (table, rows) in item.expect.rows.sorted(by: { $0.key < $1.key }) {
                    try Self.assertRows(db, table: table, want: rows, name: item.name)
                }
            }
        }
    }

    private static func run(_ w: SwiftWriter, db: Database, now: String, name: String) throws {
        let a = w.args
        let id = a.id ?? 0
        let date = AutomationDates.parse(a.now ?? now) ?? Date()
        if try runOutputWriter(w.writer, db: db, id: id, hash: a.contentHash ?? "", now: date) { return }
        switch w.writer {
        case "BriefingQueries.markRead":
            try BriefingQueries.markRead(db, ids: a.ids ?? [])
        case "InboxQueries.markRead":
            try InboxQueries.markRead(db, id: Int(id))
        case "TrackDone":
            // ActionStripViewModel.markTrackDone's one write.
            try TrackQueries.markRead(db, id: Int(id))
            try TrackEventQueries.markAllRead(db, trackId: Int(id))
        case "TrackQueries.dismiss":
            try TrackQueries.dismiss(db, id: Int(id))
        case "TrackQueries.restore":
            try TrackQueries.restore(db, id: Int(id))
        case "CustomStop":
            // DirectCustomTrackControls.stopWatching's one write.
            try TrackQueries.setEnabled(db, id: Int(id), enabled: false)
            try TrackQueries.dismiss(db, id: Int(id))
        case "CustomResume":
            // DirectCustomTrackControls.resumeWatching's one write.
            try TrackQueries.restore(db, id: Int(id))
            try TrackQueries.setEnabled(db, id: Int(id), enabled: true)
        case "IdeaQueries.setStatus":
            try IdeaQueries.setStatus(db, id: Int(id), status: a.status ?? "")
        case "IdeaQueries.snooze":
            try IdeaQueries.snooze(db, id: Int(id), until: a.until)
        case "ReminderQueries.markDone":
            try ReminderQueries.markDone(db, id: id)
        case "ReminderQueries.snooze":
            try ReminderQueries.snooze(db, id: id, until: a.until ?? "")
        case "DayPlanQueries.markItemDone":
            try DayPlanQueries.markItemDone(db, itemId: id, cascadeToTask: a.cascade)
        case "DayPlanQueries.markItemPending":
            try DayPlanQueries.markItemPending(db, itemId: id, cascadeToTask: a.cascade)
        default:
            XCTFail("\(name): unknown Swift writer \(w.writer)")
        }
    }

    /// The output writers (hash-guarded); false for any other writer.
    private static func runOutputWriter(_ writer: String, db: Database, id: Int64, hash: String, now: Date) throws -> Bool {
        switch writer {
        case "AutomationQueries.markOutputOpened":
            _ = try AutomationQueries.markOutputOpened(db, id: id, contentHash: hash, now: now)
        case "AutomationQueries.markOutputDone":
            _ = try AutomationQueries.markOutputDone(db, id: id, contentHash: hash, now: now)
        case "AutomationQueries.dismissOutput":
            _ = try AutomationQueries.dismissOutput(db, id: id, contentHash: hash, now: now)
        default:
            return false
        }
        return true
    }

    private static func assertRows(_ db: Database, table: String, want: [[String: Cell]], name: String) throws {
        let columns = (want.first?.keys.sorted()) ?? []
        let order = table == "decision_reads" ? "digest_id, decision_idx" : "rowid"
        let select = columns.isEmpty ? "1" : columns.joined(separator: ", ")
        let rows = try Row.fetchAll(db, sql: "SELECT \(select) FROM \(table) ORDER BY \(order)")
        XCTAssertEqual(rows.count, want.count, "\(name): \(table) rows")
        for (index, (row, expected)) in zip(rows, want).enumerated() {
            for column in columns {
                guard let cell = expected[column] else { continue }
                let value: DatabaseValue = row[column]
                XCTAssertTrue(cell.matches(value), "\(name): \(table) row \(index) \(column) = \(value), want \(cell)")
            }
        }
    }
}

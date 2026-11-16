import Foundation
import GRDB
import WatchtowerCore
import WatchtowerTestSupport
import XCTest

/// One writer per screen write: the Go writers behind the tower's screen
/// commands (`internal/inboxfeed/screens.go`, `internal/db/screen_writes.go`,
/// `internal/db/target_owner_writes.go`) and their Swift twins leave the
/// same rows over the shared fixture
/// `internal/inboxfeed/testdata/screen_writes.json` (Go runs it in
/// `TestScreenWritesCases`). Each case with a `swift` entry seeds a
/// database, runs the named Swift writer and compares `expect.rows` (`"*"`
/// is any non-empty value, `null` a NULL; a table key may carry a `WHERE`)
/// and what the twin reports of `expect.result` (`rolled_up`, `undone`,
/// `moved`). The Swift side is deleted with the Swift writers; the fixture
/// stays as the Go golden.
final class ScreenWritesFixtureTests: XCTestCase {
    /// …/internal/inboxfeed/testdata, from …/WatchtowerDesktop/Tests/Core/<this file>.
    private static let testdata = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // …/Core
        .deletingLastPathComponent()  // …/Tests
        .deletingLastPathComponent()  // …/WatchtowerDesktop
        .deletingLastPathComponent()  // the repository
        .appendingPathComponent("internal/inboxfeed/testdata")

    /// The `expect.result` fields a twin reports.
    private static let reported: Set<String> = ["rolled_up", "undone", "moved"]

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

    /// A twin's arguments by name; each writer reads its own.
    private struct Args: Decodable {
        let values: [String: Value]

        init(from decoder: Decoder) throws {
            values = try decoder.singleValueContainer().decode([String: Value].self)
        }

        func int(_ key: String) -> Int64? {
            if case let .int(n) = values[key] { return n }
            return nil
        }

        func string(_ key: String) -> String? {
            if case let .text(s) = values[key] { return s }
            return nil
        }

        func flag(_ key: String) -> Bool {
            if case let .flag(b) = values[key] { return b }
            return false
        }

        func ints(_ key: String) -> [Int64] {
            if case let .ints(list) = values[key] { return list }
            return []
        }
    }

    /// One argument or result value.
    private enum Value: Decodable, Equatable {
        case flag(Bool), int(Int64), text(String), ints([Int64])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) {
                self = .flag(b)
            } else if let n = try? c.decode(Int64.self) {
                self = .int(n)
            } else if let list = try? c.decode([Int64].self) {
                self = .ints(list)
            } else {
                self = .text(try c.decode(String.self))
            }
        }
    }

    private struct Expect: Decodable {
        let rows: [String: [[String: Cell]]]
        let result: [String: Value]?
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
        let data = try Data(contentsOf: Self.testdata.appendingPathComponent("screen_writes.json"))
        let cases = try JSONDecoder().decode([WriteCase].self, from: data)
        let swiftCases = cases.filter { $0.swift != nil }
        XCTAssertGreaterThanOrEqual(swiftCases.count, 55)
        for item in swiftCases {
            guard let writer = item.swift else { continue }
            let queue = try TestDatabase.create()
            let answer = try queue.write { db -> [String: Value] in
                for statement in item.seed { try db.execute(sql: statement) }
                return try Self.run(writer, db: db, now: item.now, name: item.name)
            }
            for (key, want) in item.expect.result ?? [:] where Self.reported.contains(key) {
                XCTAssertEqual(answer[key], want, "\(item.name): \(key)")
            }
            try queue.read { db in
                for (table, rows) in item.expect.rows.sorted(by: { $0.key < $1.key }) {
                    try Self.assertRows(db, table: table, want: rows, name: item.name)
                }
            }
        }
    }

    /// Runs the twin; its answer holds what `expect.result` checks.
    private static func run(_ w: SwiftWriter, db: Database, now: String, name: String) throws -> [String: Value] {
        let a = w.args
        if try runInboxWriter(w.writer, db: db, args: a, now: now)
            || runTrackWriter(w.writer, db: db, args: a)
            || runIdeaWriter(w.writer, db: db, args: a)
            || runPlanWriter(w.writer, db: db, args: a)
            || runDigestWriter(w.writer, db: db, args: a, name: name) {
            return [:]
        }
        if let answer = try runReportingWriter(w.writer, db: db, args: a, name: name) { return answer }
        XCTFail("\(name): unknown Swift writer \(w.writer)")
        return [:]
    }

    /// The writers that report something (the targets' rolled-up parents,
    /// an undo); nil for any other writer.
    private static func runReportingWriter(
        _ writer: String, db: Database, args a: Args, name: String
    ) throws -> [String: Value]? {
        let id = a.int("id") ?? 0
        switch writer {
        case "IdeaQueries.undoChatIdea":
            let undone = try IdeaQueries.undoChatIdea(db, id: id, createdUpdatedAt: a.string("createdUpdatedAt") ?? "")
            return ["undone": .flag(undone)]
        case "WorkbenchQueries.updateTargetStatus":
            return ["rolled_up": .ints(try WorkbenchQueries.updateTargetStatus(db, targetID: id, status: a.string("status") ?? ""))]
        case "WorkbenchQueries.updateTargetColumn":
            let rolled = try WorkbenchQueries.updateTargetColumn(
                db, targetID: id, status: a.string("status") ?? "", columnID: a.int("columnID")
            )
            return ["rolled_up": .ints(rolled)]
        case "WorkbenchQueries.markInProgressOnWorkOn":
            let rolled = try WorkbenchQueries.markInProgressOnWorkOn(db, targetID: id)
            return ["moved": .flag(rolled != nil), "rolled_up": .ints(rolled ?? [])]
        case "TargetQueries.snoozeInstant":
            // Home's Hide: a UTC minute ("yyyy-MM-ddTHH:mm").
            let instant = try XCTUnwrap(AutomationDates.parse((a.string("until") ?? "") + ":00Z"), name)
            let before = try WorkbenchQueries.ancestorStatuses(db, of: id)
            try TargetQueries.snooze(db, id: Int(id), untilInstant: instant)
            let after = try WorkbenchQueries.ancestorStatuses(db, of: id)
            return ["rolled_up": .ints(after.filter { before[$0.key] != $0.value }.map(\.key).sorted())]
        default:
            return nil
        }
    }

    /// Home and the Inbox strip's writers; false for any other writer.
    private static func runInboxWriter(_ writer: String, db: Database, args a: Args, now: String) throws -> Bool {
        let id = a.int("id") ?? 0
        let hash = a.string("contentHash") ?? ""
        let date = AutomationDates.parse(now) ?? Date()
        switch writer {
        case "AutomationQueries.markOutputOpened":
            _ = try AutomationQueries.markOutputOpened(db, id: id, contentHash: hash, now: date)
        case "AutomationQueries.markOutputDone":
            _ = try AutomationQueries.markOutputDone(db, id: id, contentHash: hash, now: date)
        case "AutomationQueries.dismissOutput":
            _ = try AutomationQueries.dismissOutput(db, id: id, contentHash: hash, now: date)
        case "ReminderQueries.markDone":
            try ReminderQueries.markDone(db, id: id)
        case "ReminderQueries.snooze":
            try ReminderQueries.snooze(db, id: id, until: a.string("until") ?? "")
        case "BriefingQueries.markRead":
            try BriefingQueries.markRead(db, ids: a.ints("ids").map { Int($0) })
        case "InboxQueries.markRead":
            try InboxQueries.markRead(db, id: Int(id))
        default:
            return false
        }
        return true
    }

    /// The Tracks writers; false for any other writer.
    private static func runTrackWriter(_ writer: String, db: Database, args a: Args) throws -> Bool {
        let id = Int(a.int("id") ?? 0)
        switch writer {
        case "TrackQueries.markRead":
            try TrackQueries.markRead(db, ids: a.ints("ids").map { Int($0) })
        case "TrackDone":
            // ActionStripViewModel.markTrackDone's one write.
            try TrackQueries.markRead(db, id: id)
            try TrackEventQueries.markAllRead(db, trackId: id)
        case "TrackQueries.dismiss":
            try TrackQueries.dismiss(db, id: id)
        case "TrackQueries.restore":
            try TrackQueries.restore(db, id: id)
        case "CustomStop":
            // DirectCustomTrackControls.stopWatching's one write.
            try TrackQueries.setEnabled(db, id: id, enabled: false)
            try TrackQueries.dismiss(db, id: id)
        case "TrackQueries.updatePriority":
            try TrackQueries.updatePriority(db, id: id, priority: a.string("value") ?? "")
        case "TrackQueries.updateOwnership":
            try TrackQueries.updateOwnership(db, id: id, ownership: a.string("value") ?? "")
        case "TrackSubItem":
            // TracksViewModel.toggleSubItem's one write.
            let fresh = try XCTUnwrap(TrackQueries.fetchByID(db, id: id))
            var items = fresh.decodedSubItems
            let index = Int(a.int("index") ?? 0)
            guard index < items.count else { return true }
            items[index].status = a.flag("done") ? "done" : "open"
            try TrackQueries.updateSubItems(db, id: id, subItems: items)
        case "TrackQueries.setEnabled":
            try TrackQueries.setEnabled(db, id: id, enabled: a.flag("enabled"))
        case "TrackQueries.updateInstruction":
            try TrackQueries.updateInstruction(db, id: id, instruction: a.string("value") ?? "")
        case "TrackQueries.delete":
            try TrackQueries.delete(db, id: id)
        default:
            return try runTrackEventWriter(writer, db: db, args: a)
        }
        return true
    }

    /// The track event writers; false for any other writer.
    private static func runTrackEventWriter(_ writer: String, db: Database, args a: Args) throws -> Bool {
        let id = Int(a.int("id") ?? 0)
        switch writer {
        case "TrackEventQueries.setActionStatus":
            try TrackEventQueries.setActionStatus(db, id: id, status: a.string("status") ?? "")
        case "TrackEventQueries.markRead":
            try TrackEventQueries.markRead(db, id: id)
        case "TrackEventQueries.markAllRead":
            try TrackEventQueries.markAllRead(db, trackId: id)
        default:
            return false
        }
        return true
    }

    /// The Ideas and Decisions writers; false for any other writer.
    private static func runIdeaWriter(_ writer: String, db: Database, args a: Args) throws -> Bool {
        let id = Int(a.int("id") ?? 0)
        switch writer {
        case "IdeaQueries.setStatus":
            try IdeaQueries.setStatus(db, id: id, status: a.string("status") ?? "")
        case "IdeaQueries.snooze":
            try IdeaQueries.snooze(db, id: id, until: a.string("until"))
        case "IdeaQueries.merge":
            try IdeaQueries.merge(db, id: id, into: Int(a.int("into") ?? 0))
        case "IdeaQueries.supersede":
            try IdeaQueries.supersede(db, id: id, by: a.int("by").map { Int($0) })
        case "IdeaQueries.setRating":
            try IdeaQueries.setRating(db, id: id, rating: Int(a.int("rating") ?? 0), comment: a.string("comment") ?? "")
        case "IdeaQueries.createManual":
            try IdeaQueries.createManual(
                db, kind: a.string("kind") ?? "", title: a.string("title") ?? "", essence: a.string("essence") ?? ""
            )
        case "IdeaQueries.delete":
            try IdeaQueries.delete(db, id: id)
        case "IdeaConvert":
            // IdeasViewModel.convert's one write.
            let today = a.string("today") ?? ""
            let idea = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT title, essence FROM ideas WHERE id = ?", arguments: [id]))
            let targetID = try TargetQueries.create(
                db, text: idea["title"], intent: idea["essence"], level: "day", periodStart: today, periodEnd: today,
                sourceType: "idea", sourceID: String(id)
            )
            try IdeaQueries.markConverted(db, id: id, targetID: Int64(targetID))
        case "IdeaQueries.markDecisionSeen":
            try IdeaQueries.markDecisionSeen(db, id: id)
        case "IdeaQueries.markAllDecisionsSeen":
            try IdeaQueries.markAllDecisionsSeen(db)
        case "IdeaQueries.createFromChat":
            _ = try IdeaQueries.createFromChat(
                db, kind: a.string("kind") ?? "", body: a.string("body") ?? "",
                conversationID: a.int("conversationID") ?? 0, messageID: a.int("messageID") ?? 0
            )
        default:
            return false
        }
        return true
    }

    /// The Day plan writers; false for any other writer.
    private static func runPlanWriter(_ writer: String, db: Database, args a: Args) throws -> Bool {
        let id = a.int("id") ?? 0
        switch writer {
        case "DayPlanQueries.markItemDone":
            try DayPlanQueries.markItemDone(db, itemId: id, cascadeToTask: a.flag("cascade"))
        case "DayPlanQueries.markItemPending":
            try DayPlanQueries.markItemPending(db, itemId: id, cascadeToTask: a.flag("cascade"))
        case "DayPlanQueries.deleteItem":
            try DayPlanQueries.deleteItem(db, itemId: id)
        case "DayPlanQueries.reorderBacklog":
            try DayPlanQueries.reorderBacklog(db, planId: a.int("planID") ?? 0, orderedIds: a.ints("orderedIDs"))
        case "DayPlanQueries.addManualItem":
            try DayPlanQueries.addManualItem(
                db, planId: a.int("planID") ?? 0, kind: DayPlanItemKind(rawValue: a.string("kind") ?? "") ?? .backlog,
                title: a.string("title") ?? "",
                startTime: a.string("startTime").flatMap(AutomationDates.parse),
                endTime: a.string("endTime").flatMap(AutomationDates.parse)
            )
        default:
            return false
        }
        return true
    }

    /// Catch-Up and Digests' writers; false for any other writer.
    private static func runDigestWriter(_ writer: String, db: Database, args a: Args, name: String) throws -> Bool {
        switch writer {
        case "CatchUpQueries.acknowledge":
            let recap = try XCTUnwrap(CatchUpQueries.fetchRecap(db, id: Int(a.int("id") ?? 0)), name)
            try CatchUpQueries.acknowledge(db, recap: recap)
        case "DigestQueries.markRead":
            try DigestQueries.markRead(db, ids: a.ints("ids").map { Int($0) })
        case "DigestQueries.markDecisionRead":
            try DigestQueries.markDecisionRead(
                db, digestID: Int(a.int("digestID") ?? 0), decisionIdx: Int(a.int("idx") ?? 0)
            )
        case "DigestQueries.markAllDecisionsRead":
            try DigestQueries.markAllDecisionsRead(db, digestID: Int(a.int("digestID") ?? 0))
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
            for (position, column) in columns.enumerated() {
                guard let cell = expected[column] else { continue }
                let value: DatabaseValue = row[position]
                XCTAssertTrue(cell.matches(value), "\(name): \(table) row \(index) \(column) = \(value), want \(cell)")
            }
        }
    }
}

import GRDB
import XCTest
import WatchtowerTestSupport
@testable import WatchtowerCore

/// Slack today's list row and its place in the root (inbox redesign phase
/// 5): the row from the state, the Today section, the one read and Mark
/// All Seen at the drawn version.
@MainActor
final class SlackTodayRowTests: XCTestCase {
    private var path = ""
    private let suite = "SlackTodayRowTests.\(UUID().uuidString)"
    private let utc = SlackTodaySummaryTests.utc

    override func tearDown() {
        if !path.isEmpty { TestDatabase.cleanup(path: path) }
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func date(_ text: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text), text)
    }

    /// 900 messages, four channels with news (one only `more`), two quiet.
    private func busyDay(day: String = "2026-10-22") throws -> SlackTodaySummary {
        let line = { (label: String, text: String, at: String) in
            #"{"label":"\#(label)","text":"\#(text)","at":"2026-10-22T\#(at):00Z","link":"https://example.com/l"}"#
        }
        return try XCTUnwrap(SlackTodaySummaryTests.decoded(SlackTodaySummaryTests.state(channels: [
            #""C1":{"name":"acme-release","n":23,"more":0,"lines":["# + line("decided", "The tag goes out Thursday.", "09:10")
                + "]}",
            #""C2":{"name":"acme-infra","n":41,"more":0,"lines":["#
                + line("needs_someone", "Colleague D is looking for a migration reviewer.", "09:30") + ","
                + line("fyi", "Staging was down 20 min.", "09:40") + "]}",
            #""C3":{"name":"@Colleague A","n":7,"more":0,"lines":["# + line("fyi", "Budget numbers are final.", "08:00")
                + "]}",
            #""C4":{"name":"acme-design","n":12,"more":2,"link":"https://example.com/d"}"#,
            #""C5":{"name":"acme-random","n":800}"#,
            #""C6":{"name":"acme-music","n":17}"#
        ], messages: 900, day: day)))
    }

    func testRowToday() throws {
        let now = try date("2026-10-22T10:30:00Z")
        let row = SlackTodayRow.content(state: .read(try busyDay()), isUnread: true,
                                        changedAt: try date("2026-10-22T10:20:00Z"), now: now, calendar: utc)
        XCTAssertEqual(row.kind, .slackToday)
        XCTAssertEqual(row.title, "Slack today")
        XCTAssertEqual(row.preview, "#acme-infra — Colleague D is looking for a migration reviewer.\n"
            + "#acme-release — The tag goes out Thursday.")
        XCTAssertEqual(row.meta, "Built in · today · 900 messages")
        XCTAssertEqual(row.time, "10:20")
        XCTAssertEqual(row.pill, InboxRowPill(count: 4, tone: .batch), "news channels, neutral")
        XCTAssertTrue(row.isUnread)
    }

    /// A DM's line keeps its `@name`, never `#@name`.
    func testRowDrawsADirectMessageWithoutHash() throws {
        let summary = try XCTUnwrap(SlackTodaySummaryTests.decoded(SlackTodaySummaryTests.state(channels: [
            #""D1":{"name":"@Colleague A","n":1,"more":0,"lines":[{"label":"asks_you","text":"Can you sign off?","#
                + #""at":"2026-10-22T09:00:00Z","link":""}]}"#
        ], messages: 1)))
        let row = SlackTodayRow.content(state: .read(summary), isUnread: false, changedAt: try date("2026-10-22T09:05:00Z"),
                                        now: try date("2026-10-22T10:00:00Z"), calendar: utc)
        XCTAssertEqual(row.preview, "@Colleague A — Can you sign off?")
        XCTAssertEqual(row.meta, "Built in · today · 1 message")
        XCTAssertEqual(row.pill, InboxRowPill(count: 1, tone: .batch))
    }

    func testRowNoNewsHasNoPill() throws {
        let summary = try XCTUnwrap(SlackTodaySummaryTests.decoded(SlackTodaySummaryTests.state(channels: [
            #""C5":{"name":"acme-random","n":12}"#
        ], messages: 12)))
        let row = SlackTodayRow.content(state: .read(summary), isUnread: false, changedAt: try date("2026-10-22T09:05:00Z"),
                                        now: try date("2026-10-22T10:00:00Z"), calendar: utc)
        XCTAssertNil(row.pill)
        XCTAssertEqual(row.preview, "Nothing for you yet today")
        XCTAssertEqual(row.meta, "Built in · today · 12 messages")
    }

    /// An unreadable state: the row says the numbers can't be read under
    /// "Built in", never "Nothing yet today", and no pill.
    func testRowUnreadableState() throws {
        let row = SlackTodayRow.content(state: .unreadable, isUnread: false,
                                        changedAt: try date("2026-10-22T09:05:00Z"),
                                        now: try date("2026-10-22T10:00:00Z"), calendar: utc)
        XCTAssertEqual(row.preview, "Today's numbers can't be read")
        XCTAssertEqual(row.meta, "Built in")
        XCTAssertNil(row.pill)
        XCTAssertEqual(SlackTodayPaneText.subtitle(state: .unreadable, now: try date("2026-10-22T10:00:00Z"),
                                                   calendar: utc), "Today's numbers can't be read")
    }

    func testStaleDayShowsYesterdayNote() throws {
        let now = try date("2026-10-23T07:00:00Z")
        let stale = try busyDay()
        let written = try date("2026-10-22T21:00:00Z")
        let row = SlackTodayRow.content(state: .read(stale), isUnread: false, changedAt: written, now: now, calendar: utc)
        XCTAssertEqual(row.preview, "Nothing yet today")
        XCTAssertEqual(row.meta, "Built in")
        XCTAssertNil(row.pill)
        XCTAssertEqual(row.time, "yesterday")
        let none = SlackTodayRow.content(state: .none, isUnread: false, changedAt: written, now: now, calendar: utc)
        XCTAssertEqual(none.preview, "Nothing yet today")
        XCTAssertEqual(none.meta, "Built in")

        XCTAssertEqual(SlackTodayPaneText.subtitle(state: .read(stale), now: now, calendar: utc), "Nothing yet today")
        XCTAssertEqual(SlackTodayPaneText.staleNote(state: .read(stale), writtenAt: written, now: now, calendar: utc),
                       "This is yesterday's list. Today's starts after the next sync.")
        // Today's card (a run after midnight that wrote today's empty card)
        // is not yesterday's list, whatever the state's day says.
        XCTAssertNil(SlackTodayPaneText.staleNote(state: .read(stale), writtenAt: try date("2026-10-23T06:00:00Z"),
                                                  now: now, calendar: utc))
        // No state or an unreadable one (undecodable or another version):
        // the card's date decides — written yesterday, the note; written
        // today, none.
        for state in [SlackTodayState.none, .unreadable] {
            XCTAssertEqual(SlackTodayPaneText.staleNote(state: state, writtenAt: written, now: now, calendar: utc),
                           SlackTodayPaneText.staleNoteText)
            XCTAssertNil(SlackTodayPaneText.staleNote(state: state, writtenAt: try date("2026-10-23T06:00:00Z"),
                                                      now: now, calendar: utc))
        }
        XCTAssertNil(SlackTodayPaneText.staleNote(state: .read(try busyDay(day: "2026-10-23")), writtenAt: written,
                                                  now: now, calendar: utc))
    }

    func testHeaderSubtitleSingulars() throws {
        let now = try date("2026-10-22T10:00:00Z")
        XCTAssertEqual(SlackTodayPaneText.subtitle(state: .read(try busyDay()), now: now, calendar: utc),
                       "Today · 900 messages in 6 conversations · 4 with news for you")
        let one = try XCTUnwrap(SlackTodaySummaryTests.decoded(SlackTodaySummaryTests.state(channels: [
            #""C1":{"name":"acme-ops","n":1,"more":1,"link":"https://example.com/o"}"#
        ], messages: 1)))
        XCTAssertEqual(SlackTodayPaneText.subtitle(state: .read(one), now: now, calendar: utc),
                       "Today · 1 message in 1 conversation · 1 with news for you")
        XCTAssertEqual(SlackTodayPaneText.subtitle(state: .none, now: now, calendar: utc), "Nothing yet today")
    }

    func testSlackTodayEntryIsInTodaySection() throws {
        let now = try date("2026-10-23T07:00:00Z")
        // Written yesterday: an artifact would go to Running; Slack today
        // stays in Today.
        let card = AutomationOutputCard(
            id: 5, automationID: 9, automationName: "Slack today", runID: 1, title: "Slack today", body: "",
            priority: "", createdAt: try date("2026-10-22T21:00:00Z"), changedAt: try date("2026-10-22T21:00:00Z"))
        let other = AutomationOutputCard(
            id: 6, automationID: 10, automationName: "Weekly", runID: 1, title: "Weekly", body: "",
            priority: "", createdAt: try date("2026-10-22T21:00:00Z"), changedAt: try date("2026-10-22T21:00:00Z"))
        let sections = InboxRootSections.build(
            entries: [.artifact(other), .artifact(card)], folder: .root, waitingForMeAutomationID: nil,
            slackTodayAutomationID: 9, now: now, calendar: utc)
        XCTAssertEqual(sections.map(\.0), [.today, .running])
        XCTAssertEqual(sections.first?.1.map(\.id), ["artifact:5"])
        XCTAssertEqual(sections.last?.1.map(\.id), ["artifact:6"])
    }

    // MARK: - The one read

    private func pool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.createPool()
        self.path = path
        return pool
    }

    /// The built-in, its state at `stateJSON` and its living card.
    nonisolated private func seedSlackToday(
        _ db: Database, stateJSON: String?, hash: String = "h1"
    ) throws -> (automation: Int64, card: Int64) {
        let automation = try NeedsApprovalFixtures.builtin(db, id: SlackTodayQueries.builtinID, name: "Slack today")
        let run = try NeedsApprovalFixtures.run(db, automation)
        if let stateJSON {
            try db.execute(sql: "INSERT INTO automation_state (automation_id, state_json, run_id) VALUES (?, ?, ?)",
                           arguments: [automation, stateJSON, run])
        }
        let card = try TestDatabase.insertAutomationOutput(
            db, automationID: automation, runID: run, title: "Slack today", body: "#acme-release",
            createdAt: "2026-11-06T09:00:00Z", blocksJSON: #"{"v":1,"blocks":[]}"#, outputKey: "slack-today",
            contentHash: hash, writtenAt: "2026-11-06T09:00:00Z", changedAt: "2026-11-06T09:00:00Z")
        return (automation, card)
    }

    func testQueriesReadTheBuiltinsState() async throws {
        let pool = try pool()
        let none = try await pool.read { try SlackTodayQueries.read($0) }
        XCTAssertNil(none, "no built-in row")
        let state = try SlackTodaySummaryTests.goldenStateJSON()
        let ids = try await pool.write { try self.seedSlackToday($0, stateJSON: state) }
        let read = try await pool.read { try SlackTodayQueries.read($0) }
        XCTAssertEqual(read?.automationID, ids.automation)
        XCTAssertEqual(read?.state, .read(try SlackTodaySummaryTests.golden()))
        let snapshot = try await pool.read {
            try InboxFolderMenuSnapshot.read($0, nowUTC: "2026-10-22T10:00:00Z", calendar: self.utc)
        }
        XCTAssertEqual(snapshot.slackToday, read)

        try await pool.write { try $0.execute(sql: "DELETE FROM automation_state") }
        let noState = try await pool.read { try SlackTodayQueries.read($0) }
        XCTAssertEqual(noState?.automationID, ids.automation)
        XCTAssertEqual(noState?.state, SlackTodayState.none, "no state yet")

        try await pool.write {
            try $0.execute(sql: "INSERT INTO automation_state (automation_id, state_json) VALUES (?, ?)",
                           arguments: [ids.automation, #"{"today":{"v":2}}"#])
        }
        let unreadable = try await pool.read { try SlackTodayQueries.read($0) }
        XCTAssertEqual(unreadable?.state, .unreadable, "a state this version cannot read is not none")
    }

    /// The root lists the built-in's card as the Slack today row, from the state.
    func testRootRowComesFromTheState() async throws {
        let pool = try pool()
        let day = HomeFeedBuilder.dayString(NeedsApprovalFixtures.now, calendar: .autoupdatingCurrent)
        let state = SlackTodaySummaryTests.state(channels: [
            #""C1":{"name":"acme-release","n":3,"more":0,"lines":[{"label":"decided","text":"Thursday it is.","#
                + #""at":"2026-11-06T08:00:00Z","link":""}]}"#
        ], messages: 3, day: day)
        let ids = try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            let slack = try self.seedSlackToday(db, stateJSON: state)
            return (root: folders.root, card: slack.card)
        }
        let vm = NeedsApprovalFixtures.viewModel(pool, suite: suite)
        await vm.refresh()
        vm.selectFolder(ids.root)

        let row = try XCTUnwrap(vm.folderList.rows.first { $0.id == "artifact:\(ids.card)" })
        XCTAssertEqual(row.content.kind, .slackToday)
        XCTAssertEqual(row.content.preview, "#acme-release — Thursday it is.")
        XCTAssertEqual(row.content.meta, "Built in · today · 3 messages")
        XCTAssertEqual(row.content.pill, InboxRowPill(count: 1, tone: .batch))
        XCTAssertEqual(vm.folderList.sections.first { $0.rows.contains { $0.id == row.id } }?.title, "Today")
    }

    func testMarkAllSeenWritesDrawnHashOnly() async throws {
        let pool = try pool()
        let ids = try await pool.write { try self.seedSlackToday($0, stateJSON: nil) }
        let vm = NeedsApprovalFixtures.viewModel(pool, suite: suite)
        await vm.refresh()
        XCTAssertEqual(vm.outputRows.first?.contentHash, "h1")
        // A later run rewrites the card under the pane.
        try await pool.write { db in
            let run = try TestDatabase.insertAutomationRun(db, automationID: ids.automation)
            try TestDatabase.rewriteLivingOutput(db, id: ids.card, runID: run, body: "#acme-infra",
                                                 blocksJSON: #"{"v":1,"blocks":[]}"#, contentHash: "h2",
                                                 at: "2026-11-06T09:30:00Z")
        }

        await vm.markOutputSeen(id: ids.card)

        let readAt = try await pool.read {
            try String.fetchOne($0, sql: "SELECT read_at FROM automation_outputs WHERE id = ?", arguments: [ids.card])
        }
        XCTAssertNil(readAt, "the drawn version was h1: nothing written")
        XCTAssertEqual(vm.outputRows.first?.contentHash, "h2", "read again: the new version")
        XCTAssertEqual(vm.outputRows.first?.isUnread, true)
        XCTAssertNil(vm.lastError)

        await vm.markOutputSeen(id: ids.card)

        let seen = try await pool.read {
            try String.fetchOne($0, sql: "SELECT read_at FROM automation_outputs WHERE id = ?", arguments: [ids.card])
        }
        XCTAssertNotNil(seen, "at the drawn h2 it lands")
        XCTAssertEqual(vm.outputRows.first?.isUnread, false)
        XCTAssertEqual(vm.outputRows.map(\.id), [ids.card], "still listed: seen is not done")
    }
}

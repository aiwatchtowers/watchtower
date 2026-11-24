import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class SessionFeedStoreTests: XCTestCase {
    private final class FakeRunner: CLIRunnerProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [Result<String, Error>]
        private(set) var calls: [[String]] = []

        init(_ queue: [Result<String, Error>]) { self.queue = queue }

        func run(args: [String]) async throws -> Data {
            let next: Result<String, Error> = lock.withLock {
                calls.append(args)
                return queue.isEmpty ? .success("{}") : queue.removeFirst()
            }
            return Data(try next.get().utf8)
        }
    }

    private func payload(
        cursor: String = "c1", entries: String = "", subagents: String = "", activity: String = "null", before: String? = nil
    ) -> String {
        let beforeKey = before.map { #","before":"\#($0)""# } ?? ""
        return """
        {"session_id":7,"cursor":"\(cursor)","entries":[\(entries)],"subagents":[\(subagents)],
         "activity":\(activity),"skipped":0,"unknown_records":{}\(beforeKey)}
        """
    }

    /// Agent entries `e<lower>` … `e<upper-1>`, joined for `payload(entries:)`.
    private func entries(_ range: Range<Int>, text: String = "t") -> String {
        range.map { entry("e\($0)", "agent", text: text) }.joined(separator: ",")
    }

    private func entry(_ id: String, _ kind: String, text: String = "t", at: String = "2026-10-16T10:00:00Z") -> String {
        #"{"id":"\#(id)","kind":"\#(kind)","at":"\#(at)","text":"\#(text)","conversation":"main"}"#
    }

    private func marker(_ id: String, status: String) -> String {
        """
        {"id":"\(id)","kind":"subagent","at":"0001-01-01T00:00:00Z","text":"","conversation":"main",
         "subagent":{"tool_use_id":"tu1","agent_id":"a1","type":"general","description":"d","status":"\(status)"}}
        """
    }

    func testDecodesEventEntry() throws {
        let json = #"{"id":"ev1","kind":"event","event_type":"task","title":"Task done","text":"body","#
            + #""at":"2026-10-16T10:00:00Z","conversation":"main"}"#
        let e = try JSONDecoder().decode(SessionFeedEntry.self, from: Data(json.utf8))
        XCTAssertEqual(e.kind, "event")
        XCTAssertEqual(e.eventType, "task")
        XCTAssertEqual(e.title, "Task done")
        XCTAssertEqual(e.text, "body")
        XCTAssertTrue(SessionFeedEntry.knownKinds.contains("event"))
    }

    func testPhoneKindsExcludeEvent() {
        XCTAssertFalse(SessionFeedEntry.phoneKinds.contains("event"))
        XCTAssertFalse(SessionFeedEntry.phoneKinds.contains("peer"), "the phone shows no peer bubbles in v1")
        XCTAssertEqual(SessionFeedEntry.phoneKinds.union(["event", "peer"]), SessionFeedEntry.knownKinds)
    }

    func testDecodesPinnedPayload() throws {
        let kinds = ["owner", "agent", "watchtower", "brief", "separator"]
            .enumerated().map { entry("e\($0.offset)", $0.element) }
        let ask = #"{"id":"ask","kind":"ask_answer","at":"2026-10-16T10:00:00.5Z","text":"a","conversation":"main","ask_id":42,"title":"Q"}"#
        let via = #"{"id":"w","kind":"watchtower","at":"2026-10-16T10:00:00Z","text":"x","conversation":"main","via":"slack"}"#
        let json = payload(entries: (kinds + [ask, via, marker("sub", status: "running")]).joined(separator: ","))
        let p = try JSONDecoder().decode(SessionFeedPayload.self, from: Data(json.utf8))
        XCTAssertEqual(p.sessionID, 7)
        XCTAssertEqual(p.cursor, "c1")
        XCTAssertEqual(p.entries.count, 8)
        XCTAssertEqual(p.entries[5].askID, 42)
        XCTAssertEqual(p.entries[5].title, "Q")
        XCTAssertNotNil(p.entries[5].at)
        XCTAssertEqual(p.entries[6].via, "slack")
        XCTAssertEqual(p.entries[7].subagent?.status, "running")
        XCTAssertEqual(p.entries[7].subagent?.toolUseID, "tu1")
    }

    func testZeroTimeDecodesAsNoTime() throws {
        let json = payload(entries: marker("sub", status: "unknown") + "," + entry("sep", "separator", at: "0001-01-01T00:00:00Z"))
        let p = try JSONDecoder().decode(SessionFeedPayload.self, from: Data(json.utf8))
        XCTAssertNil(p.entries[0].at)
        XCTAssertNil(p.entries[1].at)
    }

    func testRefreshUpsertsByID() async {
        let runner = FakeRunner([
            .success(payload(entries: entry("m0", "owner") + "," + entry("m1", "agent", text: "short") + "," + entry("m2", "agent"))),
            .success(payload(cursor: "c2", entries: entry("m1", "agent", text: "longer text")))
        ])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        await store.refresh()
        XCTAssertEqual(store.entries.map(\.id), ["m0", "m1", "m2"])
        XCTAssertEqual(store.entries[1].text, "longer text")
        XCTAssertEqual(runner.calls[0], ["workbench", "session-feed", "--session", "7", "--json", "--tail", "60"])
        XCTAssertEqual(runner.calls[1], ["workbench", "session-feed", "--session", "7", "--json", "--after", "c1"])
    }

    /// `transcript_dirs` (Open output's project per conversation): kept across reads, a later read's value wins,
    /// a read without it (an older CLI, a Codex session) leaves what was read.
    func testTranscriptDirsAreKeptPerConversation() async {
        let first = payload(entries: entry("m0", "owner")).replacingOccurrences(
            of: #""unknown_records":{}"#, with: #""unknown_records":{},"transcript_dirs":{"c1":"/p/-a","c2":"/p/-a"}"#)
        let second = payload(cursor: "c2", entries: entry("m1", "agent")).replacingOccurrences(
            of: #""unknown_records":{}"#, with: #""unknown_records":{},"transcript_dirs":{"c2":"/p/-a-wt"}"#)
        let runner = FakeRunner([.success(first), .success(second), .success(payload(cursor: "c3"))])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        XCTAssertEqual(store.transcriptDirs, [:])
        await store.refresh()
        XCTAssertEqual(store.transcriptDirs, ["c1": "/p/-a", "c2": "/p/-a"])
        await store.refresh()
        XCTAssertEqual(store.transcriptDirs, ["c1": "/p/-a", "c2": "/p/-a-wt"])
        await store.refresh()
        XCTAssertEqual(store.transcriptDirs, ["c1": "/p/-a", "c2": "/p/-a-wt"])
    }

    // MARK: Tail read and earlier pages (#2065 Task 8)

    func testFirstReadIsATailRead() async {
        let runner = FakeRunner([.success(payload(entries: entries(90..<150), before: "e90"))])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        XCTAssertEqual(SessionFeedStore.tailSize, 60)
        XCTAssertFalse(store.hasEarlierPage, "nothing read yet")
        await store.refresh()
        XCTAssertEqual(runner.calls[0], ["workbench", "session-feed", "--session", "7", "--json", "--tail", "60"])
        XCTAssertTrue(store.hasEarlierPage)
        XCTAssertEqual(store.entries.count, 60)
    }

    func testFirstReadWithoutBeforeHasNoEarlierPage() async {
        let runner = FakeRunner([.success(payload(entries: entries(0..<10)))])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        XCTAssertFalse(store.hasEarlierPage)
        await store.loadEarlierPage()
        XCTAssertEqual(runner.calls.count, 1, "no earlier page: no read")
    }

    func testLaterReadsUseAfterCursor() async {
        let runner = FakeRunner([
            .success(payload(entries: entries(90..<150), before: "e90")),
            .success(payload(cursor: "c2", entries: entries(150..<151)))
        ])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        await store.refresh()
        XCTAssertEqual(runner.calls[1], ["workbench", "session-feed", "--session", "7", "--json", "--after", "c1"])
        XCTAssertFalse(runner.calls[1].contains("--tail"))
        XCTAssertTrue(store.hasEarlierPage, "an --after read (no before key) keeps the earlier page")
        XCTAssertEqual(store.entries.last?.id, "e150")
    }

    func testEarlierPagePrependsAndMovesBefore() async {
        let runner = FakeRunner([
            .success(payload(entries: entries(90..<150), before: "e90")),
            .success(payload(entries: entries(30..<90), before: "e30")),
            .success(payload(entries: entries(0..<30)))
        ])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        await store.loadEarlierPage()
        XCTAssertEqual(runner.calls.last, ["workbench", "session-feed", "--session", "7", "--json", "--tail", "60", "--before", "e90"])
        XCTAssertEqual(store.entries.first?.id, "e30")
        XCTAssertEqual(store.entries.count, 120)
        XCTAssertTrue(store.hasEarlierPage)
        await store.loadEarlierPage()
        XCTAssertEqual(runner.calls.last, ["workbench", "session-feed", "--session", "7", "--json", "--tail", "60", "--before", "e30"])
        XCTAssertEqual(store.entries.map(\.id), (0..<150).map { "e\($0)" })
        XCTAssertFalse(store.hasEarlierPage, "a page without before is the first one")
        await store.loadEarlierPage()
        XCTAssertEqual(runner.calls.count, 3, "no earlier page: no third page read")
    }

    func testEarlierPageSkipsEntriesAlreadyHeldAndUpsertsByIDAfter() async {
        let runner = FakeRunner([
            .success(payload(entries: entries(90..<150), before: "e90")),
            // A page overlapping what is held: e90 is not added twice.
            .success(payload(entries: entries(30..<91), before: "e30")),
            .success(payload(cursor: "c2", entries: entry("e95", "agent", text: "grown")))
        ])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        await store.loadEarlierPage()
        XCTAssertEqual(store.entries.count, 120)
        XCTAssertEqual(Set(store.entries.map(\.id)).count, 120)
        await store.refresh()
        XCTAssertEqual(store.entries[65].id, "e95", "the index is rebuilt after a prepend")
        XCTAssertEqual(store.entries[65].text, "grown")
        XCTAssertEqual(store.entries.count, 120)
    }

    func testEarlierPageFailureKeepsEntriesAndPaging() async {
        let runner = FakeRunner([
            .success(payload(entries: entries(90..<150), before: "e90")),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "boom"))
        ])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        let added = await store.loadEarlierPage()
        XCTAssertEqual(added, 0)
        XCTAssertEqual(store.entries.count, 60)
        XCTAssertEqual(store.entries.first?.id, "e90")
        XCTAssertTrue(store.hasEarlierPage)
        XCTAssertNotNil(store.earlierPageError)
        XCTAssertNil(store.error, "a page failure is kept apart from the poll's error")
    }

    func testEarlierPageRetryRefetchesThePage() async {
        let runner = FakeRunner([
            .success(payload(entries: entries(90..<150), before: "e90")),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "boom")),
            .success(payload(cursor: "c2")),
            .success(payload(entries: entries(30..<90), before: "e30"))
        ])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        await store.loadEarlierPage()
        await store.refresh()
        XCTAssertEqual(runner.calls.last?.suffix(2), ["--after", "c1"])
        XCTAssertNotNil(store.earlierPageError, "a poll never clears the page's failure")
        let added = await store.retryEarlierPage()
        XCTAssertEqual(added, 60)
        XCTAssertEqual(runner.calls.last?.suffix(2), ["--before", "e90"], "Retry asks for the same page")
        XCTAssertEqual(store.entries.first?.id, "e30")
        XCTAssertNil(store.earlierPageError)
    }

    func testFailedPageIsNotRetriedOnEveryMeasure() async {
        let runner = FakeRunner([
            .success(payload(entries: entries(90..<150), before: "e90")),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "boom"))
        ])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        await store.loadEarlierPage()
        // The layout's automatic asks after the failure spawn nothing.
        for _ in 0..<3 { await store.loadEarlierPage() }
        XCTAssertEqual(runner.calls.count, 2)
    }

    func testEarlierPageCountsOnlyItsOwnDialogEntries() async {
        let runner = FakeRunner([
            .success(payload(entries: entries(90..<150), before: "e90")),
            .success(payload(entries: marker("m1", status: "finished") + "," + entry("e89", "owner"), before: "m1"))
        ])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        let added = await store.loadEarlierPage()
        XCTAssertEqual(added, 1, "the marker is not a dialog entry")
    }

    func testEarlierPageTakesARepeatedIDOnce() async {
        let runner = FakeRunner([
            .success(payload(entries: entries(90..<150), before: "e90")),
            .success(payload(entries: entry("L5", "agent", text: "first") + "," + entry("L5", "agent", text: "second")
                + "," + entry("e89", "agent"), before: "L5"))
        ])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        await store.loadEarlierPage()
        XCTAssertEqual(store.entries.prefix(2).map(\.id), ["L5", "e89"])
        XCTAssertEqual(store.entries.first?.text, "first")
        XCTAssertEqual(store.entries.count, 62)
    }

    func testTailReadAfterAnEarlierPageKeepsBefore() async {
        let runner = FakeRunner([
            .success(payload(cursor: "", entries: entries(90..<150), before: "e90")),
            .success(payload(cursor: "", entries: entries(30..<90), before: "e30")),
            .success(payload(cursor: "", entries: entries(91..<151), before: "e91"))
        ])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        await store.loadEarlierPage()
        await store.refresh()
        XCTAssertTrue(runner.calls.last?.contains("--tail") ?? false, "an empty cursor reads the tail again")
        XCTAssertEqual(store.entries.first?.id, "e30")
        await store.loadEarlierPage()
        XCTAssertEqual(runner.calls.last?.suffix(2), ["--before", "e30"], "the tail never rewinds the paging")
    }

    func testEarlierPageWithAPermanentlyBadBeforeStopsPaging() async {
        for stderr in [#"Error: before id "L5" is ambiguous (2 entries)"#, #"Error: before "e90": no such entry"#] {
            let runner = FakeRunner([
                .success(payload(entries: entries(90..<150), before: "e90")),
                .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: stderr))
            ])
            let store = SessionFeedStore(sessionID: 7, runner: runner)
            await store.refresh()
            await store.loadEarlierPage()
            XCTAssertFalse(store.hasEarlierPage, "the same before fails every time: paging stops, never retried")
            XCTAssertEqual(store.entries.count, 60)
            XCTAssertNil(store.earlierPageError, "paging ends quietly: no error with a Retry that cannot succeed")
            await store.retryEarlierPage()
            XCTAssertEqual(runner.calls.count, 2)
        }
    }

    func testGrowingEntryInWindowUpsertsByID() async {
        let runner = FakeRunner([
            .success(payload(entries: entries(90..<150, text: "short"), before: "e90")),
            .success(payload(cursor: "c2", entries: entry("e149", "agent", text: "longer")))
        ])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        await store.refresh()
        XCTAssertEqual(store.entries.count, 60)
        XCTAssertEqual(store.entries.last?.id, "e149")
        XCTAssertEqual(store.entries.last?.text, "longer")
    }

    func testStoreKeepsEntriesWhenALaterReadFails() async {
        let runner = FakeRunner([
            .success(payload(entries: entries(90..<150), before: "e90")),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "boom"))
        ])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        await store.refresh()
        XCTAssertEqual(store.entries.count, 60)
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.hasEarlierPage)
        XCTAssertTrue(store.feedLoaded)
    }

    func testEmptyCursorMeansFullReadNext() async {
        let runner = FakeRunner([.success(payload(cursor: "")), .success(payload(cursor: ""))])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        await store.refresh()
        XCTAssertFalse(runner.calls[1].contains("--after"))
    }

    func testSubagentStatusUpdatedFromSubagentsList() async {
        let runner = FakeRunner([
            .success(payload(entries: marker("sub", status: "running"))),
            .success(payload(cursor: "c2", subagents: marker("sub", status: "finished")))
        ])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        XCTAssertEqual(store.subagents.map(\.subagent?.status), ["running"])
        await store.refresh()
        XCTAssertEqual(store.subagents.count, 1)
        XCTAssertEqual(store.subagents[0].subagent?.status, "finished")
        XCTAssertEqual(store.entries.first?.subagent?.status, "running", "the subagents list never enters the entries")
    }

    func testSubagentsKeptApartFromEntries() async {
        let runner = FakeRunner([.success(payload(entries: entry("a", "owner"), subagents: marker("sub", status: "finished")))])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        XCTAssertFalse(store.feedLoaded)
        await store.refresh()
        XCTAssertEqual(store.subagents.map(\.id), ["sub"])
        XCTAssertEqual(store.entries.map(\.id), ["a"])
        XCTAssertTrue(store.feedLoaded)
    }

    func testStoreKeepsSubagentsWhenALaterReadFails() async {
        let runner = FakeRunner([
            .success(payload(subagents: marker("sub", status: "finished"))),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "boom"))
        ])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        await store.refresh()
        XCTAssertEqual(store.subagents.map(\.id), ["sub"])
        XCTAssertTrue(store.feedLoaded, "a failure never resets the first good read")
        XCTAssertNotNil(store.error)
    }

    func testStartedAtKeepsFirstValueAcrossReads() async {
        func marker(_ status: String, startedAt: String?) -> String {
            let at = startedAt.map { #","started_at":"\#($0)""# } ?? ""
            return #"{"id":"sub","kind":"subagent","at":"0001-01-01T00:00:00Z","text":"","conversation":"main","#
                + #""subagent":{"tool_use_id":"tu1","agent_id":"a1","type":"Explore","description":"d","status":""#
                + status + "\"" + at + "}}"
        }
        let runner = FakeRunner([
            .success(payload(entries: marker("running", startedAt: nil))),
            .success(payload(cursor: "c2", subagents: marker("running", startedAt: "2026-10-01T10:00:06Z"))),
            .success(payload(cursor: "c3", subagents: marker("finished", startedAt: "2026-10-01T10:09:00Z"))),
            .success(payload(cursor: "c4", subagents: marker("finished", startedAt: nil)))
        ])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        XCTAssertNil(store.subagents.first?.subagent?.startedAt)
        await store.refresh()
        let first = SessionFeedEntry.parseDate("2026-10-01T10:00:06Z")
        XCTAssertEqual(store.subagents.first?.subagent?.startedAt, first, "the first non-nil time is taken")
        await store.refresh()
        XCTAssertEqual(store.subagents.first?.subagent?.startedAt, first, "an --after read's meta.json mtime never moves it")
        XCTAssertEqual(store.subagents.first?.subagent?.status, "finished", "the rest of the marker still updates")
        await store.refresh()
        XCTAssertEqual(store.subagents.first?.subagent?.startedAt, first, "an undated marker never clears it")
    }

    /// The cached formatters read both RFC 3339 forms Go prints, to the
    /// millisecond, and keep "no time" for Go's zero time and garbage.
    func testParseDateReadsPlainAndFractionalSeconds() {
        let base = Date(timeIntervalSince1970: 1_790_330_406) // 2026-09-25T10:00:06Z
        XCTAssertEqual(SessionFeedEntry.parseDate("2026-09-25T10:00:06Z"), base)
        let frac = SessionFeedEntry.parseDate("2026-09-25T10:00:06.578Z")
        XCTAssertEqual(frac?.timeIntervalSince1970 ?? 0, base.timeIntervalSince1970 + 0.578, accuracy: 0.0005)
        XCTAssertEqual(SessionFeedEntry.parseDate("2026-09-25T12:00:06+02:00"), base)
        for none in [nil, "", "0001-01-01T00:00:00Z", "yesterday"] {
            XCTAssertNil(SessionFeedEntry.parseDate(none), "\(none ?? "nil")")
        }
    }

    func testDecodesSubagentStartedAt() throws {
        func ref(_ startedAt: String) throws -> SessionFeedSubagent {
            let json = #"{"tool_use_id":"tu1","agent_id":"a1","type":"Explore","description":"d","status":"finished","#
                + #""started_at":"\#(startedAt)"}"#
            return try JSONDecoder().decode(SessionFeedSubagent.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try ref("2026-10-01T10:00:06Z").startedAt, SessionFeedEntry.parseDate("2026-10-01T10:00:06Z"))
        XCTAssertNotNil(try ref("2026-10-01T10:00:06Z").startedAt)
        XCTAssertNil(try ref("0001-01-01T00:00:00Z").startedAt)
        let absent = #"{"tool_use_id":"tu1","status":"finished"}"#
        XCTAssertNil(try JSONDecoder().decode(SessionFeedSubagent.self, from: Data(absent.utf8)).startedAt)
    }

    func testUnknownKindIgnored() async {
        let runner = FakeRunner([.success(payload(entries: entry("a", "owner") + "," + entry("b", "hologram")))])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        XCTAssertEqual(store.entries.map(\.id), ["a"])
    }

    func testRunnerFailureSetsError() async {
        let runner = FakeRunner([
            .success(payload(entries: entry("a", "owner"))),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "boom"))
        ])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        await store.refresh()
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.entries.map(\.id), ["a"])
    }

    private let bashActivity = #"{"tool":"Bash","summary":"go test ./...","started_at":"2026-10-21T10:00:00Z","more":2}"#

    func testRefreshSetsActivity() async {
        let runner = FakeRunner([.success(payload(entries: entry("a", "agent"), activity: bashActivity))])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        XCTAssertEqual(store.activity?.tool, "Bash")
        XCTAssertEqual(store.activity?.summary, "go test ./...")
        XCTAssertEqual(store.activity?.more, 2)
        XCTAssertEqual(store.activity?.startedAt, ISO8601DateFormatter().date(from: "2026-10-21T10:00:00Z"))
        XCTAssertEqual(store.entries.map(\.id), ["a"], "the activity is never an entry")
    }

    func testEmptyRefreshKeepsServerActivity() async {
        let runner = FakeRunner([.success(payload(activity: bashActivity))])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.activity?.tool, "Bash")
    }

    func testNullActivityClears() async {
        let runner = FakeRunner([.success(payload(activity: bashActivity)), .success(payload(cursor: "c2"))])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        await store.refresh()
        XCTAssertNil(store.activity)
    }

    func testClearActivity() async {
        let runner = FakeRunner([.success(payload(activity: bashActivity))])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        store.clearActivity()
        XCTAssertNil(store.activity)
    }

    func testSubagentFeedCarriesActivity() async throws {
        let runner = FakeRunner([.success(payload(activity: bashActivity))])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        let read = try await store.subagentFeed("tu1")
        XCTAssertEqual(read.activity?.tool, "Bash")
        XCTAssertNil(store.activity, "the main line is not touched")
    }

    func testSubagentFeedArgs() async throws {
        let runner = FakeRunner([.success(payload(entries: entry("s1", "agent")))])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        let list = try await store.subagentFeed("tu1")
        XCTAssertEqual(list.entries.map(\.id), ["s1"])
        XCTAssertEqual(runner.calls[0], ["workbench", "session-feed", "--session", "7", "--subagent", "tu1", "--json"])
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - follow (board #589): no CLI while the main window is off screen

    /// `isActive` true for `ticks` more checks, then false.
    private func activeFor(_ ticks: Int) -> () -> Bool {
        var left = ticks
        return {
            left -= 1
            return left >= 0
        }
    }

    func testFollowReadsEveryTickOnScreen() async {
        let runner = FakeRunner([])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.follow(interval: .milliseconds(1), isActive: activeFor(3)) { true }
        XCTAssertEqual(runner.calls.count, 4, "one read at once, one per active tick")
    }

    func testFollowOffScreenSpawnsNothingAndReadsOnceOnReturn() async {
        let runner = FakeRunner([])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.follow(interval: .milliseconds(1), isActive: activeFor(3)) { false }
        XCTAssertEqual(runner.calls.count, 0)
        await store.screenChanged(false)
        XCTAssertEqual(runner.calls.count, 0)
        await store.screenChanged(true)
        XCTAssertEqual(runner.calls.count, 1, "back on screen after skipped reads: one read now")
        await store.screenChanged(true)
        XCTAssertEqual(runner.calls.count, 1, "already on screen: no extra read")
    }

    func testScreenChangedWithoutSkippedReadDoesNothing() async {
        let runner = FakeRunner([])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.follow(interval: .milliseconds(1), isActive: activeFor(0)) { true }
        XCTAssertEqual(runner.calls.count, 1)
        await store.screenChanged(false)
        await store.screenChanged(true)
        XCTAssertEqual(runner.calls.count, 1, "nothing was skipped while hidden")
    }

    func testFollowWithoutRunnerNeverPolls() async {
        let store = SessionFeedStore(sessionID: 7, runner: nil)
        XCTAssertTrue(store.runnerMissing)
        await store.follow(interval: .milliseconds(1), isActive: activeFor(2)) { true }
        await store.screenChanged(true)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(store.error)
    }

    func testFollowGoesOffScreenAndBackInsideTheLoop() async {
        let runner = FakeRunner([])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        // Checks: the first read, then ticks 1-4; ticks 2 and 3 are off screen.
        var check = 0
        let screen = [true, true, false, false, true]
        await store.follow(interval: .milliseconds(1), isActive: activeFor(4)) {
            defer { check += 1 }
            return screen[check]
        }
        XCTAssertEqual(runner.calls.count, 3, "the two off-screen ticks spawn nothing")
        await store.screenChanged(true)
        XCTAssertEqual(runner.calls.count, 3, "the on-screen tick already caught up")
    }

    func testIdlePaneOpenedOffScreenReadsOnceOnReturn() async {
        let runner = FakeRunner([])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.follow(interval: .milliseconds(1), isActive: activeFor(0)) { false }
        XCTAssertEqual(runner.calls.count, 0, "the first read is skipped off screen")
        await store.screenChanged(true)
        XCTAssertEqual(runner.calls.count, 1)
    }

    // MARK: - subagents in place (#711)

    func testSubagentFollowStopsWhenFinished() async {
        let runner = FakeRunner([
            .success(payload(cursor: "", entries: entry("s1", "owner"))),
            .success(payload(cursor: "", entries: entry("s1", "owner") + "," + entry("s2", "agent"))),
            .success(payload(cursor: "", entries: entry("s1", "owner") + "," + entry("s2", "agent") + "," + entry("s3", "agent")))
        ])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        // The marker says running for the first two checks, then finished.
        var status = ["running", "running", "finished", "finished"]
        var seen: [[String]] = []
        await store.followSubagent("tu1", interval: .milliseconds(1),
                                   isRunning: { status.removeFirst() == "running" },
                                   isOnScreen: { true },
                                   onEntries: { seen.append($0.map(\.id)) })
        XCTAssertEqual(runner.calls.count, 3, "one read at open, one per running tick, none after finished")
        XCTAssertTrue(runner.calls.allSatisfy { $0.contains("--subagent") && $0.contains("tu1") })
        XCTAssertEqual(seen.last, ["s1", "s2", "s3"])
        XCTAssertTrue(store.entries.isEmpty, "a subagent's feed never enters the main feed")
    }

    /// An open subagent's marker lives in the main feed: with
    /// `readsMainFeed` each tick also reads the main feed (after the
    /// subagent's, one CLI at a time), so the status the loop checks is
    /// current and the loop ends once the marker says finished.
    func testSubagentFollowReadsMainFeedForTheMarkerStatus() async {
        let runner = FakeRunner([
            .success(payload(cursor: "", entries: entry("s1", "agent"))),
            .success(payload(entries: marker("tu1", status: "running"))),
            .success(payload(cursor: "", entries: entry("s1", "agent"))),
            .success(payload(cursor: "c2", subagents: marker("tu1", status: "finished")))
        ])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        let pushed = SessionFeedSubagent(toolUseID: "tu1", status: "running")
        await store.followSubagent("tu1", interval: .milliseconds(1), readsMainFeed: true,
                                   isRunning: { SessionFeedSubagent.currentStatus(of: pushed, in: store.subagents) == "running" },
                                   isOnScreen: { true }, onEntries: { _ in })
        XCTAssertEqual(runner.calls.count, 4, "subagent + main per tick, none after finished")
        XCTAssertTrue(runner.calls[0].contains("--subagent"))
        XCTAssertFalse(runner.calls[1].contains("--subagent"))
        XCTAssertEqual(store.subagents.first?.subagent?.status, "finished")
    }

    func testSubagentFollowFinishedReadsOnce() async {
        let runner = FakeRunner([])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.followSubagent("tu1", interval: .milliseconds(1),
                                   isRunning: { false }, isOnScreen: { true }, onEntries: { _ in })
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testSubagentFollowOffScreenSpawnsNothing() async {
        let runner = FakeRunner([])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.followSubagent("tu1", interval: .milliseconds(1),
                                   isRunning: activeFor(3), isOnScreen: { false }, onEntries: { _ in })
        XCTAssertEqual(runner.calls.count, 0)
    }

    func testSubagentFollowFailureSetsErrorAndKeepsPolling() async {
        let runner = FakeRunner([
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "boom")),
            .success(payload(cursor: "", entries: entry("s1", "agent")))
        ])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        var errors: [String?] = []
        var seen: [[String]] = []
        await store.followSubagent("tu1", interval: .milliseconds(1),
                                   isRunning: activeFor(1), isOnScreen: { true },
                                   onEntries: { seen.append($0.map(\.id)) },
                                   onError: { errors.append($0) })
        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertEqual(seen, [["s1"]])
        XCTAssertEqual(errors.count, 2)
        XCTAssertNotNil(errors[0])
        XCTAssertNil(errors[1], "a good read clears the error")
    }

    /// The pane's rule: the main follow runs only at the root of the path;
    /// while a subagent is open only its feed is read, and back at the root
    /// the main feed is read once.
    func testMainFeedNotPolledWhileSubagentOpen() async {
        let runner = FakeRunner([])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        var path = SessionChatPath()
        path.push(SessionFeedSubagent(toolUseID: "tu1", status: "finished"))

        if path.isRoot {
            await store.follow(interval: .milliseconds(1), isActive: activeFor(3)) { true }
        } else {
            await store.followSubagent("tu1", interval: .milliseconds(1),
                                       isRunning: { false }, isOnScreen: { true }, onEntries: { _ in })
        }
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertTrue(runner.calls[0].contains("--subagent"))

        path.pop()
        if path.isRoot {
            await store.follow(interval: .milliseconds(1), isActive: activeFor(0)) { true }
        }
        XCTAssertEqual(runner.calls.count, 2, "back at the root: one main read")
        XCTAssertFalse(runner.calls[1].contains("--subagent"))
    }

    func testSubagentReadWaitsForMainReadInFlight() async {
        let runner = SlowRunner()
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        async let main: Void = store.refresh()
        async let sub: Void = store.followSubagent("tu1", interval: .milliseconds(1),
                                                   isRunning: { false }, isOnScreen: { true }, onEntries: { _ in })
        _ = await (main, sub)
        XCTAssertEqual(runner.maxConcurrent, 1, "at most one CLI process per pane")
        XCTAssertEqual(runner.calls, 2)
    }

    /// Runs `during` on the main actor while the read is in flight, then answers `{}`.
    private final class DuringRunner: CLIRunnerProtocol, @unchecked Sendable {
        let during: @MainActor () -> Void
        init(during: @escaping @MainActor () -> Void) { self.during = during }
        func run(args: [String]) async throws -> Data {
            await during()
            return Data("{}".utf8)
        }
    }

    /// A read in flight when a newer pane starts its trace marks only the trace it started for (final fix).
    func testReadInFlightDoesNotMarkANewerTrace() async throws {
        var store: SessionFeedStore?
        let runner = DuringRunner { store?.beginOpenTrace(reopen: true) }
        store = SessionFeedStore(sessionID: 7, runner: runner)
        let live = try XCTUnwrap(store)
        await live.refresh()
        let newer = try XCTUnwrap(live.openTrace)
        newer.mark(.paint)
        let report = try XCTUnwrap(newer.report)
        XCTAssertTrue(report.contains("cli=-"), report)
        XCTAssertTrue(report.contains("decode=-"), report)
    }

    private final class SlowRunner: CLIRunnerProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var running = 0
        private(set) var maxConcurrent = 0
        private(set) var calls = 0

        func run(args: [String]) async throws -> Data {
            lock.withLock {
                calls += 1
                running += 1
                maxConcurrent = max(maxConcurrent, running)
            }
            try? await Task.sleep(for: .milliseconds(20))
            lock.withLock { running -= 1 }
            return Data("{}".utf8)
        }
    }
    func testLiveEnvelopeFailureKeepsSnapshotButNeverMasqueradesAsFresh() async {
        let live = #"{"observed_at":"2026-11-02T12:00:00Z","turn_active":true,"#
            + #""current":{"id":"t","tool":"Read","summary":"a.swift"},"agents":[],"agents_state":"known"}"#
        let runner = FakeRunner([
            .success("{\"live_ok\":true,\"live\":\(live),\"entries\":[],\"cursor\":\"c1\"}"),
            .success(#"{"live_ok":false,"live_error":"Activity unavailable","entries":[],"cursor":"c2"}"#),
            .failure(NSError(domain: "test", code: 1)),
            .success(#"{"entries":[],"cursor":"c3"}"#)
        ])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        await store.refresh()
        XCTAssertEqual(store.live?.current?.summary, "a.swift")
        XCTAssertNil(store.liveError)
        await store.refresh()
        XCTAssertEqual(store.live?.current?.summary, "a.swift")
        XCTAssertEqual(store.liveError, "Activity unavailable")
        await store.refresh()
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.liveError, "Activity unavailable")
        store.clearActivity()
        XCTAssertNil(store.live); XCTAssertFalse(store.liveLoaded)
        await store.refresh()
        XCTAssertEqual(store.liveError, "Activity unavailable", "older CLI is an explicit unavailable state")
    }

    func testLegacyFollowWithoutParentObservationStopsOnOwnCompletion() async {
        let stamp = "2026-11-02T12:00:00Z"
        let now = SessionFeedEntry.parseDate(stamp) ?? .distantPast
        let completed = #"{"live_ok":true,"live":{"observed_at":"2026-11-02T12:00:00Z","turn_active":false,"#
            + #""agents":[],"agents_state":"known"},"entries":[],"cursor":""}"#
        let runner = FakeRunner([.success(completed), .success(payload())])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        var selectedStatus = "running" // B was opened from A, absent in the root markers.
        await store.followSubagent("nested-b", interval: .milliseconds(1), readsMainFeed: true,
                                   isRunning: { selectedStatus == "running" }, isOnScreen: { true },
                                   onEntries: { _ in }, onLive: { snapshot, error in
            selectedStatus = SessionSubagentLifecycle.status(parentStatus: "running", snapshot: snapshot, error: error, now: now)
        })
        XCTAssertEqual(selectedStatus, "finished")
        XCTAssertEqual(runner.calls.filter { $0.contains("--subagent") }.count, 1)
        XCTAssertEqual(runner.calls.count, 2, "one final main-feed refresh; no repeated child polls")
    }

}

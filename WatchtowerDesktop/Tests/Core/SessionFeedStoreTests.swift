import XCTest
@testable import WatchtowerCore

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

    private func payload(cursor: String = "c1", entries: String = "", subagents: String = "", activity: String = "null") -> String {
        """
        {"session_id":7,"cursor":"\(cursor)","entries":[\(entries)],"subagents":[\(subagents)],
         "activity":\(activity),"skipped":0,"unknown_records":{}}
        """
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
        XCTAssertEqual(SessionFeedEntry.phoneKinds.union(["event"]), SessionFeedEntry.knownKinds)
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
        XCTAssertEqual(runner.calls[0], ["workbench", "session-feed", "--session", "7", "--json"])
        XCTAssertEqual(runner.calls[1], ["workbench", "session-feed", "--session", "7", "--json", "--after", "c1"])
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
        XCTAssertEqual(store.entries[0].subagent?.status, "running")
        await store.refresh()
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].subagent?.status, "finished")
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
                                   isRunning: { SessionFeedSubagent.currentStatus(of: pushed, in: store.entries) == "running" },
                                   isOnScreen: { true }, onEntries: { _ in })
        XCTAssertEqual(runner.calls.count, 4, "subagent + main per tick, none after finished")
        XCTAssertTrue(runner.calls[0].contains("--subagent"))
        XCTAssertFalse(runner.calls[1].contains("--subagent"))
        XCTAssertEqual(store.entries.first?.subagent?.status, "finished")
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
}

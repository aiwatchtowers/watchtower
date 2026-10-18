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

    private func payload(cursor: String = "c1", entries: String = "", subagents: String = "") -> String {
        """
        {"session_id":7,"cursor":"\(cursor)","entries":[\(entries)],"subagents":[\(subagents)],
         "skipped":0,"unknown_records":{}}
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

    func testSubagentFeedArgs() async throws {
        let runner = FakeRunner([.success(payload(entries: entry("s1", "agent")))])
        let store = SessionFeedStore(sessionID: 7, runner: runner)
        let list = try await store.subagentFeed("tu1")
        XCTAssertEqual(list.map(\.id), ["s1"])
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
}

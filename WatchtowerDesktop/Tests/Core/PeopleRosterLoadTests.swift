import XCTest
@testable import WatchtowerCore

@MainActor
final class PeopleRosterLoadTests: XCTestCase {
    /// A scripted `Run`: records each launch, hands its line sink and an
    /// exit switch to the test.
    private final class FakeRun {
        var launches: [Int] = []
        var onLine: (@MainActor (String) -> Void)?
        private var exit: CheckedContinuation<(exitCode: Int32, stderr: String), Never>?
        var cancelled = false

        func run(_ accountID: Int, _ onLine: @escaping @MainActor (String) -> Void) async -> (exitCode: Int32, stderr: String) {
            launches.append(accountID)
            self.onLine = onLine
            return await withTaskCancellationHandler {
                await withCheckedContinuation { exit = $0 }
            } onCancel: { [weak self] in
                Task { @MainActor in
                    self?.cancelled = true
                    self?.finish(exitCode: 143)
                }
            }
        }

        func finish(exitCode: Int32, stderr: String = "") {
            exit?.resume(returning: (exitCode, stderr))
            exit = nil
        }
    }

    private func line(total: Int, done: Int, phase: String = "Users", error: String? = nil) -> String {
        var json = """
        {"phase":"\(phase)","elapsed_sec":1,"users_total":0,"users_done":0,"channels_total":0,"channels_done":0,\
        "discovery_pages":0,"discovery_total_pages":0,"discovery_channels":0,"discovery_users":0,\
        "user_profiles_total":\(total),"user_profiles_done":\(done),"msg_channels_total":0,"msg_channels_done":0,\
        "messages_fetched":0
        """
        if let error { json += #","error":"\#(error)""# }
        return json + "}"
    }

    private func makeLoad(_ fake: FakeRun) -> PeopleRosterLoad {
        PeopleRosterLoad { accountID, onLine in await fake.run(accountID, onLine) }
    }

    /// Lets the load's task reach the fake's suspension point.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    func testStartsOnceWhileRunningAndAfterDone() async {
        let fake = FakeRun()
        let load = makeLoad(fake)
        XCTAssertTrue(load.start(accountID: 1))
        XCTAssertFalse(load.start(accountID: 1), "a second Slack sheet close must not start a second load")
        await settle()
        fake.finish(exitCode: 0)
        await load.waitForCompletion()
        XCTAssertFalse(load.start(accountID: 1))
        XCTAssertEqual(fake.launches, [1])
    }

    func testProgressFollowsTheLines() async {
        let fake = FakeRun()
        let load = makeLoad(fake)
        load.start(accountID: 7)
        await settle()
        XCTAssertEqual(load.state, .loading(fetched: 0, saved: 0))

        fake.onLine?(line(total: 200, done: 0))
        XCTAssertEqual(load.state, .loading(fetched: 200, saved: 0))
        fake.onLine?(line(total: 600, done: 214))
        XCTAssertEqual(load.state, .loading(fetched: 600, saved: 214))
        fake.onLine?("not json")
        XCTAssertEqual(load.state, .loading(fetched: 600, saved: 214), "a stray line changes nothing")
        fake.onLine?(line(total: 600, done: 600, phase: "Done"))

        fake.finish(exitCode: 0)
        await load.waitForCompletion()
        XCTAssertEqual(load.state, .done(count: 600))
        XCTAssertEqual(fake.launches, [7])
    }

    func testErrorLineIsTheFailureReason() async {
        let fake = FakeRun()
        let load = makeLoad(fake)
        load.start(accountID: 1)
        await settle()
        fake.onLine?(line(total: 0, done: 0, phase: "Done", error: "slack account 1 is disabled"))
        fake.finish(exitCode: 1, stderr: "Error: users sync failed")
        await load.waitForCompletion()
        XCTAssertEqual(load.state, .failed("slack account 1 is disabled"))
    }

    func testStderrIsTheReasonWithoutAnErrorLine() async {
        let fake = FakeRun()
        let load = makeLoad(fake)
        load.start(accountID: 1)
        await settle()
        fake.finish(exitCode: 2, stderr: "  panic: boom\n")
        await load.waitForCompletion()
        XCTAssertEqual(load.state, .failed("panic: boom"))

        let silent = FakeRun()
        let other = makeLoad(silent)
        other.start(accountID: 1)
        await settle()
        silent.finish(exitCode: 3)
        await other.waitForCompletion()
        XCTAssertEqual(other.state, .failed("exit code 3"))
    }

    func testRetryAfterFailureStartsAgain() async {
        let fake = FakeRun()
        let load = makeLoad(fake)
        load.start(accountID: 1)
        await settle()
        fake.finish(exitCode: 1, stderr: "network")
        await load.waitForCompletion()

        XCTAssertTrue(load.start(accountID: 1))
        await settle()
        fake.finish(exitCode: 0)
        await load.waitForCompletion()
        XCTAssertEqual(load.state, .done(count: 0))
        XCTAssertEqual(fake.launches, [1, 1])
    }

    /// The load lives outside any view: nothing but its own exit ends it,
    /// so moving on to About you leaves it running.
    func testLoadOutlivesItsStarter() async {
        let fake = FakeRun()
        let load = makeLoad(fake)
        do {
            load.start(accountID: 1)
        }
        await settle()
        fake.onLine?(line(total: 50, done: 0))
        XCTAssertEqual(load.state, .loading(fetched: 50, saved: 0))
        XCTAssertFalse(fake.cancelled)
        fake.finish(exitCode: 0)
        await load.waitForCompletion()
        XCTAssertEqual(load.state, .done(count: 50))
    }

    /// App quit: the run is cancelled (the real child gets SIGTERM) and a
    /// later start begins again.
    func testStopCancelsTheRun() async {
        let fake = FakeRun()
        let load = makeLoad(fake)
        load.start(accountID: 1)
        await settle()
        load.stop()
        await settle()
        XCTAssertTrue(fake.cancelled)
        XCTAssertEqual(load.state, .idle)
        XCTAssertTrue(load.start(accountID: 1))
        await settle()
        fake.finish(exitCode: 0)
        await load.waitForCompletion()
    }
}

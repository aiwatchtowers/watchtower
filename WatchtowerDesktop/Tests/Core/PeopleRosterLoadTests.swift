import XCTest
@testable import WatchtowerCore

@MainActor
final class PeopleRosterLoadTests: XCTestCase {
    /// A scripted `Run`: records each launch and parks until the test ends
    /// it (or the run is cancelled).
    private final class FakeRun {
        var launches: [Int] = []
        var onLine: (@MainActor (String) -> Void)?
        var cancelled = false
        private var exit: CheckedContinuation<(exitCode: Int32, stderr: String), Never>?

        var isRunning: Bool { exit != nil }

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

    /// Spins the main actor until `condition` holds (bounded).
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "condition not reached", file: file, line: line)
    }

    private func started(_ load: PeopleRosterLoad, _ fake: FakeRun, account: Int = 1) async {
        load.start(accountID: account)
        await waitUntil { fake.isRunning }
    }

    func testStartsOnceWhileRunningAndAfterDone() async {
        let fake = FakeRun()
        let load = makeLoad(fake)
        XCTAssertTrue(load.start(accountID: 1))
        XCTAssertFalse(load.start(accountID: 1), "a second trigger must not start a second load")
        await waitUntil { fake.isRunning }
        fake.finish(exitCode: 0)
        await load.waitForCompletion()
        XCTAssertFalse(load.start(accountID: 1))
        XCTAssertEqual(fake.launches, [1])
    }

    func testProgressFollowsTheLines() async {
        let fake = FakeRun()
        let load = makeLoad(fake)
        await started(load, fake, account: 7)
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

    /// Paging has no total (Slack gives none): the count stands alone;
    /// saving knows it.
    func testProgressText() {
        XCTAssertNil(PeopleRosterState.idle.progressText)
        XCTAssertEqual(PeopleRosterState.loading(fetched: 0, saved: 0).progressText, "Loading people… 0")
        XCTAssertEqual(PeopleRosterState.loading(fetched: 214, saved: 0).progressText, "Loading people… 214")
        XCTAssertEqual(PeopleRosterState.loading(fetched: 600, saved: 214).progressText, "Loading people… 214 of 600")
        XCTAssertEqual(PeopleRosterState.done(count: 600).progressText, "600 people loaded")
        XCTAssertEqual(PeopleRosterState.failed("boom").progressText, "Couldn't load people: boom")
    }

    func testErrorLineIsTheFailureReason() async {
        let fake = FakeRun()
        let load = makeLoad(fake)
        await started(load, fake)
        fake.onLine?(line(total: 0, done: 0, phase: "Done", error: "slack account 1 is disabled"))
        fake.finish(exitCode: 1, stderr: "Error: users sync failed")
        await load.waitForCompletion()
        XCTAssertEqual(load.state, .failed("slack account 1 is disabled"))
    }

    func testStderrIsTheReasonWithoutAnErrorLine() async {
        let fake = FakeRun()
        let load = makeLoad(fake)
        await started(load, fake)
        fake.finish(exitCode: 2, stderr: "  panic: boom\n")
        await load.waitForCompletion()
        XCTAssertEqual(load.state, .failed("panic: boom"))

        let silent = FakeRun()
        let other = makeLoad(silent)
        await started(other, silent)
        silent.finish(exitCode: 3)
        await other.waitForCompletion()
        XCTAssertEqual(other.state, .failed("exit code 3"))
    }

    /// Retry reloads the account whose load failed.
    func testRetryReloadsTheFailedAccount() async {
        let fake = FakeRun()
        let load = makeLoad(fake)
        XCTAssertFalse(load.retry(), "nothing failed yet")
        await started(load, fake, account: 4)
        fake.finish(exitCode: 1, stderr: "network")
        await load.waitForCompletion()

        XCTAssertTrue(load.retry())
        await waitUntil { fake.isRunning }
        fake.finish(exitCode: 0)
        await load.waitForCompletion()
        XCTAssertEqual(load.state, .done(count: 0))
        XCTAssertEqual(fake.launches, [4, 4])
        XCTAssertEqual(load.accountID, 4)
    }

    /// The load lives outside any view: nothing but its own exit ends it,
    /// so moving on to About you leaves it running.
    func testLoadOutlivesItsStarter() async {
        let fake = FakeRun()
        let load = makeLoad(fake)
        await started(load, fake)
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
        await started(load, fake)
        load.stop()
        await waitUntil { fake.cancelled }
        XCTAssertEqual(load.state, .idle)
        XCTAssertTrue(load.start(accountID: 1))
        await waitUntil { fake.isRunning }
        fake.finish(exitCode: 0)
        await load.waitForCompletion()
    }

    /// A cancelled run's late lines and exit never touch the next run.
    func testCancelledRunIsIgnored() async {
        let old = FakeRun()
        var runs = [old]
        let fresh = FakeRun()
        runs.append(fresh)
        var next = 0
        let load = PeopleRosterLoad { accountID, onLine in
            let fake = runs[next]
            next += 1
            return await fake.run(accountID, onLine)
        }
        await started(load, old)
        let oldLine = old.onLine
        load.stop()
        await waitUntil { old.cancelled }

        load.start(accountID: 2)
        await waitUntil { fresh.isRunning }
        oldLine?(line(total: 999, done: 0))
        XCTAssertEqual(load.state, .loading(fetched: 0, saved: 0))
        fresh.onLine?(line(total: 10, done: 0))
        XCTAssertEqual(load.state, .loading(fetched: 10, saved: 0))
        fresh.finish(exitCode: 0)
        await load.waitForCompletion()
        XCTAssertEqual(load.state, .done(count: 10))
    }
}

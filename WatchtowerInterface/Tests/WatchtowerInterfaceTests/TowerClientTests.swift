import WatchtowerInterface
import XCTest

/// `TowerClient`'s state machine over a scripted transport and a manual
/// clock (mobile Inbox spec §3 "Reconnecting", §9). Time moves only through
/// `clock.advance`; each step then waits until the client has gone back to
/// sleep (the down timer and the backoff: two sleepers) or for the calls it
/// made, never for wall-clock time.
final class TowerClientTests: XCTestCase {
    private var clock: ManualClock!
    private var fake: FakeTransport!

    override func setUp() {
        super.setUp()
        clock = ManualClock()
        fake = FakeTransport(clock: clock)
    }

    private func makeClient(
        restartDaemon: (@Sendable () async -> Bool)? = nil,
        startDaemon: (@Sendable () async -> Void)? = nil
    ) -> TowerClient {
        TowerClient(transport: fake, clock: clock, restartDaemon: restartDaemon, startDaemon: startDaemon)
    }

    private func ping(_ client: TowerClient) async -> Result<PingResponse, TowerFailure> {
        await client.read(.towerPing, params: PingRequest())
    }

    private func pause(_ client: TowerClient, key: String = "pause") async -> TowerActOutcome<PauseResponse> {
        await client.act(.syncPause, key: key) { PauseRequest(requestID: $0) }
    }

    /// Moves time by `step`, then waits for `hellos` hello calls in all and
    /// for the client to sleep again (down timer + backoff).
    private func step(_ step: Duration, hellos: Int) async {
        clock.advance(by: step)
        await fake.waitFor(.towerHello, count: hellos)
        await clock.waitForSleepers(2)
    }

    /// Waits until the client's screen state is `expected`.
    private func waitForState(_ client: TowerClient, _ expected: TowerScreenState) async {
        for await state in await client.screenStates() where state == expected { return }
    }

    /// Drives a fresh client (daemon down from the start) to `failed(.down)`:
    /// a read, then the whole backoff schedule up to 15 s. Returns the read.
    private func failDown(_ client: TowerClient) async -> Result<PingResponse, TowerFailure> {
        fake.setDown(true)
        let read = Task { await ping(client) }
        await fake.waitFor(.towerHello, count: 1)
        await clock.waitForSleepers(2)
        var hellos = 1
        for interval in [200, 400, 800, 1_600, 2_000, 2_000, 2_000, 2_000, 2_000] {
            hellos += 1
            await step(.milliseconds(interval), hellos: hellos)
        }
        clock.advance(by: .seconds(2)) // 15 s since the first attempt
        return await read.value
    }

    // MARK: - Screen states

    func testReadMovesLoadingThenReady() async throws {
        let client = makeClient()
        var states = await client.screenStates().makeAsyncIterator()
        let first = await states.next()
        XCTAssertEqual(first, .idle)

        let answer = try await ping(client).get()

        XCTAssertEqual(answer.at, FakeTransport.pingAt)
        let second = await states.next()
        let third = await states.next()
        XCTAssertEqual(second, .loading)
        XCTAssertEqual(third, .ready(stale: nil))
        XCTAssertEqual(fake.calls(.towerHello).count, 1, "the first call says hello first")
        XCTAssertEqual(fake.calls(.towerPing).count, 1)
    }

    func testDropUnderOneSecondShowsNoLine() async throws {
        let client = makeClient()
        _ = try await ping(client).get()
        fake.setDown(true)

        let read = Task { await ping(client) }
        await fake.waitFor(.towerPing, count: 2)
        await clock.waitForSleepers(2)
        var state = await client.screenState
        var line = await client.showsReconnectingLine()
        XCTAssertEqual(state, .reconnecting)
        XCTAssertFalse(line)

        await step(.milliseconds(200), hellos: 2) // t = 0.2 s, still down
        line = await client.showsReconnectingLine()
        XCTAssertFalse(line)

        fake.setDown(false)
        clock.advance(by: .milliseconds(400)) // t = 0.6 s, back
        _ = try await read.value.get()

        state = await client.screenState
        line = await client.showsReconnectingLine()
        XCTAssertEqual(state, .ready(stale: nil))
        XCTAssertFalse(line)
        await clock.waitForSleepers(0)
        clock.advance(by: .seconds(1)) // past 1 s: no timer is left to show the line
        line = await client.showsReconnectingLine()
        XCTAssertFalse(line)
        XCTAssertEqual(fake.calls(.towerPing).count, 3, "the read is re-sent once on return, no extra refresh")
    }

    func testDropOfThreeSecondsShowsTheLineThenRecovers() async throws {
        let client = makeClient()
        _ = try await ping(client).get()
        let events = await client.watch(.towerPing)
        await fake.waitFor(watchOpens: 1)

        fake.setDown(true)
        fake.dropWatches()
        await clock.waitForSleepers(2)
        var state = await client.screenState
        XCTAssertEqual(state, .reconnecting)

        await step(.milliseconds(200), hellos: 2) // 0.2 s
        await step(.milliseconds(400), hellos: 3) // 0.6 s
        var line = await client.showsReconnectingLine()
        XCTAssertFalse(line, "no line in the first second")
        await step(.milliseconds(800), hellos: 4) // 1.4 s
        line = await client.showsReconnectingLine()
        XCTAssertTrue(line, "the line shows after 1 s down")

        fake.setDown(false)
        clock.advance(by: .milliseconds(1_600)) // 3.0 s, back
        await fake.waitFor(watchOpens: 2)
        await fake.waitFor(.towerPing, count: 2)
        await waitForState(client, .ready(stale: nil))

        line = await client.showsReconnectingLine()
        state = await client.screenState
        XCTAssertFalse(line)
        XCTAssertEqual(state, .ready(stale: nil))
        XCTAssertEqual(fake.watchOpens, 2, "the watch is re-opened once")
        XCTAssertEqual(fake.calls(.towerPing).count, 2, "the client reads once on return")

        let event = ChangedEvent(id: "w", event: "changed", tables: ["inbox_items"])
        fake.emit(event)
        var received = events.makeAsyncIterator()
        let next = await received.next()
        XCTAssertEqual(next, event, "the re-opened watch delivers")
    }

    func testNeverReturnsFailsAfterFifteenSecondsWithRetry() async {
        let client = makeClient()

        let read = await failDown(client)

        let failure = TowerFailure(kind: .down, sentence: TowerText.daemonDown)
        XCTAssertEqual(read, .failure(failure))
        await waitForState(client, .failed(failure))
        XCTAssertEqual(failure.actionTitle, TowerText.retry)
        let line = await client.showsReconnectingLine()
        XCTAssertFalse(line)
    }

    func testRetryAfterDownAsksToStartDaemon() async throws {
        let started = Counter()
        let startDaemon: @Sendable () async -> Void = { started.increment() }
        let client = makeClient(startDaemon: startDaemon)
        _ = await failDown(client)
        await waitForState(client, .failed(TowerFailure(kind: .down, sentence: TowerText.daemonDown)))
        await clock.waitForSleepers(0)
        let hellosBefore = fake.calls(.towerHello).count
        let retriedAt = clock.now.offset

        let retry = Task { await client.retry() }
        await clock.waitForSleepers(2)
        XCTAssertEqual(started.value, 1)
        await step(.milliseconds(200), hellos: hellosBefore + 1) // still down
        fake.setDown(false)
        clock.advance(by: .milliseconds(400))
        await retry.value
        await waitForState(client, .ready(stale: nil))

        XCTAssertEqual(started.value, 1, "Retry asks the start queue once")
        let attempts = fake.calls(.towerHello).dropFirst(hellosBefore).map { $0.at - retriedAt }
        XCTAssertEqual(attempts, [.milliseconds(200), .milliseconds(600)], "the backoff starts again at 0.2 s")
    }

    func testBackoffDoublesFromTwoHundredMillisecondsToTwoSeconds() async {
        let client = makeClient()
        fake.setDown(true)
        let read = Task { await ping(client) }
        await fake.waitFor(.towerHello, count: 1)
        await clock.waitForSleepers(2)

        for (index, interval) in [200, 400, 800, 1_600, 2_000, 2_000].enumerated() {
            await step(.milliseconds(interval), hellos: index + 2)
        }

        let times = fake.calls(.towerHello).map(\.at)
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        XCTAssertEqual(gaps, [200, 400, 800, 1_600, 2_000, 2_000].map { .milliseconds($0) })
        read.cancel()
    }

    // MARK: - Actions

    func testPressedActionWaitsBusyAndIsSentWithTheSameRequestIDOnReturn() async throws {
        let client = makeClient()
        _ = try await ping(client).get()
        fake.setDown(true)

        let press = Task { await pause(client) }
        await fake.waitFor(.syncPause, count: 1)
        await clock.waitForSleepers(2)
        let busy = await client.actionState(key: "pause")
        XCTAssertEqual(busy, .busy)

        fake.setDown(false)
        clock.advance(by: .milliseconds(200))
        let outcome = await press.value

        XCTAssertEqual(outcome, .ok(PauseResponse(paused: true)))
        let ids = fake.calls(.syncPause).map(FakeTransport.requestID)
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotNil(ids.compactMap { $0 }.first)
        XCTAssertEqual(ids.first, ids.last, "the resend keeps the press's request_id")
        let after = await client.actionState(key: "pause")
        XCTAssertNil(after)
    }

    func testRetryAfterFailureReusesTheRequestID() async throws {
        let client = makeClient()
        _ = try await ping(client).get()
        fake.setDown(true)
        let press = Task { await pause(client) }
        await fake.waitFor(.syncPause, count: 1)
        await clock.waitForSleepers(2)
        var hellos = 1
        for interval in [200, 400, 800, 1_600, 2_000, 2_000, 2_000, 2_000, 2_000] {
            hellos += 1
            await step(.milliseconds(interval), hellos: hellos)
        }
        clock.advance(by: .seconds(2))
        let failed = await press.value
        XCTAssertEqual(failed, .failed(TowerFailure(kind: .down, sentence: TowerText.daemonDown)))

        fake.setDown(false)
        let retried = await pause(client)

        XCTAssertEqual(retried, .ok(PauseResponse(paused: true)))
        let ids = fake.calls(.syncPause).map(FakeTransport.requestID)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids.first, ids.last, "Retry re-sends the same request_id")
    }

    func testUnknownNeverResendsAndRefreshes() async throws {
        let client = makeClient()
        _ = try await ping(client).get()
        fake.respond(.syncPause) { Response(id: $0.id, status: .unknownStatus) }

        let outcome = await pause(client)

        XCTAssertEqual(outcome, .unknown)
        let state = await client.actionState(key: "pause")
        XCTAssertEqual(state, .unknown)
        XCTAssertEqual(fake.calls(.syncPause).count, 1, "an unknown outcome is never re-sent")
        XCTAssertEqual(fake.calls(.towerPing).count, 2, "the screen's last read is re-issued once")
        XCTAssertEqual(clock.sleeperCount, 0, "nothing is scheduled to send it again")
    }

    func testRefusalKeepsTheGoSentence() async throws {
        let client = makeClient()
        _ = try await ping(client).get()
        let sentence = "This item changed on the Mac. Look again."
        fake.respond(.syncPause) { Response(id: $0.id, status: .refused, refusal: Refusal(code: .changed, sentence: sentence)) }

        let outcome = await pause(client)

        XCTAssertEqual(outcome, .refused(sentence))
        let state = await client.actionState(key: "pause")
        XCTAssertEqual(state, .refused(sentence))
        let screen = await client.screenState
        XCTAssertEqual(screen, .ready(stale: nil), "a refused action leaves the screen as it was")
    }

    // MARK: - Handshake

    func testHelloMismatchRestartsTheDaemonWhenItCan() async throws {
        let restarts = Counter()
        let fake = try XCTUnwrap(fake)
        fake.helloVersion("0000000000000000")
        let client = makeClient(
            restartDaemon: {
                restarts.increment()
                fake.helloVersion(InterfaceVersion.current)
                return true
            },
            startDaemon: nil
        )

        let read = Task { await ping(client) }
        await clock.waitForSleepers(2)
        clock.advance(by: .milliseconds(200))
        _ = try await read.value.get()

        XCTAssertEqual(restarts.value, 1)
        let state = await client.screenState
        XCTAssertEqual(state, .ready(stale: nil))
        XCTAssertEqual(fake.calls(.towerHello).count, 2)
    }

    func testHelloMismatchWithoutRestartShowsDifferentVersion() async {
        fake.helloVersion("0000000000000000")
        let client = makeClient()

        let read = await ping(client)

        let failure = TowerFailure(kind: .version, sentence: TowerText.differentVersion)
        XCTAssertEqual(read, .failure(failure))
        let state = await client.screenState
        XCTAssertEqual(state, .failed(failure))
        XCTAssertEqual(failure.actionTitle, TowerText.restart)
        XCTAssertEqual(fake.calls(.towerPing).count, 0, "nothing is sent to a daemon of another version")
    }
}

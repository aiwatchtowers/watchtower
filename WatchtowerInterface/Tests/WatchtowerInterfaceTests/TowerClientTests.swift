import WatchtowerInterface
import XCTest

/// `TowerClient`'s state machine over a scripted transport and a manual
/// clock (mobile Inbox spec §3 "Reconnecting", §9). Time moves only through
/// `clock.advance`; each step then waits for the calls the client made and
/// for it to sleep until its next attempt, never for wall-clock time.
///
/// After a drop at 0 the attempts come at 0.2, 0.6, 1.0 (the line probe),
/// 1.4, 3.0, 5.0 … 13.0 s, and the cycle fails at 15 s.
final class TowerClientTests: XCTestCase {
    private var clock: ManualClock!
    private var fake: FakeTransport!

    /// The attempts after a drop at 0, in milliseconds.
    private static let attempts = [200, 600, 1_000, 1_400, 3_000, 5_000, 7_000, 9_000, 11_000, 13_000]

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

    /// Moves time to `offset`, then waits for `hellos` hello calls in all
    /// and for the client to sleep until `next`.
    private func step(to offset: Duration, hellos: Int, next: Duration) async {
        clock.advance(by: offset - clock.now.offset)
        await fake.waitFor(.towerHello, count: hellos)
        await clock.waitForSleeper(at: next)
    }

    /// Runs the whole down schedule of a cycle that began at `start` with
    /// `hellos` hellos already made, up to 15 s.
    private func runToFailure(from start: Duration, hellos: Int) async {
        let offsets = Self.attempts.map { start + .milliseconds($0) }
        for (index, offset) in offsets.enumerated() {
            let next = index + 1 < offsets.count ? offsets[index + 1] : start + .seconds(15)
            await step(to: offset, hellos: hellos + index + 1, next: next)
        }
        clock.advance(by: start + .seconds(15) - clock.now.offset)
    }

    /// Waits until the client's screen state is `expected`.
    private func waitForState(_ client: TowerClient, _ expected: TowerScreenState) async {
        for await state in await client.screenStates() where state == expected { return }
    }

    /// Drives a fresh client (daemon down from the start) to `failed(.down)`.
    private func failDown(_ client: TowerClient) async -> Result<PingResponse, TowerFailure> {
        fake.setDown(true)
        let read = Task { await ping(client) }
        await fake.waitFor(.towerHello, count: 1)
        await clock.waitForSleeper(at: .milliseconds(200))
        await runToFailure(from: .zero, hellos: 1)
        return await read.value
    }

    private static let down = TowerFailure(kind: .down, sentence: TowerText.daemonDown)

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
        await clock.waitForSleeper(at: .milliseconds(200))
        var state = await client.screenState
        var line = await client.showsReconnectingLine()
        XCTAssertEqual(state, .reconnecting)
        XCTAssertFalse(line)

        await step(to: .milliseconds(200), hellos: 2, next: .milliseconds(600))
        await step(to: .milliseconds(600), hellos: 3, next: .seconds(1))
        line = await client.showsReconnectingLine()
        XCTAssertFalse(line)

        fake.setDown(false) // the daemon is back after its ~1 s restart
        clock.advance(by: .milliseconds(400)) // t = 1.0 s: the line probe finds it
        _ = try await read.value.get()

        state = await client.screenState
        line = await client.showsReconnectingLine()
        XCTAssertEqual(state, .ready(stale: nil))
        XCTAssertFalse(line, "a restart of about a second shows no line")
        XCTAssertEqual(fake.calls(.towerHello).last?.at, .seconds(1))
        await clock.waitForSleepers(0)
        XCTAssertEqual(fake.calls(.towerPing).count, 3, "the read is re-sent once on return, no extra refresh")
    }

    func testDropOfThreeSecondsShowsTheLineThenRecovers() async throws {
        let client = makeClient()
        _ = try await ping(client).get()
        let events = await client.watch(.towerPing)
        await fake.waitFor(watchOpens: 1)

        fake.setDown(true)
        fake.dropWatches()
        await clock.waitForSleeper(at: .milliseconds(200))
        var state = await client.screenState
        XCTAssertEqual(state, .reconnecting)

        await step(to: .milliseconds(200), hellos: 2, next: .milliseconds(600))
        await step(to: .milliseconds(600), hellos: 3, next: .seconds(1))
        var line = await client.showsReconnectingLine()
        XCTAssertFalse(line, "no line in the first second")
        await step(to: .seconds(1), hellos: 4, next: .milliseconds(1_400))
        line = await client.showsReconnectingLine()
        XCTAssertTrue(line, "the line shows once the 1 s probe fails")
        await step(to: .milliseconds(1_400), hellos: 5, next: .seconds(3))

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

        XCTAssertEqual(read, .failure(Self.down))
        await waitForState(client, .failed(Self.down))
        XCTAssertEqual(Self.down.actionTitle, TowerText.retry)
        let line = await client.showsReconnectingLine()
        XCTAssertFalse(line)
    }

    func testHungHelloFailsAfterFifteenSeconds() async {
        fake.hang(.towerHello)
        let client = makeClient()
        let read = Task { await ping(client) }
        await fake.waitFor(.towerHello, count: 1)
        await clock.waitForSleeper(at: .milliseconds(2_500))
        var state = await client.screenState
        XCTAssertEqual(state, .loading)

        // Each unanswered hello gives up after 2.5 s and the next one starts.
        for attempt in 1...5 {
            let at = Duration.milliseconds(2_500 * attempt)
            await step(to: at, hellos: attempt + 1, next: at + .milliseconds(2_500))
        }
        state = await client.screenState
        let line = await client.showsReconnectingLine()
        XCTAssertEqual(state, .reconnecting)
        XCTAssertTrue(line)
        clock.advance(by: .seconds(15) - clock.now.offset)

        let result = await read.value
        XCTAssertEqual(result, .failure(Self.down))
        await waitForState(client, .failed(Self.down))
        XCTAssertGreaterThanOrEqual(fake.cancelledCalls, 5, "each unanswered hello's call is cancelled (its connection dropped)")
        XCTAssertEqual(fake.calls(.towerPing).count, 0)
    }

    func testRetryAfterDownAsksToStartDaemon() async throws {
        let started = Counter()
        let startDaemon: @Sendable () async -> Void = { started.increment() }
        let client = makeClient(startDaemon: startDaemon)
        _ = await failDown(client)
        await waitForState(client, .failed(Self.down))
        let hellosBefore = fake.calls(.towerHello).count
        let retriedAt = clock.now.offset

        let retry = Task { await client.retry() }
        await clock.waitForSleeper(at: retriedAt + .milliseconds(200))
        XCTAssertEqual(started.value, 1)
        await step(to: retriedAt + .milliseconds(200), hellos: hellosBefore + 1, next: retriedAt + .milliseconds(600))
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
        await clock.waitForSleeper(at: .milliseconds(200))

        let offsets = Self.attempts.prefix(8).map { Duration.milliseconds($0) }
        for (index, offset) in offsets.dropLast().enumerated() {
            await step(to: offset, hellos: index + 2, next: offsets[index + 1])
        }

        let times = fake.calls(.towerHello).map(\.at)
        XCTAssertEqual(times, [.zero] + offsets.dropLast(), "plus one probe at the line's 1 s mark")
        let backoff = times.filter { $0 != .seconds(1) }
        let gaps = zip(backoff.dropFirst(), backoff).map { $0 - $1 }
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
        await clock.waitForSleeper(at: .milliseconds(200))
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
        await clock.waitForSleeper(at: .milliseconds(200))
        await runToFailure(from: .zero, hellos: 1)
        let failed = await press.value
        XCTAssertEqual(failed, .failed(Self.down))

        fake.setDown(false)
        let retried = await pause(client)

        XCTAssertEqual(retried, .ok(PauseResponse(paused: true)))
        let ids = fake.calls(.syncPause).map(FakeTransport.requestID)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids.first, ids.last, "Retry re-sends the same request_id")
    }

    func testHungActionFailsAtTheWriteLimitAndKeepsItsRequestID() async throws {
        let client = makeClient()
        _ = try await ping(client).get()
        fake.hang(.syncPause)

        let press = Task { await pause(client) }
        await fake.waitFor(.syncPause, count: 1)
        await clock.waitForSleeper(at: TowerTiming.writeAnswerLimit)
        let busy = await client.actionState(key: "pause")
        XCTAssertEqual(busy, .busy)
        clock.advance(by: TowerTiming.writeAnswerLimit)
        let outcome = await press.value

        XCTAssertEqual(outcome, .failed(Self.down), "a press is never busy forever")
        XCTAssertEqual(fake.cancelledCalls, 1, "its call is cancelled, which drops the connection")
        let after = await client.actionState(key: "pause")
        XCTAssertNil(after)
        XCTAssertGreaterThan(TowerTiming.writeAnswerLimit, .seconds(120), "above the socket's 120 s approve wait")
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
        await clock.waitForSleepers(0)
    }

    func testRefusalKeepsTheGoSentence() async throws {
        let client = makeClient()
        _ = try await ping(client).get()
        let sentence = "This item changed on the Mac. Look again."
        fake.respond(.syncPause) { Response(id: $0.id, status: .refused, refusal: Refusal(code: .changed, sentence: sentence)) }

        let outcome = await pause(client)

        XCTAssertEqual(outcome, .refused(Refusal(code: .changed, sentence: sentence)), "the code travels with the sentence")
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
        await clock.waitForSleeper(at: .milliseconds(200))
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

    // MARK: - Hello answer

    func testHelloAnswerCarriesThePauseAndLeavesTheStateAlone() async {
        fake.respond(.towerHello) {
            FakeTransport.ok($0, HelloResponse(
                interfaceVersion: InterfaceVersion.current, build: "test", syncPaused: true, noSync: false
            ))
        }
        let client = makeClient()

        let hello = await client.helloAnswer()

        XCTAssertEqual(hello?.syncPaused, true)
        let state = await client.screenState
        XCTAssertEqual(state, .idle, "a hello beside the cycle is no screen read")
    }

    func testReadAsideAnswersWithoutBecomingTheScreensRead() async {
        let feed = Feed(v: 1, builtAt: "2026-11-16T09:00:00Z", folders: [], cards: [])
        fake.respond(.inboxFeed) { FakeTransport.ok($0, feed) }
        let client = makeClient()

        let answer: Feed? = await client.readAside(.inboxFeed, params: FeedRequest(limit: 1))

        XCTAssertEqual(answer, feed)
        let state = await client.screenState
        XCTAssertEqual(state, .idle, "a read beside the screen moves no screen state")
        await client.retry()
        XCTAssertEqual(fake.calls(.inboxFeed).count, 1, "and is never re-issued as the screen's read")
    }

    func testHelloAnswerIsNilFromAnotherVersionOrADownTower() async {
        fake.helloVersion("0000000000000000")
        let other = await makeClient().helloAnswer()
        XCTAssertNil(other)

        fake.setDown(true)
        let down = await makeClient().helloAnswer()
        XCTAssertNil(down)
    }
}

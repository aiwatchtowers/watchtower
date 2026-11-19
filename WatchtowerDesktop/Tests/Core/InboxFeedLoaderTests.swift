import Foundation
import os
import WatchtowerInterface
import XCTest
@testable import WatchtowerCore

/// A tower that answers `tower.hello` with this build's version and
/// `inbox.feed` with `nextFeed` (or `nextRefusal`), optionally holding each
/// feed read until the test releases it. Watches stay open until the
/// consumer stops; the test pushes `changed` events into them. Every change
/// of the counts wakes the waiters (`until`), so tests never poll or sleep.
final class ScriptedFeedTransport: TowerTransport, @unchecked Sendable {
    private struct State {
        var feedCalls: [FeedRequest] = []
        var nextFeed = Feed(v: 1, builtAt: "2026-11-16T09:00:00Z", folders: [], cards: [])
        var nextRefusal: Refusal?
        var down = false
        var hold = false
        var held: [CheckedContinuation<Void, Never>] = []
        var watches: [AsyncThrowingStream<ChangedEvent, Error>.Continuation] = []
        var watchesClosed = 0
        var acts: [ActRequest] = []
        var actResult = ActResult()
        var actRefusal: Refusal?
        var waiters: [(due: @Sendable (Snapshot) -> Bool, continuation: CheckedContinuation<Void, Never>)] = []
    }

    struct Snapshot {
        var feedCalls: Int
        var heldReads: Int
        var openWatches: Int
        var watchesClosed: Int
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var feedCalls: [FeedRequest] { state.withLock { $0.feedCalls } }
    /// Every `inbox.act` request, in order.
    var acts: [ActRequest] { state.withLock { $0.acts } }

    /// How the next `inbox.act` calls answer: `refusal`, else ok with `result`.
    func answerActs(_ result: ActResult = ActResult(), refusal: Refusal? = nil) {
        state.withLock { $0.actResult = result; $0.actRefusal = refusal }
    }

    func answer(_ feed: Feed) { state.withLock { $0.nextFeed = feed; $0.nextRefusal = nil } }
    func refuse(_ refusal: Refusal) { state.withLock { $0.nextRefusal = refusal } }
    func holdReads(_ on: Bool) { state.withLock { $0.hold = on } }
    /// While down, every call fails as a socket the daemon closed does.
    func goDown(_ on: Bool) { state.withLock { $0.down = on } }

    private struct Down: Error {}

    /// Lets every held read answer.
    func release() {
        let held = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            defer { state.held = [] }
            return state.held
        }
        held.forEach { $0.resume() }
    }

    /// Pushes one `changed` event into every open watch.
    func changed() {
        let watches = state.withLock { $0.watches }
        watches.forEach { $0.yield(ChangedEvent(id: "w", event: "changed", tables: nil)) }
    }

    func until(_ due: @escaping @Sendable (Snapshot) -> Bool) async {
        await withCheckedContinuation { continuation in
            let now = state.withLock { state -> Bool in
                if due(Self.snapshot(state)) { return true }
                state.waiters.append((due, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }

    func call(_ request: Request) async throws -> Response {
        if state.withLock({ $0.down }) { throw Down() }
        switch request.command {
        case TowerCommand.towerHello.rawValue:
            return try Self.ok(request, HelloResponse(
                interfaceVersion: InterfaceVersion.current, build: "test", syncPaused: false, noSync: false))
        case TowerCommand.inboxFeed.rawValue:
            let params = try request.params.map { try JSONDecoder().decode(FeedRequest.self, from: $0.data) }
            let hold = mutate { $0.feedCalls.append(params ?? FeedRequest()); return $0.hold }
            if hold {
                await withCheckedContinuation { continuation in
                    mutate { $0.held.append(continuation) }
                }
            }
            let (feed, refusal) = state.withLock { ($0.nextFeed, $0.nextRefusal) }
            if let refusal { return Response(id: request.id, status: .refused, refusal: refusal) }
            return try Self.ok(request, feed)
        case TowerCommand.inboxAct.rawValue:
            let act = try JSONDecoder().decode(ActRequest.self, from: XCTUnwrap(request.params).data)
            let (result, refusal) = state.withLock { state -> (ActResult, Refusal?) in
                state.acts.append(act)
                return (state.actResult, state.actRefusal)
            }
            if let refusal { return Response(id: request.id, status: .refused, refusal: refusal) }
            return try Self.ok(request, result)
        default:
            return Response(id: request.id, status: .refused, refusal: Refusal(code: .unsupported, sentence: "no"))
        }
    }

    func watch(_ request: Request) -> AsyncThrowingStream<ChangedEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ChangedEvent, Error>.makeStream()
        continuation.onTermination = { [weak self] _ in self?.mutate { $0.watchesClosed += 1 } }
        mutate { $0.watches.append(continuation) }
        return stream
    }

    @discardableResult
    private func mutate<T>(_ change: (inout State) -> T) -> T {
        let (value, ready) = state.withLock { state -> (T, [CheckedContinuation<Void, Never>]) in
            let value = change(&state)
            let snapshot = Self.snapshot(state)
            let ready = state.waiters.filter { $0.due(snapshot) }.map(\.continuation)
            state.waiters.removeAll { $0.due(snapshot) }
            return (value, ready)
        }
        ready.forEach { $0.resume() }
        return value
    }

    private static func snapshot(_ state: State) -> Snapshot {
        Snapshot(feedCalls: state.feedCalls.count, heldReads: state.held.count,
                 openWatches: state.watches.count - state.watchesClosed, watchesClosed: state.watchesClosed)
    }

    private static func ok(_ request: Request, _ value: some Encodable) throws -> Response {
        Response(id: request.id, status: .ok, result: try RawJSON(data: JSONEncoder().encode(value)))
    }
}

@MainActor
final class InboxFeedLoaderTests: XCTestCase {
    private func feed(_ builtAt: String) -> Feed {
        Feed(v: 1, builtAt: builtAt, folders: [], cards: [])
    }

    private func loader(_ transport: ScriptedFeedTransport) -> InboxFeedLoader {
        let client = TowerClient(transport: transport, clock: ContinuousClock(), restartDaemon: nil, startDaemon: nil)
        return InboxFeedLoader(client: client) { FeedRequest() }
    }

    /// Waits for the loader's read on its way, if any, to finish.
    private func settle(_ loader: InboxFeedLoader) async {
        while let read = loader.pendingRead { await read.value }
    }

    func testReadsOnOpenChangedAndNavigation() async {
        let transport = ScriptedFeedTransport()
        transport.answer(feed("A"))
        let loader = loader(transport)
        defer { loader.close() }

        loader.open()
        await transport.until { $0.feedCalls >= 1 && $0.openWatches == 1 }
        await settle(loader)
        XCTAssertEqual(loader.feed?.builtAt, "A", "open reads")

        transport.answer(feed("B"))
        transport.changed()
        await transport.until { $0.feedCalls >= 2 }
        await settle(loader)
        XCTAssertEqual(loader.feed?.builtAt, "B", "a changed event reads")

        transport.answer(feed("C"))
        loader.navigate(to: 7)
        await settle(loader)
        XCTAssertEqual(transport.feedCalls.count, 3, "navigation reads")
        XCTAssertEqual(loader.feed?.builtAt, "C")
        XCTAssertEqual(loader.folder, 7)
    }

    func testAChangeDuringAReadQueuesExactlyOneMore() async {
        let transport = ScriptedFeedTransport()
        transport.holdReads(true)
        let loader = loader(transport)
        defer { loader.close() }

        loader.open()
        await transport.until { $0.heldReads == 1 }
        // Three changes and a navigation while the first read is on its way.
        loader.reload()
        loader.reload()
        loader.navigate(to: 3)
        loader.reload()
        XCTAssertEqual(transport.feedCalls.count, 1, "no second read while one runs")

        transport.release()
        await transport.until { $0.heldReads == 1 && $0.feedCalls == 2 }
        transport.holdReads(false)
        transport.release()
        await settle(loader)
        XCTAssertEqual(transport.feedCalls.count, 2, "the changes during a read make exactly one more read")
    }

    func testWatchClosesWhenTheWindowHides() async {
        let transport = ScriptedFeedTransport()
        let loader = loader(transport)

        loader.open()
        await transport.until { $0.openWatches == 1 }
        loader.close()
        await transport.until { $0.watchesClosed == 1 }
        XCTAssertFalse(loader.isOpen)

        await settle(loader)
        let reads = transport.feedCalls.count
        transport.changed()
        loader.open()
        await transport.until { $0.openWatches == 1 && $0.feedCalls == reads + 1 }
        loader.close()
    }

    func testFailedReadKeepsTheLastFeed() async {
        let transport = ScriptedFeedTransport()
        transport.answer(feed("A"))
        let loader = loader(transport)
        defer { loader.close() }

        loader.open()
        await transport.until { $0.feedCalls >= 1 }
        await settle(loader)
        XCTAssertEqual(loader.feed?.builtAt, "A")

        transport.refuse(Refusal(code: .unsupported, sentence: "The Inbox couldn't be read."))
        loader.reload()
        await settle(loader)
        XCTAssertEqual(loader.feed?.builtAt, "A", "a failed read keeps the last list")
        XCTAssertEqual(loader.failure?.sentence, "The Inbox couldn't be read.")

        transport.answer(feed("B"))
        loader.reload()
        await settle(loader)
        XCTAssertEqual(loader.feed?.builtAt, "B")
        XCTAssertNil(loader.failure, "an answer clears the failure")
    }
}

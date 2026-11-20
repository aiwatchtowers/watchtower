import Combine
import XCTest
@testable import WatchtowerCore

/// A file-event source the test fires by hand; `failing` paths refuse to open.
@MainActor
final class FakeFileEventSource: FileEventSource {
    var failing: Set<String> = []
    private(set) var opens: [String] = []
    private var handlers: [String: (id: Int, onEvent: @Sendable (FileEvent) -> Void)] = [:]
    private var nextID = 0

    var openPaths: Set<String> { Set(handlers.keys) }

    func open(_ path: String, onEvent: @escaping @Sendable (FileEvent) -> Void) throws -> any Cancellable {
        if failing.contains(path) { throw POSIXError(.EMFILE) }
        nextID += 1
        let id = nextID
        opens.append(path)
        handlers[path] = (id, onEvent)
        return AnyCancellable { [weak self] in
            MainActor.assumeIsolated {
                if self?.handlers[path]?.id == id { self?.handlers[path] = nil }
            }
        }
    }

    func fire(_ path: String, _ event: FileEvent = .changed) {
        handlers[path]?.onEvent(event)
    }
}

/// A clock that moves only when the test advances it.
@MainActor
final class ManualWatchClock: TranscriptWatchClock {
    private(set) var now: ContinuousClock.Instant = .now
    private var timers: [(id: Int, at: ContinuousClock.Instant, action: @MainActor () -> Void)] = []
    private var nextID = 0

    var pendingTimers: Int { timers.count }

    func schedule(at deadline: ContinuousClock.Instant, _ action: @escaping @MainActor () -> Void) -> any Cancellable {
        nextID += 1
        let id = nextID
        timers.append((id, deadline, action))
        return AnyCancellable { [weak self] in
            MainActor.assumeIsolated { self?.timers.removeAll { $0.id == id } }
        }
    }

    /// Runs every timer due by `now + duration`, in deadline order.
    func advance(by duration: Duration) {
        let target = now + duration
        while let next = timers.filter({ $0.at <= target }).min(by: { $0.at < $1.at }) {
            timers.removeAll { $0.id == next.id }
            now = max(now, next.at)
            next.action()
        }
        now = target
    }
}

@MainActor
final class TranscriptWatchTests: XCTestCase {
    private let conv = "/p/proj/s1.jsonl"
    private let subagentsDir = "/p/proj/s1/subagents"

    private final class Refreshes {
        var at: [ContinuousClock.Instant] = []
    }

    private func make() -> (TranscriptWatch, FakeFileEventSource, ManualWatchClock, Refreshes) {
        let source = FakeFileEventSource()
        let clock = ManualWatchClock()
        let refreshes = Refreshes()
        let watch = TranscriptWatch(fileEvents: source, clock: clock) { refreshes.at.append(clock.now) }
        return (watch, source, clock, refreshes)
    }

    func testEventRefreshesOnceAfterDebounce() {
        let (watch, source, clock, refreshes) = make()
        watch.update(paths: [conv], finishedAgents: [])
        XCTAssertEqual(source.openPaths, [conv])
        source.fire(conv)
        clock.advance(by: .milliseconds(249))
        XCTAssertTrue(refreshes.at.isEmpty)
        clock.advance(by: .milliseconds(1))
        XCTAssertEqual(refreshes.at.count, 1)
        clock.advance(by: .seconds(10))
        XCTAssertEqual(refreshes.at.count, 1, "one event, one read")
    }

    func testEventsInsideTheDebounceCoalesce() {
        let (watch, source, clock, refreshes) = make()
        watch.update(paths: [conv], finishedAgents: [])
        source.fire(conv)
        clock.advance(by: .milliseconds(100))
        source.fire(conv)
        clock.advance(by: .milliseconds(249))
        XCTAssertTrue(refreshes.at.isEmpty, "the debounce runs from the last event")
        clock.advance(by: .milliseconds(1))
        XCTAssertEqual(refreshes.at.count, 1)
    }

    func testBurstRefreshesAtMostOncePerSecondWithATrailingRead() throws {
        let (watch, source, clock, refreshes) = make()
        watch.update(paths: [conv], finishedAgents: [])
        var lastEvent = clock.now
        for _ in 0..<50 {
            source.fire(conv)
            lastEvent = clock.now
            clock.advance(by: .milliseconds(100))
        }
        clock.advance(by: .seconds(3))
        XCTAssertGreaterThanOrEqual(refreshes.at.count, 5, "a burst never starves the reads")
        XCTAssertLessThanOrEqual(refreshes.at.count, 6)
        for (a, b) in zip(refreshes.at, refreshes.at.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a.duration(to: b), .seconds(1))
        }
        XCTAssertGreaterThan(try XCTUnwrap(refreshes.at.last), lastEvent, "the last event is always read")
        clock.advance(by: .seconds(10))
        XCTAssertLessThanOrEqual(refreshes.at.count, 6, "no backlog after the burst")
    }

    func testRunningSubagentFileGetsItsOwnSourceAndAFinishedOneIsClosed() {
        let (watch, source, _, _) = make()
        let a1 = "\(subagentsDir)/agent-a1.jsonl", a1Meta = "\(subagentsDir)/agent-a1.meta.json"
        let a2 = "\(subagentsDir)/agent-a2.jsonl"
        watch.update(paths: [conv, subagentsDir, a1Meta, a1, a2], finishedAgents: [])
        XCTAssertEqual(source.openPaths, [conv, subagentsDir, a1Meta, a1, a2])
        watch.update(paths: [conv, subagentsDir, a1Meta, a1, a2], finishedAgents: ["a1"])
        XCTAssertEqual(source.openPaths, [conv, subagentsDir, a2], "a finished agent's transcript and sidecar close")
        XCTAssertEqual(source.opens.count, 5, "an open source is kept, never reopened")
        XCTAssertFalse(watch.isFallback)
    }

    func testSourcesAreCappedKeepingTheConversations() {
        let (watch, source, _, _) = make()
        let agents = (0..<40).map { "\(subagentsDir)/agent-x\($0).jsonl" }
        watch.update(paths: [conv, subagentsDir] + agents, finishedAgents: [])
        XCTAssertEqual(source.openPaths.count, TranscriptWatch.maxSources)
        XCTAssertTrue(source.openPaths.isSuperset(of: [conv, subagentsDir]))
    }

    func testCapKeepsTheNewestConversationFirst() {
        let convs = (0..<40).map { "/p/proj/c\($0).jsonl" }
        let picked = TranscriptWatch.select(convs, finishedAgents: [])
        XCTAssertEqual(picked.first, "/p/proj/c39.jsonl", "the newest (last listed) conversation is watched first")
        XCTAssertEqual(picked.count, TranscriptWatch.maxSources)
    }

    func testOpenFailureFallsBackToTheThreeSecondTick() {
        let (watch, source, clock, refreshes) = make()
        source.failing = [conv]
        watch.update(paths: [conv], finishedAgents: [])
        XCTAssertTrue(watch.isFallback)
        clock.advance(by: .milliseconds(2999))
        XCTAssertTrue(refreshes.at.isEmpty)
        clock.advance(by: .milliseconds(1))
        XCTAssertEqual(refreshes.at.count, 1)
        clock.advance(by: .seconds(3))
        XCTAssertEqual(refreshes.at.count, 2)
        source.failing = []
        watch.update(paths: [conv], finishedAgents: [])
        XCTAssertFalse(watch.isFallback, "the source opened: the tick stops")
        clock.advance(by: .seconds(30))
        XCTAssertEqual(refreshes.at.count, 2)
    }

    /// Review focus 5: a just-started session whose transcript does not exist
    /// yet reads on the tick, then on file events once the read lists it.
    func testNoPathsFallsBackUntilTheTranscriptAppears() {
        let (watch, source, clock, refreshes) = make()
        watch.update(paths: [], finishedAgents: [])
        XCTAssertTrue(watch.isFallback)
        clock.advance(by: .seconds(3))
        XCTAssertEqual(refreshes.at.count, 1)
        watch.update(paths: [conv], finishedAgents: [])
        XCTAssertFalse(watch.isFallback)
        XCTAssertEqual(source.openPaths, [conv])
        clock.advance(by: .seconds(30))
        XCTAssertEqual(refreshes.at.count, 1, "no tick once the file is watched")
        source.fire(conv)
        clock.advance(by: .milliseconds(250))
        XCTAssertEqual(refreshes.at.count, 2)
    }

    func testRenameOrDeleteReopensOnTheNextRead() {
        let (watch, source, clock, refreshes) = make()
        watch.update(paths: [conv], finishedAgents: [])
        source.fire(conv, .replaced)
        XCTAssertTrue(source.openPaths.isEmpty, "the stale source closes")
        clock.advance(by: .milliseconds(250))
        XCTAssertEqual(refreshes.at.count, 1, "and the change is read")
        watch.update(paths: [conv], finishedAgents: [])
        XCTAssertEqual(source.openPaths, [conv])
        XCTAssertEqual(source.opens, [conv, conv], "the path is opened again")
    }

    func testStopClosesEverySourceAndTimer() {
        let (watch, source, clock, refreshes) = make()
        watch.update(paths: [conv, subagentsDir], finishedAgents: [])
        source.fire(conv)
        watch.stop()
        XCTAssertTrue(source.openPaths.isEmpty)
        XCTAssertEqual(clock.pendingTimers, 0)
        clock.advance(by: .seconds(10))
        XCTAssertTrue(refreshes.at.isEmpty)
    }
}

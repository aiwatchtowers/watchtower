import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class TranscriptWatchTests: XCTestCase {
    private let conv = "/p/proj/s1.jsonl"
    private let convDir = "/p/proj"
    private let subagentsDir = "/p/proj/s1/subagents"

    private final class Refreshes {
        var at: [ContinuousClock.Instant] = []
    }

    private struct Rig {
        let watch: TranscriptWatch
        let source: FakeFileEventSource
        let clock: ManualWatchClock
        let refreshes: Refreshes
    }

    private func targets(_ paths: [String]? = nil, current: [String]? = nil, running: Set<String> = []) -> TranscriptWatchTargets {
        TranscriptWatchTargets(paths: paths ?? [conv], current: current ?? [conv], running: running)
    }

    private func make() -> Rig {
        let source = FakeFileEventSource()
        let clock = ManualWatchClock()
        let refreshes = Refreshes()
        let watch = TranscriptWatch(fileEvents: source, clock: clock) { refreshes.at.append(clock.now) }
        return Rig(watch: watch, source: source, clock: clock, refreshes: refreshes)
    }

    /// A running watch past its first read and the reconcile read that
    /// followed the opening of its sources; no refresh counted yet.
    private func ready(_ targets: TranscriptWatchTargets) -> Rig {
        let rig = make()
        rig.watch.start()
        rig.watch.update(targets)
        rig.clock.advance(by: .seconds(1))
        rig.watch.readStarted()
        rig.watch.update(targets)
        rig.clock.advance(by: .seconds(1))
        rig.refreshes.at = []
        return rig
    }

    func testOpeningSourcesAsksOneReconcileReadAndNoMore() {
        let rig = make()
        rig.watch.start()
        rig.watch.update(targets())
        XCTAssertEqual(rig.source.openPaths, [conv, convDir])
        rig.clock.advance(by: .milliseconds(250))
        XCTAssertEqual(rig.refreshes.at.count, 1, "a change between the read and the open is read")
        rig.watch.readStarted()
        rig.watch.update(targets())
        rig.clock.advance(by: .seconds(30))
        XCTAssertEqual(rig.refreshes.at.count, 1, "the reconcile read opened nothing new: no loop")
    }

    func testEventRefreshesOnceAfterDebounce() {
        let rig = ready(targets())
        rig.source.fire(conv)
        rig.clock.advance(by: .milliseconds(249))
        XCTAssertTrue(rig.refreshes.at.isEmpty)
        rig.clock.advance(by: .milliseconds(1))
        XCTAssertEqual(rig.refreshes.at.count, 1)
        rig.clock.advance(by: .seconds(10))
        XCTAssertEqual(rig.refreshes.at.count, 1, "one event, one read")
    }

    func testEventsInsideTheDebounceCoalesce() {
        let rig = ready(targets())
        rig.source.fire(conv)
        rig.clock.advance(by: .milliseconds(100))
        rig.source.fire(conv)
        rig.clock.advance(by: .milliseconds(249))
        XCTAssertTrue(rig.refreshes.at.isEmpty, "the debounce runs from the last event")
        rig.clock.advance(by: .milliseconds(1))
        XCTAssertEqual(rig.refreshes.at.count, 1)
    }

    func testAReadThatStartsCoversTheEventsBeforeIt() {
        let rig = ready(targets())
        rig.source.fire(conv)
        rig.watch.readStarted()
        rig.clock.advance(by: .seconds(10))
        XCTAssertTrue(rig.refreshes.at.isEmpty)
    }

    func testBurstRefreshesAtMostOncePerSecondWithATrailingRead() throws {
        let rig = ready(targets())
        var lastEvent = rig.clock.now
        for _ in 0..<50 {
            rig.source.fire(conv)
            lastEvent = rig.clock.now
            rig.clock.advance(by: .milliseconds(100))
        }
        rig.clock.advance(by: .seconds(3))
        XCTAssertGreaterThanOrEqual(rig.refreshes.at.count, 5, "a burst never starves the reads")
        XCTAssertLessThanOrEqual(rig.refreshes.at.count, 6)
        for (a, b) in zip(rig.refreshes.at, rig.refreshes.at.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a.duration(to: b), .seconds(1))
        }
        XCTAssertGreaterThan(try XCTUnwrap(rig.refreshes.at.last), lastEvent, "the last event is always read")
        rig.clock.advance(by: .seconds(10))
        XCTAssertLessThanOrEqual(rig.refreshes.at.count, 6, "no backlog after the burst")
    }

    func testOnlyTheCurrentConversationAndRunningAgentsAreWatched() {
        let old = "/p/proj/s0.jsonl", oldSubagents = "/p/proj/s0/subagents"
        let a1 = "\(subagentsDir)/agent-a1.jsonl", a1Meta = "\(subagentsDir)/agent-a1.meta.json"
        let a10 = "\(subagentsDir)/agent-a10.jsonl", a2 = "\(subagentsDir)/agent-a2.jsonl"
        let rig = ready(targets([old, oldSubagents, conv, subagentsDir, a1Meta, a1, a10, a2], running: ["a1"]))
        XCTAssertEqual(rig.source.openPaths, [conv, convDir, subagentsDir, a1Meta, a1],
                       "older conversations, finished agents and an id that only contains a running one are not watched")
        XCTAssertFalse(rig.watch.isFallback)
        rig.watch.update(targets([old, oldSubagents, conv, subagentsDir, a1Meta, a1, a10, a2], running: []))
        XCTAssertEqual(rig.source.openPaths, [conv, convDir, subagentsDir], "a finished agent's files close")
    }

    func testCapKeepsTheConversationFirstAndCutsCountAsFailure() {
        let agents = (0..<40).map { "\(subagentsDir)/agent-x\($0).jsonl" }
        let picked = TranscriptWatch.select(targets([conv, subagentsDir] + agents, running: Set((0..<40).map { "x\($0)" })))
        XCTAssertEqual(Array(picked.paths.prefix(3)), [conv, convDir, subagentsDir])
        XCTAssertEqual(picked.paths.count, TranscriptWatch.maxSources)
        XCTAssertEqual(picked.cut, 43 - TranscriptWatch.maxSources)
        let rig = make()
        rig.watch.start()
        rig.watch.update(targets([conv, subagentsDir] + agents, running: Set((0..<40).map { "x\($0)" })))
        XCTAssertEqual(rig.source.openPaths.count, TranscriptWatch.maxSources)
        XCTAssertTrue(rig.watch.isFallback, "a path the cap cut is read by the tick")
    }

    func testFileIDs() {
        XCTAssertEqual(TranscriptWatch.fileID("/d/subagents/agent-a1.jsonl"), "a1")
        XCTAssertEqual(TranscriptWatch.fileID("/d/subagents/agent-a1.meta.json"), "a1")
        XCTAssertEqual(TranscriptWatch.fileID("/d/s1.jsonl"), "s1")
        let id = "0198a3b2-1c2d-7e3f-8a9b-0c1d2e3f4a5b"
        XCTAssertEqual(TranscriptWatch.fileID("/s/2026/11/20/rollout-2026-11-20T10-00-00-\(id).jsonl"), id)
        XCTAssertNil(TranscriptWatch.fileID("/s/rollout-short.jsonl"))
        XCTAssertNil(TranscriptWatch.fileID("/d/subagents"))
    }

    func testOpenFailureFallsBackToTheThreeSecondTick() {
        let rig = make()
        rig.source.failing = [conv]
        rig.watch.start()
        rig.watch.update(targets())
        XCTAssertTrue(rig.watch.isFallback)
        rig.refreshes.at = []
        let start = rig.clock.now
        rig.clock.advance(by: .seconds(10))
        XCTAssertFalse(rig.refreshes.at.isEmpty)
        XCTAssertTrue(rig.refreshes.at.allSatisfy { start.duration(to: $0) >= .milliseconds(250) })
        rig.source.failing = []
        rig.watch.readStarted()
        rig.watch.update(targets())
        XCTAssertFalse(rig.watch.isFallback, "every source opened: the tick stops")
        rig.watch.readStarted()
        rig.watch.update(targets())
        let count = rig.refreshes.at.count
        rig.clock.advance(by: .seconds(30))
        XCTAssertEqual(rig.refreshes.at.count, count, "no tick and no event: no read")
    }

    func testTheFallbackTicksEveryThreeSecondsAfterTheLastRead() {
        let rig = make()
        rig.watch.start()
        rig.watch.update(TranscriptWatchTargets())
        XCTAssertTrue(rig.watch.isFallback)
        rig.clock.advance(by: .milliseconds(2999))
        XCTAssertTrue(rig.refreshes.at.isEmpty)
        rig.clock.advance(by: .milliseconds(1))
        XCTAssertEqual(rig.refreshes.at.count, 1)
        rig.clock.advance(by: .seconds(3))
        XCTAssertEqual(rig.refreshes.at.count, 2)
    }

    /// Review focus 5: a just-started session whose transcript does not exist
    /// yet reads on the tick, then on file events once the read lists it.
    func testNoPathsFallsBackUntilTheTranscriptAppears() {
        let rig = make()
        rig.watch.start()
        rig.watch.update(TranscriptWatchTargets())
        rig.clock.advance(by: .seconds(3))
        XCTAssertEqual(rig.refreshes.at.count, 1)
        rig.watch.readStarted()
        rig.watch.update(targets())
        XCTAssertFalse(rig.watch.isFallback)
        rig.clock.advance(by: .seconds(1))
        rig.watch.readStarted()
        rig.watch.update(targets())
        let count = rig.refreshes.at.count
        rig.clock.advance(by: .seconds(30))
        XCTAssertEqual(rig.refreshes.at.count, count, "no tick once the file is watched")
        rig.source.fire(conv)
        rig.clock.advance(by: .seconds(1))
        XCTAssertEqual(rig.refreshes.at.count, count + 1)
    }

    func testAFailedReadArmsTheFallbackUntilAReadSucceeds() {
        let rig = ready(targets())
        rig.watch.readStarted()
        rig.watch.markReadFailed()
        XCTAssertTrue(rig.watch.isFallback)
        rig.clock.advance(by: .seconds(3))
        XCTAssertEqual(rig.refreshes.at.count, 1)
        rig.watch.readStarted()
        rig.watch.update(targets())
        XCTAssertFalse(rig.watch.isFallback)
        rig.clock.advance(by: .seconds(30))
        XCTAssertEqual(rig.refreshes.at.count, 1)
    }

    func testLosingTheOnlySourceArmsTheFallback() {
        let a1 = "\(subagentsDir)/agent-a1.jsonl"
        let rig = ready(TranscriptWatchTargets(paths: [a1], current: [], running: ["a1"]))
        XCTAssertEqual(rig.source.openPaths, [a1])
        rig.source.fire(a1, .replaced)
        XCTAssertTrue(rig.source.openPaths.isEmpty)
        XCTAssertTrue(rig.watch.isFallback, "no source left: never silent")
        rig.clock.advance(by: .seconds(1))
        rig.watch.readStarted()
        rig.source.failing = [a1]
        rig.watch.update(TranscriptWatchTargets(paths: [a1], current: [], running: ["a1"]))
        let count = rig.refreshes.at.count
        rig.clock.advance(by: .seconds(3))
        XCTAssertEqual(rig.refreshes.at.count, count + 1, "the tick keeps reading")
    }

    func testEventsAndTheFallbackShareTheMinimumGap() {
        let rig = make()
        rig.source.failing = [convDir]
        rig.watch.start()
        rig.watch.update(targets())
        XCTAssertTrue(rig.watch.isFallback)
        for _ in 0..<100 {
            rig.source.fire(conv)
            rig.clock.advance(by: .milliseconds(170))
        }
        XCTAssertFalse(rig.refreshes.at.isEmpty)
        for (a, b) in zip(rig.refreshes.at, rig.refreshes.at.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a.duration(to: b), .seconds(1))
        }
    }

    func testRenameOrDeleteReopensOnTheNextRead() {
        let rig = ready(targets())
        rig.source.fire(conv, .replaced)
        XCTAssertEqual(rig.source.openPaths, [convDir], "the stale source closes")
        rig.clock.advance(by: .milliseconds(250))
        XCTAssertEqual(rig.refreshes.at.count, 1, "and the change is read")
        rig.watch.readStarted()
        rig.watch.update(targets())
        XCTAssertEqual(rig.source.openPaths, [conv, convDir])
        XCTAssertEqual(rig.source.opens.filter { $0 == conv }.count, 2, "the path is opened again")
    }

    func testStopClosesEverySourceAndTimerAndStartReopens() {
        let rig = ready(targets([conv, subagentsDir]))
        rig.source.fire(conv)
        rig.watch.stop()
        XCTAssertTrue(rig.source.openPaths.isEmpty)
        XCTAssertEqual(rig.clock.pendingTimers, 0)
        rig.clock.advance(by: .seconds(10))
        XCTAssertTrue(rig.refreshes.at.isEmpty)
        rig.watch.update(targets([conv, subagentsDir]))
        XCTAssertTrue(rig.source.openPaths.isEmpty, "a stopped watch opens nothing")
        rig.watch.start()
        XCTAssertEqual(rig.source.openPaths, [conv, convDir, subagentsDir], "start reopens the last read's files")
    }
}

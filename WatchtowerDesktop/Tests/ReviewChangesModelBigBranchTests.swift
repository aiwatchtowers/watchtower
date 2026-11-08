import Foundation
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// A clock the test moves by hand: a sleeper wakes once `advance` passes its deadline.
final class FakeStreamClock: ReviewStreamClock, @unchecked Sendable {
    private struct Sleeper {
        let id: UUID
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    private var sleepers: [Sleeper] = []

    var now: Date { lock.withLock { current } }

    func sleep(until deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let wakeNow = lock.withLock { () -> Bool in
                    if deadline <= current { return true }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: c))
                    return false
                }
                if wakeNow { c.resume() }
            }
        } onCancel: {
            let sleeper = lock.withLock { () -> Sleeper? in
                guard let i = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: i)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by seconds: TimeInterval) {
        let due = lock.withLock { () -> [Sleeper] in
            current += seconds
            let due = sleepers.filter { $0.deadline <= current }
            sleepers.removeAll { $0.deadline <= current }
            return due
        }
        due.forEach { $0.continuation.resume() }
    }
}

/// Board #1025, Task 11: the model driven by `review map` and the streamed
/// overview — per-chapter states, the Retry queue, Refresh, waiting and busy,
/// the silence timer, the map-failed state.
@MainActor
final class ReviewChangesModelBigBranchTests: XCTestCase {
    private var paths: [String] = []
    private let clock = FakeStreamClock()

    override func tearDown() {
        paths.forEach { TestDatabase.cleanup(path: $0) }
        paths = []
        super.tearDown()
    }

    private func harness() throws -> ReviewModelHarness {
        let h = try ReviewModelHarness()
        paths.append(h.path)
        h.model.streamClock = clock
        h.cli.liveStreams = true
        return h
    }

    private func deepStart(tree: String = "t7") -> String {
        """
        {"ok":true,"round":{"id":7,"status":"open","mode":"deep","phase":"chapters","chapter_key":"",
         "active_seconds":0,"folder_root":"/r","base_sha":"b","base_label":"main","tree_sha":"\(tree)","prev_round_id":0,
         "prev_tree_sha":"","prev_tree_lost":false}}
        """
    }

    /// A Deep round on `cmd/x.go` and `pkg/y.go` (map chapters `dir:cmd`, `dir:pkg`), opened and its map in.
    private func openDeep(_ h: ReviewModelHarness, trees: [String] = ["t7"]) async {
        h.cli.script(["context": #"{"ok":true,"items":[]}"#, "diff": diffJSON(["cmd/x.go", "pkg/y.go"])])
        h.cli.script("start", trees.map { deepStart(tree: $0) })
        await h.model.open()
        await h.model.mapTask?.value
    }

    /// Waits (bounded) for `condition`, letting the model's tasks run.
    private func eventually(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<3000 where !condition() {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), "never: \(what)")
    }

    private func process(_ h: ReviewModelHarness, _ index: Int) async throws -> FakeOverviewProcess {
        await h.cli.waitProcesses(index + 1)
        let all = h.cli.processes
        return try XCTUnwrap(all.count > index ? all[index] : nil, "overview process \(index) never started")
    }

    private static let overviewEnvelope = #"{"ok":true,"overview":{"summary":"Adds y.","chapters":["#
        + #"{"key":"dir:cmd","title":"cmd","paths":["cmd/x.go"],"core":false,"what":"Flags."},"#
        + #"{"key":"dir:pkg","title":"pkg","paths":["pkg/y.go"],"core":false,"what":"Locks."}]},"incomplete":[]}"#

    private func chapterLine(_ key: String, _ state: String, what: String = "Does it.") -> String {
        #"{"event":"chapter","key":"\#(key)","state":"\#(state)","what":"\#(what)","risks":[]}"#
    }

    // MARK: - The map

    func testMapOnOpenAndOnRefresh() async throws {
        let h = try harness()
        h.cli.script("map", [
            mapJSON([(key: "dir:cmd", paths: ["cmd/x.go"], level: "normal"), (key: "dir:pkg", paths: ["pkg/y.go"], level: "breaking")]),
            mapJSON([(key: "dir:pkg", paths: ["pkg/y.go"], level: "breaking"), (key: "collapsed", paths: ["cmd/x.go"], level: "normal")])
        ])
        await openDeep(h)
        guard case .ready(let first) = h.model.map else { return XCTFail("map \(h.model.map)") }
        XCTAssertEqual(first.chapters.map(\.key), ["dir:cmd", "dir:pkg"])
        XCTAssertEqual(h.model.chapters.map(\.key), ["dir:cmd", "dir:pkg"])
        await h.model.refresh()
        await h.model.mapTask?.value
        XCTAssertEqual(h.cli.calls("map").count, 2, "read again on Refresh")
        XCTAssertEqual(h.model.chapters.map(\.key), ["dir:pkg", "collapsed"])
    }

    /// No map (an error, bad JSON, no answer in 60 s): the file list stays,
    /// no chapters, no overview; Retry builds it and starts the overview.
    func testMapFailureKeepsTheFilesAndRetryRebuildsIt() async throws {
        let h = try harness()
        h.cli.script("map", [#"{"ok":false,"error":"git log failed"}"#, "not json",
                             mapJSON([(key: "dir:cmd", paths: ["cmd/x.go", "pkg/y.go"], level: "normal")])])
        await openDeep(h)
        XCTAssertEqual(h.model.map, .failed)
        XCTAssertEqual(h.model.load, .ready)
        XCTAssertEqual(h.model.files.map(\.path), ["cmd/x.go", "pkg/y.go"], "the file list is still shown")
        XCTAssertEqual(h.model.chapters, [])
        XCTAssertEqual(h.cli.timeouts("map"), [WorkbenchCLI.reviewMapTimeout])
        XCTAssertEqual(WorkbenchCLI.reviewMapTimeout, 60)
        XCTAssertEqual(h.model.overview, .idle, "the overview is not started without a map")
        XCTAssertTrue(h.cli.processes.isEmpty)

        h.model.retryMap()
        XCTAssertEqual(h.model.map, .loading)
        await h.model.mapTask?.value
        XCTAssertEqual(h.model.map, .failed, "unreadable JSON fails too")

        h.model.retryMap()
        await h.model.mapTask?.value
        XCTAssertEqual(h.model.chapters.map(\.key), ["dir:cmd"])
        let run = try await process(h, 0)
        XCTAssertEqual(h.model.overview, .loading, "the held-back overview starts once the map is in")
        run.send(Self.overviewEnvelope)
        run.finish()
        await h.settle()
    }

    // MARK: - The stream

    func testStreamFillsTheChapterStates() async throws {
        let h = try harness()
        await openDeep(h)
        let run = try await process(h, 0)
        XCTAssertEqual(run.args, ["workbench", "review", "overview", "--workbench", String(h.projectID), "--round", "7",
                                  "--json", "--stream", "--caller", "desktop"])
        XCTAssertEqual(h.model.chapterStates, ["dir:cmd": .running, "dir:pkg": .running])
        XCTAssertEqual(h.model.summaryState, .running)
        run.send(#"{"event":"map","map":{"chapters":[{"key":"dir:cmd","title":"cmd","level":"normal","paths":["cmd/x.go"]},"#
            + #"{"key":"dir:pkg","title":"pkg","level":"normal","paths":["pkg/y.go"]}],"files":[]}}"#)
        run.send(chapterLine("dir:cmd", "cached", what: "Flags."))
        await eventually("dir:cmd cached") { h.model.chapterStates["dir:cmd"] == .cached }
        XCTAssertEqual(h.model.chapterDescription("dir:cmd"), "Flags.")
        XCTAssertEqual(h.model.chapterStates["dir:pkg"], .running, "the chapter list fills in as lines arrive")
        run.send(chapterLine("dir:pkg", "ok", what: "Locks."))
        run.send(#"{"event":"summary","state":"ok"}"#)
        run.send(Self.overviewEnvelope)
        run.finish()
        await h.settle()
        XCTAssertEqual(h.model.chapterStates, ["dir:cmd": .cached, "dir:pkg": .ok])
        XCTAssertEqual(h.model.summaryState, .ok)
        guard case .ready(let overview) = h.model.overview else { return XCTFail("overview \(h.model.overview)") }
        XCTAssertEqual(overview.summary, "Adds y.")
    }

    /// While the run goes, a described chapter's risks show at once; a failed run keeps the provider's text.
    func testStreamedRisksShowWhileTheRunGoesAndAFailedRunKeepsItsDetail() async throws {
        let h = try harness()
        await openDeep(h)
        let run = try await process(h, 0)
        XCTAssertNil(h.model.chapterRiskList("dir:pkg"), "nothing described yet")
        run.send(#"{"event":"chapter","key":"dir:pkg","state":"ok","what":"Locks.","risks":["#
            + #"{"path":"pkg/y.go","level":"low","why":"Naming."},{"path":"pkg/y.go","level":"high","why":"Deadlock."}]}"#)
        await eventually("dir:pkg ok") { h.model.chapterStates["dir:pkg"] == .ok }
        let list = try XCTUnwrap(h.model.chapterRiskList("dir:pkg"))
        XCTAssertEqual(list.risks.map(\.why), ["Deadlock.", "Naming."], "most serious first")
        XCTAssertFalse(list.outOfDate)
        XCTAssertNil(h.model.chapterRiskList("dir:cmd"), "still describing")
        run.send(#"{"ok":false,"error":"Another overview of this branch is still running.","detail":"lock held"}"#)
        run.finish(status: 1)
        await h.settle()
        XCTAssertEqual(h.model.overview, .failed("Another overview of this branch is still running.", detail: "lock held"))
    }

    /// Describe N remaining redoes exactly the chapters the run did not reach, never a failed one.
    func testDescribeRemainingSkipsFailedChapters() async throws {
        let h = try harness()
        await openDeep(h)
        let first = try await process(h, 0)
        first.send(#"{"event":"chapter","key":"dir:cmd","state":"failed","error":{"class":"provider","text":"x"}}"#)
        first.send(#"{"event":"chapter","key":"dir:pkg","state":"not_started"}"#)
        first.send(#"{"event":"summary","state":"ok"}"#)
        first.send(Self.overviewEnvelope)
        first.finish()
        await h.settle()
        h.model.describeRemaining()
        let second = try await process(h, 1)
        XCTAssertEqual(second.args.filter { $0.hasPrefix("--chapter") }, ["--chapter=dir:pkg"])
        XCTAssertFalse(second.args.contains("--continue"))
        XCTAssertEqual(h.model.chapterStates["dir:cmd"], .failed(text: "x", detail: nil), "a failed chapter keeps its Retry")
        XCTAssertEqual(h.model.chapterStates["dir:pkg"], .running)
        second.send(Self.overviewEnvelope)
        second.finish()
        await h.settle()
    }

    /// The owner's sentence and the provider's own text stay apart.
    func testFailedChapterKeepsTheSentenceAndTheDetailApart() async throws {
        let h = try harness()
        await openDeep(h)
        let run = try await process(h, 0)
        run.send(#"{"event":"chapter","key":"dir:pkg","state":"failed","#
            + #""error":{"class":"provider","text":"The AI provider failed on “pkg”.","detail":"HTTP 529 overloaded"}}"#)
        run.send(#"{"event":"summary","state":"failed","#
            + #""error":{"class":"timeout","text":"The overview of the summary did not finish in 2 min.","detail":"deadline"}}"#)
        run.send(Self.overviewEnvelope)
        run.finish()
        await h.settle()
        XCTAssertEqual(h.model.chapterStates["dir:pkg"], .failed(text: "The AI provider failed on “pkg”.", detail: "HTTP 529 overloaded"))
        XCTAssertEqual(h.model.summaryState, .failed(text: "The overview of the summary did not finish in 2 min.", detail: "deadline"))
        XCTAssertEqual(h.model.chapterStates["dir:cmd"], .cached, "described in the assembled overview")
    }

    /// Retry during a run queues; one follow-up run takes every queued key.
    func testRetryDuringARunQueuesOneFollowUpRun() async throws {
        let h = try harness()
        await openDeep(h)
        let first = try await process(h, 0)
        h.model.retry(chapter: "dir:pkg")
        h.model.retry(chapter: "dir:cmd")
        h.model.retry(chapter: "dir:pkg")
        h.model.retrySummary()
        XCTAssertEqual(h.model.chapterStates, ["dir:cmd": .queued, "dir:pkg": .queued])
        XCTAssertEqual(h.model.summaryState, .queued)
        XCTAssertEqual(h.cli.processes.count, 1, "never a second process beside the first")
        first.send(chapterLine("dir:cmd", "failed"))
        first.send(Self.overviewEnvelope)
        first.finish()
        let second = try await process(h, 1)
        XCTAssertEqual(Array(second.args.suffix(2)), ["--chapter=dir:pkg", "--chapter=dir:cmd"])
        XCTAssertFalse(second.args.contains("--summary"), "the summary is remade after the chapters anyway")
        XCTAssertEqual(h.model.chapterStates, ["dir:cmd": .running, "dir:pkg": .running])
        second.send(chapterLine("dir:pkg", "ok"))
        second.send(chapterLine("dir:cmd", "ok"))
        second.send(#"{"event":"summary","state":"ok"}"#)
        second.send(Self.overviewEnvelope)
        second.finish()
        await h.settle()
        XCTAssertEqual(h.cli.processes.count, 2, "one follow-up run")
        XCTAssertEqual(h.model.chapterStates, ["dir:cmd": .ok, "dir:pkg": .ok])
        XCTAssertEqual(h.model.summaryState, .ok)
    }

    func testRetryWithoutARunStartsAChapterRunAndDescribeRemainingContinues() async throws {
        let h = try harness()
        await openDeep(h)
        let first = try await process(h, 0)
        first.send(chapterLine("dir:cmd", "ok"))
        first.send(#"{"event":"chapter","key":"dir:pkg","state":"not_started"}"#)
        first.send(Self.overviewEnvelope.replacingOccurrences(of: #""incomplete":[]"#, with: #""incomplete":["dir:pkg"]"#))
        first.finish()
        await h.settle()
        XCTAssertEqual(h.model.chapterStates["dir:pkg"], .notStarted)
        h.model.describeRemaining()
        let second = try await process(h, 1)
        XCTAssertEqual(Array(second.args.suffix(1)), ["--chapter=dir:pkg"], "only the chapter the run did not reach")
        XCTAssertEqual(h.model.chapterStates, ["dir:cmd": .ok, "dir:pkg": .running], "only what is left runs")
        second.send(Self.overviewEnvelope)
        second.finish()
        await h.settle()
        h.model.retry(chapter: "dir:cmd")
        let third = try await process(h, 2)
        XCTAssertEqual(third.args.last, "--chapter=dir:cmd")
        third.send(Self.overviewEnvelope)
        third.finish()
        await h.settle()
        h.model.retrySummary()
        let fourth = try await process(h, 3)
        XCTAssertEqual(fourth.args.last, "--summary")
        XCTAssertEqual(h.model.summaryState, .running)
        fourth.send(#"{"event":"summary","state":"ok"}"#)
        fourth.send(Self.overviewEnvelope)
        fourth.finish()
        await h.settle()
        XCTAssertEqual(h.model.summaryState, .ok)
    }

    // MARK: - Refresh

    /// Refresh during this session's run on a moved tree stops it (finished
    /// chapters are cached by Go) and starts on the new snapshot.
    func testRefreshDuringOwnRunStopsItAndStartsAnew() async throws {
        let h = try harness()
        await openDeep(h, trees: ["t7", "u7"])
        let first = try await process(h, 0)
        first.send(chapterLine("dir:cmd", "ok"))
        await eventually("dir:cmd ok") { h.model.chapterStates["dir:cmd"] == .ok }
        await h.model.refresh()
        await eventually("SIGTERM to its own process group") { first.stopCount == 1 }
        let second = try await process(h, 1)
        XCTAssertEqual(second.stopCount, 0)
        second.send(chapterLine("dir:cmd", "cached"))
        second.send(chapterLine("dir:pkg", "ok"))
        second.send(Self.overviewEnvelope)
        second.finish()
        await h.settle()
        XCTAssertEqual(h.model.chapterStates, ["dir:cmd": .cached, "dir:pkg": .ok], "what the stopped run finished comes back cached")
        guard case .ready = h.model.overview else { return XCTFail("overview \(h.model.overview)") }
        XCTAssertEqual(first.stopCount, 1)
    }

    /// Quick: what a run streamed for one tree never shows on a cached overview of the next.
    func testCachedOverviewOfANewTreeDropsTheStreamedChapters() async throws {
        let h = try harness()
        let quick = { (tree: String) in self.deepStart(tree: tree).replacingOccurrences(of: #""mode":"deep""#, with: #""mode":"quick""#) }
        h.cli.script(["context": #"{"ok":true,"items":[]}"#, "diff": diffJSON(["cmd/x.go", "pkg/y.go"])])
        h.cli.script("start", [quick("t7"), quick("u7")])
        h.cli.script("overview", [#"{"ok":true}"#, Self.overviewEnvelope.replacingOccurrences(of: "Flags.", with: "New flags.")])
        await h.model.open()
        await h.model.mapTask?.value
        await h.model.overviewTask?.value
        h.model.makeOverview()
        let run = try await process(h, 0)
        run.send(chapterLine("dir:cmd", "ok", what: "Old flags."))
        run.send(Self.overviewEnvelope)
        run.finish()
        await h.settle()
        XCTAssertEqual(h.model.chapterDescription("dir:cmd"), "Old flags.")
        await h.model.refresh()
        await h.model.mapTask?.value
        await h.model.overviewTask?.value
        XCTAssertEqual(h.model.chapterDescription("dir:cmd"), "New flags.")
        XCTAssertEqual(h.model.chapterStates, ["dir:cmd": .cached, "dir:pkg": .cached])
    }

    /// A chapter whose files all changed between snapshots stays selected
    /// while the new map loads, and is still selected once it is in.
    func testRefreshKeepsTheSelectedChapterUntilTheNewMap() async throws {
        let h = try harness()
        let quick = { (tree: String) in self.deepStart(tree: tree).replacingOccurrences(of: #""mode":"deep""#, with: #""mode":"quick""#) }
        h.cli.script(["context": #"{"ok":true,"items":[]}"#, "overview": #"{"ok":true}"#])
        h.cli.script("diff", [diffJSON(["cmd/x.go", "z/old.go"]), diffJSON(["cmd/x.go", "z/new.go"])])
        h.cli.script("start", [quick("t7"), quick("u7")])
        await h.model.open()
        await h.model.mapTask?.value
        try await h.model.selectChapter("dir:z")
        XCTAssertEqual(h.model.currentChapterKey, "dir:z")
        await h.model.refresh()
        await h.model.mapTask?.value
        XCTAssertEqual(h.model.chapters.map(\.key), ["dir:cmd", "dir:z"])
        XCTAssertEqual(h.model.currentChapterKey, "dir:z", "the old map over the new files never moved the selection")
    }

    /// A Refresh that stopped this session's run, then could not build the
    /// map: no spinner and no running line are left without a process.
    func testRestartWhoseMapFailsLeavesNoSpinner() async throws {
        let h = try harness()
        h.cli.script("map", [mapJSON(fromDiff: diffJSON(["cmd/x.go", "pkg/y.go"])), #"{"ok":false,"error":"git log failed"}"#])
        await openDeep(h, trees: ["t7", "u7"])
        let first = try await process(h, 0)
        first.send(chapterLine("dir:cmd", "ok"))
        await eventually("dir:cmd ok") { h.model.chapterStates["dir:cmd"] == .ok }
        await h.model.refresh()
        await h.model.mapTask?.value
        await eventually("stopped") { first.stopCount == 1 }
        XCTAssertEqual(h.model.map, .failed)
        XCTAssertEqual(h.model.overview, .idle)
        XCTAssertEqual(h.model.chapterStates, ["dir:cmd": .ok, "dir:pkg": .notStarted])
        XCTAssertEqual(h.model.summaryState, .notStarted)
        XCTAssertEqual(h.cli.processes.count, 1)
    }

    /// A queued Retry dropped by a stop goes back to not started.
    func testDroppedQueueLeavesNoQueuedLine() async throws {
        let h = try harness()
        await openDeep(h, trees: ["t7", "u7"])
        let first = try await process(h, 0)
        h.model.retry(chapter: "dir:pkg")
        h.model.retrySummary()
        XCTAssertEqual(h.model.chapterStates["dir:pkg"], .queued)
        h.model.shutDown()
        await eventually("stopped") { first.stopCount == 1 }
        XCTAssertEqual(h.model.chapterStates["dir:pkg"], .notStarted)
        XCTAssertEqual(h.model.summaryState, .notStarted)
    }

    /// A refresh that finds the same snapshot (the window became key) leaves the run alone.
    func testRefreshOnTheSameTreeKeepsTheRun() async throws {
        let h = try harness()
        await openDeep(h)
        let first = try await process(h, 0)
        await h.model.refresh()
        await h.model.mapTask?.value
        XCTAssertEqual(first.stopCount, 0)
        XCTAssertEqual(h.cli.processes.count, 1)
        first.send(Self.overviewEnvelope)
        first.finish()
        await h.settle()
    }

    /// While waiting for another holder, Refresh restarts this session's
    /// waiter only — the other run is never signalled.
    func testRefreshWhileWaitingRestartsTheWaiter() async throws {
        let h = try harness()
        await openDeep(h, trees: ["t7", "u7"])
        let first = try await process(h, 0)
        first.send(#"{"event":"waiting","by":"agent"}"#)
        await eventually("waiting") { h.model.waitingFor == "agent" }
        XCTAssertEqual(h.model.waitingText, "The agent is describing this branch — chapters appear as it finishes them")
        XCTAssertEqual(h.model.chapterStates, ["dir:cmd": .waiting, "dir:pkg": .waiting])
        first.send(chapterLine("dir:cmd", "cached"))
        await eventually("cached while waiting") { h.model.chapterStates["dir:cmd"] == .cached }
        XCTAssertEqual(h.model.waitingFor, "agent", "a part another run cached does not end the wait")
        await h.model.refresh(regenerateOverview: false)
        await eventually("its own waiting process stopped") { first.stopCount == 1 }
        let second = try await process(h, 1)
        second.send(#"{"event":"waiting","by":"agent"}"#)
        await eventually("waiting again") { h.model.waitingFor == "agent" }
        second.send(chapterLine("dir:pkg", "ok"))
        await eventually("lock taken") { h.model.waitingFor == nil }
        second.send(Self.overviewEnvelope)
        second.finish()
        await h.settle()
        XCTAssertEqual(h.cli.processes.map(\.stopCount), [1, 0], "no other process was ever signalled")
    }

    func testWaitingWithoutACallerShowsTheGenericLine() async throws {
        let h = try harness()
        await openDeep(h)
        let run = try await process(h, 0)
        run.send(#"{"event":"waiting"}"#)
        await eventually("waiting") { h.model.waitingFor != nil }
        XCTAssertEqual(h.model.waitingText, "Another run is describing this branch — chapters appear as it finishes them")
        XCTAssertEqual(ReviewChangesModel.waitingText(by: "desktop"),
                       "Branch review is describing this branch — chapters appear as it finishes them")
        XCTAssertEqual(ReviewChangesModel.waitingText(by: "cli"), ReviewChangesModel.waitingText(by: ""))
        run.send(Self.overviewEnvelope)
        run.finish()
        await h.settle()
        XCTAssertNil(h.model.waitingFor)
    }

    /// A wait past the lock cap ends as `busy`: the progress card's text, and Retry runs again.
    func testBusyShowsTheCardTextWithRetry() async throws {
        let h = try harness()
        await openDeep(h)
        let run = try await process(h, 0)
        run.send(#"{"event":"waiting","by":"agent"}"#)
        run.send(#"{"ok":false,"error":"Another overview of this branch is still running.","error_class":"busy"}"#)
        run.finish(status: 0) // the envelope's class is the signal, not the exit (Task 8)
        await h.settle()
        XCTAssertEqual(h.model.overview, .failed("Another overview of this branch is still running."))
        XCTAssertNil(h.model.waitingFor)
        XCTAssertEqual(h.model.chapterStates, ["dir:cmd": .notStarted, "dir:pkg": .notStarted])
        h.model.retryOverview()
        let again = try await process(h, 1)
        XCTAssertFalse(again.args.contains("--cached-only"), "Retry runs the model again")
        again.send(Self.overviewEnvelope)
        again.finish()
        await h.settle()
        guard case .ready = h.model.overview else { return XCTFail("overview \(h.model.overview)") }
    }

    // MARK: - Silence and broken streams

    /// Ticks every 30 s for 10 min never trip the 5-min silence timer; 5 min
    /// with no complete line does.
    func testSilenceTimerResetsOnEveryLineAndTripsAfterFiveMinutes() async throws {
        let h = try harness()
        await openDeep(h)
        let run = try await process(h, 0)
        let lines = [#"{"event":"tick"}"#, #"{"event":"progress"}"#, "not json"]
        for i in 0..<20 {
            clock.advance(by: 30)
            run.send(lines[i % lines.count])
            let expected = clock.now
            await eventually("line \(i) read") { h.model.lastStreamLine == expected }
        }
        XCTAssertEqual(h.model.overview, .loading)
        XCTAssertEqual(run.stopCount, 0, "ten minutes of lines never trip it")
        clock.advance(by: 299)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(run.stopCount, 0)
        clock.advance(by: 1)
        await eventually("stopped") { run.stopCount == 1 }
        await h.settle()
        XCTAssertEqual(h.model.overview, .failed(ReviewChangesModel.streamSilentMessage))
        XCTAssertEqual(h.model.chapterStates, ["dir:cmd": .notStarted, "dir:pkg": .notStarted])
    }

    /// The process died mid-line: the cut line is dropped and the run fails.
    func testStreamCutMidLineWithoutAnEnvelopeFails() async throws {
        let h = try harness()
        await openDeep(h)
        let run = try await process(h, 0)
        run.send(chapterLine("dir:cmd", "ok"))
        run.sendRaw(#"{"event":"chapter","key":"dir:pkg","sta"#)
        run.finish(status: 137)
        await h.settle()
        XCTAssertEqual(h.model.overview, .failed(ReviewChangesModel.streamEndedMessage))
        XCTAssertEqual(h.model.chapterStates, ["dir:cmd": .ok, "dir:pkg": .notStarted], "a finished chapter stays")
    }

    func testUnreadableEnvelopeFailsTheRun() async throws {
        let h = try harness()
        await openDeep(h)
        let run = try await process(h, 0)
        run.send(#"{"ok":true,"overview":7}"#)
        run.finish()
        await h.settle()
        XCTAssertEqual(h.model.overview, .failed(ReviewChangesModel.streamUnreadableMessage))
    }

    func testUnreadableMapLineFailsTheMap() async throws {
        let h = try harness()
        await openDeep(h)
        let run = try await process(h, 0)
        run.send(#"{"event":"map","map":"broken"}"#)
        await eventually("map failed") { h.model.map == .failed }
        XCTAssertEqual(h.model.chapters, [])
        run.send(Self.overviewEnvelope)
        run.finish()
        await h.settle()
    }

    // MARK: - Navigation

    /// A deleted session's model is dropped and its run stopped with it.
    func testForgettingTheSessionStopsItsRun() async throws {
        let h = try harness()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "review-bigbranch-\(UUID().uuidString)"))
        let vm = WorkbenchesViewModel(dbPool: h.db, cli: WorkbenchCLI(runner: h.cli), defaults: defaults)
        let model = try XCTUnwrap(vm.reviewModel(sessionID: h.sessionID, projectID: h.projectID))
        model.streamClock = clock
        h.cli.script(["context": #"{"ok":true,"items":[]}"#, "diff": diffJSON(["cmd/x.go", "pkg/y.go"]), "start": deepStart()])
        await model.open()
        await model.mapTask?.value
        let run = try await process(h, 0)
        model.retry(chapter: "dir:pkg")
        vm.forgetProcessState(h.sessionID)
        await eventually("stopped with the session") { run.stopCount == 1 }
        await model.overviewTask?.value
        XCTAssertEqual(h.cli.processes.count, 1, "nothing is followed up")
    }

    /// The run belongs to the session's model, kept by the workbench across
    /// navigation: leaving the pane and coming back finds it still going.
    func testRunSurvivesLeavingThePaneAndComingBack() async throws {
        let h = try harness()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "review-bigbranch-\(UUID().uuidString)"))
        let vm = WorkbenchesViewModel(dbPool: h.db, cli: WorkbenchCLI(runner: h.cli), defaults: defaults)
        let model = try XCTUnwrap(vm.reviewModel(sessionID: h.sessionID, projectID: h.projectID))
        model.streamClock = clock
        h.cli.script(["context": #"{"ok":true,"items":[]}"#, "diff": diffJSON(["cmd/x.go", "pkg/y.go"]), "start": deepStart()])
        await model.open()
        await model.mapTask?.value
        let run = try await process(h, 0)
        run.send(chapterLine("dir:cmd", "ok"))
        await eventually("dir:cmd ok") { model.chapterStates["dir:cmd"] == .ok }

        // Away (another session's pane), then back: the same model, the run still going.
        _ = vm.reviewModel(sessionID: h.sessionID + 1, projectID: h.projectID)
        let back = try XCTUnwrap(vm.reviewModel(sessionID: h.sessionID, projectID: h.projectID))
        XCTAssertTrue(back === model)
        XCTAssertEqual(back.chapterStates, ["dir:cmd": .ok, "dir:pkg": .running])
        XCTAssertEqual(run.stopCount, 0)
        run.send(chapterLine("dir:pkg", "ok"))
        run.send(Self.overviewEnvelope)
        run.finish()
        await eventually("landed") { if case .ready = back.overview { true } else { false } }
        XCTAssertEqual(back.chapterStates, ["dir:cmd": .ok, "dir:pkg": .ok])
    }
}

import Foundation
import os
import WatchtowerChatText

/// Holds the chat feed of one session and merges each poll of
/// `watchtower workbench session-feed` into it: upsert by entry id keeping the
/// first position, so a growing agent message updates in place. The subagent
/// markers are kept apart in `subagents` (the 👥 list's source, #2065), upserted
/// the same way, so a subagent whose status changed updates in place there.
/// The first read is a tail read (the last `tailSize` entries); earlier
/// entries come a page at a time from `loadEarlierPage()` (#2065 Task 8).
@MainActor
package final class SessionFeedStore: ObservableObject {
    /// Entries per tail read and per earlier page.
    package static let tailSize = 60

    @Published package private(set) var entries: [SessionFeedEntry] = []
    /// Entries before the first one held exist and can be read a page at a
    /// time (`loadEarlierPage()`). False once the first page is held, and
    /// when the CLI refuses the page's `before` id for good.
    @Published package private(set) var hasEarlierPage = false
    /// The last earlier-page read failed (kept apart from a poll's `error`,
    /// which an `--after` read clears). Until `retryEarlierPage()` the page
    /// is not asked for again, so a layout pass never respawns the CLI.
    @Published package private(set) var earlierPageError: String?
    /// Every subagent marker read so far, from the feed's `subagents` list and
    /// the `subagent` entries; never part of `entries` by the list.
    @Published package private(set) var subagents: [SessionFeedEntry] = []
    /// A read has succeeded once; a later failure never resets it.
    @Published package private(set) var feedLoaded = false
    @Published package private(set) var error: String?
    /// The agent's open tool call from the last good read (an empty read
    /// included); the live line shows it, it is never an entry.
    @Published package private(set) var activity: SessionFeedActivity?

    @Published package private(set) var live: SessionFeedLive?
    @Published package private(set) var liveError: String?
    @Published package private(set) var liveLoaded = false
    private var liveGeneration = 0
    /// Only the selected child: preserve expected resume across Retry or a
    /// foreground task restart without starting any additional observer.
    private var subagentObservation: (key: SubagentObservationKey, value: SessionSubagentObservation)?
    private var subagentObservationGeneration = 0

    /// No CLI binary was found: the pane shows the error and never polls.
    package let runnerMissing: Bool
    /// Every read of the pane goes through it, so a read already in flight
    /// is joined instead of spawning a second CLI.
    package private(set) lazy var poller = SessionFeedPoller { [weak self] in await self?.refresh() }

    private let sessionID: Int64
    private let runner: CLIRunnerProtocol
    private var cursor = ""
    /// The id of the first entry held from the tail pages: `--before` for
    /// the next earlier page.
    private var before = ""
    /// An earlier page is being read; another ask is a no-op meanwhile.
    package private(set) var loadingEarlierPage = false
    /// An earlier page is held: a later tail read (cursor still empty) must
    /// not move `before` back to the tail.
    private var heldEarlierPage = false
    private var index: [String: Int] = [:]
    private var subagentIndex: [String: Int] = [:]
    private var screenGate = ForegroundRefreshGate()
    /// The open-time trace of the pane showing this store. The store starts
    /// one as it is made (before the pane renders its first feed), so every
    /// mark of the open lands on it; `refresh()` marks the CLI phases.
    package private(set) var openTrace: WorkchatOpenTrace?
    /// The last CLI read started; the next one waits for it, so the pane
    /// never runs two CLI processes at once (main feed and subagent alike).
    private var lastRead: Task<Void, Never>?
    private let fileEvents: FileEventSource
    private let watchClock: TranscriptWatchClock
    /// The main feed's watch, shared by every pane following this store
    /// (the workspace pane and the review panel may both show it): it runs
    /// while at least one follows and the app is on screen.
    private lazy var mainWatch = TranscriptWatch(fileEvents: fileEvents, clock: watchClock) { [weak self] in
        self?.mainWatchFired()
    }
    private var followers: [Int: MainFollower] = [:]
    private var nextFollower = 0
    /// `paths` of the last good main read.
    private var readPaths: [String] = []
    /// The running subagent follows' watches, by tool-use id.
    private var subagentWatches: [String: SubagentWatch] = [:]

    /// `runner` nil: the CLI binary is missing (`runnerMissing`).
    package init(
        sessionID: Int64,
        runner: CLIRunnerProtocol?,
        fileEvents: FileEventSource = DispatchFileEventSource(),
        watchClock: TranscriptWatchClock = MainQueueWatchClock()
    ) {
        self.sessionID = sessionID
        self.runner = runner ?? UnavailableRunner()
        runnerMissing = runner == nil
        self.fileEvents = fileEvents
        self.watchClock = watchClock
        beginOpenTrace(reopen: false)
    }

    /// Starts the trace of one pane open and marks `.appear`. Called once
    /// per open (the store's init, `WorkbenchesViewModel.feedStore`), so a
    /// kept store shown again (`reopen: true`) always times its own open: a
    /// trace a pane left unpainted is abandoned (its interval ends), never
    /// carried into the next open.
    package func beginOpenTrace(reopen: Bool) {
        openTrace?.abandon()
        let trace = WorkchatOpenTrace(sessionID: sessionID, reopen: reopen)
        openTrace = trace
        trace.mark(.appear)
    }

    /// The pane's reads: one now, then while `isActive` one on each change
    /// of a followed file (`TranscriptWatch`: 250 ms debounce, at most one a
    /// second, a 3 s tick only while it cannot watch). The session's state
    /// change re-enters `follow` (the pane's task key), which is its one
    /// read: the watch reopens the last read's files before it. No liveness
    /// timer. Off screen (the main window hidden, minimised or covered) no
    /// file is watched and no read runs; `screenChanged` reads at once on the
    /// way back. Returns when inactive or cancelled; the last follower to
    /// leave closes the watch.
    package func follow(isActive: @escaping () -> Bool, isOnScreen: @escaping () -> Bool) async {
        guard !runnerMissing else { return }
        let onScreen = isOnScreen()
        let readNow = gatedTick(onScreen)
        guard isActive(), !Task.isCancelled else {
            if readNow { await poller.refresh() }
            return
        }
        let id = nextFollower
        nextFollower += 1
        followers[id] = MainFollower(isActive: isActive, isOnScreen: isOnScreen)
        if onScreen { mainWatch.start() }
        if readNow { await poller.refresh() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (wake: CheckedContinuation<Void, Never>) in
                if Task.isCancelled || followers[id] == nil {
                    wake.resume()
                } else {
                    followers[id]?.wake = wake
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.endFollower(id) }
        }
        endFollower(id)
    }

    private func endFollower(_ id: Int) {
        guard let follower = followers.removeValue(forKey: id) else { return }
        follower.wake?.resume()
        if followers.isEmpty { mainWatch.stop() }
    }

    /// A followed file changed (or the fallback tick): one read, unless no
    /// follower is active any more or none is on screen.
    private func mainWatchFired() {
        for (id, follower) in Array(followers) where !follower.isActive() { endFollower(id) }
        guard !followers.isEmpty else { return }
        guard gatedTick(followers.values.contains { $0.isOnScreen() }) else { return }
        Task { await poller.refresh() }
    }

    /// The app's windows went on or off screen (`UIVisibilityCenter`). Off
    /// screen the watch closes; back on screen it reopens and the feed is
    /// read at once (also after a skipped read with no follower).
    package func screenChanged(_ onScreen: Bool) async {
        guard !runnerMissing else { return }
        let missed = screenGate.setOnScreen(onScreen)
        guard onScreen else {
            mainWatch.stop()
            return
        }
        var catchUp = missed
        if !followers.isEmpty, !mainWatch.isRunning {
            mainWatch.start()
            catchUp = true
        }
        if catchUp { await poller.refresh() }
    }

    private func gatedTick(_ onScreen: Bool) -> Bool {
        _ = screenGate.setOnScreen(onScreen)
        return screenGate.tick()
    }

    /// Reads what is new since the last cursor (a tail read of the last
    /// `tailSize` entries while none exists). A failure keeps the entries and
    /// sets `error`.
    package func refresh() async {
        let tailRead = cursor.isEmpty
        var args = ["workbench", "session-feed", "--session", String(sessionID), "--json"]
        args += tailRead ? ["--tail", String(Self.tailSize)] : ["--after", cursor]
        let generation = liveGeneration
        // The open this read started for: a newer pane's trace begun while it
        // runs is not marked by it.
        let trace = openTrace
        mainWatch.readStarted()
        do {
            trace?.mark(.spawn)
            let data = try await read(args)
            trace?.mark(.exit)
            let payload = try Self.decode(data)
            trace?.mark(.decode)
            merge(payload.entries)
            mergeSubagents(payload.entries.filter { $0.kind == "subagent" } + payload.subagents)
            // Only a tail read prints `before`; an `--after` read leaves it.
            if tailRead, !heldEarlierPage { setBefore(payload.before) }
            cursor = payload.cursor
            feedLoaded = true
            if generation == liveGeneration {
                activity = payload.activity
                liveLoaded = true
                if payload.liveOK == true, let snapshot = payload.live {
                    live = snapshot
                    liveError = nil
                } else {
                    liveError = payload.liveError ?? WorkchatLivePresentation.unavailable
                }
            }
            error = nil
            readPaths = payload.paths
            mainWatch.update(mainTargets())
        } catch {
            mainWatch.markReadFailed()
            self.error = error.localizedDescription
            if generation == liveGeneration {
                liveLoaded = true
                liveError = WorkchatLivePresentation.unavailable
            }
        }
    }

    /// The main watch's targets: the current conversation (the live
    /// snapshot's, else the last conversation file listed) and the running
    /// agents, the live snapshot's word over the markers'.
    private func mainTargets() -> TranscriptWatchTargets {
        var status: [String: String] = [:]
        for marker in subagents {
            if let ref = marker.subagent, !ref.agentID.isEmpty { status[ref.agentID] = ref.status }
        }
        for agent in live?.agents ?? [] where !agent.ref.agentID.isEmpty {
            status[agent.ref.agentID] = agent.ref.status
        }
        let running = Set(status.filter { $0.value == "running" }.keys)
        return TranscriptWatchTargets(paths: readPaths, current: mainConversation(knownAgents: Set(status.keys)).map { [$0] } ?? [],
                                      running: running, mustCover: Self.liveRunning(live))
    }

    /// The running agents of a live snapshot, by agent id.
    private static func liveRunning(_ live: SessionFeedLive?) -> Set<String> {
        Set((live?.agents ?? []).filter { $0.ref.status == "running" && !$0.ref.agentID.isEmpty }.map(\.ref.agentID))
    }

    /// The main feed's live snapshot as the line shows it at `now`: while
    /// the watch is healthy (`isLiveWatched`) a quiet transcript is not out
    /// of date, so its age does not count (spec C4); otherwise the read's own
    /// `observedAt` does.
    package func presentedLive(now: Date) -> SessionFeedLive? {
        WorkchatLiveFreshness.effective(live, watched: isLiveWatched, now: now)
    }

    /// The main feed's watch sees every change: it runs, every followed
    /// file is open and the last read succeeded.
    package var isLiveWatched: Bool { mainWatch.isHealthy }

    /// The same for an open subagent's follow.
    package func isSubagentWatched(_ toolUseID: String) -> Bool {
        subagentWatches[toolUseID]?.watch.isHealthy ?? false
    }

    private func mainConversation(knownAgents: Set<String>) -> String? {
        func isConversation(_ path: String) -> Bool {
            let name = (path as NSString).lastPathComponent
            guard name.hasSuffix(".jsonl"), !name.hasPrefix("agent-"), let id = TranscriptWatch.fileID(path) else { return false }
            return !knownAgents.contains(id)
        }
        if let conversation = live?.conversation, !conversation.isEmpty,
           let path = readPaths.first(where: { isConversation($0) && TranscriptWatch.fileID($0) == conversation }) {
            return path
        }
        return readPaths.last(where: isConversation)
    }

    /// Reads the page of `tailSize` entries before the first one held and
    /// puts it in front; returns how many dialog entries
    /// (`WorkchatFeedAdapter.dialog`) this page added, never counting what a
    /// poll appended meanwhile. A no-op (0) without an
    /// earlier page, while one is being read, or after a failed one (until
    /// `retryEarlierPage()`). Goes through the pane's serial read, so it never
    /// overlaps a poll. A failure keeps the entries and sets
    /// `earlierPageError`; the page stays asked for (`hasEarlierPage`), except
    /// when the CLI refuses its `before` id for good, which ends the paging
    /// quietly (logged, no `earlierPageError`).
    @discardableResult
    package func loadEarlierPage() async -> Int {
        guard hasEarlierPage, earlierPageError == nil, !before.isEmpty, !loadingEarlierPage, !runnerMissing else {
            return 0
        }
        loadingEarlierPage = true
        defer { loadingEarlierPage = false }
        do {
            let data = try await read([
                "workbench", "session-feed", "--session", String(sessionID), "--json",
                "--tail", String(Self.tailSize), "--before", before
            ])
            let payload = try Self.decode(data)
            let added = prepend(payload.entries)
            mergeSubagents(payload.entries.filter { $0.kind == "subagent" } + payload.subagents)
            heldEarlierPage = true
            setBefore(payload.before)
            return WorkchatFeedAdapter.dialog(added).count
        } catch {
            if Self.refusesBefore(error) {
                // The same id fails every time: paging ends quietly (no
                // error with a Retry that could never succeed).
                Self.log.notice("session \(self.sessionID, privacy: .public): earlier pages end, before refused")
                setBefore("")
            } else {
                earlierPageError = error.localizedDescription
            }
            return 0
        }
    }

    /// The owner's Retry after a failed earlier page: reads it again.
    @discardableResult
    package func retryEarlierPage() async -> Int {
        earlierPageError = nil
        return await loadEarlierPage()
    }

    private static let log = Logger(subsystem: "com.watchtower.desktop", category: "SessionFeed")

    /// The CLI's `--before` errors that the same id gives on every try
    /// (`internal/sessionfeed/feed.go` `TailPage`): an id no longer in the
    /// feed, or a legacy Codex id ("L<offset>") repeated across conversations.
    /// Each text is pinned in `internal/sessionfeed/feed_tail_test.go`:
    /// "is ambiguous" by `TestTailPage_AmbiguousBeforeIsAnError`, "no such
    /// entry" by `TestTailPage_UnknownBeforeIsAnError`.
    private static func refusesBefore(_ error: Error) -> Bool {
        guard case let CLIRunnerError.nonZeroExit(_, stderr) = error else { return false }
        return stderr.contains("is ambiguous") || stderr.contains("no such entry")
    }

    private func setBefore(_ id: String) {
        before = id
        hasEarlierPage = !id.isEmpty
    }

    /// The session left working: the old step must not flash on the next turn.
    package func clearActivity() {
        liveGeneration += 1
        subagentObservation = nil
        subagentObservationGeneration += 1
        activity = nil; live = nil; liveError = nil; liveLoaded = false
    }

    /// One serial loop for the open pane. While the root stays active,
    /// completed child history pauses but its immediate parent is observed
    /// for resume. No per-agent timer or tree walk is started: the loop reads
    /// on a change of the child's transcript, its parent's conversation or a
    /// running nested agent's file (`TranscriptWatch` over the reads'
    /// `paths`), the 3 s tick only while it cannot watch. Off screen it
    /// returns at once (the pane's task key restarts it on the way back).
    /// `interval`, for tests, sets every watch bound to one cadence.
    package func followSubagent(
        _ toolUseID: String,
        interval: Duration? = nil,
        readsMainFeed: Bool = false,
        parentToolUseID: String? = nil,
        isSessionActive: (() -> Bool)? = nil,
        isRunning: () -> Bool,
        isOnScreen: () -> Bool,
        onEntries: ([SessionFeedEntry]) -> Void,
        onActivity: (SessionFeedActivity?) -> Void = { _ in },
        onLive: (SessionFeedLive?, String?) -> Void = { _, _ in },
        onStatus: (String) -> Void = { _ in },
        onError: (String?) -> Void = { _ in }
    ) async {
        guard !runnerMissing, isOnScreen() else { return }
        if isSessionActive != nil { subagentObservationGeneration += 1 }
        let generation = subagentObservationGeneration
        func isCurrentObservation() -> Bool { isSessionActive == nil || generation == subagentObservationGeneration }
        let observationKey = SubagentObservationKey(child: toolUseID, parent: parentToolUseID)
        if isSessionActive != nil, subagentObservation?.key != observationKey {
            subagentObservation = (observationKey, SessionSubagentObservation())
        }
        var observation = isSessionActive != nil ? (subagentObservation?.value ?? SessionSubagentObservation()) : SessionSubagentObservation()
        func rememberObservation() {
            if isSessionActive != nil, isCurrentObservation(), subagentObservation?.key == observationKey {
                subagentObservation = (observationKey, observation)
            }
        }
        let watch = SubagentWatch(fileEvents: fileEvents, clock: watchClock, interval: interval)
        func readChild() async {
            do {
                let result = try await subagentFeed(toolUseID)
                watch.childRead(Self.subagentTargets(result.paths, live: result.live))
                guard !Task.isCancelled, isCurrentObservation() else { return }
                if isSessionActive != nil {
                    let status = observation.receiveOwn(snapshot: result.live, entries: result.entries,
                                                        error: result.liveError, now: .now)
                    rememberObservation()
                    onStatus(status)
                    // A fresh read clock does not make the previous run's
                    // completed transcript an acknowledgement of resume.
                    if observation.awaitingOwnEvidence, result.liveError == nil { onError(nil); return }
                }
                onEntries(result.entries); onActivity(result.activity)
                onLive(result.live, result.liveError); onError(nil)
            } catch {
                watch.childFailed()
                guard !Task.isCancelled, isCurrentObservation() else { return }
                if isSessionActive != nil {
                    let status = observation.receiveOwn(snapshot: nil, entries: [], error: error.localizedDescription, now: .now)
                    rememberObservation()
                    onStatus(status)
                }
                onError(error.localizedDescription); onLive(nil, WorkchatLivePresentation.unavailable)
            }
        }
        func readParent() async -> SessionFeedLive? {
            if isSessionActive != nil, let parentToolUseID {
                // Only the immediate parent, never a tree-wide fan-out.
                do {
                    let result = try await subagentFeed(parentToolUseID)
                    watch.parentRead(Self.subagentTargets(result.paths, live: result.live))
                    guard !Task.isCancelled, isCurrentObservation() else { return nil }
                    onError(result.liveError)
                    return result.liveError == nil ? result.live : nil
                } catch {
                    watch.parentFailed()
                    guard !Task.isCancelled, isCurrentObservation() else { return nil }
                    onError(error.localizedDescription)
                }
            } else if readsMainFeed || isSessionActive != nil {
                await poller.refresh()
                if error == nil { watch.parentRead(mainTargets()) } else { watch.parentFailed() }
                return liveError == nil ? live : nil
            }
            return nil
        }
        var opening = true
        func tick() async {
            guard isOnScreen(), !Task.isCancelled, isCurrentObservation() else { return }
            let readOwn = opening || isSessionActive == nil || observation.shouldReadOwn
            opening = false
            if readOwn { await readChild() }
            guard !Task.isCancelled, isOnScreen(), isCurrentObservation() else { return }
            if let isSessionActive, !isSessionActive() { return }
            let parent = await readParent()
            guard !Task.isCancelled, isOnScreen(), isCurrentObservation() else { return }
            if let isSessionActive, !isSessionActive() { return }
            if isSessionActive != nil {
                let resumed = observation.receiveParent(parent, childID: toolUseID, now: .now)
                rememberObservation()
                if let status = observation.parentTransition { onStatus(status) }
                if resumed { await readChild() }
            }
        }
        await watchSubagent(toolUseID, watch, isOnScreen: isOnScreen, tick: tick) { isCurrentObservation() && (isSessionActive?() ?? isRunning()) }
    }

    /// Runs one subagent follow's watch, listed for `isSubagentWatched` meanwhile.
    private func watchSubagent(
        _ toolUseID: String,
        _ watch: SubagentWatch,
        isOnScreen: () -> Bool,
        tick: () async -> Void,
        following: () -> Bool
    ) async {
        subagentWatches[toolUseID] = watch
        defer { if subagentWatches[toolUseID] === watch { subagentWatches[toolUseID] = nil } }
        await watch.run(isOnScreen: isOnScreen, following: following, tick: tick)
    }

    /// What one subagent read says to watch: its own transcript (the read's
    /// first path) and the nested agents it lists as running.
    private static func subagentTargets(_ paths: [String], live: SessionFeedLive?) -> TranscriptWatchTargets {
        let running = liveRunning(live)
        return TranscriptWatchTargets(paths: paths, current: paths.first.map { [$0] } ?? [], running: running, mustCover: running)
    }

    /// The feed of one subagent run with its own open tool call; not merged
    /// into the main feed.
    package func subagentFeed(
        _ toolUseID: String
    ) async throws -> SubagentRead {
        let data = try await read([
            "workbench", "session-feed", "--session", String(sessionID), "--subagent", toolUseID, "--json"
        ])
        let payload = try Self.decode(data)
        return SubagentRead(
            entries: payload.entries.filter { SessionFeedEntry.knownKinds.contains($0.kind) }, activity: payload.activity,
            live: payload.liveOK == true ? payload.live : nil,
            liveError: payload.liveOK == true ? nil : (payload.liveError ?? WorkchatLivePresentation.unavailable),
            paths: payload.paths
        )
    }

    /// Runs one CLI read after the one before it has finished. The read
    /// lives in its own task, so a cancelled caller never overlaps the next;
    /// a closed pane's in-flight read also runs to completion (one process
    /// at a time, never killed).
    private func read(_ args: [String]) async throws -> Data {
        let previous = lastRead
        let runner = runner
        let task = Task { @MainActor () throws -> Data in
            await previous?.value
            return try await runner.run(args: args)
        }
        lastRead = Task { _ = try? await task.value }
        return try await task.value
    }

    private static func decode(_ data: Data) throws -> SessionFeedPayload {
        try JSONDecoder().decode(SessionFeedPayload.self, from: data)
    }

    private func merge(_ incoming: [SessionFeedEntry]) {
        for entry in incoming where SessionFeedEntry.knownKinds.contains(entry.kind) {
            if let i = index[entry.id] {
                entries[i] = entry
            } else {
                index[entry.id] = entries.count
                entries.append(entry)
            }
        }
    }

    /// An earlier page goes in front; an entry already held stays where it
    /// is, and an id repeated inside the page (legacy Codex "L<offset>") is
    /// taken once, the first time. Returns the entries added.
    private func prepend(_ page: [SessionFeedEntry]) -> [SessionFeedEntry] {
        var seen = Set(index.keys)
        let fresh = page.filter { SessionFeedEntry.knownKinds.contains($0.kind) && seen.insert($0.id).inserted }
        guard !fresh.isEmpty else { return [] }
        entries = fresh + entries
        index = Dictionary(entries.enumerated().map { ($1.id, $0) }) { first, _ in first }
        return fresh
    }

    private func mergeSubagents(_ incoming: [SessionFeedEntry]) {
        for entry in incoming where entry.kind == "subagent" {
            if let i = subagentIndex[entry.id] {
                // The first known start time stays: an `--after` read dates a
                // marker by its meta.json mtime, and Done's order must not jump.
                var entry = entry
                if let first = subagents[i].subagent?.startedAt { entry.subagent?.startedAt = first }
                subagents[i] = entry
            } else {
                subagentIndex[entry.id] = subagents.count
                subagents.append(entry)
            }
        }
    }
}

/// Stand-in when the CLI binary is missing: the store never polls then, so
/// this is never called.
private struct UnavailableRunner: CLIRunnerProtocol {
    func run(args: [String]) async throws -> Data { Data() }
    func runModel(args: [String], origin: CLIOrigin, timeout: TimeInterval?, stdin: Data?) async throws -> Data { Data() }
}

/// One `--subagent` read.
package struct SubagentRead {
    package var entries: [SessionFeedEntry]
    package var activity: SessionFeedActivity?
    package var live: SessionFeedLive?
    package var liveError: String?
    /// The files the read went through (`TranscriptWatch`).
    package var paths: [String]
}

/// One subagent follow's watch: its own transcript's targets and its
/// parent's (the main feed or the immediate parent agent), merged.
@MainActor
private final class SubagentWatch {
    let watch: TranscriptWatch
    private let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var child = TranscriptWatchTargets()
    private var parent = TranscriptWatchTargets()
    /// Each read's last outcome: the fallback tick runs until both have
    /// succeeded since their last failure, so one never masks the other.
    private var childFailing = false
    private var parentFailing = false

    init(fileEvents: FileEventSource, clock: TranscriptWatchClock, interval: Duration?) {
        let (events, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.events = events
        self.continuation = continuation
        watch = TranscriptWatch(fileEvents: fileEvents, clock: clock,
                                timing: interval.map(TranscriptWatchTiming.uniform) ?? .standard) { continuation.yield() }
    }

    /// One tick now, then one per change while `following`; returns off
    /// screen or cancelled, closing the watch.
    func run(isOnScreen: () -> Bool, following: () -> Bool, tick: () async -> Void) async {
        watch.start()
        defer {
            watch.stop()
            continuation.finish()
        }
        watch.readStarted()
        await tick()
        guard following() else { return }
        for await _ in events {
            if Task.isCancelled || !isOnScreen() { return }
            watch.readStarted()
            await tick()
            guard following() else { return }
        }
    }

    func childRead(_ targets: TranscriptWatchTargets) { child = targets; childFailing = false; push() }
    func childFailed() { childFailing = true; push() }
    func parentRead(_ targets: TranscriptWatchTargets) { parent = targets; parentFailing = false; push() }
    func parentFailed() { parentFailing = true; push() }

    private func push() {
        watch.update(TranscriptWatchTargets(paths: child.paths + parent.paths, current: child.current + parent.current,
                                            running: child.running.union(parent.running),
                                            mustCover: child.mustCover.union(parent.mustCover)),
                     readFailed: childFailing || parentFailing)
    }
}

private struct MainFollower {
    let isActive: () -> Bool
    let isOnScreen: () -> Bool
    var wake: CheckedContinuation<Void, Never>?
}

private struct SubagentObservationKey: Equatable {
    let child: String
    let parent: String?
}

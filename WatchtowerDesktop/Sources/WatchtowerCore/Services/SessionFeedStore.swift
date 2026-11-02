import Foundation

/// Holds the chat feed of one session and merges each poll of
/// `watchtower workbench session-feed` into it: upsert by entry id keeping the
/// first position, so a growing agent message or a subagent whose status
/// changed updates in place.
@MainActor
package final class SessionFeedStore: ObservableObject {
    @Published package private(set) var entries: [SessionFeedEntry] = []
    @Published package private(set) var error: String?
    /// The agent's open tool call from the last good read (an empty read
    /// included); the live line shows it, it is never an entry.
    @Published package private(set) var activity: SessionFeedActivity?

    @Published package private(set) var live: SessionFeedLive?
    @Published package private(set) var liveError: String?
    @Published package private(set) var liveLoaded = false
    private var liveGeneration = 0

    /// No CLI binary was found: the pane shows the error and never polls.
    package let runnerMissing: Bool
    /// Every read of the pane goes through it, so a read already in flight
    /// is joined instead of spawning a second CLI.
    package private(set) lazy var poller = SessionFeedPoller { [weak self] in await self?.refresh() }

    private let sessionID: Int64
    private let runner: CLIRunnerProtocol
    private var cursor = ""
    private var index: [String: Int] = [:]
    private var screenGate = ForegroundRefreshGate()
    /// The last CLI read started; the next one waits for it, so the pane
    /// never runs two CLI processes at once (main feed and subagent alike).
    private var lastRead: Task<Void, Never>?

    /// `runner` nil: the CLI binary is missing (`runnerMissing`).
    package init(sessionID: Int64, runner: CLIRunnerProtocol?) {
        self.sessionID = sessionID
        self.runner = runner ?? UnavailableRunner()
        runnerMissing = runner == nil
    }

    /// The pane's poll: one read now, then while `isActive` one more every
    /// `interval`. A read due while `isOnScreen` is false (the main window
    /// hidden, minimised or covered) is skipped, and `screenChanged` reads at
    /// once on the way back. Returns when inactive or cancelled.
    package func follow(
        interval: Duration = .seconds(3),
        isActive: () -> Bool,
        isOnScreen: () -> Bool
    ) async {
        guard !runnerMissing else { return }
        if gatedTick(isOnScreen()) { await poller.refresh() }
        while isActive() {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            if gatedTick(isOnScreen()) { await poller.refresh() }
        }
    }

    /// The app's windows went on or off screen (`UIVisibilityCenter`): back
    /// on screen after a skipped read, the feed is read now.
    package func screenChanged(_ onScreen: Bool) async {
        guard !runnerMissing, screenGate.setOnScreen(onScreen) else { return }
        await poller.refresh()
    }

    private func gatedTick(_ onScreen: Bool) -> Bool {
        _ = screenGate.setOnScreen(onScreen)
        return screenGate.tick()
    }

    /// Reads what is new since the last cursor (a full read while none exists).
    /// A failure keeps the entries and sets `error`.
    package func refresh() async {
        var args = ["workbench", "session-feed", "--session", String(sessionID), "--json"]
        if !cursor.isEmpty { args += ["--after", cursor] }
        let generation = liveGeneration
        do {
            let payload = try Self.decode(try await read(args))
            merge(payload.entries)
            merge(payload.subagents)
            cursor = payload.cursor
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
        } catch {
            self.error = error.localizedDescription
            if generation == liveGeneration {
                liveLoaded = true
                liveError = WorkchatLivePresentation.unavailable
            }
        }
    }

    /// The session left working: the old step must not flash on the next turn.
    package func clearActivity() {
        liveGeneration += 1
        activity = nil; live = nil; liveError = nil; liveLoaded = false
    }

    /// One serial loop for the open pane. While the root stays active,
    /// completed child history pauses but its immediate parent is observed
    /// for resume. No per-agent timer or tree walk is started.
    package func followSubagent(
        _ toolUseID: String,
        interval: Duration = .seconds(3),
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
        guard !runnerMissing else { return }
        var observation = SessionSubagentObservation()
        func readChild() async {
            do {
                let result = try await subagentFeed(toolUseID)
                guard !Task.isCancelled else { return }
                if isSessionActive != nil {
                    onStatus(observation.receiveOwn(snapshot: result.live, entries: result.entries,
                                                    error: result.liveError, now: .now))
                }
                onEntries(result.entries); onActivity(result.activity)
                onLive(result.live, result.liveError); onError(nil)
            } catch {
                guard !Task.isCancelled else { return }
                if isSessionActive != nil {
                    onStatus(observation.receiveOwn(snapshot: nil, entries: [], error: error.localizedDescription, now: .now))
                }
                onError(error.localizedDescription); onLive(nil, WorkchatLivePresentation.unavailable)
            }
        }
        func tick() async {
            guard isOnScreen(), !Task.isCancelled else { return }
            let readOwn = isSessionActive == nil || !observation.finished
            if readOwn { await readChild() }
            guard !Task.isCancelled, isOnScreen() else { return }
            // An inactive session still gets its one opening history read.
            if let isSessionActive, !isSessionActive() { return }
            var parent: SessionFeedLive?
            if isSessionActive != nil, observation.finished, !readOwn, let parentToolUseID {
                do {
                    let result = try await subagentFeed(parentToolUseID)
                    if result.liveError == nil { parent = result.live; onError(nil) } else { onError(result.liveError) }
                } catch {
                    // Surface the failed parent read without discarding the
                    // completed interval; retry its parent next tick.
                    parent = nil; onError(error.localizedDescription)
                }
            }
            guard !Task.isCancelled, isOnScreen() else { return }
            if readsMainFeed || isSessionActive != nil { await poller.refresh() }
            guard !Task.isCancelled, isOnScreen() else { return }
            if let isSessionActive, !isSessionActive() { return }
            if isSessionActive != nil, parentToolUseID == nil, liveError == nil { parent = live }
            if isSessionActive != nil,
               observation.receiveParent(parent, childID: toolUseID, now: .now) {
                onStatus("running")
                await readChild()
            }
        }
        await tick()
        while isSessionActive?() ?? isRunning() {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            await tick()
        }
    }

    /// The feed of one subagent run with its own open tool call; not merged
    /// into the main feed.
    package func subagentFeed(
        _ toolUseID: String
    ) async throws -> (entries: [SessionFeedEntry], activity: SessionFeedActivity?, live: SessionFeedLive?, liveError: String?) {
        let data = try await read([
            "workbench", "session-feed", "--session", String(sessionID), "--subagent", toolUseID, "--json"
        ])
        let payload = try Self.decode(data)
        return (payload.entries.filter { SessionFeedEntry.knownKinds.contains($0.kind) }, payload.activity,
                payload.liveOK == true ? payload.live : nil,
                payload.liveOK == true ? nil : (payload.liveError ?? WorkchatLivePresentation.unavailable))
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
}

/// Stand-in when the CLI binary is missing: the store never polls then, so
/// this is never called.
private struct UnavailableRunner: CLIRunnerProtocol {
    func run(args: [String]) async throws -> Data { Data() }
}

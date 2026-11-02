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
        subagentObservation = nil
        subagentObservationGeneration += 1
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
        func readChild() async {
            do {
                let result = try await subagentFeed(toolUseID)
                guard !Task.isCancelled, isCurrentObservation() else { return }
                if isSessionActive != nil {
                    let status = observation.receiveOwn(snapshot: result.live, entries: result.entries,
                                                        error: result.liveError, now: .now)
                    rememberObservation()
                    onStatus(status)
                    // A fresh read clock does not make the previous run's
                    // completed transcript an acknowledgement of resume.
                    if observation.awaitingResume, result.liveError == nil { onError(nil); return }
                }
                onEntries(result.entries); onActivity(result.activity)
                onLive(result.live, result.liveError); onError(nil)
            } catch {
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
                    guard !Task.isCancelled, isCurrentObservation() else { return nil }
                    onError(result.liveError)
                    return result.liveError == nil ? result.live : nil
                } catch {
                    guard !Task.isCancelled, isCurrentObservation() else { return nil }
                    onError(error.localizedDescription)
                }
            } else if readsMainFeed || isSessionActive != nil {
                await poller.refresh()
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
        await tick()
        while isCurrentObservation() && (isSessionActive?() ?? isRunning()) {
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

private struct SubagentObservationKey: Equatable {
    let child: String
    let parent: String?
}

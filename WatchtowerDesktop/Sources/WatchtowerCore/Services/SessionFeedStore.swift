import Foundation

/// Holds the chat feed of one session and merges each poll of
/// `watchtower workbench session-feed` into it: upsert by entry id keeping the
/// first position, so a growing agent message or a subagent whose status
/// changed updates in place.
@MainActor
package final class SessionFeedStore: ObservableObject {
    @Published package private(set) var entries: [SessionFeedEntry] = []
    @Published package private(set) var error: String?

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

    /// The main window's visibility changed: back on screen after a skipped
    /// read, the feed is read now.
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
        do {
            let payload = try Self.decode(try await runner.run(args: args))
            merge(payload.entries)
            merge(payload.subagents)
            cursor = payload.cursor
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The feed of one subagent run; not merged into the main feed.
    package func subagentFeed(_ toolUseID: String) async throws -> [SessionFeedEntry] {
        let data = try await runner.run(args: [
            "workbench", "session-feed", "--session", String(sessionID), "--subagent", toolUseID, "--json"
        ])
        return try Self.decode(data).entries.filter { SessionFeedEntry.knownKinds.contains($0.kind) }
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

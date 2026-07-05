import Foundation
import GRDB

// MARK: - Catch-Up v2 review-mode ViewModel
//
// Drives the two-panel review UX. Themes/sessions live in the DB (written by
// `watchtower catchup run`); the VM streams them in via a GRDB ValueObservation
// on the active session's themes and lets the operator review one theme at a
// time. Per-theme feedback / regen are delegated to the CLI; acknowledge and
// snooze are direct DB writes via `CatchUpQueries`.

@MainActor
@Observable
final class CatchUpViewModel {
    var session: CatchUpSession?
    var themes: [CatchUpTheme] = []
    var selected: CatchUpTheme?
    var isLoading = false
    var error: String?

    private let dbPool: DatabasePool
    private var observationTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    /// Poll cadence while `catchup run` is building. GRDB ValueObservation cannot
    /// see writes from the separate CLI process, so the streaming list needs a
    /// periodic reload to surface themes as the CLI persists them.
    private let pollInterval: Duration = .seconds(1)

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Session lifecycle

    /// Starts a fresh review pass: runs `watchtower catchup run` (which writes the
    /// session + themes to the DB), then begins observing so the list streams in
    /// as expand completes.
    func startSession() {
        guard let cliPath = Constants.findCLIPath() else {
            error = "Watchtower CLI not found"
            return
        }
        isLoading = true
        error = nil
        startObserving()
        startPolling() // CLI runs in a separate process; observation can't see its writes.

        Task.detached {
            let result = await Self.runCLI(path: cliPath, arguments: ["catchup", "run"])
            await MainActor.run {
                self.isLoading = false
                self.stopPolling()
                if result.exitCode != 0 {
                    self.error = result.stderr.isEmpty
                        ? "Catch-up failed (exit \(result.exitCode))"
                        : String(result.stderr.prefix(300))
                }
                // Authoritative final load once the CLI has finished writing.
                Task { await self.reload() }
            }
        }
    }

    /// One-shot reload of the active session's themes from disk, applied the same
    /// way the observation does. Used by the build-time poll and the final load,
    /// because the CLI's cross-process writes are invisible to ValueObservation.
    func reload() async {
        do {
            let themes = try await dbPool.read { db -> [CatchUpTheme] in
                guard let session = try CatchUpQueries.fetchActiveSession(db) else { return [] }
                return try CatchUpQueries.fetchThemes(db, sessionID: session.id)
            }
            await apply(themes: themes)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { break }
                await self.reload()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Observes the active session's themes. Updates `session`/`themes` live and
    /// auto-selects the first pending theme when nothing is selected yet.
    func startObserving() {
        guard observationTask == nil else { return }
        let dbPool = self.dbPool
        observationTask = Task { [weak self] in
            let observation = CatchUpQueries.observeActiveThemes()
            do {
                for try await themes in observation.values(in: dbPool) {
                    guard !Task.isCancelled else { break }
                    await self?.apply(themes: themes)
                }
            } catch {
                await MainActor.run { self?.error = error.localizedDescription }
            }
        }
    }

    private func apply(themes: [CatchUpTheme]) async {
        self.themes = themes
        do {
            self.session = try await dbPool.read { db in try CatchUpQueries.fetchActiveSession(db) }
        } catch {
            // Keep the previous session on a transient read failure — nulling a
            // live session here would blank the review UI mid-pass.
            print("CatchUp: fetchActiveSession failed (keeping previous session): \(error)")
        }

        // Re-point the selection at the freshest copy of the selected row, then
        // auto-advance to the first pending theme when there is no live selection.
        if let current = selected, let fresh = themes.first(where: { $0.id == current.id }) {
            selected = fresh
        }
        if selected == nil || !(selected?.isPending ?? false) {
            selected = themes.first { $0.isPending }
        }
    }

    // MARK: - Per-theme actions

    /// Acknowledges a theme: cascade mark-read over its refs, flip review_state to
    /// reviewed, bump the session count, then advance selection to the next pending.
    func acknowledge(_ theme: CatchUpTheme) async {
        do {
            try await dbPool.write { db in
                try CatchUpQueries.acknowledge(db, theme: theme)
            }
            advanceSelection(after: theme)
        } catch {
            self.error = "Failed to acknowledge: \(error.localizedDescription)"
        }
    }

    /// Snoozes a theme until the given date; it leaves the current pass.
    func snooze(_ theme: CatchUpTheme, until: Date) async {
        let stamp = Self.isoFormatter.string(from: until)
        do {
            try await dbPool.write { db in
                try CatchUpQueries.setReview(db, id: theme.id, state: "snoozed", snoozeUntil: stamp)
            }
            advanceSelection(after: theme)
        } catch {
            self.error = "Failed to snooze: \(error.localizedDescription)"
        }
    }

    /// Creates a target from the theme and links the theme back to it via
    /// `task_id`. source_type is "manual" (the operator created it during review):
    /// the targets.source_type CHECK has no 'catchup' value, and the theme→target
    /// link lives on catchup_themes.task_id, so a target→theme backlink onto an
    /// ephemeral session theme would add nothing.
    func createTask(_ theme: CatchUpTheme) async {
        let today = Self.dayFormatter.string(from: Date())
        let text = theme.suggestedAction.isEmpty ? theme.title : theme.suggestedAction
        do {
            try await dbPool.write { db in
                let taskID = try TargetQueries.create(
                    db,
                    text: text,
                    intent: theme.title,
                    periodStart: today,
                    periodEnd: today,
                    priority: theme.priority,
                    sourceType: "manual",
                    sourceID: ""
                )
                try CatchUpQueries.setTask(db, id: theme.id, taskID: taskID)
            }
        } catch {
            self.error = "Failed to create task: \(error.localizedDescription)"
        }
    }

    /// Records 👍/👎 (+ optional comment) via the CLI, which runs the learning
    /// interpreter and derives targeted rules when a comment is present.
    func submitFeedback(_ theme: CatchUpTheme, rating: Int, comment: String) {
        guard let cliPath = Constants.findCLIPath() else {
            error = "Watchtower CLI not found"
            return
        }
        var args = ["catchup", "feedback", String(theme.id), "--rating", rating >= 0 ? "up" : "down"]
        if !comment.isEmpty {
            args.append(contentsOf: ["--comment", comment])
        }
        Task.detached {
            let result = await Self.runCLI(path: cliPath, arguments: args)
            if result.exitCode != 0 {
                await MainActor.run {
                    self.error = result.stderr.isEmpty
                        ? "Feedback failed (exit \(result.exitCode))"
                        : String(result.stderr.prefix(300))
                }
            }
        }
    }

    /// Regenerates a single theme with an operator correction comment via the CLI;
    /// the row is overwritten in place and picked up by the observation.
    func regenerate(_ theme: CatchUpTheme, comment: String) {
        guard let cliPath = Constants.findCLIPath() else {
            error = "Watchtower CLI not found"
            return
        }
        var args = ["catchup", "regen", String(theme.id)]
        if !comment.isEmpty {
            args.append(contentsOf: ["--comment", comment])
        }
        Task.detached {
            let result = await Self.runCLI(path: cliPath, arguments: args)
            if result.exitCode != 0 {
                await MainActor.run {
                    self.error = result.stderr.isEmpty
                        ? "Regenerate failed (exit \(result.exitCode))"
                        : String(result.stderr.prefix(300))
                }
            }
        }
    }

    // MARK: - Inline source detail

    // Read-only fetches backing the review pane's expandable source rows. They
    // read the VM's own live `dbPool` (the same handle the theme stream uses), so
    // a digest/track referenced by a theme always resolves — no separate
    // DatabaseManager or observed list to be out of sync with.

    /// Fetch a referenced digest by id for inline expansion. nil if the row is
    /// gone (e.g. pruned after the theme snapshot).
    func digest(byID id: Int) -> Digest? {
        try? dbPool.read { try DigestQueries.fetchByID($0, id: id) }
    }

    /// Fetch a referenced track by id for inline expansion. nil if the row is gone.
    func track(byID id: Int) -> Track? {
        try? dbPool.read { try TrackQueries.fetchByID($0, id: id) }
    }

    // MARK: - Selection

    /// Advances selection to the next pending theme after the given one (by
    /// order), wrapping to the first pending if none follow.
    private func advanceSelection(after theme: CatchUpTheme) {
        let pending = themes.filter { $0.isPending && $0.id != theme.id }
        selected = pending.first { $0.orderIdx > theme.orderIdx } ?? pending.first
    }

    // MARK: - Formatters

    private static let isoFormatter = ISO8601DateFormatter()

    private static let dayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt
    }()

    // MARK: - CLI (detached, drains stdout+stderr concurrently)

    nonisolated private static func runCLI(
        path: String, arguments: [String]
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: runCLIBlocking(path: path, arguments: arguments))
            }
        }
    }

    nonisolated private static func runCLIBlocking(
        path: String, arguments: [String]
    ) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = Constants.resolvedEnvironment()
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        // Drain stdout and stderr CONCURRENTLY before waitUntilExit: if stderr fills its
        // ~64KB pipe buffer while we block on stdout (or vice versa), the child stalls and
        // we deadlock. Reading both in parallel keeps both buffers flowing.
        var stderrData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        let stdout = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }
}

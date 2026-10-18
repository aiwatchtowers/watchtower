import Foundation
import Observation

// MARK: - Wire models (`watchtower db compact --json`)

/// `db compact --check --json`: whether compaction is due and the disk rule's
/// numbers (`needs_disk_bytes` = 2 × `db_bytes`).
package struct CompactionCheck: Decodable, Equatable, Sendable {
    package let due: Bool
    /// `migration:<version>`, `freelist`, `schema_pending`, `gave_up` or empty.
    package let reason: String
    package let dbBytes: Int64
    package let walBytes: Int64
    package let freeDiskBytes: Int64
    package let needsDiskBytes: Int64
    package let diskOk: Bool

    enum CodingKeys: String, CodingKey {
        case due, reason
        case dbBytes = "db_bytes"
        case walBytes = "wal_bytes"
        case freeDiskBytes = "free_disk_bytes"
        case needsDiskBytes = "needs_disk_bytes"
        case diskOk = "disk_ok"
    }

    package init(
        due: Bool,
        reason: String,
        dbBytes: Int64,
        walBytes: Int64,
        freeDiskBytes: Int64,
        needsDiskBytes: Int64,
        diskOk: Bool
    ) {
        self.due = due
        self.reason = reason
        self.dbBytes = dbBytes
        self.walBytes = walBytes
        self.freeDiskBytes = freeDiskBytes
        self.needsDiskBytes = needsDiskBytes
        self.diskOk = diskOk
    }
}

/// `db compact --if-due --json`: the result line of a compaction run. Every
/// field but `compacted` depends on the outcome (`skipped` names why nothing
/// ran; `error`/`failures`/`gave_up` come with exit 1).
package struct CompactionRunOutput: Decodable, Equatable, Sendable {
    package let compacted: Bool
    package let skipped: String?
    package let reason: String?
    package let bytesBefore: Int64?
    package let bytesAfter: Int64?
    package let durationMs: Int64?
    package let error: String?
    package let failures: Int?
    /// The failure cap was reached: the CLI skips compaction until the next
    /// app version. Absent on every other result.
    package let gaveUp: Bool
    /// The final checkpoint could not pass a reader: part of the space is
    /// reclaimed at the next checkpoint. Absent reads false.
    package let checkpointBusy: Bool

    enum CodingKeys: String, CodingKey {
        case compacted, skipped, reason, error, failures
        case bytesBefore = "bytes_before"
        case bytesAfter = "bytes_after"
        case durationMs = "duration_ms"
        case gaveUp = "gave_up"
        case checkpointBusy = "checkpoint_busy"
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        compacted = try container.decode(Bool.self, forKey: .compacted)
        skipped = try container.decodeIfPresent(String.self, forKey: .skipped)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        bytesBefore = try container.decodeIfPresent(Int64.self, forKey: .bytesBefore)
        bytesAfter = try container.decodeIfPresent(Int64.self, forKey: .bytesAfter)
        durationMs = try container.decodeIfPresent(Int64.self, forKey: .durationMs)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        failures = try container.decodeIfPresent(Int.self, forKey: .failures)
        gaveUp = try container.decodeIfPresent(Bool.self, forKey: .gaveUp) ?? false
        checkpointBusy = try container.decodeIfPresent(Bool.self, forKey: .checkpointBusy) ?? false
    }
}

/// A finished `db compact` child. `status` is the exit code, or the signal
/// number when `reason` is `.uncaughtSignal`.
package struct CompactionExit: Sendable {
    package let status: Int32
    package let reason: Process.TerminationReason
    package let stdout: Data
    package let stderr: String

    package init(status: Int32, reason: Process.TerminationReason = .exit, stdout: Data, stderr: String) {
        self.status = status
        self.reason = reason
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// A running `db compact --if-due` child.
package protocol CompactionChild: AnyObject, Sendable {
    /// SIGTERM: the CLI interrupts `VACUUM` and exits 4.
    func terminate()
    /// SIGKILL: safe, `VACUUM` is atomic.
    func kill()
    func waitForExit() async -> CompactionExit
}

/// The process seam of `DatabaseCompactionStep`.
package protocol CompactionCLI: Sendable {
    /// `db compact --check --json`, 30 s timeout; throws on spawn failure,
    /// timeout, non-zero exit or undecodable output.
    func check() async throws -> CompactionCheck
    /// Spawns `db compact --if-due --json` with no timeout.
    func startCompact() throws -> any CompactionChild
}

package struct CompactionOutputError: Error, LocalizedError {
    package var errorDescription: String? { "the CLI printed no JSON line" }
}

/// Decodes the last non-empty line of stdout: a line the CLI prints before
/// its JSON (a schema-format upgrade notice, a deprecation) is not a failure.
package func decodeLastJSONLine<T: Decodable>(_ type: T.Type, from stdout: Data) throws -> T {
    let text = String(data: stdout, encoding: .utf8) ?? ""
    guard let line = text.split(whereSeparator: \.isNewline)
        .map({ $0.trimmingCharacters(in: .whitespaces) })
        .last(where: { !$0.isEmpty })
    else { throw CompactionOutputError() }
    return try JSONDecoder().decode(type, from: Data(line.utf8))
}

// MARK: - DatabaseCompactionStep

/// The launch step between `db migrate` and opening the pool (#850, spec D5):
/// checks whether the database is due for `VACUUM`, and if it is, stops the
/// daemon and runs `db compact --if-due` while the splash shows progress.
/// Best effort throughout: every failure is logged and the launch continues.
///
/// Elapsed time counts the injected `sleep(1 s)` calls, never the wall clock:
/// `elapsedSeconds` goes up by one after each completed sleep, so an action
/// taken between two ticks lies anywhere inside that second.
@MainActor @Observable
package final class DatabaseCompactionStep {
    package enum Phase: Equatable {
        case idle, checking, compacting(dbBytes: Int64), finished
    }

    package private(set) var phase: Phase = .idle
    package private(set) var elapsedSeconds = 0
    /// A non-blocking notice for the owner, shown once per launch.
    package private(set) var notice: String?
    /// The step stopped the daemon: a launch that then cannot open the
    /// database brings it back (`AppState.restoreDaemonStoppedForCompaction`).
    @ObservationIgnored package private(set) var stoppedDaemon = false
    /// Runs the daemon stop. The app routes it through its start queue, so a
    /// start already running finishes before the stop; the default runs it
    /// directly.
    @ObservationIgnored package var serializeDaemonStop: @MainActor (
        _ stop: @escaping @Sendable () async -> Void
    ) async -> Void = { await $0() }

    package var isRunning: Bool {
        switch phase {
        case .checking, .compacting: true
        case .idle, .finished: false
        }
    }

    package var canSkip: Bool {
        guard case .compacting = phase else { return false }
        return elapsedSeconds >= Self.skipAfterSeconds && skipRequestedAt == nil
    }

    package static let skipAfterSeconds = 15
    package static let killAfterSkipSeconds = 10
    /// How long a quit waits for the child to exit on SIGTERM before SIGKILL.
    package static let quitGrace: Duration = .seconds(3)
    package static let subtitle = "This happens rarely, usually after an update."
    package static let gaveUpNotice =
        "Watchtower could not optimize its database after 3 attempts. It will try again after the next update."

    @ObservationIgnored private let cli: any CompactionCLI
    @ObservationIgnored private let stopDaemon: @Sendable () async -> Void
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private let log: @Sendable (String) -> Void
    @ObservationIgnored private var child: (any CompactionChild)?
    /// The running `--check`, cancelled by a quit.
    @ObservationIgnored private var checkTask: Task<CompactionCheck, any Error>?
    /// The app quit while the step ran: nothing more is started.
    @ObservationIgnored private var quitRequested = false
    /// `elapsedSeconds` when Skip sent SIGTERM; nil until then.
    @ObservationIgnored private var skipRequestedAt: Int?
    @ObservationIgnored private var killed = false
    /// Quits waiting for the running child to exit, by id.
    @ObservationIgnored private var exitWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    package init(
        cli: any CompactionCLI,
        stopDaemon: @escaping @Sendable () async -> Void,
        sleep: @escaping @Sendable (Duration) async -> Void,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.cli = cli
        self.stopDaemon = stopDaemon
        self.sleep = sleep
        self.log = log
    }

    /// Returns when the launch may continue; never throws. Runs once: a
    /// second call is a no-op.
    package func run(resolveDBPath: () throws -> String) async {
        guard phase == .idle else { return }
        defer { phase = .finished }
        // No workspace database yet (fresh install): nothing to compact. The
        // caller logs any other resolve error.
        guard (try? resolveDBPath()) != nil else { return }

        phase = .checking
        let check: CompactionCheck
        let checkTask = Task { [cli] in try await cli.check() }
        self.checkTask = checkTask
        defer { self.checkTask = nil }
        do {
            check = try await checkTask.value
        } catch is CancellationError {
            log("DB compaction check cancelled by quit")
            return
        } catch {
            log("DB compaction check failed, skipping: \(error.localizedDescription)")
            return
        }
        guard !quitRequested else { return }
        guard check.due else { return }
        guard check.diskOk else {
            log("DB compaction skipped: \(check.needsDiskBytes) bytes of free disk needed, \(check.freeDiskBytes) available")
            notice = Self.diskNotice(needs: check.needsDiskBytes, available: check.freeDiskBytes)
            return
        }

        await serializeDaemonStop(stopDaemon)
        stoppedDaemon = true
        guard !quitRequested else { return }
        let child: any CompactionChild
        do {
            child = try cli.startCompact()
        } catch {
            log("DB compaction could not start: \(error.localizedDescription)")
            return
        }
        self.child = child
        phase = .compacting(dbBytes: check.dbBytes)
        let ticker = Task { await self.tick() }
        let exit = await child.waitForExit()
        ticker.cancel()
        self.child = nil
        resumeExitWaiters(exited: true)
        handle(exit, check: check)
    }

    /// "Skip for now": SIGTERM now, SIGKILL on the first tick more than
    /// `killAfterSkipSeconds` ticks later if the child is still alive. Skip
    /// lands between two ticks, so `killAfterSkipSeconds` ticks after it may
    /// be just under that many seconds; one more tick makes the wait
    /// strictly longer than the threshold.
    package func skip() {
        guard canSkip, let child else { return }
        skipRequestedAt = elapsedSeconds
        log("DB compaction: skipped by the owner, stopping the child")
        child.terminate()
    }

    /// The app is quitting: cancels a running `--check` (its child is
    /// terminated) and SIGTERMs a running compaction child, so neither
    /// outlives the app, and nothing more is started. Returns once the child
    /// has exited, or SIGKILLs it after `quitGrace`. No-op when the step is
    /// not running.
    package func terminateForQuit() async {
        guard isRunning else { return }
        quitRequested = true
        checkTask?.cancel()
        guard let child else { return }
        child.terminate()
        guard await !childExits(within: Self.quitGrace) else { return }
        log("DB compaction: the child did not exit within \(Self.quitGrace) of SIGTERM at quit, killing it")
        child.kill()
    }

    /// Whether the running child exits before `grace` elapses (the injected
    /// sleep).
    private func childExits(within grace: Duration) async -> Bool {
        guard child != nil else { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            exitWaiters[id] = continuation
            Task { @MainActor [weak self, sleep] in
                await sleep(grace)
                self?.exitWaiters.removeValue(forKey: id)?.resume(returning: false)
            }
        }
    }

    private func resumeExitWaiters(exited: Bool) {
        let waiters = exitWaiters.values
        exitWaiters = [:]
        waiters.forEach { $0.resume(returning: exited) }
    }

    package func dismissNotice() {
        notice = nil
    }

    // MARK: Ticking

    private func tick() async {
        while !Task.isCancelled {
            await sleep(.seconds(1))
            guard !Task.isCancelled, case .compacting = phase else { return }
            elapsedSeconds += 1
            if let skipAt = skipRequestedAt, !killed,
               elapsedSeconds - skipAt > Self.killAfterSkipSeconds {
                killed = true
                log("DB compaction: the child ignored SIGTERM for more than \(Self.killAfterSkipSeconds) s, killing it")
                child?.kill()
            }
        }
    }

    // MARK: Exit handling

    private func handle(_ exit: CompactionExit, check: CompactionCheck) {
        let output: CompactionRunOutput?
        do {
            output = try decodeLastJSONLine(CompactionRunOutput.self, from: exit.stdout)
        } catch {
            output = nil
            log("DB compaction: no result line (exit \(exit.status)): \(error.localizedDescription)")
        }
        let stderr = CLILog.detail(exit.stderr)
        if exit.reason == .uncaughtSignal {
            log("DB compaction: the child was killed by signal \(exit.status): \(stderr)")
            return
        }
        // Exits 2–5 count only when the result line names the same skip; any
        // other combination is logged with stderr.
        switch (exit.status, output?.skipped) {
        case (0, _):
            guard let output else {
                log("DB compaction: exit 0 without a result line: \(stderr)")
                return
            }
            if output.compacted {
                let sizes = "\(output.bytesBefore ?? 0) → \(output.bytesAfter ?? 0) bytes"
                log("DB compacted (\(output.reason ?? "")): \(sizes) in \(output.durationMs ?? 0) ms")
                if output.checkpointBusy {
                    log("DB compaction: the final checkpoint was busy; the space is reclaimed at the next checkpoint")
                }
            } else {
                log("DB compaction: nothing done (\(output.skipped ?? "no reason given"))")
            }
        case (1, _):
            log("DB compaction failed: \(output?.error ?? stderr)")
            if output?.gaveUp ?? false { notice = Self.gaveUpNotice }
        case (2, "disk"):
            log("DB compaction skipped for disk space")
            notice = Self.diskNotice(needs: check.needsDiskBytes, available: check.freeDiskBytes)
        case (3, "daemon_running"):
            log("DB compaction skipped: the daemon is still running")
        case (4, "interrupted"):
            log("DB compaction interrupted; it is due again next launch")
        case (5, "schema_pending"):
            log("DB compaction skipped: schema migrations are pending")
        default:
            log("DB compaction ended with exit status \(exit.status) (\(output?.skipped ?? "no result line")): \(stderr)")
        }
    }

    // MARK: Strings

    /// `m:ss`.
    package nonisolated static func elapsedText(seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    package nonisolated static func progressLine(
        dbBytes: Int64,
        elapsedSeconds: Int,
        size: (Int64) -> String = byteText
    ) -> String {
        "Optimizing database — \(size(dbBytes)), \(elapsedText(seconds: elapsedSeconds))"
    }

    package nonisolated static func diskNotice(
        needs: Int64,
        available: Int64,
        size: (Int64) -> String = byteText
    ) -> String {
        "Watchtower could not optimize its database: it needs \(size(needs)) free, \(size(available)) available."
    }

    /// Sizes in the owner's locale, file style (1000-based, as Finder shows).
    package nonisolated static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

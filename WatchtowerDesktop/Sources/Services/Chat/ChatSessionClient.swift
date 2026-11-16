import Foundation
import GRDB
import WatchtowerCore

/// What a session process is spawned with. Every argv-affecting field
/// belongs in `isCompatible`. A session never resumes a stored provider
/// session (#604 G11): a new process replays the history from the database.
struct ChatSessionConfig: Equatable, Sendable {
    var conversationID: Int64
    var provider: String
    var model: String?
    var automatic: Bool
    var surface: String
    /// The chat project whose instructions/files join the session's prompt
    /// (`--project-id`); nil for a chat outside any project.
    var projectID: Int64?

    init(
        conversationID: Int64,
        provider: String,
        model: String?,
        surface: String = "main",
        automatic: Bool = false,
        projectID: Int64? = nil
    ) {
        self.conversationID = conversationID
        self.provider = provider
        self.model = model
        self.surface = surface
        self.automatic = automatic
        self.projectID = projectID
    }

    /// Moving a chat into or out of a project changes its prompt, so a warm
    /// session spawned for the old project is not reused.
    func isCompatible(with other: Self) -> Bool {
        conversationID == other.conversationID && automatic == other.automatic
            && (automatic || (provider == other.provider && model == other.model)) && surface == other.surface && projectID == other.projectID
    }
}

/// How a turn sent to a persisting session started.
enum ChatStartOutcome: Equatable, Sendable {
    /// Its rows are on disk; the driver streams it.
    case started(ChatStarted)
    /// Another owner holds the conversation: nothing was written or sent.
    case refused(ChatRefusal)
    /// Nothing was written: the session could not take it (dead, silent
    /// for `startedTimeout`, or the start write failed — Go's sentence).
    case failed(ChatSessionError)
}

/// A turn waiting for its `started`: the one awaiter of `startTurn`. It moves
/// with a held turn to a replacement session (`surrenderHeldTurn`).
@MainActor
final class PendingChatStart {
    let command: ChatTurnCommand
    private var continuation: CheckedContinuation<ChatStartOutcome, Never>?
    private var outcome: ChatStartOutcome?

    init(command: ChatTurnCommand) {
        self.command = command
    }

    var isResolved: Bool { outcome != nil }

    func wait() async -> ChatStartOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ value: ChatStartOutcome) {
        guard outcome == nil else { return }
        outcome = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// One warm `watchtower ai session --persist` process for one conversation.
/// The process saves the turn's rows itself (mobile Inbox spec §8); this
/// client sends the turn, waits for its `started`, and owns the turn driver,
/// so a running turn keeps streaming no matter which view (if any) shows it.
///
/// A client may be created *pending* (`launchImmediately: false`): the pool
/// launches it once a slot is free and any process it replaces has exited.
/// A turn started while pending is held and sent at launch.
///
/// Teardown (quit, eviction, stop watchdog) never signals twice: `close`,
/// then at most ONE SIGTERM (a second one makes the Go side exit without its
/// temp-file cleanup), then SIGKILL only if the process outlived `killAfter`.
@MainActor
@Observable
final class ChatSessionClient {
    /// How long a SIGTERMed process gets before SIGKILL.
    nonisolated static let defaultKillAfter: Duration = .seconds(3)
    /// A turn written to the process with no `started` by then gives up:
    /// the process is retired and the draft comes back (spec §9).
    nonisolated static let defaultStartedTimeout: Duration = .seconds(10)

    let conversationID: Int64
    let config: ChatSessionConfig
    let driver: ChatTurnDriver
    /// False once the process has exited, failed to spawn, or was closed. A
    /// pending (not yet launched) session is alive: its turns wait for launch.
    private(set) var isAlive = true
    /// Waiting for the pool to launch it (a free slot / a predecessor's exit).
    private(set) var isPending = true
    private(set) var startupError: ChatSessionError?
    /// Set when the process ended without being asked to: the exit status
    /// and the stderr tail, as a `session_lost` error.
    private(set) var exitError: ChatSessionError?
    private(set) var lastActivity: Date

    @ObservationIgnored var onTurnFinished: ((Int64) -> Void)?
    /// A running turn's step started waiting on an approval card (`tool_wait`).
    @ObservationIgnored var onActionAwaited: (() -> Void)?
    /// The process ended (or could not be spawned) — the pool re-admits.
    @ObservationIgnored var onEnded: (() -> Void)?
    /// The process ended with a started turn it never let go of (no
    /// `turn_saved`): its rows need `chat.recover` (spec §9).
    @ObservationIgnored var onTurnLost: ((_ conversationID: Int64, _ turnID: String) -> Void)?
    @ObservationIgnored private var process: (any ChatSessionProcess)?
    @ObservationIgnored private let spawn: () throws -> any ChatSessionProcess
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let startedTimeout: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var readTask: Task<Void, Never>?
    /// The turn held while pending, or written and waiting for `started`.
    @ObservationIgnored private var pendingStart: PendingChatStart?
    @ObservationIgnored private var startTimer: Task<Void, Never>?
    /// The started turn the session has not let go of yet (`turn_saved`).
    @ObservationIgnored private var unsavedTurnID: String?
    @ObservationIgnored private var exited = false
    @ObservationIgnored private var shutdownRequested = false
    @ObservationIgnored private var sigtermSent = false
    /// Set by `retireAfterTurn`: the running turn is this session's last.
    @ObservationIgnored private var retiresAfterTurn = false

    init(
        config: ChatSessionConfig,
        spawn: @escaping () throws -> any ChatSessionProcess,
        clock: @escaping () -> Date,
        launchImmediately: Bool = true,
        startedTimeout: Duration = ChatSessionClient.defaultStartedTimeout,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.conversationID = config.conversationID
        self.config = config
        self.spawn = spawn
        self.clock = clock
        self.startedTimeout = startedTimeout
        self.sleep = sleep
        self.lastActivity = clock()
        self.driver = ChatTurnDriver(conversationID: config.conversationID, clock: clock)
        driver.onTurnFinished = { [weak self] turn in self?.turnFinished(turn) }
        driver.onActionAwaited = { [weak self] _ in self?.onActionAwaited?() }
        if launchImmediately { launch() }
    }

    var liveTurn: LiveTurn? { driver.liveTurn }
    /// A turn is waiting for its `started`, running, or its last write is
    /// under way: no next turn starts and nothing evicts the session.
    var isBusy: Bool { driver.isBusy || pendingStart != nil }
    /// A process was launched and has not exited yet.
    var hasLiveProcess: Bool { process != nil && !exited }

    /// The argv — flags only, never content (CHAT-04). `--provider` is the
    /// root persistent flag; the rest are `ai session`'s own. `--persist`:
    /// the session saves its turns, claiming their lease as this app launch
    /// (`desktop`, `leaseOwnerID`), exactly as the Swift claim did.
    static func arguments(for config: ChatSessionConfig, dbPath: String?, leaseOwnerID: String) -> [String] {
        var args = ["ai", "session", "--conversation", String(config.conversationID)]
        if !config.automatic {
            args += ["--provider", config.provider]
        }
        args += ["--surface", config.surface]
        if !config.automatic, let model = config.model, !model.isEmpty { args += ["--model", model] }
        if let projectID = config.projectID { args += ["--project-id", String(projectID)] }
        if let dbPath, !dbPath.isEmpty { args += ["--db-path", dbPath] }
        args += ["--persist", "--lease-owner", ChatLease.Owner.desktop.rawValue, "--lease-owner-id", leaseOwnerID]
        return args
    }

    /// The owner-facing text for a process that died on its own: the status
    /// plus the last stderr lines (bounded).
    static func exitMessage(status: Int32, stderrTail: String) -> String {
        let base = "The chat session ended unexpectedly (exit status \(status))."
        let lines = stderrTail.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return base }
        var detail = lines.suffix(3).joined(separator: " ")
        if detail.count > 500 { detail = "…" + detail.suffix(500) }
        return base + " " + detail
    }

    /// A held turn stopped (or its session closed) before it was sent.
    static let notSentMessage = "Stopped before your message was sent."

    /// The message a turn gets when the session stays silent past `startedTimeout`.
    static let silentMessage = "The chat session didn't answer, so your message wasn't sent."

    func touch() {
        lastActivity = clock()
    }

    /// Spawns the process (once). A spawn failure never throws: the client
    /// is dead with `startupError`, and a held turn fails visibly.
    func launch() {
        guard isPending, !shutdownRequested else { return }
        isPending = false
        do {
            process = try spawn()
        } catch {
            exited = true
            isAlive = false
            let failure = ChatSessionError(turnID: nil, code: .providerUnavailable,
                                           message: error.localizedDescription, retryable: true)
            startupError = failure
            failStart(failure)
            onEnded?()
            return
        }
        startReading()
        if let held = pendingStart { send(held) }
    }

    /// Runs one turn: the session writes its rows, then answers `started`
    /// (or `refused`); this returns that answer. On a pending session the
    /// turn is held until launch. A dead session, a failed pipe write or a
    /// silent process answer `failed` — nothing was written then.
    func startTurn(_ command: ChatTurnCommand) async -> ChatStartOutcome {
        guard !isBusy else {
            return .failed(ChatSessionError(turnID: command.turnID, code: .internalError,
                                            message: "A turn is already running in this chat.", retryable: false))
        }
        let pending = PendingChatStart(command: command)
        begin(pending)
        return await pending.wait()
    }

    /// Takes over a turn another (never launched) session held.
    func begin(_ pending: PendingChatStart) {
        touch()
        pendingStart = pending
        if isPending, !shutdownRequested { return }
        guard hasLiveProcess, isAlive else {
            let reason = exitError?.message ?? startupError?.message ?? "The chat session is not running."
            failStart(ChatSessionError(turnID: pending.command.turnID, code: .sessionLost, message: reason,
                                       retryable: true))
            return
        }
        send(pending)
    }

    /// Stop: ask the provider to interrupt; if no `turn_done` arrives within
    /// `grace`, keep the partial text and kill the process (Go already kills
    /// its child after 5 s, so 7 s covers a Go side that hung too).
    func cancel(grace: Duration = .seconds(7), killAfter: Duration = ChatSessionClient.defaultKillAfter) {
        if isPending, pendingStart != nil {
            // Held, never sent: nothing to interrupt and nothing was written —
            // the text goes back, and the pool drops the queued client instead
            // of spawning a process that would idle until the TTL.
            abandon()
            onEnded?()
            return
        }
        guard let turn = driver.liveTurn, turn.isRunning else { return }
        do {
            guard let process, !exited else { throw CancellationError() }
            try process.send(.cancel)
        } catch {
            // The pipe is gone (or never existed): nothing will answer.
            driver.finishRunningAsPartial()
            return
        }
        let turnID = turn.turnID
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            // Still running: a turn that ended and only waits for its final
            // write answered the cancel; its session is healthy.
            guard let self, let live = self.driver.liveTurn, live.turnID == turnID, live.isRunning else { return }
            // A session that ignored `cancel` is never reused.
            self.shutdownRequested = true
            self.isAlive = false
            await self.terminateAndReap(killAfter: killAfter)
            self.driver.finishRunningAsPartial()
        }
    }

    /// The prompt this session was spawned with is stale (its chat project
    /// changed, or the claude.ai switches did) but a turn is running: let it
    /// finish, then stop counting as alive so the pool replaces it (CHAT-03 —
    /// a running turn is never cut).
    func retireAfterTurn() {
        retiresAfterTurn = true
    }

    /// Hands back the turn this not-yet-launched session holds, so it can be
    /// sent on a replacement session instead (nothing of it was written).
    /// Nil when nothing is held.
    func surrenderHeldTurn() -> PendingChatStart? {
        guard isPending, let held = pendingStart else { return nil }
        pendingStart = nil
        return held
    }

    /// Ends the client without a process to shut down (never launched, or
    /// already exited): a held turn comes back unsent, a running one keeps
    /// what streamed.
    func abandon() {
        shutdownRequested = true
        isPending = false
        failStart(ChatSessionError(turnID: pendingStart?.command.turnID, code: .interrupted,
                                   message: Self.notSentMessage, retryable: true))
        driver.finishRunningAsPartial()
        isAlive = false
    }

    /// Quit / eviction: ask politely (`close` — the session saves what
    /// streamed as `partial`), wait up to `grace`, then one SIGTERM, then
    /// SIGKILL after `killAfter`. Returns once the process is gone.
    func close(grace: Duration, killAfter: Duration = ChatSessionClient.defaultKillAfter) async {
        shutdownRequested = true
        isPending = false
        if let process, !exited {
            // A failed write means the pipe is already closed — the process is
            // gone or going; the wait below and the signals still apply.
            try? process.send(.close)
            await waitForExit(upTo: grace)
            await terminateAndReap(killAfter: killAfter)
        }
        abandon()
    }

    // MARK: - Private

    private func send(_ pending: PendingChatStart) {
        guard let process else { return }
        do {
            try process.send(.turn(pending.command))
        } catch {
            failStart(ChatSessionError(turnID: pending.command.turnID, code: .sessionLost,
                                       message: error.localizedDescription, retryable: true))
            return
        }
        let (sleep, timeout, turnID) = (sleep, startedTimeout, pending.command.turnID)
        startTimer?.cancel()
        startTimer = Task { [weak self] in
            do { try await sleep(timeout) } catch { return }
            self?.startTimedOut(turnID)
        }
    }

    /// No `started` in time: the process is silent — it may never start
    /// the turn, or start it late; it is retired so nothing of it runs
    /// after the draft came back.
    private func startTimedOut(_ turnID: String) {
        guard pendingStart?.command.turnID == turnID, !exited else { return }
        failStart(ChatSessionError(turnID: turnID, code: .sessionLost, message: Self.silentMessage, retryable: true))
        shutdownRequested = true
        isAlive = false
        Task { await terminateAndReap(killAfter: Self.defaultKillAfter) }
    }

    private func failStart(_ failure: ChatSessionError) {
        guard let pending = pendingStart else { return }
        pendingStart = nil
        startTimer?.cancel()
        pending.resolve(.failed(failure))
    }

    private func startReading() {
        guard let process else { return }
        readTask = Task { [weak self] in
            for await event in process.events {
                guard let self else { return }
                self.handle(event)
            }
            self?.processEnded()
        }
    }

    private func handle(_ event: ChatEvent) {
        touch()
        switch event {
        case let .exited(status, stderrTail):
            // Only an exit nobody asked for is an error: a non-zero status, or
            // any exit that leaves a turn without its terminal event.
            if !shutdownRequested, status != 0 || driver.liveTurn?.isRunning == true || pendingStart != nil {
                let failure = ChatSessionError(turnID: nil, code: .sessionLost,
                                               message: Self.exitMessage(status: status, stderrTail: stderrTail),
                                               retryable: true)
                exitError = failure
                driver.noteSessionError(failure)
            }
            processEnded()
            return
        case let .started(started):
            guard let pending = pendingStart, pending.command.turnID == started.turnID else { return }
            pendingStart = nil
            startTimer?.cancel()
            unsavedTurnID = started.turnID
            driver.begin(messageID: started.assistantMessageID, turnID: started.turnID)
            pending.resolve(.started(started))
            return
        case let .refused(refusal):
            guard let pending = pendingStart, refusal.turnID == nil || refusal.turnID == pending.command.turnID else { return }
            pendingStart = nil
            startTimer?.cancel()
            pending.resolve(.refused(refusal))
            return
        case let .error(error):
            // The start write failed: nothing was written or sent.
            if let pending = pendingStart, error.turnID == pending.command.turnID {
                pendingStart = nil
                startTimer?.cancel()
                pending.resolve(.failed(error))
                return
            }
        case let .turnSaved(turnID):
            if unsavedTurnID == turnID { unsavedTurnID = nil }
        default:
            break
        }
        driver.apply(event)
    }

    private func processEnded() {
        guard !exited else { return }
        exited = true
        isAlive = false
        failStart(exitError ?? ChatSessionError(turnID: nil, code: .sessionLost,
                                                message: "The chat session ended before your message was sent.",
                                                retryable: true))
        if let lost = unsavedTurnID {
            unsavedTurnID = nil
            onTurnLost?(conversationID, lost)
        }
        driver.finishRunningAsPartial()
        onEnded?()
    }

    private func waitForExit(upTo bound: Duration) async {
        let deadline = ContinuousClock.now + bound
        while !exited, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// One SIGTERM per process lifetime, then SIGKILL if it is still alive
    /// after `killAfter`. Safe to call from both the watchdog and `close`.
    private func terminateAndReap(killAfter: Duration) async {
        guard let process, !exited else { return }
        if !sigtermSent {
            sigtermSent = true
            process.terminate()
        }
        await waitForExit(upTo: killAfter)
        if !exited { process.kill() }
    }

    private func turnFinished(_ turn: LiveTurn) {
        if retiresAfterTurn { isAlive = false }
        touch()
        onTurnFinished?(conversationID)
    }
}

/// The real session process. Writes JSONL to stdin, parses NDJSON from
/// stdout, drains stderr concurrently (sequential pipe reads deadlock) into
/// a bounded tail, and never blocks a cooperative thread waiting for exit.
final class FoundationChatSessionProcess: ChatSessionProcess, @unchecked Sendable {
    let events: AsyncStream<ChatEvent>
    private let process: Process
    private let stdin: FileHandle
    /// Guards `stdin` writes/close and `signalled`.
    private let lock = NSLock()
    private var signalled = false
    private var stdinClosed = false

    static func launch(arguments: [String]) throws -> any ChatSessionProcess {
        guard let cliPath = Constants.findCLIPath() else { throw WatchtowerAIError.cliNotFound }
        return try FoundationChatSessionProcess(executable: cliPath, arguments: arguments)
    }

    /// `environment` replaces the app's resolved one (tests run the CLI
    /// with their own HOME); nil keeps it.
    init(executable: String, arguments: [String], environment: [String: String]? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        // Built on the main actor (`ChatSessionPool.ProcessFactory`): never wait
        // for the login-shell probe here. The app's pool holds admission until
        // the resolve is done (`holdAdmissionUntil` in `ensureChatSessionPool`).
        process.environment = environment ?? Constants.resolvedEnvironmentIfReady()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // A write after the child died must fail with EPIPE, not kill the app with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let exit = ExitLatch()
        process.terminationHandler = { exit.fire($0.terminationStatus) }
        let stderrTail = TailBuffer(limit: 8192)
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stderrTail.markEOF()
            } else {
                stderrTail.append(data)
            }
        }

        let (stream, continuation) = AsyncStream.makeStream(of: ChatEvent.self)
        self.events = stream
        self.process = process
        self.stdin = input.fileHandleForWriting
        do {
            try process.run()
        } catch {
            errors.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            throw error
        }

        let stdout = output.fileHandleForReading
        Task.detached { [weak self] in
            await Self.readEvents(from: stdout, into: continuation)
            let status = await exit.wait()
            // Let the stderr drain catch up (bounded: a surviving grandchild may hold the pipe open).
            await stderrTail.waitForEOF(upTo: .milliseconds(500))
            self?.closeStdin()
            continuation.yield(.exited(status: status, stderrTail: stderrTail.string))
            continuation.finish()
        }
    }

    /// Reads through `ndjsonLines`, never `stdout.bytes`: that one serializes
    /// every reader in the app, so an idle warm session stalled the others.
    private static func readEvents(from stdout: FileHandle, into continuation: AsyncStream<ChatEvent>.Continuation) async {
        for await line in stdout.ndjsonLines {
            if let event = ChatEvent.parse(line) { continuation.yield(event) }
        }
    }

    func send(_ command: ChatCommand) throws {
        let line = try command.jsonLine() + "\n"
        lock.lock()
        defer { lock.unlock() }
        guard !stdinClosed else { throw CocoaError(.fileWriteUnknown) }
        try stdin.write(contentsOf: Data(line.utf8))
    }

    func terminate() {
        lock.lock()
        let first = !signalled
        signalled = true
        lock.unlock()
        if first, process.isRunning { process.terminate() }
    }

    func kill() {
        guard process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }

    private func closeStdin() {
        lock.lock()
        defer { lock.unlock() }
        guard !stdinClosed else { return }
        stdinClosed = true
        try? stdin.close()
    }
}

/// Resumes one waiter with the exit status, whichever comes first.
private final class ExitLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiter: CheckedContinuation<Int32, Never>?

    func fire(_ value: Int32) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: value)
            return
        }
        status = value
        lock.unlock()
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }
}

/// The last `limit` bytes written to a stream, for error messages.
private final class TailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var reachedEOF = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > limit { data = Data(data.suffix(limit)) }
    }

    func markEOF() {
        lock.lock()
        reachedEOF = true
        lock.unlock()
    }

    func waitForEOF(upTo bound: Duration) async {
        let deadline = ContinuousClock.now + bound
        while ContinuousClock.now < deadline {
            if lock.withLock({ reachedEOF }) { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        // Lossy on purpose: the tail may start mid-way through a UTF-8 sequence.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: data, as: UTF8.self)
    }
}

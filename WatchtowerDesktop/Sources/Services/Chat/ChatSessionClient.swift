import Foundation
import GRDB
import WatchtowerCore

/// What a session process is spawned with. Every argv-affecting field
/// except `resumeSessionID` (a spawn-time hint) belongs in `isCompatible`.
struct ChatSessionConfig: Equatable, Sendable {
    var conversationID: Int64
    var provider: String
    var model: String?
    var surface: String
    var resumeSessionID: String?
    /// The chat project whose instructions/files join the session's prompt
    /// (`--project-id`); nil for a chat outside any project.
    var projectID: Int64?

    init(
        conversationID: Int64,
        provider: String,
        model: String?,
        surface: String = "main",
        resumeSessionID: String? = nil,
        projectID: Int64? = nil
    ) {
        self.conversationID = conversationID
        self.provider = provider
        self.model = model
        self.surface = surface
        self.resumeSessionID = resumeSessionID
        self.projectID = projectID
    }

    /// Moving a chat into or out of a project changes its prompt, so a warm
    /// session spawned for the old project is not reused.
    func isCompatible(with other: Self) -> Bool {
        conversationID == other.conversationID && provider == other.provider
            && model == other.model && surface == other.surface && projectID == other.projectID
    }
}

/// One warm `watchtower ai session` process for one conversation. Owns the
/// turn driver, so a running turn keeps streaming into the database no
/// matter which view (if any) is showing it.
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
    static let defaultKillAfter: Duration = .seconds(3)

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
    /// The last message this provider session has seen (see `ChatContinuity`).
    var continuousLeafID: Int64?

    @ObservationIgnored var onTurnFinished: ((Int64) -> Void)?
    /// The process ended (or could not be spawned) — the pool re-admits.
    @ObservationIgnored var onEnded: (() -> Void)?
    @ObservationIgnored private var process: (any ChatSessionProcess)?
    @ObservationIgnored private let spawn: () throws -> any ChatSessionProcess
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var pendingTurn: ChatTurnCommand?
    @ObservationIgnored private var exited = false
    @ObservationIgnored private var shutdownRequested = false
    @ObservationIgnored private var sigtermSent = false
    @ObservationIgnored private var hasRunTurn = false
    /// Set by `retireAfterTurn`: the running turn is this session's last.
    @ObservationIgnored private var retiresAfterTurn = false
    /// The turn whose `turn` command was actually written to the process.
    @ObservationIgnored private var sentTurnID: String?

    init(
        config: ChatSessionConfig,
        spawn: @escaping () throws -> any ChatSessionProcess,
        store: ChatTurnStore,
        clock: @escaping () -> Date,
        launchImmediately: Bool = true
    ) {
        self.conversationID = config.conversationID
        self.config = config
        self.spawn = spawn
        self.clock = clock
        self.lastActivity = clock()
        self.driver = ChatTurnDriver(conversationID: config.conversationID, projectID: config.projectID,
                                     store: store, clock: clock)
        driver.onTurnFinished = { [weak self] turn in self?.turnFinished(turn) }
        if launchImmediately { launch() }
    }

    var liveTurn: LiveTurn? { driver.liveTurn }
    var isBusy: Bool { driver.liveTurn?.isRunning == true }
    /// A process was launched and has not exited yet.
    var hasLiveProcess: Bool { process != nil && !exited }

    /// The argv — flags only, never content (CHAT-04). `--provider` is the
    /// root persistent flag; the rest are `ai session`'s own.
    static func arguments(for config: ChatSessionConfig, dbPath: String?) -> [String] {
        var args = ["ai", "session", "--conversation", String(config.conversationID),
                    "--provider", config.provider, "--surface", config.surface]
        if let model = config.model, !model.isEmpty { args += ["--model", model] }
        if let resume = config.resumeSessionID, !resume.isEmpty { args += ["--resume", resume] }
        if let projectID = config.projectID { args += ["--project-id", String(projectID)] }
        if let dbPath, !dbPath.isEmpty { args += ["--db-path", dbPath] }
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
            if let held = pendingTurn {
                pendingTurn = nil
                failTurn(held.turnID, message: failure.message)
            }
            onEnded?()
            return
        }
        startReading()
        if let held = pendingTurn {
            pendingTurn = nil
            send(held)
        }
    }

    /// Only a session that has run no turn yet may adopt the conversation's
    /// history as "already seen" (a `--resume` spawn).
    func adoptInitialContinuity(_ leafID: Int64?) {
        guard !hasRunTurn else { return }
        continuousLeafID = leafID
    }

    /// Runs one turn. The assistant row (`request.assistantMessageID`) must
    /// already exist; a dead session or a failed write fails the turn
    /// visibly with `provider_unavailable` rather than throwing. On a
    /// pending session the turn is held until launch.
    func startTurn(_ request: ChatTurnRequest) {
        guard !isBusy else { return }
        hasRunTurn = true
        touch()
        let command = request.command
        driver.begin(messageID: request.assistantMessageID, turnID: command.turnID)
        if isPending, !shutdownRequested {
            pendingTurn = command
            return
        }
        guard hasLiveProcess, isAlive else {
            let reason = exitError?.message ?? startupError?.message ?? "The chat session is not running."
            failTurn(command.turnID, message: reason)
            return
        }
        send(command)
    }

    /// Stop: ask the provider to interrupt; if no `turn_done` arrives within
    /// `grace`, keep the partial text and kill the process (Go already kills
    /// its child after 5 s, so 7 s covers a Go side that hung too).
    func cancel(grace: Duration = .seconds(7), killAfter: Duration = ChatSessionClient.defaultKillAfter) {
        guard let turn = driver.liveTurn, turn.isRunning else { return }
        if pendingTurn != nil {
            // Never sent: nothing to interrupt, and nothing left to launch
            // for — the pool drops the queued client instead of spawning a
            // process that would idle until the TTL.
            abandon()
            onEnded?()
            return
        }
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
            guard let self, self.driver.liveTurn?.turnID == turnID else { return }
            self.driver.finishRunningAsPartial()
            // A session that ignored `cancel` is never reused.
            self.shutdownRequested = true
            self.isAlive = false
            await self.terminateAndReap(killAfter: killAfter)
        }
    }

    /// The prompt this session was spawned with is stale (its chat project
    /// changed) but a turn is running: let it finish, record no session id,
    /// then stop counting as alive so the pool replaces it (CHAT-03 — a
    /// running turn is never cut).
    func retireAfterTurn() {
        retiresAfterTurn = true
        driver.stopRecordingSession()
    }

    /// Hands back the turn this not-yet-launched session holds, so it can be
    /// sent on a replacement session instead (its row stays as it is — the
    /// turn neither failed nor stopped). Nil when nothing is held.
    func surrenderHeldTurn() -> ChatTurnRequest? {
        guard let held = pendingTurn else { return nil }
        guard let turn = driver.liveTurn, turn.turnID == held.turnID else {
            // startTurn always begins the driver's turn before holding it.
            NSLog("ChatSessionClient: held turn %@ of conversation %lld has no live turn; it is dropped",
                  held.turnID, conversationID)
            return nil
        }
        pendingTurn = nil
        driver.releaseUnsentTurn()
        return ChatTurnRequest(command: held, assistantMessageID: turn.messageID)
    }

    /// Ends the client without a process to shut down (never launched, or
    /// already exited): a held or running turn keeps its text as `partial`.
    func abandon() {
        shutdownRequested = true
        pendingTurn = nil
        isPending = false
        driver.finishRunningAsPartial()
        isAlive = false
    }

    /// Quit / eviction: keep what streamed, ask politely (`close`), wait up
    /// to `grace`, then one SIGTERM, then SIGKILL after `killAfter`.
    func close(grace: Duration, killAfter: Duration = ChatSessionClient.defaultKillAfter) async {
        abandon()
        guard let process, !exited else { return }
        // A failed write means the pipe is already closed — the process is gone
        // or going; the wait below and the signals still apply.
        try? process.send(.close)
        await waitForExit(upTo: grace)
        await terminateAndReap(killAfter: killAfter)
    }

    // MARK: - Private

    private func send(_ command: ChatTurnCommand) {
        guard let process else { return }
        do {
            try process.send(.turn(command))
            sentTurnID = command.turnID
        } catch {
            failTurn(command.turnID, message: error.localizedDescription)
        }
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
        if case let .exited(status, stderrTail) = event {
            // Only an exit nobody asked for is an error: a non-zero status, or
            // any exit that leaves a turn without its terminal event.
            if !shutdownRequested, status != 0 || isBusy {
                let failure = ChatSessionError(turnID: nil, code: .sessionLost,
                                               message: Self.exitMessage(status: status, stderrTail: stderrTail),
                                               retryable: true)
                exitError = failure
                driver.noteSessionError(failure)
            }
            processEnded()
            return
        }
        driver.apply(event)
    }

    private func processEnded() {
        guard !exited else { return }
        exited = true
        isAlive = false
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

    private func failTurn(_ turnID: String, message: String) {
        driver.apply(.error(ChatSessionError(turnID: turnID, code: .providerUnavailable, message: message,
                                             retryable: true)))
    }

    private func turnFinished(_ turn: LiveTurn) {
        // A failed turn may or may not have reached the provider, and a held
        // turn stopped before launch never did: force a replay next time.
        if case .failed = turn.phase {
            continuousLeafID = nil
        } else {
            continuousLeafID = turn.turnID == sentTurnID ? turn.messageID : nil
        }
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

    init(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        process.environment = Constants.resolvedEnvironment()
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

    /// Frames stdout on byte 0x0A only (`NDJSONLineSplitter`) — never
    /// `bytes.lines`, which also splits on the raw U+0085 Go leaves in JSON
    /// strings and would drop the event.
    private static func readEvents(from stdout: FileHandle, into continuation: AsyncStream<ChatEvent>.Continuation) async {
        var splitter = NDJSONLineSplitter()
        var chunk: [UInt8] = []
        func emit(_ lines: [String]) {
            for line in lines {
                if let event = ChatEvent.parse(line) { continuation.yield(event) }
            }
        }
        do {
            for try await byte in stdout.bytes {
                chunk.append(byte)
                if byte == 0x0A {
                    emit(splitter.append(chunk))
                    chunk.removeAll(keepingCapacity: true)
                }
            }
        } catch {
            // A read error means stdout closed; the exit status says why.
        }
        emit(splitter.append(chunk))
        if let tail = splitter.finish() { emit([tail]) }
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
            lock.lock()
            let done = reachedEOF
            lock.unlock()
            if done { return }
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

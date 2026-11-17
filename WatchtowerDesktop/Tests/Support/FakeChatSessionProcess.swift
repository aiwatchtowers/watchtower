import Foundation
import GRDB
import WatchtowerCore

/// Scripted stand-in for `watchtower ai session`. Records every command,
/// lets a test emit v2 events, and models exit/terminate/kill. `@unchecked
/// Sendable`: `lock` guards the recorded state; the config flags are set
/// before the client starts using the fake.
///
/// Spawned with `--persist` and a database (`db`), it also does what the Go
/// session saves (`FakePersistSession`): a `turn` writes its starting rows
/// and answers `started` (or `refused`), each emitted event is folded into
/// the rows before it is read, and the turn's end is followed by
/// `turn_saved`. `turns` are then the turns the provider got.
package final class FakeChatSessionProcess: ChatSessionProcess, @unchecked Sendable {
    package let arguments: [String]
    package let events: AsyncStream<ChatEvent>
    private let continuation: AsyncStream<ChatEvent>.Continuation
    private let lock = NSLock()
    private var sentStorage: [ChatCommand] = []
    private var terminateCountStorage = 0
    private var killedStorage = false
    private var exitedStorage = false

    /// Called synchronously inside `send`, after recording — lets a test
    /// inspect the database at the exact moment a turn goes out (CHAT-01).
    package var onSend: ((ChatCommand) -> Void)?
    /// The Go session's writes (`--persist` with a database); nil otherwise.
    package let persist: FakePersistSession?
    private var forwardedStorage: [ChatTurnCommand] = []
    package var sendError: Error?
    package var exitsOnClose = false
    /// Under `--persist`: a turn's start waits for `releaseStarts()` (the
    /// moment between Send and `started`).
    package var holdsStarts = false
    private var heldStarts: [() -> Void] = []
    /// `false` models a process that ignores SIGTERM (only SIGKILL ends it).
    package var exitsOnTerminate = true

    /// `db` is the database a `--persist` session writes; nil opens its
    /// `--db-path` (as the Go session does).
    package init(arguments: [String], db: (any DatabaseWriter)? = nil) {
        self.arguments = arguments
        (events, continuation) = AsyncStream.makeStream(of: ChatEvent.self)
        persist = (db ?? Self.openDatabase(arguments)).flatMap { FakePersistSession(arguments: arguments, db: $0) }
    }

    private static func openDatabase(_ arguments: [String]) -> (any DatabaseWriter)? {
        guard arguments.contains("--persist"), let index = arguments.firstIndex(of: "--db-path"),
              index + 1 < arguments.count,
              FileManager.default.fileExists(atPath: arguments[index + 1]) else { return nil }
        if let shared = TestDatabasePools.pool(at: arguments[index + 1]) { return shared }
        var config = Configuration()
        config.busyMode = .timeout(30)
        config.prepareDatabase { try $0.execute(sql: "PRAGMA foreign_keys = ON") }
        do {
            return try DatabasePool(path: arguments[index + 1], configuration: config)
        } catch {
            // A persisting fake without its database would never answer `started`.
            preconditionFailure("FakeChatSessionProcess: opening \(arguments[index + 1]) failed: \(error)")
        }
    }

    package var sent: [ChatCommand] {
        lock.lock()
        defer { lock.unlock() }
        return sentStorage
    }

    /// The turns the provider got: under `--persist`, the ones started (with
    /// the text and replay the session sends), else every `turn` written.
    package var turns: [ChatTurnCommand] {
        if persist != nil { return lock.withLock { forwardedStorage } }
        return sent.compactMap { command in
            if case let .turn(turn) = command { turn } else { nil }
        }
    }

    /// Whether SIGTERM was sent at least once.
    package var terminated: Bool { terminateCount > 0 }

    package var terminateCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return terminateCountStorage
    }

    package var killed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return killedStorage
    }

    /// Whether `exit` ran (by script, close, SIGTERM or SIGKILL).
    package var hasExited: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exitedStorage
    }

    package func argument(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    package func send(_ command: ChatCommand) throws {
        if let sendError { throw sendError }
        lock.lock()
        sentStorage.append(command)
        lock.unlock()
        if let persist, case let .turn(turn) = command {
            let start = { [self] in
                persist.queue.async { [self] in
                    let (answer, forwarded) = persist.start(turn)
                    if let forwarded {
                        lock.withLock { forwardedStorage.append(forwarded) }
                        onSend?(.turn(forwarded))
                    }
                    continuation.yield(answer)
                }
            }
            if lock.withLock({ holdsStarts }) {
                lock.withLock { heldStarts.append(start) }
            } else {
                start()
            }
            return
        }
        onSend?(command)
        if exitsOnClose, command == .close { exit(status: 0) }
    }

    package func terminate() {
        lock.lock()
        terminateCountStorage += 1
        lock.unlock()
        if exitsOnTerminate { exit(status: 15) }
    }

    package func kill() {
        lock.lock()
        killedStorage = true
        lock.unlock()
        exit(status: 9)
    }

    /// Runs the starts `holdsStarts` kept back.
    package func releaseStarts() {
        let starts = lock.withLock { () -> [() -> Void] in
            holdsStarts = false
            defer { heldStarts = [] }
            return heldStarts
        }
        for start in starts { start() }
    }

    package func emit(_ event: ChatEvent) {
        guard let persist else {
            continuation.yield(event)
            return
        }
        persist.queue.async { [self] in
            // stdout first, then the session's write, then `turn_saved`.
            let ended = persist.endsTurn(event)
            if !ended { persist.apply(event) }
            continuation.yield(event)
            if ended, let saved = persist.apply(event) { continuation.yield(.turnSaved(turnID: saved)) }
        }
    }

    /// Idempotent: a yield after `finish` is dropped by `AsyncStream`. A
    /// persisting session that exits on its own terms (`close`, SIGTERM)
    /// saves a running turn as `partial` first; one killed (any other
    /// status) leaves it as it was.
    package func exit(status: Int32, stderr: String = "") {
        lock.lock()
        exitedStorage = true
        lock.unlock()
        let finish = { [self] in
            continuation.yield(.exited(status: status, stderrTail: stderr))
            continuation.finish()
        }
        guard let persist else {
            finish()
            return
        }
        persist.queue.async { [self] in
            if status == 0 || status == 15, let saved = persist.endOnExit() {
                continuation.yield(.turnSaved(turnID: saved))
            }
            persist.close()
            finish()
        }
    }
}

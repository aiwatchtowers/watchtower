import Foundation
import WatchtowerCore

/// Scripted stand-in for `watchtower ai session`. Records every command,
/// lets a test emit v2 events, and models exit/terminate/kill. `@unchecked
/// Sendable`: `lock` guards the recorded state; the config flags are set
/// before the client starts using the fake.
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
    package var sendError: Error?
    package var exitsOnClose = false
    /// `false` models a process that ignores SIGTERM (only SIGKILL ends it).
    package var exitsOnTerminate = true

    package init(arguments: [String]) {
        self.arguments = arguments
        (events, continuation) = AsyncStream.makeStream(of: ChatEvent.self)
    }

    package var sent: [ChatCommand] {
        lock.lock()
        defer { lock.unlock() }
        return sentStorage
    }

    package var turns: [ChatTurnCommand] {
        sent.compactMap { command in
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

    package func emit(_ event: ChatEvent) {
        continuation.yield(event)
    }

    /// Idempotent: a yield after `finish` is dropped by `AsyncStream`.
    package func exit(status: Int32, stderr: String = "") {
        lock.lock()
        exitedStorage = true
        lock.unlock()
        continuation.yield(.exited(status: status, stderrTail: stderr))
        continuation.finish()
    }
}

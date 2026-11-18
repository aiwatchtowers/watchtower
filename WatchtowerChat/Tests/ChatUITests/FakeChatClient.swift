import ChatUI
import ChatWire
import Foundation

/// A `ChatClient` that records every operation and answers from a script: no socket, no clock. A responder may
/// suspend until the test opens its `Gate`, so a test sees the state before the echo arrives.
final class FakeChatClient: ChatClient, @unchecked Sendable {
    typealias Responder = @Sendable (ChatOperation) async throws -> ChatEcho

    /// The connection dropped before the answer (`ChatConnectionError`).
    struct Dropped: ChatConnectionError {}
    /// An operation that failed for its own reason (not the transport).
    struct Broken: Error {}

    private let lock = NSLock()
    private var recorded: [ChatOperation] = []
    private var responders: [Responder] = []
    private var feeds: [Int64: AsyncStream<ChatFeedUpdate>.Continuation] = [:]
    private(set) var feedSubscriptions: [Int64] = []
    private let opStream: AsyncStream<ChatOperation>
    private let opContinuation: AsyncStream<ChatOperation>.Continuation
    let reachability: AsyncStream<ChatReachability>
    let reachabilityContinuation: AsyncStream<ChatReachability>.Continuation
    private var listContinuation: AsyncStream<ChatListUpdate>.Continuation?
    private var opIterator: AsyncStream<ChatOperation>.Iterator
    /// Answers `createsConversationOnTurn` (the phone's relay: a new chat is created by its first turn).
    var createsOnTurn = false
    var createsConversationOnTurn: Bool { createsOnTurn }

    init() {
        (opStream, opContinuation) = AsyncStream.makeStream(of: ChatOperation.self)
        (reachability, reachabilityContinuation) = AsyncStream.makeStream(of: ChatReachability.self)
        opIterator = opStream.makeAsyncIterator()
    }

    /// The next responders, in order; once they are used up every operation is applied with no result.
    func respond(_ responder: @escaping Responder) {
        lock.withLock { responders.append(responder) }
    }

    var ops: [ChatOperation] { lock.withLock { recorded } }

    /// Waits until the next operation is recorded (no clock: the stream buffers them).
    func nextOp() async -> ChatOperation? {
        await opIterator.next()
    }

    func send(_ op: ChatOperation) async throws -> ChatEcho {
        let responder: Responder? = lock.withLock {
            recorded.append(op)
            return responders.isEmpty ? nil : responders.removeFirst()
        }
        opContinuation.yield(op)
        guard let responder else { return .applied(.none) }
        return try await responder(op)
    }

    func feed(_ conversation: Int64) -> AsyncStream<ChatFeedUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: ChatFeedUpdate.self)
        lock.withLock {
            feeds[conversation] = continuation
            feedSubscriptions.append(conversation)
        }
        return stream
    }

    func list() -> AsyncStream<ChatListUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: ChatListUpdate.self)
        lock.withLock { listContinuation = continuation }
        return stream
    }
}

/// A door a responder waits behind until the test opens it.
actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// A clock whose sleeps end only when the test fires them; a cancelled sleep ends at once (`CancellationError`).
final class ManualClock: ChatUIClock, @unchecked Sendable {
    private let lock = NSLock()
    private var sleepers: [UUID: CheckedContinuation<Void, Error>] = [:]

    var pendingSleeps: Int { lock.withLock { sleepers.count } }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled: Bool = lock.withLock {
                    if Task.isCancelled { return true }
                    sleepers[id] = continuation
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
            sleeper?.resume(throwing: CancellationError())
        }
    }

    /// Ends every pending sleep.
    func fire() {
        let due = lock.withLock {
            let due = Array(sleepers.values)
            sleepers = [:]
            return due
        }
        due.forEach { $0.resume() }
    }
}

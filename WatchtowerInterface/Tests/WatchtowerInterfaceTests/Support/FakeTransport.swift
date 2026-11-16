import Foundation
import WatchtowerInterface

/// A scripted `TowerTransport`. While `setDown(true)` every call is
/// recorded and throws `.down`, and a new watch ends at once; otherwise a
/// call is answered by the command's responder (default: `tower.hello` with
/// the current interface version, `tower.ping` with a fixed time, anything
/// else `ok` with `{}`). Every call is recorded with the clock's time, and a
/// test can wait for a number of calls or watch opens without any timer.
final class FakeTransport: TowerTransport, @unchecked Sendable {
    typealias Responder = @Sendable (Request) -> Response

    struct Call: Sendable {
        let request: Request
        let at: Duration
    }

    static let pingAt = "2026-11-16T09:14:00Z"

    private let lock = NSLock()
    private let clock: ManualClock
    private var down = false
    private var hanging: Set<String> = []
    private var cancelled = 0
    private var responders: [String: Responder] = [:]
    private var recorded: [Call] = []
    private var opened: [Request] = []
    private var liveWatches: [AsyncThrowingStream<ChangedEvent, Error>.Continuation] = []
    private var waiters: [(ready: () -> Bool, continuation: CheckedContinuation<Void, Never>)] = []

    init(clock: ManualClock) {
        self.clock = clock
    }

    // MARK: - Script

    func setDown(_ isDown: Bool) {
        lock.withLock { down = isDown }
    }

    /// Calls of `command` never answer; they end (throwing) only when cancelled.
    func hang(_ command: TowerCommand) {
        lock.withLock { _ = hanging.insert(command.rawValue) }
    }

    /// Hanging calls that were cancelled.
    var cancelledCalls: Int { lock.withLock { cancelled } }

    func respond(_ command: TowerCommand, with responder: @escaping Responder) {
        lock.withLock { responders[command.rawValue] = responder }
    }

    /// Answers `tower.hello` with `version`.
    func helloVersion(_ version: String) {
        respond(.towerHello) { Self.ok($0, HelloResponse(interfaceVersion: version, build: "test", syncPaused: false, noSync: false)) }
    }

    /// Yields `event` on every open watch.
    func emit(_ event: ChangedEvent) {
        lock.withLock { liveWatches }.forEach { $0.yield(event) }
    }

    /// Ends every open watch as a closed socket does.
    func dropWatches() {
        let watches = lock.withLock {
            defer { liveWatches = [] }
            return liveWatches
        }
        watches.forEach { $0.finish(throwing: TowerTransportError.down) }
    }

    // MARK: - Record

    func calls(_ command: TowerCommand) -> [Call] {
        lock.withLock { recorded.filter { $0.request.command == command.rawValue } }
    }

    var watchOpens: Int { lock.withLock { opened.count } }

    /// The request_id a write call carried.
    static func requestID(_ call: Call) -> String? {
        guard let data = call.request.params?.data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["request_id"] as? String
    }

    func waitFor(_ command: TowerCommand, count: Int) async {
        await waitUntil { self.recorded.filter { $0.request.command == command.rawValue }.count >= count }
    }

    func waitFor(watchOpens count: Int) async {
        await waitUntil { self.opened.count >= count }
    }

    // MARK: - TowerTransport

    func call(_ request: Request) async throws -> Response {
        let (isDown, hangs, responder) = record {
            recorded.append(Call(request: request, at: clock.now.offset))
            return (down, hanging.contains(request.command), responders[request.command])
        }
        if isDown { throw TowerTransportError.down }
        if hangs { try await hangUntilCancelled() }
        if let responder { return responder(request) }
        switch request.command {
        case TowerCommand.towerHello.rawValue:
            return Self.ok(request, HelloResponse(interfaceVersion: InterfaceVersion.current, build: "test", syncPaused: false, noSync: false))
        case TowerCommand.towerPing.rawValue:
            return Self.ok(request, PingResponse(at: Self.pingAt))
        default:
            return Self.ok(request, PauseResponse(paused: true))
        }
    }

    func watch(_ request: Request) -> AsyncThrowingStream<ChangedEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ChangedEvent, Error>.makeStream()
        let isDown = record {
            opened.append(request)
            if !down { liveWatches.append(continuation) }
            return down
        }
        if isDown { continuation.finish(throwing: TowerTransportError.down) }
        return stream
    }

    // MARK: - Helpers

    private func hangUntilCancelled() async throws {
        let gate = HangGate()
        await withTaskCancellationHandler {
            await withCheckedContinuation { gate.park($0) }
        } onCancel: {
            gate.release()
        }
        lock.withLock { cancelled += 1 }
        throw CancellationError()
    }

    static func ok(_ request: Request, _ value: some Encodable) -> Response {
        // swiftlint:disable:next force_try
        Response(id: request.id, status: .ok, result: try! RawJSON(data: JSONEncoder().encode(value)))
    }

    /// Runs `change` under the lock, then wakes the waiters it satisfied.
    private func record<T>(_ change: () -> T) -> T {
        lock.lock()
        let value = change()
        let met = waiters.filter { $0.ready() }
        waiters.removeAll { $0.ready() }
        lock.unlock()
        met.forEach { $0.continuation.resume() }
        return value
    }

    private func waitUntil(_ ready: @escaping () -> Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if ready() {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append((ready, continuation))
            lock.unlock()
        }
    }
}

/// A thread-safe counter for the daemon closures.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

/// Parks a hanging call until its task is cancelled (either order).
private final class HangGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func park(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeNow = lock.withLock {
            if released { return true }
            self.continuation = continuation
            return false
        }
        if resumeNow { continuation.resume() }
    }

    func release() {
        let waiting = lock.withLock {
            released = true
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume()
    }
}

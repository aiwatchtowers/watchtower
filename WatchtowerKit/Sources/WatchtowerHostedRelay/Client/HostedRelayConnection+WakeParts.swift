import Foundation
import os

/// One ping of a wake (live link R6), answered once: by the pong or by a failed ping. A ping is not cancellable,
/// so it is never awaited past what a caller wants: each wait ends on its own deadline or cancel.
final class PongWatch: Sendable {
    enum Answer: Sendable {
        case pong, failed
    }

    private struct State {
        var answer: Answer?
        var nextID = 0
        var waiters: [Int: CheckedContinuation<Answer?, Never>] = [:]
    }

    private enum Wait: Sendable {
        case answer(Answer?)
        case timedOut
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ socket: any RelaySocket) {
        Task { [state] in
            let pong: Answer
            do {
                try await socket.ping()
                pong = .pong
            } catch {
                pong = .failed
            }
            let waiters = state.withLock { state in
                state.answer = pong
                defer { state.waiters = [:] }
                return Array(state.waiters.values)
            }
            for waiter in waiters { waiter.resume(returning: pong) }
        }
    }

    /// The answer; nil when the caller is cancelled first.
    func answered() async -> Answer? {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Answer?, Never>) in
                let now: Answer?? = state.withLock { state in
                    if let answer = state.answer { return .some(answer) }
                    if Task.isCancelled { return .some(nil) }
                    state.waiters[id] = continuation
                    return nil
                }
                if let now { continuation.resume(returning: now) }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(returning: nil)
        }
    }

    /// The answer if it comes within `limit` on `clock`, else nil.
    func answered(within limit: Duration, clock: any RelayClock) async -> Answer? {
        await withTaskGroup(of: Wait.self) { group in
            group.addTask { .answer(await self.answered()) }
            group.addTask {
                do { try await clock.sleep(for: limit) } catch { return .answer(nil) }
                return .timedOut
            }
            defer { group.cancelAll() }
            if case .answer(let answer)? = await group.next() { return answer }
            return nil
        }
    }
}

/// The socket a wake's redial hands to the reconnect loop, or nil when it hands none: set once, read by the loop.
final class HandoverPromise: Sendable {
    typealias Handover = HostedRelayConnection.Handover

    private struct State {
        var fulfilled = false
        var value: Handover?
        var nextID = 0
        var waiters: [Int: CheckedContinuation<Handover?, Never>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Sets the outcome; false (and ignored) when it was already set.
    @discardableResult
    func fulfil(_ value: Handover?) -> Bool {
        set { value }.settled
    }

    /// Sets the outcome to what `make` returns, `make` run only while unset and under this promise's lock (so
    /// nobody settles it meanwhile); nil when it was already set or `make` gave nil.
    func settle(_ make: () -> Handover?) -> Handover? {
        let result = set(make)
        return result.settled ? result.value : nil
    }

    private func set(_ make: () -> Handover?) -> (settled: Bool, value: Handover?) {
        let (settled, value, waiters) = state.withLock { state -> (Bool, Handover?, [CheckedContinuation<Handover?, Never>]) in
            guard !state.fulfilled else { return (false, nil, []) }
            state.fulfilled = true
            state.value = make()
            defer { state.waiters = [:] }
            return (true, state.value, Array(state.waiters.values))
        }
        for waiter in waiters { waiter.resume(returning: value) }
        return (settled, value)
    }

    /// The outcome once set; nil when the caller is cancelled first.
    func value() async -> Handover? {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Handover?, Never>) in
                let now: Handover?? = state.withLock { state in
                    if state.fulfilled { return .some(state.value) }
                    if Task.isCancelled { return .some(nil) }
                    state.waiters[id] = continuation
                    return nil
                }
                if let now { continuation.resume(returning: now) }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(returning: nil)
        }
    }
}

/// Fires once; each `wait` returns once it fired, or as soon as the waiting task is cancelled.
final class Latch: Sendable {
    private struct State {
        var fired = false
        var nextID = 0
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var fired: Bool {
        state.withLock { $0.fired }
    }

    func fire() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard !state.fired else { return [] }
            state.fired = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = state.withLock { state in
                    if state.fired || Task.isCancelled { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume()
        }
    }
}

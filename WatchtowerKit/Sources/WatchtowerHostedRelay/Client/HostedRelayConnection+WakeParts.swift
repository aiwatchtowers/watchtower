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
    private struct State {
        var fulfilled = false
        var value: HostedRelayConnection.Handover?
        var nextID = 0
        var waiters: [Int: CheckedContinuation<HostedRelayConnection.Handover?, Never>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Sets the outcome; a second call is ignored.
    func fulfil(_ value: HostedRelayConnection.Handover?) {
        let waiters = state.withLock { state -> [CheckedContinuation<HostedRelayConnection.Handover?, Never>] in
            guard !state.fulfilled else { return [] }
            state.fulfilled = true
            state.value = value
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume(returning: value) }
    }

    /// The outcome once set; nil when the caller is cancelled first.
    func value() async -> HostedRelayConnection.Handover? {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<HostedRelayConnection.Handover?, Never>) in
                let now: HostedRelayConnection.Handover?? = state.withLock { state in
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

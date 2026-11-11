import Foundation
import Observation
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

// Deadline-free seams for tests that would otherwise wait on a clock
// (no-wall-clock tests, board #1738).

/// A sleep seam the test opens by hand: each `open()` lets the oldest
/// waiting `sleep()` return (banked when nobody sleeps yet). A sleeper whose
/// task is cancelled returns at once and is counted, so a test waits for the
/// cancel, or for a sleep to begin, instead of a clock.
final class HandOpenedSleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var banked = 0
    private var sleepers: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []
    private var calls = 0
    private var cancelled = 0
    private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var cancelWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func sleep() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                calls += 1
                var ready = takeReady(&callWaiters, upTo: calls)
                if Task.isCancelled {
                    cancelled += 1
                    ready += takeReady(&cancelWaiters, upTo: cancelled)
                    lock.unlock()
                    continuation.resume()
                } else if banked > 0 {
                    banked -= 1
                    lock.unlock()
                    continuation.resume()
                } else {
                    sleepers.append((id, continuation))
                    lock.unlock()
                }
                ready.forEach { $0.resume() }
            }
        } onCancel: {
            lock.lock()
            var sleeper: CheckedContinuation<Void, Never>?
            if let index = sleepers.firstIndex(where: { $0.id == id }) {
                sleeper = sleepers.remove(at: index).continuation
                cancelled += 1
            }
            let ready = takeReady(&cancelWaiters, upTo: cancelled)
            lock.unlock()
            sleeper?.resume()
            ready.forEach { $0.resume() }
        }
    }

    /// Lets `count` sleeps return: the waiting ones first (oldest first), the
    /// rest banked for sleeps still to come.
    func open(_ count: Int = 1) {
        lock.lock()
        var woken: [CheckedContinuation<Void, Never>] = []
        for _ in 0..<count {
            if sleepers.isEmpty {
                banked += 1
            } else {
                woken.append(sleepers.removeFirst().continuation)
            }
        }
        lock.unlock()
        woken.forEach { $0.resume() }
    }

    /// Returns once `sleep()` has been called `count` times in all.
    func untilCalled(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if calls >= count {
                lock.unlock()
                continuation.resume()
            } else {
                callWaiters.append((count, continuation))
                lock.unlock()
            }
        }
    }

    /// Returns once `count` sleepers were ended by their task's cancel.
    func untilCancelled(_ count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if cancelled >= count {
                lock.unlock()
                continuation.resume()
            } else {
                cancelWaiters.append((count, continuation))
                lock.unlock()
            }
        }
    }

    /// Under `lock`.
    private func takeReady(
        _ waiters: inout [(count: Int, continuation: CheckedContinuation<Void, Never>)], upTo reached: Int
    ) -> [CheckedContinuation<Void, Never>] {
        let ready = waiters.filter { $0.count <= reached }.map(\.continuation)
        waiters.removeAll { $0.count <= reached }
        return ready
    }
}

/// Returns only when its task is cancelled (then throws): a sleep seam's
/// "this clock never fires on its own".
func parkUntilTaskCancelled() async throws {
    let (stream, continuation) = AsyncStream<Never>.makeStream()
    for await _ in stream {}
    withExtendedLifetime(continuation) {}
    throw CancellationError()
}

/// A `ScriptedAIService` whose call count is on Observation, so
/// `untilObserved` re-checks a condition on `ai.calls` when a turn starts
/// (the scripted service's own list is plain state).
@Observable
final class CallCountingAI: AIServiceProtocol, @unchecked Sendable {
    @ObservationIgnored let inner: ScriptedAIService
    private(set) var count = 0

    init(_ inner: ScriptedAIService) {
        self.inner = inner
    }

    func stream(
        prompt: String,
        systemPrompt: String?,
        sessionID: String?,
        dbPath: String?,
        model: String?,
        provider: String?,
        toolMode: ChatToolMode?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let stream = inner.stream(prompt: prompt, systemPrompt: systemPrompt, sessionID: sessionID, dbPath: dbPath,
                                  model: model, provider: provider, toolMode: toolMode)
        count = inner.calls.count
        return stream
    }

    // swiftlint:disable:next function_parameter_count
    func stream(
        prompt: String,
        systemPrompt: String?,
        sessionID: String?,
        dbPath: String?,
        model: String?,
        provider: String?,
        toolMode: ChatToolMode?,
        readFolder: String?,
        ownerInstructions: Bool,
        purpose: String?,
        readFolderAskID: Int64?,
        readFolderRoundID: Int64?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let stream = inner.stream(prompt: prompt, systemPrompt: systemPrompt, sessionID: sessionID, dbPath: dbPath,
                                  model: model, provider: provider, toolMode: toolMode, readFolder: readFolder,
                                  ownerInstructions: ownerInstructions, purpose: purpose,
                                  readFolderAskID: readFolderAskID, readFolderRoundID: readFolderRoundID)
        count = inner.calls.count
        return stream
    }
}

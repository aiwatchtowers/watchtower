import Foundation
import WatchtowerSync

/// A dispatcher handler's own deadline (a hub stop cannot cut a hung
/// await): runs `work` in its own task and returns its outcome, or
/// `outcome_unknown` with `message` once `timeout` passes first. The work
/// then keeps running to its end, its outcome dropped — it is never cut
/// mid-write, so the phone is told to check on the Mac.
@MainActor
func withHandlerTimeout(
    _ timeout: Duration,
    sleep: @escaping @Sendable (Duration) async -> Void,
    message: String,
    _ work: @escaping @MainActor () async throws -> ActionOutcome
) async throws -> ActionOutcome {
    try await withCheckedThrowingContinuation { continuation in
        let once = ResumeOnce(continuation)
        let timer = Task { @MainActor in
            await sleep(timeout)
            guard !Task.isCancelled else { return }
            once.resume(.success(.failed(.outcomeUnknown, message: message)))
        }
        Task { @MainActor in
            let result: Result<ActionOutcome, Error>
            do { result = .success(try await work()) } catch { result = .failure(error) }
            timer.cancel()
            once.resume(result)
        }
    }
}

/// A continuation the first of two racers resumes; the other is a no-op.
@MainActor
private final class ResumeOnce {
    private var continuation: CheckedContinuation<ActionOutcome, Error>?

    init(_ continuation: CheckedContinuation<ActionOutcome, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<ActionOutcome, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

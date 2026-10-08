import Foundation
import GRDB
import WatchtowerCore
import WatchtowerSync

/// `ask_answer` from the phone (mobile POC spec §5.2, §6.2): params
/// `{workbench_id, answer}`, entity the ask id. The answer goes through the
/// Desktop's own structured entry (`OwnerAsksViewModel.answer(_:with:)`):
/// re-validated by the draft's rules, stored in one guarded write
/// (`WHERE status = 'open'`), then delivered, held or left to the brief as
/// a Desktop answer is (PROJ-12 unchanged).
///
/// Idempotent: an ask already answered is `ask_not_open` before anything
/// runs, so a second delivery of one action never stores twice nor types a
/// second line. The handler owns its timeout (a hub stop cannot cut a hung
/// await) and never calls back into the relay processor.
@MainActor
final class AskAnswerHandler {
    typealias Answer = @MainActor (OwnerAsk, OwnerAskAnswer) async -> OwnerAsksViewModel.AnswerOutcome

    /// Ample for a delivery's state reads and its submit pause.
    static let defaultTimeout: Duration = .seconds(30)
    static let timeoutMessage = "The Mac did not finish this answer in time — check the ask on the Mac"

    private let dbPool: DatabasePool
    private let answer: Answer
    private let timeout: Duration
    private let sleep: @Sendable (Duration) async -> Void

    init(
        dbPool: DatabasePool,
        timeout: Duration = AskAnswerHandler.defaultTimeout,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        answer: @escaping Answer
    ) {
        self.dbPool = dbPool
        self.timeout = timeout
        self.sleep = sleep
        self.answer = answer
    }

    /// The echo of one `ask_answer`. A timeout is `outcome_unknown`: the
    /// answer may still land (it is never cut mid-write or mid-delivery).
    func handle(_ action: ActionRequestPayload) async throws -> ActionOutcome {
        try await withTimeout { try await self.apply(action) }
    }

    private func apply(_ action: ActionRequestPayload) async throws -> ActionOutcome {
        guard let askID = action.entityID.flatMap(Int64.init),
              case let .integer(workbenchID)? = action.params["workbench_id"],
              case let .object(fields)? = action.params["answer"] else {
            return .failed(.invalidParams, message: "ask_answer needs an ask id, workbench_id and answer")
        }
        let value: OwnerAskAnswer
        do {
            let data = try JSONEncoder().encode(JSONValue.object(fields))
            value = try JSONDecoder().decode(OwnerAskAnswer.self, from: data)
        } catch {
            return .failed(.invalidAnswer, message: "The answer could not be read: \(error.localizedDescription)")
        }
        // A read error is not "not found": it throws, echoed write_failed.
        guard let ask = try await dbPool.read({ try OwnerAskQueries.ask($0, id: askID, projectID: workbenchID) }) else {
            return .failed(.notFound, message: "No such ask on this workbench")
        }
        guard ask.isOpen else { return .failed(.askNotOpen) }
        return Self.outcome(await answer(ask, value))
    }

    static func outcome(_ outcome: OwnerAsksViewModel.AnswerOutcome) -> ActionOutcome {
        switch outcome {
        case let .stored(delivery): .applied(["delivery": .string(wire(delivery))])
        case .notOpen: .failed(.askNotOpen)
        case let .invalid(message): .failed(.invalidAnswer, message: message)
        // Another answer to the ask is being written on the Mac right now.
        case .busy: .failed(.conflict, message: "Another answer to this ask is being saved on the Mac")
        case let .failed(message): .failed(.writeFailed, message: message)
        }
    }

    /// `result.delivery` values (spec §5.2).
    static func wire(_ delivery: OwnerAsksViewModel.Delivery) -> String {
        switch delivery {
        case .submitted: "submitted"
        case .typed: "typed"
        case .held: "held"
        case .queued: "queued"
        case .copied: "copied"
        case .noSession: "no_session"
        }
    }

    /// Runs `work` in its own task and returns its outcome, or
    /// `outcome_unknown` once `timeout` passes first; the work then keeps
    /// running to its end, its outcome dropped.
    private func withTimeout(_ work: @escaping @MainActor () async throws -> ActionOutcome) async throws -> ActionOutcome {
        let (timeout, sleep) = (timeout, sleep)
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let timer = Task { @MainActor in
                await sleep(timeout)
                guard !Task.isCancelled else { return }
                once.resume(.success(.failed(.outcomeUnknown, message: Self.timeoutMessage)))
            }
            Task { @MainActor in
                let result: Result<ActionOutcome, Error>
                do { result = .success(try await work()) } catch { result = .failure(error) }
                timer.cancel()
                once.resume(result)
            }
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

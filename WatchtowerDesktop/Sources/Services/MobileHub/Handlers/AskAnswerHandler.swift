import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

/// `ask_answer` from the phone (mobile POC spec §5.2, §6.2): params
/// `{workbench_id, answer}`, entity the ask id. The answer goes through the
/// Desktop's own structured entry (`OwnerAsksViewModel.answer(_:with:)`):
/// re-validated by the draft's rules, stored in one guarded write
/// (`WHERE status = 'open'`), then delivered, held or left to the brief as
/// a Desktop answer is (PROJ-12 unchanged).
///
/// Idempotent (spec §5.2): the guarded write stores one answer per ask, and
/// a re-run of an action whose answer is already stored — its echo's save
/// failed, or the hub stopped before the echo — is `applied` again with the
/// delivery the sidecar kept, with no second write and no second line. Any
/// other ask that is not open is `ask_not_open`. The handler owns its
/// timeout (a hub stop cannot cut a hung await) and never calls back into
/// the relay processor.
@MainActor
final class AskAnswerHandler {
    typealias Answer = @MainActor (OwnerAsk, OwnerAskAnswer) async -> OwnerAsksViewModel.AnswerOutcome

    /// Ample for a delivery's state reads and its submit pause.
    nonisolated static let defaultTimeout: Duration = .seconds(30)
    static let timeoutMessage = "The Mac did not finish this answer in time — check the ask on the Mac"
    private static let logger = Logger(subsystem: Constants.bundleID, category: "AskAnswerHandler")

    private let dbPool: DatabasePool
    private let sidecar: HubSyncState
    private let answer: Answer
    private let timeout: Duration
    private let sleep: @Sendable (Duration) async -> Void

    init(
        dbPool: DatabasePool,
        sidecar: HubSyncState,
        timeout: Duration = AskAnswerHandler.defaultTimeout,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        answer: @escaping Answer
    ) {
        self.dbPool = dbPool
        self.sidecar = sidecar
        self.timeout = timeout
        self.sleep = sleep
        self.answer = answer
    }

    /// The echo of one `ask_answer`. A timeout is `outcome_unknown`: the
    /// answer may still land (it is never cut mid-write or mid-delivery).
    func handle(_ action: ActionRequestPayload) async throws -> ActionOutcome {
        try await withHandlerTimeout(timeout, sleep: sleep, message: Self.timeoutMessage) { try await self.apply(action) }
    }

    private func apply(_ action: ActionRequestPayload) async throws -> ActionOutcome {
        guard let askID = action.entityID.flatMap(Int64.init),
              case let .integer(workbenchID)? = action.params["workbench_id"],
              case let .object(fields)? = action.params["answer"] else {
            return .failed(.invalidParams, message: "ask_answer needs an ask id, workbench_id and answer")
        }
        // Scope first (spec §5.2 rule 3). A read error is not "not found":
        // it throws, echoed write_failed.
        guard let ask = try await dbPool.read({ try OwnerAskQueries.ask($0, id: askID, projectID: workbenchID) }) else {
            return .failed(.notFound, message: "No such ask on this workbench")
        }
        let value: OwnerAskAnswer
        do {
            let data = try JSONEncoder().encode(JSONValue.object(fields))
            value = try JSONDecoder().decode(OwnerAskAnswer.self, from: data)
        } catch {
            return .failed(.invalidAnswer, message: "The answer could not be read: \(error.localizedDescription)")
        }
        guard ask.isOpen else { return try rerun(action, ask: ask, value: value) }
        let outcome = await answer(ask, value)
        if case let .stored(delivery) = outcome { remember(delivery, of: action) }
        return Self.outcome(outcome)
    }

    /// An ask no longer open: `applied` again when it holds this very
    /// answer (answered, or since delivered by the brief), echoing the
    /// delivery the sidecar kept — none when the hub stopped before keeping
    /// it; otherwise `ask_not_open`.
    private func rerun(_ action: ActionRequestPayload, ask: OwnerAsk, value: OwnerAskAnswer) throws -> ActionOutcome {
        guard ask.status == .answered || ask.status == .delivered,
              ask.answer == value.normalized(for: ask) else { return .failed(.askNotOpen) }
        guard let delivery = try sidecar.askAnswerDelivery(for: action.recordName) else { return .applied() }
        return .applied(["delivery": .string(delivery)])
    }

    /// Kept right after the store, before the echo. A failure only costs a
    /// re-run its `delivery` key; the answer itself is stored, so the
    /// echo stays `applied`.
    private func remember(_ delivery: OwnerAsksViewModel.Delivery, of action: ActionRequestPayload) {
        do {
            try sidecar.recordAskAnswerDelivery(Self.wire(delivery), for: action.recordName, at: Date())
        } catch {
            Self.logger.warning(
                "ask answer \(action.recordName, privacy: .public): delivery not kept: \(error.localizedDescription, privacy: .public)"
            )
        }
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
}

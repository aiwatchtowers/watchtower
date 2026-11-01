import Foundation
import WatchtowerKit
import WatchtowerSync

extension DemoSeed {
    /// The outbox state of relay client mockup 5a, for the screenshot tour only (the app's demo hub stays on
    /// today's path): two actions under Not delivered — a move withdrawn after 24 h without an answer, then an
    /// answer the transport refused for good — and three queued behind a flush that stopped (no network). Each is
    /// enqueued through the demo session's own outbox, so it is sealed with the demo keys like any phone action.
    ///
    /// `setClock` moves the session's clock (the withdrawal needs a day-old action); `refuse` sets the refusal the
    /// demo transport answers every conditional save with, nil to let them through. The clock ends at `now` and the
    /// transport keeps refusing (`unreachable`), so the queue stays waiting.
    static func loadOutboxDemo(
        outbox: ActionOutbox,
        now: Date,
        setClock: @Sendable (Date) -> Void,
        refuse: @Sendable (TransportRefusal?) async -> Void
    ) async throws {
        try await outbox.enableOrderedActions()
        let workbench = acmeID

        // Withdrawn after 24 h: queued yesterday behind no network, swept today.
        await refuse(.unreachable)
        setClock(now.addingTimeInterval(-25 * 3_600))
        try await enqueue(
            outbox, .boardTargetStatus, SliceKind.workbenchTarget.recordName(id: "416"),
            BoardTargetStatusParams(workbenchID: workbench, status: .done, fromStatus: .todo))
        setClock(now.addingTimeInterval(-240))
        _ = try await outbox.sweepSilentPending()

        // Refused for good: the zone is gone.
        await refuse(.permanent(code: "zone_gone"))
        try await enqueue(
            outbox, .askAnswer, SliceKind.ownerAsk.recordName(id: "109"),
            AskAnswerParams(workbenchID: workbench, answer: OwnerAskAnswer(answers: [.init(id: "q1", labels: ["Archive Now"])])))

        // Waiting to send: the flush stops on the first of them.
        await refuse(.unreachable)
        setClock(now.addingTimeInterval(-180))
        try await enqueue(
            outbox, .boardCommentAdd, SliceKind.workbenchTarget.recordName(id: "415"),
            BoardCommentAddParams(workbenchID: workbench, body: "Menu wording looks right."))
        setClock(now.addingTimeInterval(-120))
        try await enqueue(
            outbox, .sessionInput, SliceKind.terminalSession.recordName(id: "10"), SessionInputParams(text: "Run the tests again"))
        setClock(now.addingTimeInterval(-60))
        try await enqueue(
            outbox, .boardTargetStatus, SliceKind.workbenchTarget.recordName(id: "421"),
            BoardTargetStatusParams(workbenchID: workbench, status: .done, fromStatus: .blocked))
        setClock(now)
    }

    /// One action, then the flush it asked for, so each lands in its state before the next.
    private static func enqueue(_ outbox: ActionOutbox, _ kind: ActionKind, _ entity: String, _ params: some ActionParams) async throws {
        _ = try await outbox.enqueue(kind: kind, entityRecordName: entity, params: try params.wireParams())
        _ = try await outbox.flush()
    }
}

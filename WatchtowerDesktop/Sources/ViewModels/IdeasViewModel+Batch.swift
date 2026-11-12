import Foundation
import os
import WatchtowerCore

/// How an Idea finder press ended (`IdeasViewModel.press(_:on:then:)`).
enum IdeaBatchPressOutcome: Equatable {
    /// The verdict landed; Make a Target… carries the new target's id.
    case landed(targetID: Int?)
    /// The write failed; the text is the press's own, for the card's line.
    case failed(String)
    /// Another write on this idea was pending: nothing was written.
    case didNotRun
}

extension IdeasViewModel {
    /// The Idea finder card's verdict (spec "Idea finder (phase 3)"): Keep →
    /// `active`, Drop → `rejected` (never `dropped`, which is Clear Old
    /// Ideas'), Later → `not_now` with no date, Make a Target… → the idea
    /// converted into a new target. Each clears the review flag (IDEA-04).
    ///
    /// Runs under the idea's verdict key (`InboxIdeaPane.writeKey`), the one
    /// the Inbox's idea card uses too, and Make a Target… under the
    /// conversion's key as well: a press while either is pending does
    /// nothing (`.didNotRun`), so K K or K then D writes one verdict. `then`
    /// (the Inbox's re-read) runs after a write that ran, still under the
    /// key, as `InboxIdeaPane.actions` does: a card still shown from before
    /// the re-read cannot be judged twice. A failure's text is returned, not
    /// put in `errorMessage`, which the Ideas lists show.
    func press(
        _ press: IdeaBatchPress, on idea: Idea, then afterWrite: @MainActor () async -> Void = {}
    ) async -> IdeaBatchPressOutcome {
        let outcome = await pendingWrites.run(InboxIdeaPane.writeKey(idea.id)) { () -> IdeaBatchPressOutcome in
            let outcome: IdeaBatchPressOutcome
            switch press {
            case .keep:
                outcome = Self.outcome(await attempt("approve idea") { db in
                    try IdeaQueries.setStatus(db, id: idea.id, status: "active")
                })
            case .drop:
                outcome = Self.outcome(await attempt("reject idea") { db in
                    try IdeaQueries.setStatus(db, id: idea.id, status: "rejected")
                })
            case .later:
                outcome = Self.outcome(await attempt("snooze idea") { db in
                    try IdeaQueries.snooze(db, id: idea.id, until: nil)
                })
            case .makeTarget:
                let converted = await pendingWrites.run(Self.convertKey(idea.id)) { await convert(idea) }
                switch converted {
                case .success(let targetID)?: outcome = .landed(targetID: targetID)
                case .failure(let failure)?: outcome = .failed(failure.message)
                case nil: outcome = .didNotRun
                }
            }
            if outcome != .didNotRun { await afterWrite() }
            return outcome
        }
        return outcome ?? .didNotRun
    }

    /// The batch card's own press is writing: its verdict key or, for Make
    /// a Target…, its conversion.
    func isPressing(_ ideaID: Int) -> Bool {
        pendingWrites.isPending(InboxIdeaPane.writeKey(ideaID)) || pendingWrites.isPending(Self.convertKey(ideaID))
    }

    /// An Idea finder card's quotes and source; nil on a failed read,
    /// logged (the card leaves them out).
    func facts(for ideaID: Int) async -> IdeaBatchCardFacts? {
        do {
            return try await dbManager.dbPool.read { db in try IdeaBatchCardFacts.read(db, ideaID: ideaID) }
        } catch {
            InboxLog.logger.error("idea facts read failed for idea \(ideaID): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func outcome(_ result: Result<Void, IdeaWriteFailure>) -> IdeaBatchPressOutcome {
        switch result {
        case .success: .landed(targetID: nil)
        case .failure(let failure): .failed(failure.message)
        }
    }
}

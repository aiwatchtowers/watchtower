import Foundation
import WatchtowerCore

/// What a context action row (the Context block's Do these, the Accepted
/// edits log's session rows) needs besides the proposals: the coach, where
/// the workbench's sessions are, and how to start or open one.
@MainActor
struct ContextActionsInputs {
    let coach: CoachCenter
    let workbench: Int64
    /// `WorkbenchesViewModel.coachSessionKinds`: the workbench's session rows.
    let sessionKinds: [Int64: SessionSwitcherPresentation.State.Kind]
    /// The sessions whose process runs (a started one counts as starting
    /// until it is here).
    let liveSessions: Set<Int64>
    /// The workbench's GitHub repository, for a PR link the CLI did not give.
    let repository: URL?
    /// Starts a session (workbench, title, prompt) → its id, nil on failure.
    let startSession: (Int64, String, String) async -> Int64?
    let openSession: (Int64) -> Void

    /// The Context block's rows.
    func rows(_ context: AgentContextReport, now: Date = Date()) -> (doThese: [ContextActionRow], done: [ContextActionRow]) {
        ContextActionsPresentation.rows(
            proposals: coach.proposals?.value ?? [], workbenchID: workbench, sources: context.sources ?? [],
            sessionKinds: sessionKinds, linkFailed: coach.linkFailed, now: now,
            starting: coach.starting(live: liveSessions, now: now), errors: coach.cardErrors, repository: repository,
            revertSessions: coach.revertSessions
        )
    }

    /// A proposal of any origin accepted through a session, as a row (the
    /// Accepted edits log); nil for one that is not.
    func row(for p: CoachProposal, now: Date = Date()) -> ContextActionRow? {
        guard p.viaSession, p.status == "accepted" else { return nil }
        return ContextActionsPresentation.row(
            of: p, sessionKinds: sessionKinds, linkFailed: coach.linkFailed,
            starting: coach.starting(live: liveSessions, now: now), errors: coach.cardErrors, repository: repository,
            revertSessions: coach.revertSessions
        )
    }

    /// A row's button: the session or the PR page at once, a coach verb in
    /// a task. Undo whose destination changed since hands its diff to
    /// `rollback` (the Roll Back sheet).
    func perform(
        _ action: ContextActionRow.Action,
        _ row: ContextActionRow,
        openURL: (URL) -> Void,
        rollback: @escaping (CoachRollbackPrompt) -> Void
    ) {
        switch action {
        case .openSession:
            if let session = Self.session(of: row) { openSession(session) }
        case .openPR:
            if let url = row.prLink { openURL(url) }
        case .showDiff:
            if let url = row.diffURL { openURL(url) }
        case .undo:
            Task { [coach] in
                if let diff = await coach.rollback(row.id, force: false) {
                    rollback(CoachRollbackPrompt(proposal: row.proposal, diff: diff))
                }
            }
        default:
            let workbench = row.proposal.workbenchID == 0 ? self.workbench : row.proposal.workbenchID
            Task { [coach, startSession] in
                await Self.run(action, id: row.id, coach: coach) { await startSession(workbench, $0, $1) }
            }
        }
    }

    /// The coach verb behind a button; a session one starts with `start`.
    static func run(
        _ action: ContextActionRow.Action, id: Int64, coach: CoachCenter, start: @escaping (String, String) async -> Int64?
    ) async {
        switch action {
        case .turnOff: await coach.accept(id, editedText: nil)
        case .accept, .archive: await coach.acceptThroughSession(id, start: start)
        case .decline: await coach.decline(id)
        case .retryLink: await coach.retryLink(id)
        case .startAgain: await coach.restartThroughSession(id, start: start)
        case .dismiss: await coach.dismiss(id)
        case .turnOffAgain: await coach.reapply(id)
        case .revert: await coach.revertThroughSession(id, start: start)
        case .openSession, .openPR, .showDiff, .undo: break
        }
    }

    /// The session a row's Open Session opens.
    static func session(of row: ContextActionRow) -> Int64? {
        switch row.state {
        case let .working(session), let .linkFailed(session), let .reverting(session): return session
        case let .endedWithoutChange(session): return session
        default: return nil
        }
    }
}

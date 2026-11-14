import Foundation
import WatchtowerCore

/// The workbench sessions coach proposals start (context actions, spec
/// 2026-11-12 C6): a repository or memory Accept, Start Again and Revert…
/// each start one through `CoachCenter`, which records it with the CLI.
extension WorkbenchesViewModel {
    /// Starts a Claude Code session of workbench `id` with the coach's
    /// brief, beside its Analytics pane; nil when it did not start (the
    /// start path reports why on the workbench). Claude Code, not the
    /// default agent: the brief changes Claude Code's own start context
    /// (CLAUDE.md, its memory index).
    func startCoachSession(workbench id: Int64, title: String, prompt: String) async -> Int64? {
        guard let project = await project(id: id) else { return nil }
        let session = await startNewSession(
            project: project, title: title, prompt: prompt, placement: .keeping(.analytics), agent: .claude
        )
        return session?.id
    }

    /// The state of each session row of workbench `projectID` the Desktop
    /// has, as the sessions panel shows it; nil until the list was read.
    func coachSessionKinds(projectID: Int64) -> [Int64: SessionSwitcherPresentation.State.Kind]? {
        guard let sessions = terminalSessions[projectID] else { return nil }
        let live = terminalCenter?.liveIDs ?? []
        let statuses = sessionStatuses
        return Dictionary(uniqueKeysWithValues: sessions.map { session in
            (session.id, SessionSwitcherPresentation.state(of: session.id, liveIDs: live, statuses: statuses).kind)
        })
    }

    /// Drops each `coach.linkFailed` entry whose session row is gone from
    /// the database. A failed read keeps the entry: an unreadable row is
    /// not a missing one.
    func forgetGoneCoachLinks() async {
        guard let coach, !coach.linkFailed.isEmpty else { return }
        for (id, session) in coach.linkFailed {
            let exists: Bool
            do {
                exists = try await dbPool.read { try TerminalSessionQueries.fetch($0, id: session) } != nil
            } catch {
                continue
            }
            if !exists { coach.forgetLink(id, session: session) }
        }
    }
}

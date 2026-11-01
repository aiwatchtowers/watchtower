import Foundation
import GRDB
import WatchtowerCore

/// The workbench side of the one-time v1-host restart (`HostRestartStep`,
/// go hub spec §8 p. 4b): the rows a restart list names, and their
/// relaunch with resume.
extension WorkbenchesViewModel {
    static let hostRestartDidNotStart = "[Watchtower] This session did not restart after the update."
    static let hostRestartCodexUnchecked = "Could not check Codex's saved sessions: Codex's home folder is not known."

    /// The rows of these ids that still exist in this workspace, by id.
    func hostRestartRows(_ ids: [Int64]) async throws -> [Int64: TerminalSession] {
        try await dbPool.read { db in
            var found: [Int64: TerminalSession] = [:]
            for id in Set(ids) {
                if let row = try TerminalSessionQueries.fetch(db, id: id) { found[id] = row }
            }
            return found
        }
    }

    /// Relaunches a listed row with resume (Claude `--resume`, Codex
    /// `resume`) in the background. A row with no conversation to resume is
    /// never started anew: it ends in the resume-failure state (Start fresh
    /// offered). A launch that does not run leaves the row stopped with its
    /// reason in the pane; nothing here is an exit of the session's own, so
    /// no PROJ-18 cleanup follows.
    func relaunchAfterHostRestart(rowID: Int64) async -> HostRestartRelaunch {
        guard let center = terminalCenter else { return .failed(Self.hostRestartDidNotStart) }
        let fetched: TerminalSession?
        do {
            fetched = try await dbPool.read { try TerminalSessionQueries.fetch($0, id: rowID) }
        } catch {
            return .failed("Could not read the session: \(error.localizedDescription)")
        }
        guard let row = fetched else { return .rowGone }
        if center.liveIDs.contains(row.id) { return .launched }
        switch await hasConversationToResume(row, center: center) {
        case let .failure(failure):
            center.refuseLaunch(row, reason: failure.reason)
            return .failed(failure.reason)
        case .success(false):
            center.showResumeFailure(row)
            resumeFailed.insert(row.id)
            await loadSessions(projectID: row.projectID)
            return .noConversation
        case .success(true):
            break
        }
        await open(row, placement: .background)
        if center.liveIDs.contains(row.id) { return .launched }
        if case let .unavailable(reason)? = center.states[row.id] { return .failed(reason) }
        center.refuseLaunch(row, reason: Self.hostRestartDidNotStart)
        return .failed(Self.hostRestartDidNotStart)
    }

    /// Whether the row's agent has a conversation to resume: Claude Code's
    /// transcript, Codex's rollout (at its stored path, else in the login
    /// shell's Codex home). A shell has nothing to resume and just opens.
    private func hasConversationToResume(
        _ row: TerminalSession, center: TerminalCenter
    ) async -> Result<Bool, HostRestartCheckFailure> {
        switch row.kind {
        case .shell:
            return .success(true)
        case .claude:
            return .success(center.hasTranscript(row))
        case .codex:
            do {
                if try center.codexResumes(row, codexHome: nil) { return .success(true) }
                guard let home = await resolveCodexHome() else {
                    return .failure(HostRestartCheckFailure(Self.hostRestartCodexUnchecked))
                }
                return .success(try center.codexResumes(row, codexHome: home))
            } catch {
                return .failure(HostRestartCheckFailure("Could not check Codex's saved sessions: \(error.localizedDescription)"))
            }
        }
    }
}

/// A conversation check that could not answer (not "no conversation").
struct HostRestartCheckFailure: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

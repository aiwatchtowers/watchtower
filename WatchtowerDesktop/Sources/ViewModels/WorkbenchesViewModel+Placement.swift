import Foundation
import WatchtowerCore

/// Where a new workbench agent session starts (board #229, spec
/// 2026-10-14-session-worktrees-design.md §4, §7): the main folder, or —
/// when a live agent already works there, or the owner asks — its own git
/// worktree made by `watchtower workbench worktree create`.
extension WorkbenchesViewModel {
    /// The folder a new row is inserted with, its worktree branch and base
    /// (nil in the main folder), and the line `startNotice` shows (nil =
    /// nothing to say).
    typealias NewSessionPlacement = (folderPath: String, worktreeBranch: String?, worktreeBase: String?, notice: String?)

    /// Decides and, for a worktree, makes it. Never fails: a worktree that
    /// could not be made starts the session in the folder with a notice
    /// saying why. The folder's git status is read only when a worktree is
    /// wanted.
    func placementForNewSession(
        project: Workbench, choice: WorktreeChoice, targetID: Int64?, targetText: String?
    ) async -> NewSessionPlacement {
        let folder = project.folderPath
        let working = workingAgentRows(projectID: project.id)
        let occupied = working.contains { row in
            SessionStartPlacement.occupies(
                row: row, place: sessionPlaces.currentPlace(sessionID: row.id), workbenchFolder: folder
            )
        }
        var status: WorkbenchGitStatus?
        if choice == .worktree || (choice == .auto && occupied), let cli {
            do {
                status = try await cli.gitStatus(projectID: project.id)
            } catch {
                NSLog("WorkbenchesViewModel: git status for workbench %lld before a start failed: %@",
                      project.id, error.localizedDescription)
            }
        }
        switch SessionStartPlacement.decide(choice: choice, gitStatus: status, occupied: occupied) {
        case let .folder(note):
            return (folder, nil, nil, note)
        case .worktree:
            // `decide` gives `.worktree` only with a status, which needs `cli`.
            guard let cli else { return (folder, nil, nil, "Started in the folder: no CLI is available.") }
            let slug = SessionStartPlacement.slug(
                targetID: targetID, targetText: targetText, sessionNumber: working.count + 1
            )
            let made: WorktreeCreateResult
            do {
                made = try await cli.worktreeCreate(projectID: project.id, name: slug)
            } catch {
                return (folder, nil, nil, "Started in the folder: \(error.localizedDescription)")
            }
            guard made.created else {
                let reason = [made.refusedDetail, made.error, made.refused].first { !$0.isEmpty }
                return (folder, nil, nil, "Started in the folder: \(reason ?? "the worktree could not be made.")")
            }
            return (made.cwd, made.branch, made.base, Self.worktreeNotice(made))
        }
    }

    /// Why "In Its Own Worktree" is disabled, from the header's last git
    /// status (no new read); nil when one can be made or none was read yet
    /// (the start then reads it and says why on `startNotice`).
    func worktreeUnavailableReason(projectID: Int64) -> String? {
        gitStatus[projectID].flatMap(SessionStartPlacement.unavailableReason)
    }

    /// Runs `body` as the workbench's placement turn: after every earlier
    /// start's turn ended. Main actor only, so the queue needs no lock.
    func inPlacementTurn<T>(_ projectID: Int64, _ body: () async throws -> T) async rethrows -> T {
        let previous = placementTurns[projectID]
        let (ended, end) = AsyncStream<Void>.makeStream()
        let turn = Task { for await _ in ended {} }
        placementTurns[projectID] = turn
        defer {
            end.finish()
            if placementTurns[projectID] == turn { placementTurns[projectID] = nil }
        }
        await previous?.value
        return try await body()
    }

    /// The workbench's live agent rows and the ones a start inserted and is
    /// still launching.
    private func workingAgentRows(projectID: Int64) -> [TerminalSession] {
        var rows: [Int64: TerminalSession] = [:]
        for row in startingRows.values where row.projectID == projectID && row.kind.isAgent {
            rows[row.id] = row
        }
        for row in terminalCenter?.liveAgentRows(ofWorkbench: projectID) ?? [] {
            rows[row.id] = row
        }
        return Array(rows.values)
    }

    /// One line for a made worktree: the missing uncommitted changes, then
    /// the first thing that went wrong after it existed.
    private static func worktreeNotice(_ made: WorktreeCreateResult) -> String? {
        var parts: [String] = []
        if made.baseDirty { parts.append("The new worktree does not have the folder's uncommitted changes.") }
        if let warning = (made.includeWarnings + [made.warning, made.integrationError]).first(where: { !$0.isEmpty }) {
            parts.append("Worktree: \(warning)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

import Foundation
import WatchtowerCore

/// A Fix session started from the drift popover: for one finding
/// (`targetID`) or, nil, for all of them.
struct DriftFixSession: Equatable {
    let targetID: Int64?
    let sessionID: Int64
}

extension WorkbenchesViewModel {
    /// The title of the all-findings session.
    static let driftFixTitle = "Fix board drift"

    /// The agent states that end a Fix: its turn is over and the agent sits
    /// at its prompt (or called `finish_session`). A Fix waiting on the
    /// owner (an ask, an approval) or with background agents still works.
    static let driftFixDoneKinds: Set<SessionSwitcherPresentation.State.Kind> = [
        .stopped, .finished, .failed, .readyToCheck
    ]

    /// The working Fix session the popover button should open instead of
    /// starting another, newest first: for the header (`targetID` nil) the
    /// all-findings session; for a row its own session or the all-findings
    /// one, which covers it too.
    func liveDriftFix(projectID: Int64, targetID: Int64? = nil) -> Int64? {
        driftFixSessions[projectID]?.last { fix in
            (fix.targetID == nil || fix.targetID == targetID) && driftFixWorking(fix.sessionID)
        }?.sessionID
    }

    /// A Fix works while its process runs and its agent has not ended the
    /// turn; a session with no agent state yet (just started) works.
    private func driftFixWorking(_ sessionID: Int64) -> Bool {
        guard terminalCenter?.states[sessionID] == .running else { return false }
        guard let kind = agentStates?.statuses[sessionID]?.state.kind else { return true }
        return !Self.driftFixDoneKinds.contains(kind)
    }

    /// Fix for every finding (`targetID` nil) or one: a working Fix session
    /// is opened, else a new agent session of the workbench starts with
    /// `TerminalLaunch.driftFixPrompt`. A press while a start of the same
    /// workbench is in flight starts nothing. A start failure is reported
    /// by the start path itself.
    func fixDrift(projectID: Int64, findings: [WorkbenchDriftFinding], targetID: Int64? = nil) async {
        if let live = liveDriftFix(projectID: projectID, targetID: targetID) {
            await showSession(id: live)
            return
        }
        let chosen = targetID.map { id in findings.filter { Int64($0.targetID) == id } } ?? findings
        guard !chosen.isEmpty, !startingDriftFix.contains(projectID) else { return }
        startingDriftFix.insert(projectID)
        defer { startingDriftFix.remove(projectID) }
        let prompt = TerminalLaunch.driftFixPrompt(workbenchID: projectID, findings: chosen)
        let started: TerminalSession?
        if let targetID {
            started = try? await startForTarget(
                targetID: targetID, prompt: prompt, mode: .new, placement: .keeping(.board)
            )
        } else {
            let ticket = beginSwitch(projectID: projectID)
            guard let project = await project(id: projectID) else { return }
            started = await startNewSession(
                project: project, title: Self.driftFixTitle, prompt: prompt, ticket: ticket, agent: currentDefaultAgent()
            )
        }
        guard let started else { return }
        driftFixSessions[projectID, default: []].append(.init(targetID: targetID, sessionID: started.id))
    }
}

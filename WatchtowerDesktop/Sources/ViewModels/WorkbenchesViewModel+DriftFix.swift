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

    /// The running Fix session the popover button should open instead of
    /// starting another: for `targetID` its own, for nil (the header) the
    /// newest of the workbench. A session whose process ended is done.
    func liveDriftFix(projectID: Int64, targetID: Int64? = nil) -> Int64? {
        driftFixSessions[projectID]?.last { fix in
            (targetID == nil || fix.targetID == targetID) && terminalCenter?.states[fix.sessionID] == .running
        }?.sessionID
    }

    /// Fix for every finding (`targetID` nil) or one: a live Fix session is
    /// opened, else a new agent session of the workbench starts with
    /// `TerminalLaunch.driftFixPrompt`. A start failure is reported by the
    /// start path itself.
    func fixDrift(projectID: Int64, findings: [WorkbenchDriftFinding], targetID: Int64? = nil) async {
        if let live = liveDriftFix(projectID: projectID, targetID: targetID) {
            await showSession(id: live)
            return
        }
        let chosen = targetID.map { id in findings.filter { Int64($0.targetID) == id } } ?? findings
        guard !chosen.isEmpty else { return }
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

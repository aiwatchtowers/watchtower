import Foundation

/// Which sessions get the one-gesture delete (✕ and ⌘⌫ without a dialog,
/// board #480, spec 2026-10-12-sessions-panel-design §4.1); the rest go
/// through the confirmation. The ✕ is shown exactly when `isQuick`.
package enum SessionDeletePolicy {
    /// A workbench session that is not live → quick, whatever its ring says
    /// (there is no process to kill). A live one → quick only once its agent
    /// is done: finished, stopped, failed. A live session working, at a
    /// permission prompt, running with no reported state, with background
    /// agents, waiting on an ask or ready to check asks first. A standalone terminal has no
    /// state and keeps its dialog.
    package static func isQuick(_ state: SessionSwitcherPresentation.State, isWorkbenchSession: Bool) -> Bool {
        guard isWorkbenchSession else { return false }
        guard state.live else { return true }
        switch state.kind {
        case .finished, .stopped, .failed:
            return true
        case .notStarted, .running, .working, .needsApproval, .waitingOnAsk, .readyToCheck, .background:
            return false
        }
    }
}

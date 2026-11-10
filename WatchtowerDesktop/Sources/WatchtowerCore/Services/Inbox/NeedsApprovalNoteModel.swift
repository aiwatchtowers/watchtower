import Foundation

/// Needs approval's note press (spec "Needs approval" → States; plan Task
/// 12): **Turn On** on the off and stopped notes runs the built-in card's own
/// Turn On (`AppState.setBuiltinEnabled(["approval-cards"], on: true)`,
/// handed in as `turnOn`) once; **Run History** opens the latest failed run.
/// Owned by `ActionStripViewModel` (on `AppState`), so a Turn On still
/// running when the Inbox leaves the screen lands in the state the Inbox
/// finds on return. The reason a Turn On returned is its own `failure`,
/// never the feature manager's shared `loadError`.
@MainActor
@Observable
package final class NeedsApprovalNoteModel {
    /// The reason the last Turn On returned, and the note it was pressed on.
    package private(set) var failure: (state: NeedsApprovalNoteContent.State, reason: String)?
    /// A Turn On under way: the button waits.
    package private(set) var isApplying = false

    package init() {}

    /// The note for `state` (nil: no note); a failure shows only under the
    /// note it was pressed on.
    package func content(_ state: NeedsApprovalNoteContent.State?) -> NeedsApprovalNoteContent? {
        guard let state else { return nil }
        let reason = failure.flatMap { $0.state == state ? $0.reason : nil }
        return NeedsApprovalNoteContent(state: state, failure: reason, isApplying: isApplying)
    }

    /// Turn On: one call; a reason stays under the note, nil re-reads the
    /// Inbox (the note leaves once the read sees the feature on and the
    /// built-in not stopped — or stays, with no message, when another apply
    /// won the race and nothing changed). A second press while one runs is
    /// ignored.
    package func turnOn(
        on state: NeedsApprovalNoteContent.State,
        _ turnOn: () async -> String?,
        refresh: () async -> Void
    ) async {
        guard !isApplying else { return }
        isApplying = true
        failure = nil
        defer { isApplying = false }
        if let reason = await turnOn() {
            failure = (state, reason)
        } else {
            await refresh()
        }
    }

    /// Run History's target: the built-in's card with its latest failed run
    /// open, or the card alone when none is left (pruned).
    package static func runHistory(_ state: NeedsApprovalState) -> (automationID: Int64, runID: Int64?)? {
        state.automationID.map { ($0, state.latestFailedRunID) }
    }
}

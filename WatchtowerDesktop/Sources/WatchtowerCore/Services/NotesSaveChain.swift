import Foundation

/// Orders a recording pane's notes saves and coalesces them (board #590).
///
/// Each save waits for the one before it (`enqueue` returns that task), so an
/// older draft never lands after a newer one. When a save's turn comes it
/// writes only if it is still the newest save queued for its recording
/// (`isNewest`): a draft overtaken while it waited is skipped. A save for
/// another recording never makes this one skip — one pane can show several
/// recordings in turn, and each recording's newest draft must land.
///
/// A reference type on purpose: the final flush's task outlives the view,
/// so it holds the chain itself rather than reading the view's `@State`.
@MainActor
package final class NotesSaveChain {
    /// The save handed over last; the next one awaits it.
    package var last: Task<Void, Never>?
    private var issued = 0
    private var newest: [Int64: Int] = [:]

    package init() {}

    /// The task to await before writing, and this save's ticket.
    package func enqueue(_ recordingID: Int64) -> (previous: Task<Void, Never>?, ticket: Int) {
        issued += 1
        newest[recordingID] = issued
        return (last, issued)
    }

    package func isNewest(_ ticket: Int, for recordingID: Int64) -> Bool {
        newest[recordingID] == ticket
    }
}

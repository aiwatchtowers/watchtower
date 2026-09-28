import Foundation
import WatchtowerCore

/// App-wide owner of meeting-prep state, living on AppState so a `meeting-prep`
/// run (a strong-tier CLI call taking tens of seconds) and its result survive
/// navigation — the Day Plan and Calendar screens used to hold the VM in view
/// `@State`, so leaving the tab dropped the result while the CLI kept running.
///
/// One `MeetingPrepViewModel` per event id: a screen never shows another
/// event's prep, and the VM's own in-flight guard keeps a second click (or a
/// return to a still-running prep) from starting a parallel run.
@MainActor
@Observable
final class MeetingPrepCenter {
    /// Not observed: views observe the per-event VM itself, and handing one
    /// out from a view body must not count as a state mutation.
    @ObservationIgnored private var sessions: [String: MeetingPrepViewModel] = [:]
    @ObservationIgnored private let makeRunner: () -> (any CLIRunnerProtocol)?

    init(makeRunner: @escaping () -> (any CLIRunnerProtocol)? = { ProcessCLIRunner.makeDefault() }) {
        self.makeRunner = makeRunner
    }

    /// The prep VM for `eventID`, created on first use and kept for the app's
    /// lifetime (a handful of small results — one per event the owner prepped).
    func viewModel(for eventID: String) -> MeetingPrepViewModel {
        if let existing = sessions[eventID] { return existing }
        let vm = MeetingPrepViewModel(makeRunner: makeRunner)
        sessions[eventID] = vm
        return vm
    }
}

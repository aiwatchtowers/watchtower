import Foundation
import WatchtowerCore

/// How a Desktop start waits for the run Go's `workbench session start`
/// launches (Go hub 3 Task 8): the session host's list (each request bounded
/// by `SessionHostClient.replyTimeout`) and the row are asked every `poll`
/// until `deadline` of wall-clock time has passed — a little over the
/// detached finish's 3-minute budget. `sleep` is a seam for tests.
struct GoSessionStartWait {
    var poll: Duration = .milliseconds(200)
    var deadline: Duration = .seconds(200)
    /// The `workbench session start` call's own limit (it answers at once).
    var cliTimeout: TimeInterval = 30
    var sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    /// The pane's reason when no run and no failure came within the wait.
    static let timedOutReason = "the session did not start in time"
    /// The pane's reason when Go recorded a failure without one.
    static let noReason = "the session did not start"
}

/// Where Go's start of a row ended, as the Desktop sees it.
enum GoLaunchOutcome: Equatable {
    /// The run the session host holds for the row (possibly exited already).
    case launched(SessionHostSessionInfo)
    /// Go recorded the start's failure on the row (or none came in time).
    case failed(String)
    /// The row is gone, or waits in the Undo batch (PROJ-17): it never
    /// shows; `run` is the run Go launched meanwhile, which is stopped.
    case deleted(run: SessionHostSessionInfo?)
}

import Foundation
import WatchtowerCore

/// How a Desktop start waits for the run Go's `workbench session start`
/// launches (Go hub 3 Task 8): the session host's list and the row are asked
/// every `poll`, `polls` times — together a little over the detached
/// finish's 3-minute budget. `sleep` is a seam for tests.
struct GoSessionStartWait {
    var poll: Duration = .milliseconds(200)
    var polls = 1000
    var sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    /// The pane's reason when no run and no failure came within the wait.
    static let timedOutReason = "the session did not start in time"
    /// The pane's reason when Go recorded a failure without one.
    static let noReason = "the session did not start"
}

/// Where Go's start of a row ended, as the Desktop sees it.
enum GoLaunchOutcome: Equatable {
    /// The run the session host holds for the row.
    case launched(SessionHostSessionInfo)
    /// Go recorded the start's failure on the row (or none came in time).
    case failed(String)
    /// The row is gone: the owner deleted it, or Go could not place it.
    case gone
}

import Foundation
import Observation
import WatchtowerCore

/// The Morning brief's **Make a Task** state (R9), held on AppState so it
/// outlives the pane: one press at a time across the whole brief, and the
/// last failure kept with the brief it belongs to. The pane draws that
/// failure once, at its top, and only while that brief is on screen; a
/// failure that lands after the owner stepped to another day is still there
/// when they step back.
@MainActor
@Observable
final class BriefMakeTaskModel {
    struct Failure: Equatable {
        let briefingID: Int
        let message: String
    }

    /// A press is running; every Make a Task button is disabled.
    private(set) var running = false
    private(set) var failure: Failure?

    /// The failure to show over `briefingID`'s pane, or nil.
    func message(for briefingID: Int?) -> String? {
        guard let failure, failure.briefingID == briefingID else { return nil }
        return failure.message
    }

    func dismiss() {
        failure = nil
    }

    /// Runs one Make a Task of `briefingID`'s brief through `run`, which
    /// returns the failure to show, or nil. A press while one runs does nothing.
    func press(
        _ source: BriefingTaskSource,
        briefingID: Int,
        run: (BriefingTaskSource) async -> String?
    ) async {
        guard !running else { return }
        running = true
        failure = nil
        let message = await run(source)
        running = false
        failure = message.map { Failure(briefingID: briefingID, message: $0) }
    }
}

/// What a brief's Jira key badges need: read once per pane, not per section.
struct BriefingJiraLinks: Equatable {
    var connected = false
    var siteURL: String?

    /// A directory listing and a database read, both off the main thread.
    static func load() async -> Self {
        let connected = await Task.detached { JiraQueries.isConnected() }.value
        return Self(connected: connected, siteURL: await JiraConfigHelper.siteURL())
    }
}

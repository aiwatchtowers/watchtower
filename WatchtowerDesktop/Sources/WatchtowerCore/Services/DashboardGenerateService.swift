import Foundation

/// Bridges the Desktop app to `watchtower inbox generate` — the on-demand assistant
/// pipeline run (detectors → triage → cards → situation composer) triggered from the
/// Dashboard's "Generate" button/empty-state action, instead of waiting for the
/// daemon's next cycle. Mirrors `TrackComposeService`.
package struct DashboardGenerateService {
    package let runner: CLIRunnerProtocol

    package init(runner: CLIRunnerProtocol) {
        self.runner = runner
    }

    /// Runs the pipeline and waits for it to finish. Throws `CLIRunnerError` on
    /// nonzero exit or launch failure. Stdout is discarded — the caller reloads
    /// the feed from disk rather than parsing a result payload.
    package func generate() async throws {
        _ = try await runner.run(args: ["inbox", "generate"])
    }
}

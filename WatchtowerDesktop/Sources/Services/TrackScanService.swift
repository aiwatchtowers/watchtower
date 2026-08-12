import Foundation
import WatchtowerCore

/// Bridges the Desktop app to `watchtower tracks scan <id>`, which force-runs a
/// custom track's scan and prints the new events as JSON. Used for manual
/// "refresh now"; the daemon produces events automatically otherwise.
/// Ported from the removed `TargetObserveService`.
struct TrackScanService {
    let runner: CLIRunnerProtocol

    /// Force-runs the custom track's scan. When `since` is non-nil, scans
    /// history from that ISO8601 instant (the "Scan history" action) instead of
    /// the track's watermark.
    func run(trackID: Int, since: String? = nil) async throws -> [TrackEvent] {
        var args = ["tracks", "scan", "\(trackID)"]
        if let since, !since.isEmpty {
            args.append(contentsOf: ["--since", since])
        }
        let data = try await runner.run(args: args)
        if data.isEmpty { return [] }
        // Malformed output must throw (callers surface it via errorMessage);
        // swallowing it would render a scan failure as "no new events".
        // Empty results are printed as [] by the CLI, so they decode fine.
        return try JSONDecoder().decode([TrackEvent].self, from: data)
    }
}

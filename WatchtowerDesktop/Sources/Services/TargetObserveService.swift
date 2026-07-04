import Foundation

/// Bridges the Desktop app to `watchtower targets observe <id>`, which force-runs
/// the target's observers and prints the new events as JSON. Used for manual
/// "refresh now"; the daemon produces events automatically otherwise.
/// See `cmd/targets_ai.go` `runTargetsObserve`.
struct TargetObserveService {
    let runner: CLIRunnerProtocol

    /// Force-runs the target's observers. When `since` is non-nil, scans history
    /// from that ISO8601 instant (the "Scan history" action) instead of the
    /// observer watermark.
    func run(targetID: Int, since: String? = nil) async throws -> [ObserverEvent] {
        var args = ["targets", "observe", "\(targetID)"]
        if let since, !since.isEmpty {
            args.append(contentsOf: ["--since", since])
        }
        let data = try await runner.run(args: args)
        if data.isEmpty { return [] }
        // Malformed output must throw (callers surface it via errorMessage);
        // swallowing it would render a scan failure as "no new events".
        // Empty results are printed as [] by the CLI, so they decode fine.
        return try JSONDecoder().decode([ObserverEvent].self, from: data)
    }
}

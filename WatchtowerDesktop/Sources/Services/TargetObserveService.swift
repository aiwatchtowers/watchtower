import Foundation

/// Bridges the Desktop app to `watchtower targets observe <id>`, which force-runs
/// the target's observers and prints the new events as JSON. Used for manual
/// "refresh now"; the daemon produces events automatically otherwise.
/// See `cmd/targets_ai.go` `runTargetsObserve`.
struct TargetObserveService {
    let runner: CLIRunnerProtocol

    func run(targetID: Int) async throws -> [ObserverEvent] {
        let data = try await runner.run(args: ["targets", "observe", "\(targetID)"])
        if data.isEmpty { return [] }
        return (try? JSONDecoder().decode([ObserverEvent].self, from: data)) ?? []
    }
}

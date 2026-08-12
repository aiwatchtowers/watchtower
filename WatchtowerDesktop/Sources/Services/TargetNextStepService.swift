import Foundation
import WatchtowerCore

/// Bridges the Desktop app to the `watchtower targets next-step <id>` subprocess,
/// which (re)generates the AI next-step suggestion and prints it as JSON.
/// Decodes the output into `TargetNextStep` for the target detail card.
/// See `cmd/targets_ai.go` `runTargetsNextStep` for the Go side.
struct TargetNextStepService {
    let runner: CLIRunnerProtocol

    func generate(targetID: Int) async throws -> TargetNextStep {
        let args = ["targets", "next-step", "\(targetID)"]
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(TargetNextStep.self, from: data)
    }
}

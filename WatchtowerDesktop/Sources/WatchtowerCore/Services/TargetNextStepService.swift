import Foundation

/// Bridges the Desktop app to the `watchtower targets next-step <id>` subprocess,
/// which (re)generates the AI next-step suggestion and prints it as JSON.
/// Decodes the output into `TargetNextStep` for the target detail card.
/// See `cmd/targets_ai.go` `runTargetsNextStep` for the Go side.
package struct TargetNextStepService {
    package let runner: CLIRunnerProtocol

    package init(runner: CLIRunnerProtocol) {
        self.runner = runner
    }

    package func generate(targetID: Int) async throws -> TargetNextStep {
        let args = ["targets", "next-step", "\(targetID)"]
        let data = try await runner.runModel(args: args, origin: .owner)
        return try JSONDecoder().decode(TargetNextStep.self, from: data)
    }
}

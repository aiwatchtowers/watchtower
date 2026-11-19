import Foundation
import WatchtowerCore

extension CLIRunnerProtocol {
    /// The default `runModel` for test doubles only (production runners each
    /// implement it, so none can drop an origin by accident): forwards to the
    /// generic entries and drops `origin`. Doubles that should catch a model
    /// command launched without an origin (`FakeCLIRunner`, `HeldCLIRunner`)
    /// implement both sides themselves.
    package func runModel(args: [String], origin: CLIOrigin, timeout: TimeInterval?, stdin: Data?) async throws -> Data {
        if let stdin { return try await run(args: args, stdin: stdin) }
        if let timeout { return try await run(args: args, timeout: timeout) }
        return try await run(args: args)
    }
}

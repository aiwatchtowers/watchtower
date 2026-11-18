import Foundation
import WatchtowerCore

/// The model entry of the review fake: `overview` and `lessons propose` come
/// through here, the generic entries refuse them (#1886 Task 18). Kept apart
/// from ReviewChangesModelTests.swift, which sits at the file-length limit.
extension ReviewScriptedRunner {
    func runModel(args: [String], origin _: CLIOrigin, timeout: TimeInterval?, stdin _: Data?) async throws -> Data {
        try await answer(args, timeout, model: true)
    }
}

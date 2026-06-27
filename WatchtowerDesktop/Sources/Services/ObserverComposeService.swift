import Foundation

/// AI-drafted observer name + watch instruction returned by
/// `watchtower observers compose`.
struct ObserverDraft: Decodable {
    let name: String
    let instruction: String
}

/// Bridges the Desktop app to `watchtower observers compose`, which turns a
/// free-text "what to watch" request into a scoped observer name + instruction.
/// See `cmd/observers.go` `runObserversCompose` for the Go side.
struct ObserverComposeService {
    let runner: CLIRunnerProtocol

    func compose(targetID: Int, input: String) async throws -> ObserverDraft {
        let args = ["observers", "compose", "--entity", "target:\(targetID)", "--input", input]
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(ObserverDraft.self, from: data)
    }
}

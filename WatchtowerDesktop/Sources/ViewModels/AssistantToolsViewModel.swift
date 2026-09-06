import Foundation
import WatchtowerCore

/// One registry tool as `watchtower actions tools --json` lists it.
struct AssistantToolRow: Identifiable, Equatable, Decodable, Sendable {
    var id: String { name }
    let name: String
    let description: String
    let access: String
    let external: Bool
    let surfaces: [String]
    var trust: String
}

/// Settings → Assistant tools backing store. The registry lives in Go; this
/// VM only lists it and flips trust through the CLI, then re-reads.
@MainActor
@Observable
final class AssistantToolsViewModel {
    private(set) var rows: [AssistantToolRow] = []
    private(set) var isLoading = false
    var error: String?
    private let cliRunner: CLIRunnerProtocol?

    init(cliRunner: CLIRunnerProtocol? = nil) {
        self.cliRunner = cliRunner
    }

    private func runner() throws -> CLIRunnerProtocol {
        if let cliRunner { return cliRunner }
        if let r = ProcessCLIRunner.makeDefault() { return r }
        throw CLIRunnerError.binaryNotFound
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await runner().run(args: ["actions", "tools", "--json"])
            rows = try JSONDecoder().decode([AssistantToolRow].self, from: data)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setTrust(_ name: String, execute: Bool) async {
        do {
            _ = try await runner().run(args: ["actions", "trust", name, execute ? "execute" : "ask"])
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await load()
    }
}

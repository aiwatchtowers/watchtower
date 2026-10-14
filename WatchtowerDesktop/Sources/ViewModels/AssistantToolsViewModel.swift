import Foundation
import WatchtowerCore

/// One registry tool as `watchtower actions tools --json` lists it.
struct AssistantToolRow: Identifiable, Equatable, Decodable, Sendable {
    var id: String { name }
    let name: String
    let description: String
    let access: String
    let external: Bool
    /// `Tool.AlwaysAsk` (dismiss_tracks): local, but never trusted to execute.
    let alwaysAsk: Bool
    let surfaces: [String]
    var trust: String
    /// Trust per chat surface (`trust_by_surface`, target 167): an execute on
    /// one surface never covers another. Empty from a CLI older than the field.
    let trustBySurface: [String: String]

    /// The surfaces a trust switch is offered on: every surface but the
    /// workbench, whose write tools always apply directly (DEV-06).
    var trustSurfaces: [String] { surfaces.filter { $0 != AssistantToolSurface.workbench } }

    /// On the workbench surface only: no switch, a note instead.
    var appliesOnlyInWorkbench: Bool { !surfaces.isEmpty && trustSurfaces.isEmpty }

    /// Locked to "ask": SetTrust refuses execute for both kinds.
    var isLockedToAsk: Bool { external || alwaysAsk }

    private enum CodingKeys: String, CodingKey {
        case name, description, access, external, surfaces, trust
        case alwaysAsk = "always_ask"
        case trustBySurface = "trust_by_surface"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decode(String.self, forKey: .description)
        access = try c.decode(String.self, forKey: .access)
        external = try c.decode(Bool.self, forKey: .external)
        // Absent from a CLI older than the field.
        alwaysAsk = try c.decodeIfPresent(Bool.self, forKey: .alwaysAsk) ?? false
        surfaces = try c.decode([String].self, forKey: .surfaces)
        trust = try c.decode(String.self, forKey: .trust)
        trustBySurface = try c.decodeIfPresent([String: String].self, forKey: .trustBySurface) ?? [:]
    }

    /// Whether `surface` runs this tool without approval; an older CLI's
    /// single `trust` stands for every surface.
    func executes(on surface: String) -> Bool {
        (trustBySurface[surface] ?? trust) == "execute"
    }
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

    /// Sets the trust on one surface only, so turning one switch on never
    /// grants execute on the tool's other surfaces.
    func setTrust(_ name: String, surface: String, execute: Bool) async {
        do {
            _ = try await runner().run(
                args: ["actions", "trust", name, execute ? "execute" : "ask", "--surface", surface]
            )
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await load()
    }
}

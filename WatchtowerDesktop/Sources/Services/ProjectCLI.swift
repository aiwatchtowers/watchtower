import Foundation
import WatchtowerCore

/// `watchtower project create --json` envelope (Task 4).
struct ProjectCreated: Decodable, Equatable {
    let id: Int64
    let folder: String
    let name: String
}

/// `watchtower project delete N --json` envelope. The project rows are gone
/// whenever the command exits 0; `removalOK == false` means only the folder
/// cleanup failed, and `removalError` says why.
struct ProjectDeleted: Decodable, Equatable {
    let id: Int64
    let deleted: Bool
    let removalOK: Bool
    let removalError: String

    enum CodingKeys: String, CodingKey {
        case id, deleted
        case removalOK = "removal_ok"
        case removalError = "removal_error"
    }
}

/// `watchtower integrate status --project N --json` (Task 12). `skill` is a
/// devpack state (`installed`, `updated`, `unchanged`, `drifted`, `missing`,
/// `foreign`); a drifted or foreign skill is the owner's own content (PROJ-04)
/// and counts as present.
struct ProjectInstallStatus: Decodable, Equatable {
    let skill: String
    let hook: Bool
    let mcp: Bool

    var needsRepair: Bool { skill == "missing" || !hook || !mcp }
}

/// The Projects tab's CLI calls. Everything the Desktop does to the folder or
/// to project rows it does not own goes through here — never a direct write.
/// Folder paths travel as a single argv element (`Process` does no shell
/// parsing), so spaces and Unicode need no quoting.
struct ProjectCLI {
    let runner: any CLIRunnerProtocol

    func create(folder: String, name: String?) async throws -> ProjectCreated {
        var args = ["project", "create", "--folder", folder, "--json"]
        if let name, !name.isEmpty { args += ["--name", name] }
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(ProjectCreated.self, from: data)
    }

    /// Installs the skill, SessionStart hook and local MCP registration into
    /// the project folder. Idempotent — also the Repair action.
    func install(projectID: Int64) async throws {
        _ = try await runner.run(args: ["integrate", "claude-code", "--project", String(projectID)])
    }

    func status(projectID: Int64) async throws -> ProjectInstallStatus {
        let data = try await runner.run(args: ["integrate", "status", "--project", String(projectID), "--json"])
        return try JSONDecoder().decode(ProjectInstallStatus.self, from: data)
    }

    /// Removes what was installed in the folder, then the project and every
    /// row it owns (Task 4 runs the removal first). Used by Task 20.
    func delete(projectID: Int64) async throws -> ProjectDeleted {
        let data = try await runner.run(args: ["project", "delete", String(projectID), "--json"])
        return try JSONDecoder().decode(ProjectDeleted.self, from: data)
    }
}

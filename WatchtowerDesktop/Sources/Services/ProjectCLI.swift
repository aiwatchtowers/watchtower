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
/// devpack status state: `unchanged` (current), `updated` (an older shipped
/// version that an install would replace), `missing`, or `drifted`/`foreign`
/// — the owner's own content (PROJ-04), which counts as present.
/// `claude_found == false` means the `claude` CLI is not on PATH, so `mcp`
/// could not be checked and a Repair could not register it either.
struct ProjectInstallStatus: Decodable, Equatable {
    let skill: String
    let hook: Bool
    let mcp: Bool
    let claudeFound: Bool

    enum CodingKeys: String, CodingKey {
        case skill, hook, mcp
        case claudeFound = "claude_found"
    }

    init(skill: String, hook: Bool, mcp: Bool, claudeFound: Bool = true) {
        self.skill = skill
        self.hook = hook
        self.mcp = mcp
        self.claudeFound = claudeFound
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skill = try c.decode(String.self, forKey: .skill)
        hook = try c.decode(Bool.self, forKey: .hook)
        mcp = try c.decode(Bool.self, forKey: .mcp)
        // An older CLI without the key could always check the registration.
        claudeFound = try c.decodeIfPresent(Bool.self, forKey: .claudeFound) ?? true
    }

    /// Whether Repair can fix something. Without `claude` an unregistered
    /// MCP server is not repairable from here — see `manualMCPCommand`.
    var needsRepair: Bool {
        skill == "missing" || skill == "updated" || !hook || (claudeFound && !mcp)
    }

    /// The command the owner runs once Claude Code is installed, mirroring
    /// what `integrate claude-code --project` registers. It starts with
    /// `cd <folder> &&` because a local-scope registration is keyed on the
    /// working directory. Go twin: `devpack.ProjectMCPCommand`
    /// (`internal/devpack/project.go`) — same text, pinned by one shared
    /// fixture on both sides.
    static func manualMCPCommand(projectID: Int64, folder: String, cliPath: String) -> String {
        "cd \(shellQuote(folder)) && claude mcp add --scope local watchtower-project -- "
            + "\(shellQuote(cliPath)) mcp --project \(projectID)"
    }

    /// Go `shellQuote`'s rule: bare when every character is shell-safe,
    /// otherwise single-quoted with `'` escaped as `'\''`.
    private static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+:@%,=")
        if !s.isEmpty, s.unicodeScalars.allSatisfy(safe.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
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

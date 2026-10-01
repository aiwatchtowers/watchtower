import Foundation
import WatchtowerCore

/// `watchtower project create --json` envelope (Task 4). The folder's
/// document import is best-effort: the project exists whenever the command
/// exits 0; `docsImportOK == false` says the import failed, and a successful
/// one may still have skipped unreadable paths or files past its cap.
struct ProjectCreated: Decodable, Equatable {
    let id: Int64
    let folder: String
    let name: String
    let docsImportOK: Bool
    let docsImportError: String
    /// `"<rel_path>: <reason>"` per path the import could not read.
    let unreadable: [String]
    /// New documents past the per-run cap; the next `import-docs` takes them.
    let skippedOverCap: Int

    enum CodingKeys: String, CodingKey {
        case id, folder, name
        case docsImportOK = "docs_import_ok"
        case docsImportError = "docs_import_error"
        case docsImport = "docs_import"
    }

    private struct DocsImport: Decodable {
        let unreadable: [String]?
        let skippedOverCap: [String]?

        enum CodingKeys: String, CodingKey {
            case unreadable
            case skippedOverCap = "skipped_over_cap"
        }
    }

    init(
        id: Int64,
        folder: String,
        name: String,
        docsImportOK: Bool = true,
        docsImportError: String = "",
        unreadable: [String] = [],
        skippedOverCap: Int = 0
    ) {
        self.id = id
        self.folder = folder
        self.name = name
        self.docsImportOK = docsImportOK
        self.docsImportError = docsImportError
        self.unreadable = unreadable
        self.skippedOverCap = skippedOverCap
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        folder = try c.decode(String.self, forKey: .folder)
        name = try c.decode(String.self, forKey: .name)
        // An older CLI without the keys imported nothing, so nothing failed.
        docsImportOK = try c.decodeIfPresent(Bool.self, forKey: .docsImportOK) ?? true
        docsImportError = try c.decodeIfPresent(String.self, forKey: .docsImportError) ?? ""
        let report = try c.decodeIfPresent(DocsImport.self, forKey: .docsImport)
        unreadable = report?.unreadable ?? []
        skippedOverCap = report?.skippedOverCap?.count ?? 0
    }

    /// What the project page tells the owner about the import, or nil when
    /// everything was attached. Each case ends with the command that retries.
    var importNote: String? {
        let retry = "watchtower project import-docs \(id)"
        if !docsImportOK {
            let reason = docsImportError.isEmpty ? "" : " (\(docsImportError))"
            return "Importing the folder's documents failed\(reason) — retry with: \(retry)"
        }
        var parts: [String] = []
        if let first = unreadable.first {
            let more = unreadable.count > 1 ? " and \(unreadable.count - 1) more" : ""
            parts.append("Could not read \(first)\(more) — fix it, then run: \(retry)")
        }
        if skippedOverCap > 0 {
            parts.append("\(skippedOverCap) more document(s) past the import cap — run: \(retry)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }
}

/// `watchtower project delete N --json` envelope. The project rows are gone
/// whenever the command exits 0; `removalOK == false` means only the folder
/// cleanup failed, and `removalError` says why; `filesOK == false` means
/// Watchtower's stored copies of the targets' images could not all be
/// removed (`filesError`). A CLI older than the images feature sends no
/// `files_*` keys: nothing to remove, so they decode as clean.
struct ProjectDeleted: Decodable, Equatable {
    let id: Int64
    let deleted: Bool
    let removalOK: Bool
    let removalError: String
    let filesOK: Bool
    let filesError: String

    init(id: Int64, deleted: Bool, removalOK: Bool, removalError: String, filesOK: Bool = true, filesError: String = "") {
        self.id = id
        self.deleted = deleted
        self.removalOK = removalOK
        self.removalError = removalError
        self.filesOK = filesOK
        self.filesError = filesError
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        deleted = try c.decode(Bool.self, forKey: .deleted)
        removalOK = try c.decode(Bool.self, forKey: .removalOK)
        removalError = try c.decode(String.self, forKey: .removalError)
        filesOK = try c.decodeIfPresent(Bool.self, forKey: .filesOK) ?? true
        filesError = try c.decodeIfPresent(String.self, forKey: .filesError) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case id, deleted
        case removalOK = "removal_ok"
        case removalError = "removal_error"
        case filesOK = "files_ok"
        case filesError = "files_error"
    }

    /// The non-blocking warning for a delete whose cleanup partly failed, or
    /// nil when everything was removed.
    var cleanupWarning: String? {
        var parts: [String] = []
        if !removalOK { parts.append("cleaning its folder failed: \(removalError)") }
        if !filesOK { parts.append("removing its stored images failed: \(filesError)") }
        return parts.isEmpty ? nil : "The project was deleted, but " + parts.joined(separator: "; ")
    }
}

/// `watchtower project attach-doc N <path> --json` envelope (#80).
/// `created == false` means the path was already attached (left untouched).
struct ProjectDocumentAttached: Decodable, Equatable {
    let documentID: Int64
    let relPath: String
    let created: Bool

    enum CodingKeys: String, CodingKey {
        case documentID = "document_id"
        case relPath = "rel_path"
        case created
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
    /// The Stop hook running the board drift check (PROJ-07). A project
    /// installed before it existed lacks it until a Repair.
    let stopHook: Bool
    let mcp: Bool
    let claudeFound: Bool

    enum CodingKeys: String, CodingKey {
        case skill, hook, mcp
        case stopHook = "stop_hook"
        case claudeFound = "claude_found"
    }

    init(skill: String, hook: Bool, stopHook: Bool = true, mcp: Bool, claudeFound: Bool = true) {
        self.skill = skill
        self.hook = hook
        self.stopHook = stopHook
        self.mcp = mcp
        self.claudeFound = claudeFound
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skill = try c.decode(String.self, forKey: .skill)
        hook = try c.decode(Bool.self, forKey: .hook)
        // An older CLI has no Stop hook to install: nothing to repair.
        stopHook = try c.decodeIfPresent(Bool.self, forKey: .stopHook) ?? true
        mcp = try c.decode(Bool.self, forKey: .mcp)
        // An older CLI without the key could always check the registration.
        claudeFound = try c.decodeIfPresent(Bool.self, forKey: .claudeFound) ?? true
    }

    /// Whether Repair can fix something. Without `claude` an unregistered
    /// MCP server is not repairable from here — see `manualMCPCommand`.
    var needsRepair: Bool {
        skill == "missing" || skill == "updated" || !hook || !stopHook || (claudeFound && !mcp)
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

    /// Installs the skill, the SessionStart and Stop hooks and the local MCP
    /// registration into the project folder. Idempotent — also the Repair action.
    func install(projectID: Int64) async throws {
        _ = try await runner.run(args: ["integrate", "claude-code", "--project", String(projectID)])
    }

    func status(projectID: Int64) async throws -> ProjectInstallStatus {
        let data = try await runner.run(args: ["integrate", "status", "--project", String(projectID), "--json"])
        return try JSONDecoder().decode(ProjectInstallStatus.self, from: data)
    }

    /// Attaches a file inside the project folder as the owner's document. The
    /// CLI owns the checks (inside the folder with symlinks resolved, a regular
    /// .md/.txt file, the target on this board) — the attach_document rules.
    /// `--` ends the flags, so no path can be read as one.
    func attachDocument(projectID: Int64, path: String, kind: String, targetID: Int64?) async throws -> ProjectDocumentAttached {
        var args = ["project", "attach-doc", "--kind", kind, "--json"]
        if let targetID { args += ["--target", String(targetID)] }
        args += ["--", String(projectID), path]
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(ProjectDocumentAttached.self, from: data)
    }

    /// The board drift check (PROJ-07), offline — no gh call, so it stays
    /// cheap enough to run whenever the board changes.
    func checkDrift(projectID: Int64) async throws -> ProjectDriftReport {
        let data = try await runner.run(args: ["project", "check", "--project", String(projectID), "--json", "--no-network"])
        return try JSONDecoder().decode(ProjectDriftReport.self, from: data)
    }

    /// Sets the board language every session writes the board in; an empty
    /// `language` follows the session language again. The CLI validates it.
    /// `--flag=value` form, so an empty value is never read as a missing one.
    func setBoardLanguage(projectID: Int64, language: String) async throws {
        _ = try await runner.run(args: ["project", "update", String(projectID), "--board-language=\(language)"])
    }

    /// Removes what was installed in the folder, then the project and every
    /// row it owns (Task 4 runs the removal first). Used by Task 20.
    func delete(projectID: Int64) async throws -> ProjectDeleted {
        let data = try await runner.run(args: ["project", "delete", String(projectID), "--json"])
        return try JSONDecoder().decode(ProjectDeleted.self, from: data)
    }
}

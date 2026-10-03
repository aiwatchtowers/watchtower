import Foundation
import WatchtowerCore

/// The Go `workbenchdocs.Report` inside the create and resync envelopes; every
/// list optional, so a CLI that omits one still decodes.
private struct WorkbenchDocsReport: Decodable {
    let imported: [String]?
    let unreadable: [String]?
    let skippedOverCap: [String]?

    enum CodingKeys: String, CodingKey {
        case imported, unreadable
        case skippedOverCap = "skipped_over_cap"
    }
}

/// `watchtower workbench create --json` envelope (Task 4). The folder's
/// document import is best-effort: the workbench exists whenever the command
/// exits 0; `docsImportOK == false` says the import failed, and a successful
/// one may still have skipped unreadable paths or files past its cap.
struct WorkbenchCreated: Decodable, Equatable {
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
        let report = try c.decodeIfPresent(WorkbenchDocsReport.self, forKey: .docsImport)
        unreadable = report?.unreadable ?? []
        skippedOverCap = report?.skippedOverCap?.count ?? 0
    }

    /// What the workbench page tells the owner about the import, or nil when
    /// everything was attached. Each case ends with the command that retries.
    var importNote: String? {
        let retry = "watchtower workbench import-docs \(id)"
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

/// `watchtower workbench delete N --json` envelope. The workbench rows are gone
/// whenever the command exits 0; `removalOK == false` means only the folder
/// cleanup failed, and `removalError` says why; `filesOK == false` means
/// Watchtower's stored copies of the targets' images could not all be
/// removed (`filesError`). A CLI older than the images feature sends no
/// `files_*` keys: nothing to remove, so they decode as clean.
struct WorkbenchDeleted: Decodable, Equatable {
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
        return parts.isEmpty ? nil : "The workbench was deleted, but " + parts.joined(separator: "; ")
    }
}

/// `watchtower workbench resync N --json` (#91): what Re-run Setup added. The
/// command is additive — it never deletes or changes targets, comments,
/// documents, sources or the description, and never creates targets;
/// `suggestions` are what the owner may take to the agent. It exits 0 once
/// the workbench is found; the `*_ok`/`*_error` fields say which step failed
/// (the `workbench create --json` precedent).
struct WorkbenchResynced: Decodable, Equatable {
    /// One summary line; `problem` lines show in the error colour.
    struct Line: Equatable {
        let text: String
        let problem: Bool
    }

    let docsOK: Bool
    let docsError: String
    let imported: [String]
    let skippedOverCap: Int
    let unreadable: [String]
    let integrationOK: Bool
    let integrationError: String
    /// A devpack state: installed, updated, unchanged, drifted or foreign;
    /// empty when the skill was not installed.
    let skill: String
    let hooksAdded: Bool
    let excluded: [String]
    let mcpRegistered: Bool
    let mcpCommand: String
    let suggestions: [String]
    let suggestionsError: String
    /// The migration of a folder set up before the Workbench rename (spec
    /// 2026-10-02 §5.4). `legacySkill` is what became of the old skill:
    /// `removed`, `drifted`/`foreign` (kept — the owner's, PROJ-04), or empty
    /// when there was none. A permission-rule count above zero already comes
    /// with its own line in `suggestions`. A CLI older than the rename sends
    /// none of these keys: nothing was migrated.
    let legacySkill: String
    let legacyMCPRemoved: Bool
    let legacyHooksReplaced: Bool
    let legacyPermissionRules: Int
    /// The workbench documents' search index (#89). A CLI older than it sends
    /// none of these keys: nothing was indexed, nothing failed.
    let indexOK: Bool
    let indexError: String
    let indexed: Int
    let indexSkipped: Bool

    enum CodingKeys: String, CodingKey {
        case docsOK = "docs_ok"
        case docsError = "docs_error"
        case docs
        case integrationOK = "integration_ok"
        case integrationError = "integration_error"
        case skill, excluded, suggestions
        case hooksAdded = "hooks_added"
        case mcpRegistered = "mcp_registered"
        case mcpCommand = "mcp_command"
        case suggestionsError = "suggestions_error"
        case indexOK = "index_ok"
        case indexError = "index_error"
        case indexed
        case indexSkipped = "index_skipped"
        case legacySkill = "legacy_skill"
        case legacyMCPRemoved = "legacy_mcp_removed"
        case legacyHooksReplaced = "legacy_hooks_replaced"
        case legacyPermissionRules = "legacy_permission_rules"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A CLI that no longer imports documents (spec 2026-10-03 §7) sends
        // none of the docs keys: nothing was imported, nothing failed.
        docsOK = try c.decodeIfPresent(Bool.self, forKey: .docsOK) ?? true
        docsError = try c.decodeIfPresent(String.self, forKey: .docsError) ?? ""
        let docs = try c.decodeIfPresent(WorkbenchDocsReport.self, forKey: .docs)
        imported = docs?.imported ?? []
        unreadable = docs?.unreadable ?? []
        skippedOverCap = docs?.skippedOverCap?.count ?? 0
        integrationOK = try c.decode(Bool.self, forKey: .integrationOK)
        integrationError = try c.decode(String.self, forKey: .integrationError)
        skill = try c.decode(String.self, forKey: .skill)
        hooksAdded = try c.decode(Bool.self, forKey: .hooksAdded)
        excluded = try c.decode([String].self, forKey: .excluded)
        mcpRegistered = try c.decode(Bool.self, forKey: .mcpRegistered)
        mcpCommand = try c.decode(String.self, forKey: .mcpCommand)
        suggestions = try c.decode([String].self, forKey: .suggestions)
        suggestionsError = try c.decode(String.self, forKey: .suggestionsError)
        indexOK = try c.decodeIfPresent(Bool.self, forKey: .indexOK) ?? true
        indexError = try c.decodeIfPresent(String.self, forKey: .indexError) ?? ""
        indexed = try c.decodeIfPresent(Int.self, forKey: .indexed) ?? 0
        indexSkipped = try c.decodeIfPresent(Bool.self, forKey: .indexSkipped) ?? false
        legacySkill = try c.decodeIfPresent(String.self, forKey: .legacySkill) ?? ""
        legacyMCPRemoved = try c.decodeIfPresent(Bool.self, forKey: .legacyMCPRemoved) ?? false
        legacyHooksReplaced = try c.decodeIfPresent(Bool.self, forKey: .legacyHooksReplaced) ?? false
        legacyPermissionRules = try c.decodeIfPresent(Int.self, forKey: .legacyPermissionRules) ?? 0
    }

    /// What the workbench page shows: what was added, what failed, then the
    /// suggestions. Never empty.
    var summaryLines: [Line] {
        var lines = documentLines + indexLines + integrationLines
        if lines.isEmpty { lines.append(Line(text: "Everything was already up to date.", problem: false)) }
        lines += suggestions.map { Line(text: "Next: \($0)", problem: false) }
        if !suggestionsError.isEmpty {
            lines.append(Line(text: "Suggestions may be incomplete: \(suggestionsError)", problem: true))
        }
        return lines
    }

    private var documentLines: [Line] {
        guard docsOK else { return [Line(text: "Attaching documents failed: \(docsError)", problem: true)] }
        var lines: [Line] = []
        if !imported.isEmpty {
            lines.append(Line(text: "Attached \(imported.count) new document(s): \(imported.joined(separator: ", "))", problem: false))
        }
        if skippedOverCap > 0 {
            lines.append(Line(text: "\(skippedOverCap) more document(s) past the import cap — run Re-run Setup again", problem: true))
        }
        if let first = unreadable.first {
            let more = unreadable.count > 1 ? " and \(unreadable.count - 1) more" : ""
            lines.append(Line(text: "Could not read \(first)\(more)", problem: true))
        }
        return lines
    }

    private var indexLines: [Line] {
        if !indexOK { return [Line(text: "Indexing the documents for search failed: \(indexError)", problem: true)] }
        if indexSkipped { return [Line(text: "Documents not indexed for search: knowledge search is off", problem: false)] }
        if indexed > 0 {
            return [Line(text: "Indexed \(indexed) document(s) for search in this workbench's sessions", problem: false)]
        }
        return []
    }

    private var integrationLines: [Line] {
        let skillName = WorkbenchVocabulary.current.skillName
        var lines: [Line] = []
        switch skill {
        case "installed": lines.append(Line(text: "Installed the \(skillName) skill", problem: false))
        case "updated": lines.append(Line(text: "Updated the \(skillName) skill", problem: false))
        case "drifted", "foreign":
            lines.append(Line(text: "Your own copy of the \(skillName) skill was kept, so its update was not applied "
                              + "— merge it by hand, or delete your copy and run Re-run Setup again", problem: true))
        default: break
        }
        // A replaced legacy hook also reports `hooks_added` (the file changed);
        // `legacyLines` says that instead.
        if hooksAdded && !legacyHooksReplaced { lines.append(Line(text: "Added the session hooks", problem: false)) }
        if !excluded.isEmpty {
            lines.append(Line(text: "Excluded \(excluded.count) more path(s) from git", problem: false))
        }
        if !mcpRegistered && !mcpCommand.isEmpty {
            lines.append(Line(text: "The MCP server is not registered — run: \(mcpCommand)", problem: true))
        }
        if !integrationOK {
            lines.append(Line(text: "Installing into the folder failed: \(integrationError)", problem: true))
        }
        return lines + legacyLines
    }

    /// What the migration did to a folder set up before the rename. Go twin:
    /// `printLegacyMigration` and `legacySkillKeptNote`
    /// (`cmd/integrate_workbench.go`) — same lines in the same order, the
    /// first letter capitalised like every summary line here; `--json`
    /// carries only the states, so change both sides together.
    private var legacyLines: [Line] {
        let legacy = WorkbenchVocabulary.legacy
        var lines: [Line] = []
        switch legacySkill {
        case "removed": lines.append(Line(text: "Removed the old \(legacy.skillName) skill", problem: false))
        case "drifted", "foreign":
            lines.append(Line(text: "Your own copy of the old \(legacy.skillName) skill was kept — delete "
                              + ".claude/skills/\(legacy.skillName) yourself once you no longer need it; "
                              + "until then Claude Code sees both skills.", problem: true))
        default: break
        }
        if legacyHooksReplaced {
            lines.append(Line(text: "Replaced the old hook commands", problem: false))
        }
        if legacyMCPRemoved {
            lines.append(Line(text: "Removed the old \(legacy.mcpServerName) MCP server", problem: false))
        }
        return lines
    }
}

/// `watchtower integrate status --workbench N --json` (Task 12). `skill` is a
/// devpack status state: `unchanged` (current), `updated` (an older shipped
/// version that an install would replace), `missing`, or `drifted`/`foreign`
/// — the owner's own content (PROJ-04), which counts as present.
/// `claude_found == false` means the `claude` CLI is not on PATH, so `mcp`
/// could not be checked and a Repair could not register it either.
struct WorkbenchInstallStatus: Decodable, Equatable {
    let skill: String
    let hook: Bool
    /// The Stop hook running the board drift check (PROJ-07). A workbench
    /// installed before it existed lacks it until a Repair.
    let stopHook: Bool
    /// The session-state hooks (`UserPromptSubmit`, `Notification`,
    /// `PostToolUse`, `StopFailure`, board #312): all of them present. A
    /// workbench installed before them lacks them until a Repair.
    let stateHooks: Bool
    /// The ask guard (owner asks, spec 2026-10-03 §6): the Stop prompt hook
    /// sending a plain-text request to `ask_owner`, and the PreToolUse hook
    /// denying `AskUserQuestion`. A workbench installed before them lacks
    /// them until a Repair.
    let askGuard: Bool
    let askToolBlock: Bool
    let mcp: Bool
    let claudeFound: Bool
    /// The folder was set up before the Workbench rename and still holds
    /// something Re-run Setup migrates — the old MCP registration, an old
    /// hook command, or the old skill as shipped (spec 2026-10-02 §5.4). Its
    /// old hooks count in `hook`/`stopHook` and its old registration in
    /// `mcp`, so it reads as working; only the new skill reads `missing`.
    let legacy: Bool
    /// The old skill's state: empty when absent, `unchanged`, `drifted` or
    /// `foreign`.
    let legacySkill: String
    /// The watchtower-workbench registration itself; `mcp` also counts the
    /// old one. A CLI that does not send the key gets `mcp`, which keeps the
    /// pre-`current_mcp` repair rule.
    let currentMCP: Bool

    enum CodingKeys: String, CodingKey {
        case skill, hook, mcp, legacy
        case stopHook = "stop_hook"
        case stateHooks = "state_hooks"
        case askGuard = "ask_guard"
        case askToolBlock = "ask_tool_block"
        case claudeFound = "claude_found"
        case legacySkill = "legacy_skill"
        case currentMCP = "current_mcp"
    }

    /// Without `currentMCP`: the current registration is taken to be `mcp`,
    /// as the decoder does for a CLI that does not send the key.
    init(
        skill: String,
        hook: Bool,
        stopHook: Bool = true,
        stateHooks: Bool = true,
        askGuard: Bool = true,
        askToolBlock: Bool = true,
        mcp: Bool,
        claudeFound: Bool = true,
        legacy: Bool = false,
        legacySkill: String = ""
    ) {
        self.init(skill: skill, hook: hook, stopHook: stopHook, stateHooks: stateHooks,
                  askGuard: askGuard, askToolBlock: askToolBlock, mcp: mcp,
                  claudeFound: claudeFound, legacy: legacy, legacySkill: legacySkill, currentMCP: mcp)
    }

    init(
        skill: String,
        hook: Bool,
        stopHook: Bool = true,
        stateHooks: Bool = true,
        askGuard: Bool = true,
        askToolBlock: Bool = true,
        mcp: Bool,
        claudeFound: Bool = true,
        legacy: Bool = false,
        legacySkill: String = "",
        currentMCP: Bool
    ) {
        self.legacy = legacy
        self.currentMCP = currentMCP
        self.legacySkill = legacySkill
        self.skill = skill
        self.hook = hook
        self.stopHook = stopHook
        self.stateHooks = stateHooks
        self.askGuard = askGuard
        self.askToolBlock = askToolBlock
        self.mcp = mcp
        self.claudeFound = claudeFound
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skill = try c.decode(String.self, forKey: .skill)
        hook = try c.decode(Bool.self, forKey: .hook)
        // An older CLI has no Stop hook to install: nothing to repair.
        stopHook = try c.decodeIfPresent(Bool.self, forKey: .stopHook) ?? true
        // Nor one without the session-state hooks.
        stateHooks = try c.decodeIfPresent(Bool.self, forKey: .stateHooks) ?? true
        // Nor one without the ask guard.
        askGuard = try c.decodeIfPresent(Bool.self, forKey: .askGuard) ?? true
        askToolBlock = try c.decodeIfPresent(Bool.self, forKey: .askToolBlock) ?? true
        mcp = try c.decode(Bool.self, forKey: .mcp)
        // An older CLI without the key could always check the registration.
        claudeFound = try c.decodeIfPresent(Bool.self, forKey: .claudeFound) ?? true
        // A CLI older than the Workbench rename knows no legacy folder.
        legacy = try c.decodeIfPresent(Bool.self, forKey: .legacy) ?? false
        legacySkill = try c.decodeIfPresent(String.self, forKey: .legacySkill) ?? ""
        // A CLI older than `current_mcp`: fall back to `mcp`, so needsRepair keeps the old rule.
        currentMCP = try c.decodeIfPresent(Bool.self, forKey: .currentMCP) ?? mcp
    }

    /// Whether Repair can fix something. Without `claude` an unregistered
    /// MCP server is not repairable from here — see `manualMCPCommand`.
    var needsRepair: Bool {
        (skill == "missing" && !runsOnLegacySkill) || skill == "updated" || !hook || !stopHook || !stateHooks
            || !askGuard || !askToolBlock
            || (claudeFound && (!mcp || missesCurrentMCP))
    }

    /// The new skill is in but only the old registration serves it — a
    /// resync whose `mcp add` failed: the skill names tools the session does
    /// not have, so Repair re-runs the add.
    private var missesCurrentMCP: Bool {
        skill != "missing" && !currentMCP
    }

    /// The install icon's tooltip for a folder set up before the Workbench
    /// rename (spec 2026-10-02 A10), or nil for any other.
    var legacyNotice: String? {
        legacy ? "Set up by an older Watchtower — Re-run Setup to update" : nil
    }

    /// A legacy folder whose new skill is `missing` but whose old one is still
    /// there: the agent works through the old skill, so the missing new one
    /// is no repair — the "older setup" nudge covers it (spec 2026-10-02 A10,
    /// §5.4) and the owner decides when to Re-run Setup (O6). With no skill
    /// at all, Repair stays on: there is nothing for the agent to read.
    var runsOnLegacySkill: Bool {
        legacy && !legacySkill.isEmpty
    }

    /// The skill the folder's agent reads, for the prompts the Desktop types
    /// (spec 2026-10-02 §5.3): the old one only while it is all there is.
    var vocabulary: WorkbenchVocabulary {
        runsOnLegacySkill && skill == "missing" ? .legacy : .current
    }

    /// The skill state the tooltip shows: a legacy folder's new skill is
    /// `missing` only because it still runs on the old one.
    var skillDisplay: String {
        vocabulary == .legacy ? "\(WorkbenchVocabulary.legacy.skillName) (older setup)" : skill
    }

    /// The command the owner runs once Claude Code is installed, mirroring
    /// what `integrate claude-code --workbench` registers. It starts with
    /// `cd <folder> &&` because a local-scope registration is keyed on the
    /// working directory. Go twin: `devpack.WorkbenchMCPCommand`
    /// (`internal/devpack/workbench.go`) — same text, pinned by one shared
    /// fixture on both sides.
    static func manualMCPCommand(projectID: Int64, folder: String, cliPath: String) -> String {
        "cd \(shellQuote(folder)) && claude mcp add --scope local \(WorkbenchVocabulary.current.mcpServerName) -- "
            + "\(shellQuote(cliPath)) mcp --workbench \(projectID)"
    }

    /// Go `shellQuote`'s rule: bare when every character is shell-safe,
    /// otherwise single-quoted with `'` escaped as `'\''`.
    private static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+:@%,=")
        if !s.isEmpty, s.unicodeScalars.allSatisfy(safe.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// The Workbench tab's CLI calls. Everything the Desktop does to the folder or
/// to workbench rows it does not own goes through here — never a direct write.
/// Folder paths travel as a single argv element (`Process` does no shell
/// parsing), so spaces and Unicode need no quoting.
struct WorkbenchCLI {
    let runner: any CLIRunnerProtocol

    func create(folder: String, name: String?) async throws -> WorkbenchCreated {
        var args = ["workbench", "create", "--folder", folder, "--json"]
        if let name, !name.isEmpty { args += ["--name", name] }
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(WorkbenchCreated.self, from: data)
    }

    /// Installs the skill, the SessionStart and Stop hooks and the local MCP
    /// registration into the workbench folder. Idempotent — also the Repair action.
    func install(projectID: Int64) async throws {
        _ = try await runner.run(args: ["integrate", "claude-code", "--workbench", String(projectID)])
    }

    func status(projectID: Int64) async throws -> WorkbenchInstallStatus {
        let data = try await runner.run(args: ["integrate", "status", "--workbench", String(projectID), "--json"])
        return try JSONDecoder().decode(WorkbenchInstallStatus.self, from: data)
    }

    /// The board drift check (PROJ-07), offline — no gh call, so it stays
    /// cheap enough to run whenever the board changes.
    func checkDrift(projectID: Int64) async throws -> WorkbenchDriftReport {
        let data = try await runner.run(args: ["workbench", "check", "--workbench", String(projectID), "--json", "--no-network"])
        return try JSONDecoder().decode(WorkbenchDriftReport.self, from: data)
    }

    /// Re-run setup (#91): re-indexes the folder for search and re-installs missing or
    /// outdated integration pieces — additive only, never creates targets.
    func resync(projectID: Int64) async throws -> WorkbenchResynced {
        let data = try await runner.run(args: ["workbench", "resync", String(projectID), "--json"])
        return try JSONDecoder().decode(WorkbenchResynced.self, from: data)
    }

    /// The folder's branch, upstream counters and dirty state (#233). Go runs
    /// git (never the `/usr/bin/git` shim, never outside a repository); the
    /// Desktop never does.
    func gitStatus(projectID: Int64) async throws -> WorkbenchGitStatus {
        let data = try await runner.run(args: ["workbench", "git", "status", "--workbench", String(projectID), "--json"])
        return try JSONDecoder().decode(WorkbenchGitStatus.self, from: data)
    }

    /// The local branches, newest commit first.
    func gitBranches(projectID: Int64) async throws -> WorkbenchGitBranches {
        let data = try await runner.run(args: ["workbench", "git", "branches", "--workbench", String(projectID), "--json"])
        return try JSONDecoder().decode(WorkbenchGitBranches.self, from: data)
    }

    /// Switches the folder to a local branch. Go decides the guards: without
    /// `stash` a dirty tree comes back as `needs_confirmation`, and so does
    /// `agentRunning` (a fact only the Desktop knows) without `confirmAgent`.
    /// A refusal exits 0 with the envelope.
    func gitSwitch(
        projectID: Int64,
        branch: String,
        stash: Bool,
        agentRunning: Bool,
        confirmAgent: Bool
    ) async throws -> WorkbenchGitSwitchResult {
        var args = ["workbench", "git", "switch", "--workbench", String(projectID), "--branch", branch]
        if stash { args.append("--stash") }
        if agentRunning { args.append("--agent-running") }
        if confirmAgent { args.append("--confirm-agent") }
        args.append("--json")
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(WorkbenchGitSwitchResult.self, from: data)
    }

    /// Creates a branch from HEAD and switches to it (`git switch -c`): no
    /// files change, so no guard applies.
    func gitCreateBranch(projectID: Int64, name: String) async throws -> WorkbenchGitSwitchResult {
        let data = try await runner.run(args: ["workbench", "git", "create", "--workbench", String(projectID), "--name", name, "--json"])
        return try JSONDecoder().decode(WorkbenchGitSwitchResult.self, from: data)
    }

    /// Removes what was installed in the folder, then the workbench and every
    /// row it owns (Task 4 runs the removal first). Used by Task 20.
    func delete(projectID: Int64) async throws -> WorkbenchDeleted {
        let data = try await runner.run(args: ["workbench", "delete", String(projectID), "--json"])
        return try JSONDecoder().decode(WorkbenchDeleted.self, from: data)
    }
}

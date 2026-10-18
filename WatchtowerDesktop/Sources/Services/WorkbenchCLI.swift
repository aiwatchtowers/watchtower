import Foundation
import WatchtowerCore

/// `watchtower workbench create --json` envelope (Task 4): the workbench
/// exists whenever the command exits 0. The folder's search-index keys it
/// also carries are not read here.
struct WorkbenchCreated: Decodable, Equatable {
    let id: Int64
    let folder: String
    let name: String
}

/// `watchtower workbench target add … --json` output.
struct WorkbenchTargetAdded: Decodable, Equatable {
    let targetID: Int64

    enum CodingKeys: String, CodingKey {
        case targetID = "target_id"
    }
}

/// `watchtower workbench delete N --json` envelope. The workbench rows are gone
/// whenever the command exits 0; `removalOK == false` means only the folder
/// cleanup failed, and `removalError` says why; `filesOK == false` means
/// Watchtower's stored copies of the targets' images could not all be
/// removed (`filesError`). A CLI older than the images feature sends no
/// `files_*` keys: nothing to remove, so they decode as clean.
/// `removalHints` name what a removal refused through a link leaving the
/// folder left there and what to remove by hand (PROJ-02's exception, ask
/// #118); absent from an older CLI.
struct WorkbenchDeleted: Decodable, Equatable {
    let id: Int64
    let deleted: Bool
    let removalOK: Bool
    let removalError: String
    let removalHints: [String]
    let filesOK: Bool
    let filesError: String
    /// Worktrees of the workbench's placed sessions that held work and were
    /// left on disk (`workbench delete`, board #229).
    let keptWorktrees: [String]

    init(
        id: Int64,
        deleted: Bool,
        removalOK: Bool,
        removalError: String,
        removalHints: [String] = [],
        filesOK: Bool = true,
        filesError: String = "",
        keptWorktrees: [String] = []
    ) {
        self.id = id
        self.deleted = deleted
        self.removalOK = removalOK
        self.removalError = removalError
        self.removalHints = removalHints
        self.filesOK = filesOK
        self.filesError = filesError
        self.keptWorktrees = keptWorktrees
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        deleted = try c.decode(Bool.self, forKey: .deleted)
        removalOK = try c.decode(Bool.self, forKey: .removalOK)
        removalError = try c.decode(String.self, forKey: .removalError)
        removalHints = try c.decodeIfPresent([String].self, forKey: .removalHints) ?? []
        filesOK = try c.decodeIfPresent(Bool.self, forKey: .filesOK) ?? true
        filesError = try c.decodeIfPresent(String.self, forKey: .filesError) ?? ""
        keptWorktrees = try c.decodeIfPresent([String].self, forKey: .keptWorktrees) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case id, deleted
        case removalOK = "removal_ok"
        case removalError = "removal_error"
        case removalHints = "removal_hints"
        case filesOK = "files_ok"
        case filesError = "files_error"
        case keptWorktrees = "kept_worktrees"
    }

    /// One line naming the worktrees the delete kept because work was in
    /// them, or nil when it kept none.
    var keptWorktreesNotice: String? {
        guard !keptWorktrees.isEmpty else { return nil }
        let n = keptWorktrees.count
        return "Kept \(n) worktree\(n == 1 ? "" : "s") with work in \(n == 1 ? "it" : "them"): "
            + keptWorktrees.joined(separator: ", ")
    }

    /// The non-blocking warning for a delete whose cleanup partly failed, or
    /// nil when everything was removed. Hints name the exact file linked
    /// outside the folder and what to remove; `removal_error` then carries
    /// only the other failures (Go's `devpack.WithoutHinted`), so none hides
    /// behind the hints.
    var cleanupWarning: String? {
        var parts: [String] = []
        if !removalHints.isEmpty {
            parts.append("Watchtower could not clean a file linked outside its folder. "
                + removalHints.map { $0 + "." }.joined(separator: " "))
        }
        if !removalOK, !removalError.isEmpty || removalHints.isEmpty {
            parts.append("cleaning its folder failed: \(removalError)")
        }
        if !filesOK { parts.append("removing its stored images failed: \(filesError)") }
        return parts.isEmpty ? nil : "The workbench was deleted, but " + parts.joined(separator: "; ")
    }
}

/// `watchtower workbench resync N --json` (#91): what Re-run Setup added. The
/// command is additive — it never deletes or changes targets, comments,
/// sources or the description, and never creates targets;
/// `suggestions` are what the owner may take to the agent. It exits 0 once
/// the workbench is found; the `*_ok`/`*_error` fields say which step failed
/// (the `workbench create --json` precedent).
struct WorkbenchResynced: Decodable, Equatable {
    /// One summary line; `problem` lines show in the error colour.
    struct Line: Equatable {
        let text: String
        let problem: Bool
    }

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
    /// The workbench folder files' search index (#89). A CLI older than it sends
    /// none of these keys: nothing was indexed, nothing failed.
    let indexOK: Bool
    let indexError: String
    let indexed: Int
    let indexSkipped: Bool
    /// The codex part (board #399, spec §4.1): nil when the step was skipped
    /// — no codex binary and no codex skill copy in the folder — and from a
    /// CLI older than Codex support.
    let codex: Codex?

    /// `workbench resync --json`'s `codex` object.
    struct Codex: Decodable, Equatable {
        let ok: Bool
        let error: String
        let found: Bool
        /// A devpack state, as `skill` above.
        let skill: String
        /// nil: codex could not be asked.
        let hooksTrusted: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let duplicatesRemoved: Bool

        enum CodingKeys: String, CodingKey {
            case ok, error, found, skill
            case hooksTrusted = "hooks_trusted"
            case duplicatesRemoved = "duplicates_removed"
        }
    }

    enum CodingKeys: String, CodingKey {
        case codex
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
        codex = try c.decodeIfPresent(Codex.self, forKey: .codex)
    }

    /// What the workbench page shows: what was added, what failed, then the
    /// suggestions. Never empty.
    var summaryLines: [Line] {
        var lines = indexLines + integrationLines + codexLines
        if lines.isEmpty { lines.append(Line(text: "Everything was already up to date.", problem: false)) }
        lines += suggestions.map { Line(text: "Next: \($0)", problem: false) }
        if !suggestionsError.isEmpty {
            lines.append(Line(text: "Suggestions may be incomplete: \(suggestionsError)", problem: true))
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
        let skillName = WorkbenchNames.skill
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

    /// The codex part's lines. A failed codex step is its own problem line:
    /// it never makes the Claude Code part read as failed.
    private var codexLines: [Line] {
        guard let codex else { return [] }
        let skillName = WorkbenchNames.skill
        var lines: [Line] = []
        switch codex.skill {
        case "installed": lines.append(Line(text: "Installed the \(skillName) skill for Codex", problem: false))
        case "updated": lines.append(Line(text: "Updated the \(skillName) skill for Codex", problem: false))
        case "drifted", "foreign":
            lines.append(Line(text: "Your own copy of the \(skillName) skill for Codex (.agents/skills) was kept, "
                              + "so its update was not applied", problem: true))
        default: break
        }
        if codex.duplicatesRemoved {
            lines.append(Line(text: "Removed the Watchtower hooks Codex had imported into .codex", problem: false))
        }
        if codex.ok, codex.hooksTrusted == false {
            lines.append(Line(text: "Codex does not trust every Watchtower hook yet — use Repair install", problem: true))
        }
        if !codex.ok {
            lines.append(Line(text: "Setting up Codex failed: \(codex.error)", problem: true))
        }
        return lines
    }

    /// What the migration did to a folder set up before the rename. Go twin:
    /// `printLegacyMigration` and `legacySkillKeptNote`
    /// (`cmd/integrate_workbench.go`) — same lines in the same order, the
    /// first letter capitalised like every summary line here; `--json`
    /// carries only the states, so change both sides together.
    private var legacyLines: [Line] {
        // The skill and MCP server's name before the rename (Go
        // `devpack.LegacySkillName` / `LegacyMCPServerName`).
        let oldName = "watchtower-project"
        var lines: [Line] = []
        switch legacySkill {
        case "removed": lines.append(Line(text: "Removed the old \(oldName) skill", problem: false))
        case "drifted", "foreign":
            lines.append(Line(text: "Your own copy of the old \(oldName) skill was kept — it names tools "
                              + "that no longer exist, so delete .claude/skills/\(oldName) once its edits "
                              + "are carried over; until then Claude Code sees both skills.", problem: true))
        default: break
        }
        if legacyHooksReplaced {
            lines.append(Line(text: "Replaced the old hook commands", problem: false))
        }
        if legacyMCPRemoved {
            lines.append(Line(text: "Removed the old \(oldName) MCP server", problem: false))
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
    /// The session-state hooks — the core four (`UserPromptSubmit`,
    /// `Notification`, `PostToolUse`, `StopFailure`, board #312),
    /// `SubagentStop` (board #411) and `SubagentStart` (board #543): all six
    /// present. A workbench installed before any of them lacks them until a
    /// Repair.
    let stateHooks: Bool
    /// The ask guard (owner asks, spec 2026-10-03 §6): the Stop prompt hook
    /// sending a plain-text request to `ask_owner`, and the PreToolUse hook
    /// denying `AskUserQuestion`. A workbench installed before them lacks
    /// them until a Repair.
    let askGuard: Bool
    let askToolBlock: Bool
    /// The `PermissionRequest` hook holding a permission dialog for an
    /// answer from the phone (#517). A workbench installed before it lacks
    /// it until a Repair; an older CLI without the key has nothing to install.
    let permissionWait: Bool
    /// The `permissions.allow` entry letting the session's agent run
    /// `watchtower workbench cleanup` (board #535, PROJ-04). A folder set
    /// up before it lacks it until a Repair; a CLI that does not send the
    /// key has none to install.
    let cleanupPermission: Bool
    let mcp: Bool
    let claudeFound: Bool
    /// The folder was set up before the Workbench rename and still holds
    /// something Re-run Setup migrates — the old MCP registration, an old
    /// hook command, or the old skill as shipped (spec 2026-10-02 §5.4). Its
    /// old hooks count in `hook`/`stopHook` and its old registration in
    /// `mcp`, but the CLI no longer serves the old `project …` commands they
    /// call, so the folder needs Repair (`claudeNeedsRepair`), which runs
    /// the migrating resync.
    let legacy: Bool
    /// The old skill's state: empty when absent, `unchanged`, `drifted` or
    /// `foreign`.
    let legacySkill: String
    /// The watchtower-workbench registration itself; `mcp` also counts the
    /// old one. A CLI that does not send the key gets `mcp`, which keeps the
    /// pre-`current_mcp` repair rule.
    let currentMCP: Bool
    /// The skill a Claude Code session here reads names the group first
    /// prompt (`group_prompt`, board #476), checked by its content. A CLI
    /// that does not send the key ships a skill that knows it: true.
    let groupPrompt: Bool
    /// The codex part (board #399, spec §4.5); nil from a CLI older than
    /// Codex support, which has no codex part to repair.
    let codex: Codex?

    /// `integrate status --json`'s `codex` object.
    struct Codex: Decodable, Equatable {
        /// A codex binary was found (`codex_path`, then PATH).
        let found: Bool
        /// The skill copy in `.agents/skills` is there (current or not).
        let skill: Bool
        /// The copy's state: `updated` = a previously shipped version the
        /// next setup replaces (Repair); nil from a CLI that does not send it.
        let skillState: String?
        /// nil: codex could not be asked (it timed out, or speaks an unknown
        /// protocol) — no Repair is offered for an unknown.
        let hooksTrusted: Bool? // swiftlint:disable:this discouraged_optional_boolean
        /// Watchtower hooks codex imported from Claude Code's settings into
        /// the folder's `.codex` are still there (they would run twice).
        let importedDuplicates: Bool
        /// Why the CLI could not confirm the hook trust (codex did not
        /// answer, did not list every hook, or could not be resolved); nil
        /// when it could, or from a CLI that does not send the key.
        let trustError: String?
        /// The skill copy names the group first prompt (`group_prompt`);
        /// true from a CLI that does not send the key.
        let groupPrompt: Bool

        init(
            found: Bool,
            skill: Bool,
            hooksTrusted: Bool?, // swiftlint:disable:this discouraged_optional_boolean
            importedDuplicates: Bool = false,
            trustError: String? = nil,
            skillState: String? = nil,
            groupPrompt: Bool = true
        ) {
            self.groupPrompt = groupPrompt
            self.found = found
            self.skill = skill
            self.skillState = skillState
            self.hooksTrusted = hooksTrusted
            self.importedDuplicates = importedDuplicates
            self.trustError = trustError
        }

        enum CodingKeys: String, CodingKey {
            case found, skill
            case skillState = "skill_state"
            case hooksTrusted = "hooks_trusted"
            case importedDuplicates = "imported_duplicates"
            case trustError = "trust_error"
            case groupPrompt = "group_prompt"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            found = try c.decode(Bool.self, forKey: .found)
            skill = try c.decode(Bool.self, forKey: .skill)
            skillState = try c.decodeIfPresent(String.self, forKey: .skillState)
            hooksTrusted = try c.decodeIfPresent(Bool.self, forKey: .hooksTrusted)
            importedDuplicates = try c.decode(Bool.self, forKey: .importedDuplicates)
            trustError = try c.decodeIfPresent(String.self, forKey: .trustError)
            groupPrompt = try c.decodeIfPresent(Bool.self, forKey: .groupPrompt) ?? true
        }

        /// The Codex part's state, for the page header: nothing without
        /// codex (D5: skipped quietly); never set up — a neutral "Set up
        /// Codex", not a failure; set up and whole; set up and broken since
        /// (its hooks untrusted, say after a Codex update, imported twice, or
        /// its skill copy outdated) — Repair. An unknown trust is no break:
        /// it is only logged.
        var state: State {
            guard found else { return .absent }
            guard skill else { return .notSetUp }
            return hooksTrusted == false || importedDuplicates || skillOutdated ? .broken : .ready
        }

        /// The skill copy is a previously shipped version (`skill_state`
        /// `updated`).
        var skillOutdated: Bool { skillState == "updated" }

        enum State: Equatable {
            case absent, notSetUp, ready, broken
        }

        /// The Codex part of the install tooltip, with the trust check's
        /// failure when there is one.
        var summary: String {
            (state == .notSetUp ? "Codex: not set up" : partsSummary)
                + (trustError.map { "\nCodex trust check failed: \($0)" } ?? "")
        }

        private var partsSummary: String {
            let trust = switch hooksTrusted {
            case true?: "trusted"
            case false?: "not trusted"
            case nil: "trust unknown"
            }
            let skillText = skillOutdated ? "outdated" : skill ? "on" : "missing"
            return "Codex: skill \(skillText) · hooks \(trust)"
                + (importedDuplicates ? " · imported duplicate hooks in .codex" : "")
        }
    }

    enum CodingKeys: String, CodingKey {
        case codex
        case skill, hook, mcp, legacy
        case stopHook = "stop_hook"
        case stateHooks = "state_hooks"
        case askGuard = "ask_guard"
        case askToolBlock = "ask_tool_block"
        case permissionWait = "permission_wait"
        case cleanupPermission = "cleanup_permission"
        case claudeFound = "claude_found"
        case legacySkill = "legacy_skill"
        case currentMCP = "current_mcp"
        case groupPrompt = "group_prompt"
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
        permissionWait: Bool = true,
        cleanupPermission: Bool = true,
        mcp: Bool,
        claudeFound: Bool = true,
        legacy: Bool = false,
        legacySkill: String = "",
        groupPrompt: Bool = true,
        codex: Codex? = nil
    ) {
        self.init(skill: skill, hook: hook, stopHook: stopHook, stateHooks: stateHooks,
                  askGuard: askGuard, askToolBlock: askToolBlock, permissionWait: permissionWait, cleanupPermission: cleanupPermission, mcp: mcp,
                  claudeFound: claudeFound, legacy: legacy, legacySkill: legacySkill, currentMCP: mcp,
                  groupPrompt: groupPrompt, codex: codex)
    }

    init(
        skill: String,
        hook: Bool,
        stopHook: Bool = true,
        stateHooks: Bool = true,
        askGuard: Bool = true,
        askToolBlock: Bool = true,
        permissionWait: Bool = true,
        cleanupPermission: Bool = true,
        mcp: Bool,
        claudeFound: Bool = true,
        legacy: Bool = false,
        legacySkill: String = "",
        currentMCP: Bool,
        groupPrompt: Bool = true,
        codex: Codex? = nil
    ) {
        self.codex = codex
        self.groupPrompt = groupPrompt
        self.legacy = legacy
        self.currentMCP = currentMCP
        self.legacySkill = legacySkill
        self.skill = skill
        self.hook = hook
        self.stopHook = stopHook
        self.stateHooks = stateHooks
        self.askGuard = askGuard
        self.askToolBlock = askToolBlock
        self.permissionWait = permissionWait
        self.cleanupPermission = cleanupPermission
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
        permissionWait = try c.decodeIfPresent(Bool.self, forKey: .permissionWait) ?? true
        // Nor one without the cleanup permission (board #535).
        cleanupPermission = try c.decodeIfPresent(Bool.self, forKey: .cleanupPermission) ?? true
        mcp = try c.decode(Bool.self, forKey: .mcp)
        // An older CLI without the key could always check the registration.
        claudeFound = try c.decodeIfPresent(Bool.self, forKey: .claudeFound) ?? true
        // A CLI older than the Workbench rename knows no legacy folder.
        legacy = try c.decodeIfPresent(Bool.self, forKey: .legacy) ?? false
        legacySkill = try c.decodeIfPresent(String.self, forKey: .legacySkill) ?? ""
        // A CLI older than `current_mcp`: fall back to `mcp`, so needsRepair keeps the old rule.
        currentMCP = try c.decodeIfPresent(Bool.self, forKey: .currentMCP) ?? mcp
        // A CLI older than the key ships a skill that knows the group prompt.
        groupPrompt = try c.decodeIfPresent(Bool.self, forKey: .groupPrompt) ?? true
        // A CLI older than Codex support has no codex part.
        codex = try c.decodeIfPresent(Codex.self, forKey: .codex)
    }

    /// Whether Repair can fix something: the Claude Code part or the Codex
    /// part.
    var needsRepair: Bool {
        claudeNeedsRepair || codexNeedsRepair
    }

    /// The Codex part was set up and broke since (`Codex.State.broken`):
    /// Repair, with the orange install icon. A part never set up is no
    /// repair — see `codexNeedsSetup`.
    var codexNeedsRepair: Bool {
        codex?.state == .broken
    }

    /// Codex is installed but this folder's Codex part was never set up (or
    /// its skill copy is gone): a neutral "Set up Codex", never the orange
    /// icon.
    var codexNeedsSetup: Bool {
        codex?.state == .notSetUp
    }

    /// Whether the skill the agent's session reads knows the group first
    /// prompt (board #476): Claude Code's `group_prompt`, or the codex
    /// part's; a CLI without a codex part ships a skill that knows it.
    func skillKnowsGroupPrompt(_ agent: AgentKind) -> Bool {
        switch agent {
        case .claude: groupPrompt
        case .codex: codex?.groupPrompt ?? true
        }
    }

    /// Whether the agent's CLI is there to launch: `claude_found`, or the
    /// codex part's `found` (a CLI without a codex part cannot launch Codex).
    func agentFound(_ agent: AgentKind) -> Bool {
        switch agent {
        case .claude: claudeFound
        case .codex: codex?.found ?? false
        }
    }

    /// The header's Codex setup control (board #399): nil unless codex is
    /// found and this folder's Codex part was never set up. Neutral by
    /// default; a warning only after a setup that failed (`failure`).
    func codexSetupNotice(failure: String?) -> CodexSetupNotice? {
        guard codexNeedsSetup else { return nil }
        guard let failure else {
            return CodexSetupNotice(
                title: "Codex: not set up",
                help: "Codex is installed but this folder is not set up for it yet. Set up Codex adds the "
                    + "\(WorkbenchNames.skill) skill for Codex and trusts Watchtower's hooks, "
                    + "so Codex sessions here get the board tools.",
                isWarning: false
            )
        }
        return CodexSetupNotice(title: "Codex setup failed", help: "\(failure)\nSet up Codex tries again.", isWarning: true)
    }

    /// The Claude Code part. Without `claude` an unregistered MCP server is
    /// not repairable from here — see `manualMCPCommand`. `legacy` and a
    /// missing skill are: the resync Repair runs migrates the files whether
    /// or not the registration goes in (ask #312), and without `claude`
    /// `legacy` sees only those files, so one Repair settles them.
    var claudeNeedsRepair: Bool {
        legacy || skill == "missing" || skill == "updated" || !hook || !stopHook || !stateHooks
            || !askGuard || !askToolBlock || !permissionWait || !cleanupPermission
            || (claudeFound && (!mcp || missesCurrentMCP))
    }

    /// The new skill is in but only the old registration serves it — a
    /// resync whose `mcp add` failed: the skill names tools the session does
    /// not have, so Repair re-runs the add.
    private var missesCurrentMCP: Bool {
        skill != "missing" && !currentMCP
    }

    /// The command the owner runs once Claude Code is installed, mirroring
    /// what `integrate claude-code --workbench` registers. It starts with
    /// `cd <folder> &&` because a local-scope registration is keyed on the
    /// working directory. Go twin: `devpack.WorkbenchMCPCommand`
    /// (`internal/devpack/workbench.go`) — same text, pinned by one shared
    /// fixture on both sides.
    static func manualMCPCommand(projectID: Int64, folder: String, cliPath: String) -> String {
        "cd \(shellQuote(folder)) && claude mcp add --scope local \(WorkbenchNames.mcpServer) -- "
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

/// What the page header shows for a Codex part never set up.
struct CodexSetupNotice: Equatable {
    let title: String
    let help: String
    /// Orange: a setup that failed. Otherwise neutral (secondary).
    let isWarning: Bool
}

/// A `WorkbenchCLI` call's own refusals, beyond the runner's errors.
enum WorkbenchCLIError: LocalizedError, Equatable {
    /// `launch-args` found no binary for the agent (exit 3).
    case agentNotFound(AgentKind)

    var errorDescription: String? {
        switch self {
        case let .agentNotFound(agent): TerminalLaunch.exitMessage(code: 127, agent: agent)
        }
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

    /// A board target recorded as the owner's (spec §6.3): Go applies the
    /// board defaults, the parent checks (PROJ-09) and the parent's progress
    /// in the same writer as the agent's `create_targets`. Values travel as
    /// `--flag=value`, so one starting with "-" is never read as a flag.
    func addTarget(workbenchID: Int64, title: String, intent: String, priority: String, parentID: Int64?) async throws -> Int64 {
        var args = ["workbench", "target", "add", "--workbench=\(workbenchID)", "--title=\(title)", "--priority=\(priority)"]
        if !intent.isEmpty { args.append("--intent=\(intent)") }
        if let parentID { args.append("--parent=\(parentID)") }
        args.append("--json")
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(WorkbenchTargetAdded.self, from: data).targetID
    }

    /// Installs the skill, the SessionStart and Stop hooks and the local MCP
    /// registration into the workbench folder. Idempotent — also the Repair action.
    func install(projectID: Int64) async throws {
        _ = try await runner.run(args: ["integrate", "claude-code", "--workbench", String(projectID)])
    }

    /// The Codex part of the folder install (board #399, D5): the skill copy
    /// in `.agents/skills`, the imported duplicate hooks out of `.codex`,
    /// and the hook trust through codex's own app-server. Idempotent — also
    /// Repair's Codex step. Only run when codex is found: without it the
    /// CLI would still copy the skill.
    func installCodex(projectID: Int64) async throws {
        _ = try await runner.run(args: ["integrate", "codex", "--workbench", String(projectID)])
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

    /// The workbench's methodology — personal settings, effective values and
    /// their sources (spec 2026-10-15 §8). Read-only.
    func methodology(projectID: Int64) async throws -> WorkbenchMethodologyState {
        try await methodologyCall(projectID: projectID, extra: [])
    }

    /// Sets one methodology setting; `WorkbenchMethodologyKey.fromFile` drops
    /// it. Go updates the folder's skills right after a preset change.
    func setMethodology(projectID: Int64, key: WorkbenchMethodologyKey, choice: String) async throws -> WorkbenchMethodologyState {
        try await methodologyCall(projectID: projectID, extra: ["\(key.flag)=\(choice)"])
    }

    /// Writes the commented `.watchtower/workflow.md` template when the
    /// folder has none; never overwrites.
    func createWorkflowFile(projectID: Int64) async throws -> WorkbenchMethodologyState {
        try await methodologyCall(projectID: projectID, extra: ["--create-file"])
    }

    private func methodologyCall(projectID: Int64, extra: [String]) async throws -> WorkbenchMethodologyState {
        let data = try await runner.run(args: ["workbench", "methodology", String(projectID)] + extra + ["--json"])
        return try JSONDecoder().decode(WorkbenchMethodologyState.self, from: data)
    }

    // MARK: - Owner instructions (agent instructions, Task 9)

    /// `watchtower instructions show --json`: the owner's texts, the limit and
    /// the open "you keep saying this" suggestions. `workbenchID` adds that
    /// workbench's own texts.
    func instructions(workbenchID: Int64?) async throws -> OwnerInstructionsState {
        try await instructionsCall(["show"], workbenchID: workbenchID)
    }

    /// Saves one field (empty clears it). The text goes over stdin, never
    /// argv; a refusal (over the limit) throws `OwnerInstructionsError`.
    func setInstruction(field: InstructionField, workbenchID: Int64?, body: String) async throws -> OwnerInstructionsState {
        try await instructionsCall(["set", "--field", field.rawValue, "--stdin"], workbenchID: workbenchID, stdin: Data(body.utf8))
    }

    /// Adds (to the matching instructions) or dismisses one suggestion.
    func decideSuggestion(id: Int64, add: Bool) async throws -> OwnerInstructionsState {
        try await instructionsCall(["suggestion", add ? "add" : "dismiss", String(id)], workbenchID: nil)
    }

    /// The exact brief slot and target procedure the agent receives.
    func instructionsPreview(workbenchID: Int64?) async throws -> (briefSlot: String, procedure: String) {
        let data = try await instructionsRun(["preview"], workbenchID: workbenchID, stdin: nil)
        let p = try OwnerInstructionsPreview.decode(data)
        return (p.briefSlot, p.procedure)
    }

    private func instructionsCall(_ sub: [String], workbenchID: Int64?, stdin: Data? = nil) async throws -> OwnerInstructionsState {
        try OwnerInstructionsState.decode(try await instructionsRun(sub, workbenchID: workbenchID, stdin: stdin))
    }

    /// A refusal exits non-zero with Go's message on stderr (and
    /// `{"ok":false,…}` on stdout, which the runner does not return): surface
    /// that message as an `OwnerInstructionsError`.
    private func instructionsRun(_ sub: [String], workbenchID: Int64?, stdin: Data?) async throws -> Data {
        var args = ["instructions"] + sub
        if let workbenchID, sub.first != "suggestion" { args += ["--workbench", String(workbenchID)] }
        args.append("--json")
        do {
            if let stdin { return try await runner.run(args: args, stdin: stdin) }
            return try await runner.run(args: args)
        } catch CLIRunnerError.nonZeroExit(_, let stderr) where !stderr.isEmpty {
            throw OwnerInstructionsError(message: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// The workbench's board column definition (board #267, PROJ-19) as
    /// `watchtower workbench columns <id> --json` prints it.
    func boardColumns(projectID: Int64) async throws -> WorkbenchBoardColumns {
        let data = try await runner.run(args: ["workbench", "columns", String(projectID), "--json"])
        return try JSONDecoder().decode(WorkbenchBoardColumns.self, from: data)
    }

    /// Replaces the whole definition (`--set -`, the JSON on stdin) and
    /// returns the stored one. A refused definition exits 1 with Go's
    /// message on stderr (`CLIRunnerError.nonZeroExit`); nothing is written.
    func setBoardColumns(projectID: Int64, _ def: WorkbenchBoardColumns) async throws -> WorkbenchBoardColumns {
        let data = try await runner.run(
            args: ["workbench", "columns", String(projectID), "--set", "-", "--json"], stdin: try JSONEncoder().encode(def)
        )
        return try JSONDecoder().decode(WorkbenchBoardColumns.self, from: data)
    }

    /// The folder's branch, upstream counters and dirty state (#233). Go runs
    /// git (never the `/usr/bin/git` shim, never outside a repository); the
    /// Desktop never does. `folder` (absolute) asks about that folder instead
    /// of the workbench folder (board #565): Go places it — `folder_scope`,
    /// `folder_root`, `worktree_name` — and reports that worktree's status.
    /// nil (the main folder) sends no flag, so the main argv is unchanged.
    func gitStatus(projectID: Int64, folder: String? = nil) async throws -> WorkbenchGitStatus {
        var args = ["workbench", "git", "status", "--workbench", String(projectID)]
        if let folder { args += ["--folder", folder] }
        args.append("--json")
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(WorkbenchGitStatus.self, from: data)
    }

    // MARK: - Diff review (board #328)

    /// Every review call prints one envelope; a refusal is `ok: false` with
    /// `error` at exit 0, not a throw.
    private func review(_ args: [String], timeout: TimeInterval? = nil) async throws -> ReviewEnvelope {
        let full = ["workbench", "review"] + args + ["--json"]
        let data: Data
        if let timeout {
            data = try await runner.run(args: full, timeout: timeout)
        } else {
            data = try await runner.run(args: full)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ReviewEnvelope.self, from: data)
    }

    func reviewStart(projectID: Int64, sessionID: Int64, refresh: Bool) async throws -> ReviewEnvelope {
        try await review(["start", "--workbench", String(projectID), "--session", String(sessionID)]
            + (refresh ? ["--refresh"] : []))
    }

    func reviewDiff(projectID: Int64, roundID: Int64, since: Bool) async throws -> ReviewEnvelope {
        try await review(["diff", "--workbench", String(projectID), "--round", String(roundID)]
            + (since ? ["--since"] : []))
    }

    /// `oldPath`: a renamed file's old path, where its old side is read.
    func reviewFile(projectID: Int64, roundID: Int64, path: String, oldPath: String?, since: Bool) async throws -> ReviewEnvelope {
        try await review(["file", "--workbench", String(projectID), "--round", String(roundID), "--path", path]
            + (oldPath.map { ["--old-path", $0] } ?? [])
            + (since ? ["--since"] : []))
    }

    func reviewSend(projectID: Int64, roundID: Int64) async throws -> ReviewEnvelope {
        try await review(["send", "--workbench", String(projectID), "--round", String(roundID)])
    }

    func reviewContext(projectID: Int64, sessionID: Int64) async throws -> ReviewEnvelope {
        try await review(["context", "--workbench", String(projectID), "--session", String(sessionID)])
    }

    /// The two LLM calls (overview, lessons) run under Go's 5-minute budget; the Desktop waits a little longer.
    static let reviewAITimeout: TimeInterval = 330

    /// `cachedOnly` reads only a cached overview and never calls the model (Quick mode, board #585).
    func reviewOverview(projectID: Int64, roundID: Int64, cachedOnly: Bool = false) async throws -> ReviewEnvelope {
        let args = ["overview", "--workbench", String(projectID), "--round", String(roundID)]
        if cachedOnly { return try await review(args + ["--cached-only"]) }
        return try await review(args, timeout: Self.reviewAITimeout)
    }

    /// Undoes one hunk of the round's diff in the working tree (never the index).
    func reviewRevertHunk(projectID: Int64, roundID: Int64, hunkID: String, since: Bool) async throws -> ReviewEnvelope {
        try await review(["revert-hunk", "--workbench", String(projectID), "--round", String(roundID), "--hunk", hunkID]
            + (since ? ["--since"] : []))
    }

    enum LessonAction: Equatable {
        case propose
        case accept(Int64)
        case dismiss(Int64)
    }

    func reviewLessons(projectID: Int64, action: LessonAction) async throws -> ReviewEnvelope {
        let workbench = ["--workbench", String(projectID)]
        switch action {
        case .propose:
            return try await review(["lessons", "propose"] + workbench, timeout: Self.reviewAITimeout)
        case .accept(let id):
            return try await review(["lessons", "accept"] + workbench + ["--lesson", String(id)])
        case .dismiss(let id):
            return try await review(["lessons", "dismiss"] + workbench + ["--lesson", String(id)])
        }
    }

    /// Makes a session worktree named `name` (Go slugs it and cuts `wt/<slug>`).
    /// A refusal or failure exits 0 with the envelope's `refused`/`error`.
    func worktreeCreate(projectID: Int64, name: String) async throws -> WorktreeCreateResult {
        let args = ["workbench", "worktree", "create", "--workbench", String(projectID), "--name", name, "--json"]
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(WorktreeCreateResult.self, from: data)
    }

    /// Re-creates a placed worktree at `path` on `branch` when it is gone from disk.
    func worktreeEnsure(projectID: Int64, path: String, branch: String) async throws -> WorktreeCreateResult {
        let args = ["workbench", "worktree", "ensure", "--workbench", String(projectID),
                    "--path", path, "--branch", branch, "--json"]
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(WorktreeCreateResult.self, from: data)
    }

    /// Drops the placed worktree at `path` from the workbench's records.
    func worktreeForget(projectID: Int64, path: String) async throws -> WorktreeForgetResult {
        let args = ["workbench", "worktree", "forget", "--workbench", String(projectID), "--path", path, "--json"]
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(WorktreeForgetResult.self, from: data)
    }

    /// The local branches, newest commit first. `folder`: a session's
    /// worktree, as for `gitStatus` — a folder in none of the repository's
    /// worktrees comes back refused (`folder_not_a_worktree`), exit 0.
    func gitBranches(projectID: Int64, folder: String? = nil) async throws -> WorkbenchGitBranches {
        var args = ["workbench", "git", "branches", "--workbench", String(projectID)]
        if let folder { args += ["--folder", folder] }
        args.append("--json")
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(WorkbenchGitBranches.self, from: data)
    }

    /// Switches the folder to a local branch. Go decides the guards: without
    /// `stash` a dirty tree comes back as `needs_confirmation`, and so does
    /// `agentRunning` (a fact only the Desktop knows) without `confirmAgent`.
    /// A refusal exits 0 with the envelope. `folder`: switch a session's
    /// worktree instead of the workbench folder (board #565).
    func gitSwitch(
        projectID: Int64,
        branch: String,
        stash: Bool,
        agentRunning: Bool,
        confirmAgent: Bool,
        folder: String? = nil
    ) async throws -> WorkbenchGitSwitchResult {
        var args = ["workbench", "git", "switch", "--workbench", String(projectID), "--branch", branch]
        if stash { args.append("--stash") }
        if agentRunning { args.append("--agent-running") }
        if confirmAgent { args.append("--confirm-agent") }
        if let folder { args += ["--folder", folder] }
        args.append("--json")
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(WorkbenchGitSwitchResult.self, from: data)
    }

    /// Checks out one of origin's remote-only branches (board #563): a local
    /// branch tracking `origin/<branch>`, switched to behind the same guards
    /// and confirmations as `gitSwitch`.
    func gitCheckout(
        projectID: Int64,
        branch: String,
        stash: Bool,
        agentRunning: Bool,
        confirmAgent: Bool,
        folder: String? = nil
    ) async throws -> WorkbenchGitSwitchResult {
        var args = ["workbench", "git", "checkout", "--workbench", String(projectID), "--branch", branch]
        if stash { args.append("--stash") }
        if agentRunning { args.append("--agent-running") }
        if confirmAgent { args.append("--confirm-agent") }
        if let folder { args += ["--folder", folder] }
        args.append("--json")
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(WorkbenchGitSwitchResult.self, from: data)
    }

    /// `git fetch --prune origin` (board #563): only origin's remote-tracking
    /// refs move. Go never lets it prompt; every outcome is an exit-0
    /// envelope. `folder`: in a session's worktree (board #565).
    func gitFetch(projectID: Int64, folder: String? = nil) async throws -> WorkbenchGitFetchResult {
        var args = ["workbench", "git", "fetch", "--workbench", String(projectID)]
        if let folder { args += ["--folder", folder] }
        args.append("--json")
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(WorkbenchGitFetchResult.self, from: data)
    }

    /// Creates a branch from HEAD and switches to it (`git switch -c`): no
    /// files change, so no guard applies.
    /// `folder`: in a session's worktree (board #565).
    func gitCreateBranch(projectID: Int64, name: String, folder: String? = nil) async throws -> WorkbenchGitSwitchResult {
        var args = ["workbench", "git", "create", "--workbench", String(projectID), "--name", name]
        if let folder { args += ["--folder", folder] }
        args.append("--json")
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(WorkbenchGitSwitchResult.self, from: data)
    }

    /// Raises session `sessionID`'s recorded Chat question into an owner ask
    /// (owner asks v2, Part 5.3). `at` is the `chat_question_at` the Desktop
    /// read, passed back verbatim: Go files only while it is still the stored
    /// question. Go always exits 0 with one envelope; a run that does not
    /// comes back as the Desktop's own envelope, never thrown: a binary that
    /// could not be started as `launchFailure` (retried), a non-zero exit,
    /// unparsable stdout or a cancel as `failure` (not retried).
    func escalateQuestion(
        projectID: Int64,
        sessionID: Int64,
        at: String,
        reason: ChatQuestionEscalationPolicy.Reason
    ) async -> ChatQuestionEscalationResult {
        let args = ["workbench", "escalate-question", "--workbench", String(projectID),
                    "--session", String(sessionID), "--at", at, "--reason", reason.rawValue]
        do {
            let data = try await runner.run(args: args)
            return try JSONDecoder().decode(ChatQuestionEscalationResult.self, from: data)
        } catch CLIRunnerError.launchFailed(let underlying) {
            return .launchFailure(underlying.localizedDescription)
        } catch {
            // A DecodingError's localizedDescription drops the key path.
            return .failure(error is DecodingError ? String(describing: error) : error.localizedDescription)
        }
    }

    /// How to launch `agent` in workbench `workbenchID` (spec 2026-10-12
    /// §4.2): its binary, `PATH` prefix and argv. Exit 3 is "no binary for
    /// the agent", thrown as `WorkbenchCLIError.agentNotFound`.
    func launchArgs(agent: AgentKind, workbenchID: Int64) async throws -> CodexLaunchArgs {
        let data: Data
        do {
            data = try await runner.run(args: ["workbench", "launch-args", "--agent", agent.rawValue,
                                               "--workbench", String(workbenchID), "--json"])
        } catch CLIRunnerError.nonZeroExit(code: 3, _) {
            throw WorkbenchCLIError.agentNotFound(agent)
        }
        return try JSONDecoder().decode(CodexLaunchArgs.self, from: data)
    }

    /// Removes what was installed in the folder, then the workbench and every
    /// row it owns (Task 4 runs the removal first). Used by Task 20.
    func delete(projectID: Int64) async throws -> WorkbenchDeleted {
        let data = try await runner.run(args: ["workbench", "delete", String(projectID), "--json"])
        return try JSONDecoder().decode(WorkbenchDeleted.self, from: data)
    }
}

import Foundation

/// How an embedded terminal starts (spec §6.2): the owner's own login shell,
/// so `PATH` and `claude`'s auth are exactly theirs. A Claude session `exec`s
/// `claude` in the folder with a session id the app chose, so it can be
/// resumed later. A first prompt (a fixed constant below, or a code question
/// handed over — spec 2026-10-02 §9.5) travels in `firstPromptEnv` and the
/// command names only the variable, read by `/bin/sh` whatever the login
/// shell, so no prompt text is ever parsed by a shell, and `env -u` drops
/// the variable before `claude` runs, so its
/// children never see it; `positionalPrompt` keeps a leading "-" from
/// being read as a flag.
package struct TerminalLaunch: Equatable, Sendable {
    /// `newAgent`'s `sessionID` is the id the app chose (Claude Code, always
    /// set) or nil (Codex mints its own, spec 2026-10-12 §5). `resumeAgent`
    /// reopens a stored id.
    package enum Mode: Equatable, Sendable {
        case newAgent(AgentKind, sessionID: String?, prompt: String?)
        case resumeAgent(AgentKind, sessionID: String)
        case shell

        package static func newClaude(uuid: String, prompt: String?) -> Self {
            .newAgent(.claude, sessionID: uuid, prompt: prompt)
        }

        package static func resumeClaude(uuid: String) -> Self {
            .resumeAgent(.claude, sessionID: uuid)
        }

        /// The agent the mode launches; nil for a shell.
        package var agent: AgentKind? {
            switch self {
            case let .newAgent(agent, _, _), let .resumeAgent(agent, _): agent
            case .shell: nil
            }
        }

        var prompt: String? {
            if case let .newAgent(_, _, prompt) = self { return prompt }
            return nil
        }

        /// The new session's chosen id or the resumed one; nil for a shell
        /// and a new session of an agent that mints its own.
        var sessionID: String? {
            switch self {
            case let .newAgent(_, id, _): id
            case let .resumeAgent(_, id): id
            case .shell: nil
            }
        }

        var isResume: Bool {
            if case .resumeAgent = self { return true }
            return false
        }
    }

    /// Names the `terminal_sessions` row a `claude` process runs in, so the
    /// workbench's `SessionStart` hook (`watchtower workbench brief`) can store
    /// the conversation's new id after `/clear` or a resume (Go
    /// `terminalSessionEnv`, a dual path).
    package static let sessionRowEnv = "WATCHTOWER_TERMINAL_SESSION_ID"
    /// Names the automation run that started the session (AGENT-07): the
    /// CLI refuses owner-only writes under it (Go `RunEnvMarker`).
    package static let automationRunEnv = "WATCHTOWER_AUTOMATION_RUN_ID"
    /// The first prompt of a new `claude` session.
    package static let firstPromptEnv = "WATCHTOWER_FIRST_PROMPT"

    /// The first session of a new workbench.
    package static let firstRunPrompt = "Set up this Watchtower workbench using the \(WorkbenchNames.skill) skill."

    package static let fallbackShell = "/bin/zsh"

    package let executable: String
    package let args: [String]
    package let currentDirectory: String
    /// `NAME=value` entries added to the terminal's environment.
    package var environment: [String] = []
    /// The `terminal_sessions` row the launch belongs to; the session host
    /// keys its sessions by it. Nil for a launch with no row.
    package let rowID: Int64?

    package init(
        executable: String,
        args: [String],
        currentDirectory: String,
        environment: [String] = [],
        rowID: Int64? = nil
    ) {
        self.executable = executable
        self.args = args
        self.currentDirectory = currentDirectory
        self.environment = environment
        self.rowID = rowID
    }

    /// Does not validate a session id: callers check `isValidSessionID`
    /// first. The agent's own command comes from its session adapter
    /// (`SessionAgent.launchCommand`). `rowID` reaches an agent launch's
    /// environment as `sessionRowEnv`. An agent whose hooks arrive with its
    /// launch flags runs as `launch-args` resolved it (`codex`); without one
    /// there is no binary to run, and the launch exits 127 ("Codex was not
    /// found"). `automationRunID` reaches every agent launch, a resume
    /// included, as `automationRunEnv`; a shell never carries it.
    package static func make(
        shell: String?,
        folder: String,
        mode: Mode,
        rowID: Int64? = nil,
        codex: CodexLaunchArgs? = nil,
        setup: String? = nil,
        automationRunID: Int64? = nil
    ) -> Self {
        let executable = shell.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? fallbackShell
        guard let agent = mode.agent else {
            return Self(executable: executable, args: ["-l"], currentDirectory: folder, rowID: rowID)
        }
        let start = AgentStart(sessionID: mode.sessionID, prompt: mode.prompt, resume: mode.isResume, launchArgs: codex)
        let command = agent.session.launchCommand(start)
        // The worktree setup command runs before a NEW agent start only
        // (never a resume or a plain shell), ahead of the agent's own command.
        let setupText = setup.flatMap { text in
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !start.resume && command.runs ? text : nil
        }
        var launch = Self(
            executable: executable,
            args: ["-l", "-c", (setupText == nil ? "" : setupPrefix) + command.command],
            currentDirectory: folder,
            rowID: rowID
        )
        if let rowID { launch.environment.append("\(sessionRowEnv)=\(rowID)") }
        launch.environment += command.environment
        if let prompt = command.prompt { launch.environment.append("\(firstPromptEnv)=\(prompt)") }
        if let setupText { launch.environment.append("\(setupCommandEnv)=\(setupText)") }
        if let automationRunID { launch.environment.append("\(automationRunEnv)=\(automationRunID)") }
        return launch
    }

    /// The owner's worktree setup command, verbatim (spec 2026-10-14): only
    /// `/bin/sh` ever parses it, from the environment. The variable stays in the
    /// agent's environment (the owner's own command; the existing `-c` string is
    /// kept unchanged by design).
    package static let setupCommandEnv = "WATCHTOWER_WORKTREE_SETUP"

    /// Prepended to a new agent start's login-shell command: a fixed literal
    /// with no backslash (so no dim escape) and only its own pair of single quotes, so every
    /// login shell (fish, nushell, csh) hands it to `/bin/sh` as is. The
    /// command runs in a subshell (an `exit` in it must not end the script, and
    /// its `cd`/`export` do not carry into the agent);
    /// a failure is reported and the agent starts anyway.
    package static let setupPrefix = "/bin/sh -c '"
        + "echo \"watchtower: running the worktree setup command…\"; "
        + "( eval \"$\(setupCommandEnv)\" ); s=$?; "
        + "[ \"$s\" -eq 0 ] || echo \"watchtower: the worktree setup command failed (exit $s); starting the agent anyway.\""
        + "'; "

    /// The `/bin/sh` script a Codex launch runs, carried in the environment.
    package static let codexCommandEnv = "WATCHTOWER_CODEX_COMMAND"

    /// The login shell's command for Codex: a fixed literal with no quote or
    /// backslash inside, so every login shell (fish and nushell too) passes
    /// it to `/bin/sh` as is; `/bin/sh` reads the script from
    /// `codexCommandEnv` and runs it, so only `/bin/sh` ever parses values.
    package static let codexLoginCommand = "exec /bin/sh -c 'eval \"$\(codexCommandEnv)\"'"

    /// POSIX single quotes, with a `'` inside written `'\''` (for `/bin/sh`).
    package static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// `claude`'s usage documents no `--` before the prompt, so a prompt
    /// starting with "-" gets a leading space and is never read as a flag.
    /// The first scalar is checked, not the first character: "-" with a
    /// combining mark is one character, but an argv parser sees the dash
    /// (same as Go `positionalPrompt`).
    package static func positionalPrompt(_ prompt: String) -> String {
        prompt.unicodeScalars.first == "-" ? " " + prompt : prompt
    }

    /// Lowercase canonical UUID only, any version (Claude Code's v4, Codex's
    /// v7; same as Go's `uuidRe`): the id is interpolated into a shell
    /// command, so nothing else may pass.
    package static func isValidSessionID(_ id: String) -> Bool {
        let scalars = Array(id.unicodeScalars)
        guard scalars.count == 36 else { return false }
        return scalars.enumerated().allSatisfy { index, scalar in
            if [8, 13, 18, 23].contains(index) { return scalar == "-" }
            return ("0"..."9").contains(scalar) || ("a"..."f").contains(scalar)
        }
    }

    package static func workOnTargetPrompt(targetID: Int64) -> String {
        "Work on target #\(targetID) using the \(WorkbenchNames.skill) skill."
    }

    /// "Work on it" on a target with sub-targets (spec 2026-10-08): the skill's
    /// "Working a group" section keys on this wording.
    package static func workOnGroupPrompt(targetID: Int64) -> String {
        "Work on group #\(targetID) using the \(WorkbenchNames.skill) skill."
    }

    /// The first prompt of a Work on It session: the group wording when the
    /// target has sub-targets and the folder's skill knows that wording
    /// (`skillKnowsGroups`, board #476). A skill without it — the old one, a
    /// version before the group rules, an owner's copy that dropped them —
    /// gets the target wording, as before the group prompt existed.
    package static func workOnPrompt(targetID: Int64, isGroup: Bool, skillKnowsGroups: Bool) -> String {
        isGroup && skillKnowsGroups ? workOnGroupPrompt(targetID: targetID) : workOnTargetPrompt(targetID: targetID)
    }

    /// How many findings the drift-fix prompt lists; the session runs
    /// `workbench check` itself, so the list is only a head start.
    package static let driftFixPromptLimit = 20

    /// The first prompt of a board drift Fix session (spec 2026-10-20 §4):
    /// the agent re-runs the check, then writes the board as each finding
    /// says. One finding gives the same shape with one entry.
    package static func driftFixPrompt(workbenchID: Int64, findings: [WorkbenchDriftFinding]) -> String {
        let listed = findings.prefix(driftFixPromptLimit).map { finding in
            let label = finding.kindLabel
            return "#\(finding.targetID) \(label.prefix(1).lowercased())\(label.dropFirst())"
        }
        var list = listed.joined(separator: "; ")
        if findings.count > driftFixPromptLimit { list += "; and \(findings.count - driftFixPromptLimit) more" }
        return "Fix the board drift using the \(WorkbenchNames.skill) skill: run "
            + "`watchtower workbench check --workbench \(workbenchID)`, then update the board as each finding says. "
            + "Findings now: \(list)."
    }

    /// Follows a session's brief when the owner asked for a plan first (a
    /// start from the phone, mobile POC spec §6.5).
    package static let planFirstSuffix =
        "Plan first: put the plan on the board, then ask me with ask_owner before you change any code."

    /// The terminal pane's line after the session ends. 127 is the shell's
    /// "command not found": `exec claude` found no `claude` on the login
    /// shell's PATH, which a bare exit code would not tell the owner. For
    /// Codex it also names a `launch-args` that found no `codex`.
    package static func exitMessage(code: Int32?, agent: AgentKind = .claude) -> String {
        switch code {
        case 127?: agent.session.notFoundMessage
        case let code?: "\(agent.displayName) exited (code \(code))."
        case nil: "\(agent.displayName) exited."
        }
    }
}

/// `watchtower workbench launch-args --agent codex --workbench N --json`
/// (spec 2026-10-12 §4.2): the `codex` binary, the folder to put ahead of
/// `PATH` (its own, so an nvm install finds `node`), and the argv elements
/// that follow the binary (the update-check, MCP and hook
/// overrides), each one raw.
package struct CodexLaunchArgs: Decodable, Equatable, Sendable {
    package let binary: String
    package let pathPrepend: String
    package let args: [String]

    package init(binary: String, pathPrepend: String, args: [String]) {
        self.binary = binary
        self.pathPrepend = pathPrepend
        self.args = args
    }

    enum CodingKeys: String, CodingKey {
        case binary, args
        case pathPrepend = "path_prepend"
    }
}

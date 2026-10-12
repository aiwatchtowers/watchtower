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
    }

    /// Names the `terminal_sessions` row a `claude` process runs in, so the
    /// workbench's `SessionStart` hook (`watchtower workbench brief`) can store
    /// the conversation's new id after `/clear` or a resume (Go
    /// `terminalSessionEnv`, a dual path).
    package static let sessionRowEnv = "WATCHTOWER_TERMINAL_SESSION_ID"
    /// The first prompt of a new `claude` session.
    package static let firstPromptEnv = "WATCHTOWER_FIRST_PROMPT"

    /// The first session of a new workbench. `vocabulary` picks the skill the
    /// folder has installed (spec 2026-10-02 §5.3).
    package static func firstRunPrompt(_ vocabulary: WorkbenchVocabulary) -> String {
        "Set up this Watchtower workbench using the \(vocabulary.skillName) skill."
    }

    package static let fallbackShell = "/bin/zsh"

    package let executable: String
    package let args: [String]
    package let currentDirectory: String
    /// `NAME=value` entries added to the terminal's environment.
    package var environment: [String] = []

    /// Does not validate a session id: callers check `isValidSessionID`
    /// first. `rowID` reaches an agent launch's environment as
    /// `sessionRowEnv`. A Codex mode runs `codex` as `launch-args` resolved
    /// it (`codex`); without one there is no binary to run, and the launch
    /// exits 127 ("Codex was not found").
    package static func make(
        shell: String?, folder: String, mode: Mode, rowID: Int64? = nil, codex: CodexLaunchArgs? = nil
    ) -> Self {
        let executable = shell.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? fallbackShell
        let args: [String]
        switch mode {
        case let .newAgent(.claude, uuid, prompt):
            // `env -u` keeps the prompt out of everything Claude Code runs.
            // `/bin/sh` reads the variable: the login shell only runs a
            // single-quoted literal, so one whose `$VAR` is not POSIX
            // (nushell's `$env.VAR`) or that quotes differently (csh) still
            // passes the prompt as one argument.
            let uuid = uuid ?? ""
            args = ["-l", "-c", prompt == nil ? "exec claude --session-id \(uuid)"
                : "exec /bin/sh -c 'exec env -u \(firstPromptEnv) claude --session-id \(uuid) \"$\(firstPromptEnv)\"'"]
        case let .resumeAgent(.claude, uuid):
            args = ["-l", "-c", "exec claude --resume \(uuid)"]
        case .newAgent(.codex, _, _), .resumeAgent(.codex, _):
            args = ["-l", "-c", codex.map { codexCommand($0, mode: mode) } ?? "exit 127"]
        case .shell:
            args = ["-l"]
        }
        var launch = Self(executable: executable, args: args, currentDirectory: folder)
        if let rowID, mode != .shell {
            launch.environment = ["\(sessionRowEnv)=\(rowID)"]
        }
        if let prompt = mode.prompt {
            launch.environment.append("\(firstPromptEnv)=\(mode.agent == .codex ? prompt : positionalPrompt(prompt))")
        }
        return launch
    }

    /// The login shell's command for Codex (spec 2026-10-12 §7): `/bin/sh`
    /// runs `<binary> <launch-args…> [resume '<id>'] [-- "$PROMPT"]`, every
    /// value single-quoted, with `path_prepend` ahead of `PATH` so an nvm
    /// `codex` finds its `node`. Nothing follows `resume <id>` but `--` and
    /// the prompt: a `-c` after the subcommand would replace every root `-c`
    /// (the hooks and the MCP server). The prompt is read from the
    /// environment, after `--`, so one starting with "-" is no flag.
    private static func codexCommand(_ codex: CodexLaunchArgs, mode: Mode) -> String {
        var words = ["exec", "env", "-u", firstPromptEnv, shellQuote(codex.binary)] + codex.args.map(shellQuote)
        if case let .resumeAgent(_, id) = mode { words += ["resume", shellQuote(id)] }
        if mode.prompt != nil { words += ["--", "\"$\(firstPromptEnv)\""] }
        let path = codex.pathPrepend.isEmpty ? "" : "PATH=\(shellQuote(codex.pathPrepend)):\"$PATH\" "
        return "exec /bin/sh -c \(shellQuote(path + words.joined(separator: " ")))"
    }

    /// Single quotes, with a `'` inside written `'\''`: the same in `sh`,
    /// `zsh`, `bash`, `fish` and `csh`.
    package static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// `claude`'s usage documents no `--` before the prompt, so a prompt
    /// starting with "-" gets a leading space and is never read as a flag.
    package static func positionalPrompt(_ prompt: String) -> String {
        prompt.hasPrefix("-") ? " " + prompt : prompt
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

    package static func workOnTargetPrompt(targetID: Int64, vocabulary: WorkbenchVocabulary) -> String {
        "Work on target #\(targetID) using the \(vocabulary.skillName) skill."
    }

    /// "Work on it" on a target with sub-targets (spec 2026-10-08): the skill's
    /// "Working a group" section keys on this wording.
    package static func workOnGroupPrompt(targetID: Int64, vocabulary: WorkbenchVocabulary) -> String {
        "Work on group #\(targetID) using the \(vocabulary.skillName) skill."
    }

    /// The first prompt of a Work on It session: the group wording when the target has sub-targets.
    package static func workOnPrompt(targetID: Int64, isGroup: Bool, vocabulary: WorkbenchVocabulary) -> String {
        isGroup ? workOnGroupPrompt(targetID: targetID, vocabulary: vocabulary)
            : workOnTargetPrompt(targetID: targetID, vocabulary: vocabulary)
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
        switch (agent, code) {
        case (.claude, 127?):
            "Claude Code was not found on your login-shell PATH. Install it, or add it to PATH, then Restart."
        case (.codex, 127?):
            "Codex was not found. Install it, or set codex_path in Watchtower's config, then try again."
        case let (agent, code?):
            "\(agent.displayName) exited (code \(code))."
        case let (agent, nil):
            "\(agent.displayName) exited."
        }
    }
}

/// `watchtower workbench launch-args --agent codex --workbench N --json`
/// (spec 2026-10-12 §4.2): the `codex` binary, the folder to put ahead of
/// `PATH` (its own, so an nvm install finds `node`), and the argv elements
/// that follow the binary (`--no-daemon`, the update-check, MCP and hook
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

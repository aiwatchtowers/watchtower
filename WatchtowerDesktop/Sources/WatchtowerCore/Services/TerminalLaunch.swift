import Foundation

/// How an embedded terminal starts (spec §6.2): the owner's own login shell,
/// so `PATH` and `claude`'s auth are exactly theirs. A Claude session `exec`s
/// `claude` — the resolved binary when there is one (`claudeBinaryEnv`) — in
/// the folder with a session id the app chose, so it can be resumed later. A
/// first prompt (a fixed constant below, or a code question handed over —
/// spec 2026-10-02 §9.5) travels in `firstPromptEnv` and the command names
/// only the variable, read by `/bin/sh` whatever the login shell, so no
/// prompt text is ever parsed by a shell, and `env -u` drops the variable
/// before `claude` runs, so its children never see it; `positionalPrompt`
/// keeps a leading "-" from being read as a flag.
package struct TerminalLaunch: Equatable, Sendable {
    package enum Mode: Equatable, Sendable {
        case newClaude(uuid: String, prompt: String?)
        case resumeClaude(uuid: String)
        case shell
    }

    /// Names the `terminal_sessions` row a `claude` process runs in, so the
    /// workbench's `SessionStart` hook (`watchtower workbench brief`) can store
    /// the conversation's new id after `/clear` or a resume (Go
    /// `terminalSessionEnv`, a dual path).
    package static let sessionRowEnv = "WATCHTOWER_TERMINAL_SESSION_ID"
    /// The first prompt of a new `claude` session.
    package static let firstPromptEnv = "WATCHTOWER_FIRST_PROMPT"
    /// The resolved `claude` binary (`Constants.claudeBinary()`), read by
    /// `/bin/sh` like `firstPromptEnv`, so the path is never parsed by a
    /// shell and a login `PATH` without it (an export only in `.zshrc`) still
    /// launches it (spec 2026-10-10).
    package static let claudeBinaryEnv = "WATCHTOWER_CLAUDE_BIN"

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

    /// Does not validate `uuid`: callers check `isValidSessionID` first.
    /// `rowID` reaches a `claude` launch's environment as `sessionRowEnv`,
    /// `claudeBinary` (the resolved binary) as `claudeBinaryEnv`.
    package static func make(
        shell: String?, folder: String, mode: Mode, rowID: Int64? = nil, claudeBinary: String? = nil
    ) -> Self {
        let executable = shell.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? fallbackShell
        let args: [String]
        switch mode {
        case let .newClaude(uuid, prompt):
            args = ["-l", "-c", claudeCommand("--session-id \(uuid)", resolved: claudeBinary != nil, withPrompt: prompt != nil)]
        case let .resumeClaude(uuid):
            args = ["-l", "-c", claudeCommand("--resume \(uuid)", resolved: claudeBinary != nil, withPrompt: false)]
        case .shell:
            args = ["-l"]
        }
        var launch = Self(executable: executable, args: args, currentDirectory: folder)
        if let rowID, mode != .shell {
            launch.environment = ["\(sessionRowEnv)=\(rowID)"]
        }
        if let claudeBinary, mode != .shell {
            launch.environment.append("\(claudeBinaryEnv)=\(claudeBinary)")
        }
        if case let .newClaude(_, prompt?) = mode {
            launch.environment.append("\(firstPromptEnv)=\(positionalPrompt(prompt))")
        }
        return launch
    }

    /// The login shell's command for `claude <tail>`. Bare `exec claude`
    /// when nothing travels in the environment; otherwise `/bin/sh` reads
    /// the variables (the login shell only runs a single-quoted literal, so
    /// one whose `$VAR` is not POSIX — nushell's `$env.VAR` — or that
    /// quotes differently — csh — still works) and `env -u` drops them
    /// before `claude` runs, so its children never see them. A resolved
    /// binary's directory leads `PATH`, so a hook running `claude` by name
    /// finds the same one.
    private static func claudeCommand(_ tail: String, resolved: Bool, withPrompt: Bool) -> String {
        guard resolved || withPrompt else { return "exec claude \(tail)" }
        var unset = resolved ? ["-u \(claudeBinaryEnv)"] : []
        if withPrompt { unset.append("-u \(firstPromptEnv)") }
        let pathFix = resolved ? "export PATH=\"$(dirname \"$\(claudeBinaryEnv)\")\":\"$PATH\"; " : ""
        let binary = resolved ? "\"$\(claudeBinaryEnv)\"" : "claude"
        let prompt = withPrompt ? " \"$\(firstPromptEnv)\"" : ""
        return "exec /bin/sh -c '\(pathFix)exec env \(unset.joined(separator: " ")) \(binary) \(tail)\(prompt)'"
    }

    /// `claude`'s usage documents no `--` before the prompt, so a prompt
    /// starting with "-" gets a leading space and is never read as a flag.
    package static func positionalPrompt(_ prompt: String) -> String {
        prompt.hasPrefix("-") ? " " + prompt : prompt
    }

    /// Lowercase canonical UUID only (same as Go's `uuidRe`): the id is
    /// interpolated into a shell command, so nothing else may pass.
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
    /// "command not found": no `claude` was resolved and the login shell's
    /// PATH has none, which a bare exit code would not tell the owner.
    package static func exitMessage(code: Int32?) -> String {
        switch code {
        case 127?:
            "Claude Code was not found. Set its path, or add it to your login shell's PATH, then Restart."
        case let code?:
            "Claude Code exited (code \(code))."
        case nil:
            "Claude Code exited."
        }
    }

    /// Whether the exit bar offers **Set Claude Path…**: only a Claude
    /// session's 127 — a shell's 127 is the owner's last command.
    package static func offersClaudePathFix(code: Int32?, isClaude: Bool) -> Bool {
        isClaude && code == 127
    }
}

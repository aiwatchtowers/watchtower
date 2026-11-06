import Foundation

/// Claude Code (Go `sessionagent.claudeAdapter`): hooks installed into the
/// folder, a session id the app chooses, transcripts under
/// `~/.claude/projects`.
package struct ClaudeSessionAgent: SessionAgent {
    package init() {}

    package var kind: AgentKind { .claude }

    package var caps: AgentSessionCaps {
        AgentSessionCaps(
            midturnInput: true, phoneInput: true, permissionWait: true, idleSignal: true, elicitation: true,
            appSessionID: true
        )
    }

    package var wireAgent: String { "claude_code" }

    package var inputProfile: AgentInputProfile { .claude }

    /// 127 is the shell's "command not found": `exec claude` found no `claude`
    /// on the login shell's PATH.
    package var notFoundMessage: String {
        "Claude Code was not found on your login-shell PATH. Install it, or add it to PATH, then Restart."
    }

    /// `exec claude` with the app's id, `--resume` for a resume. A first
    /// prompt travels in `TerminalLaunch.firstPromptEnv`: `/bin/sh` reads the
    /// variable (the login shell only runs a single-quoted literal, so one
    /// whose `$VAR` is not POSIX — nushell's `$env.VAR` — or that quotes
    /// differently — csh — still passes the prompt as one argument), and
    /// `env -u` keeps it out of everything Claude Code runs. `claude` is
    /// looked up on the login shell's PATH, so the start always runs.
    package func launchCommand(_ start: AgentStart) -> AgentLaunchCommand {
        let id = start.sessionID ?? ""
        if start.resume { return AgentLaunchCommand(command: "exec claude --resume \(id)", runs: true) }
        guard let prompt = start.prompt else {
            return AgentLaunchCommand(command: "exec claude --session-id \(id)", runs: true)
        }
        let env = TerminalLaunch.firstPromptEnv
        return AgentLaunchCommand(
            command: "exec /bin/sh -c 'exec env -u \(env) claude --session-id \(id) \"$\(env)\"'",
            prompt: TerminalLaunch.positionalPrompt(prompt),
            runs: true
        )
    }

    /// Claude Code's transcript is found by id; the stored path and the home
    /// are not read.
    package func transcriptExists(id: String, storedPath _: String?, home _: URL?, in lookups: AgentTranscriptLookups) -> Bool {
        lookups.claude(id)
    }

    /// Always `~/.claude` (`ClaudeTranscript.defaultConfigDir`), whatever the
    /// environment: the lookup finds it itself.
    package func transcriptHome(environment _: [String: String]) -> URL? { nil }
}

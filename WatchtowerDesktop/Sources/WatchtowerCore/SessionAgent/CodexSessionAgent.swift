import Foundation

/// Codex (Go `sessionagent.codexAdapter`): hooks and MCP server arrive with
/// its launch flags (`workbench launch-args`), it mints its own session id,
/// and its transcripts are rollouts under `$CODEX_HOME/sessions`.
package struct CodexSessionAgent: SessionAgent {
    package init() {}

    package var subscriptionUsage: SubscriptionUsagePolicy {
        SubscriptionUsagePolicy(title: "Codex", signInApplication: "Codex",
                                statusTable: "codex_plan_usage_status", samplesTable: "codex_plan_usage_samples",
                                storage: .identityScoped, defaultQuotaBucket: "codex", layout: .grouped, tint: "teal", icon: "terminal",
                                suppliesSurfaceBreakdown: false, sendsNotifications: false)
    }

    package var kind: AgentKind { .codex }

    /// Plan Task G7's spikes on codex 0.159.2: a line pasted mid-turn goes
    /// into the running turn, but an MCP form it opens mid-turn raises no
    /// hook state, so nothing is sent while it works; its PermissionRequest
    /// hook hides the terminal prompt while it holds, so it does not wait for
    /// the phone; it has no idle event; a failed or interrupted turn is read
    /// from its rollout.
    package var caps: AgentSessionCaps {
        AgentSessionCaps(
            midturnInput: true, phoneInput: true, permissionWait: false, idleSignal: false, elicitation: false,
            rolloutWatch: true, launchHooks: true
        )
    }

    package var wireAgent: String { "codex_cli" }

    package var inputProfile: AgentInputProfile { .codex }

    /// 127: no `codex` binary, on the login shell's PATH or as `launch-args`
    /// resolved it.
    package var notFoundMessage: String {
        "Codex was not found. Install it, or set codex_path in Watchtower's config, then try again."
    }

    package var notFoundReason: String { "codex_not_found" }

    /// Runs `codex` as `launch-args` resolved it, its script in
    /// `TerminalLaunch.codexCommandEnv`; without one there is no binary to
    /// run and the start exits 127 (`TerminalCenter.start` refuses such a
    /// launch before it gets here; this stays total for any other caller).
    package func launchCommand(_ start: AgentStart) -> AgentLaunchCommand {
        let prompt = start.newPrompt
        guard let args = start.launchArgs else {
            return AgentLaunchCommand(command: "exit 127", prompt: prompt, runs: false)
        }
        return AgentLaunchCommand(
            command: TerminalLaunch.codexLoginCommand,
            environment: ["\(TerminalLaunch.codexCommandEnv)=\(Self.script(args, start: start))"],
            prompt: prompt,
            runs: true
        )
    }

    /// The Codex script (spec 2026-10-12 §7): `<binary> <launch-args…>
    /// [resume '<id>'] [-- "$PROMPT"]`, every value single-quoted, with
    /// `path_prepend` ahead of `PATH` so an nvm `codex` finds its `node`.
    /// Nothing follows `resume <id>` but `--` and the prompt: a `-c` after
    /// the subcommand would replace every root `-c` (the hooks and the MCP
    /// server). The prompt is read from the environment, after `--`, so one
    /// starting with "-" is no flag. `env -u` drops both variables before
    /// `codex` runs.
    static func script(_ codex: CodexLaunchArgs, start: AgentStart) -> String {
        let quote = TerminalLaunch.shellQuote
        var words = ["exec", "env", "-u", TerminalLaunch.firstPromptEnv, "-u", TerminalLaunch.codexCommandEnv,
                     quote(codex.binary)] + codex.args.map(quote)
        if start.resume, let id = start.sessionID { words += ["resume", quote(id)] }
        if start.newPrompt != nil { words += ["--", "\"$\(TerminalLaunch.firstPromptEnv)\""] }
        let path = codex.pathPrepend.isEmpty ? "" : "PATH=\(quote(codex.pathPrepend)):\"$PATH\" "
        return path + words.joined(separator: " ")
    }

    /// A rollout at the stored path, or under `home`.
    package func transcriptExists(id: String, storedPath: String?, home: URL?, in lookups: AgentTranscriptLookups) throws -> Bool {
        try lookups.codex(id, storedPath, home)
    }

    /// `$CODEX_HOME` when absolute, else `~/.codex` (`CodexRollout.home`).
    package func transcriptHome(environment: [String: String]) -> URL? {
        CodexRollout.home(environment: environment)
    }
}

package chat

import "strings"

// ClaudeAIMode turns on the warm Claude session's claude.ai tools: publishing
// to the owner's claude.ai account and the account's claude.ai connectors.
// The zero value is off: argv and environment exactly as without it.
type ClaudeAIMode struct {
	// On drops --strict-mcp-config (the account's connectors load), answers
	// every permission request over stdio (--permission-prompt-tool stdio)
	// and registers the Artifact built-in (CLAUDE_CODE_ARTIFACT=1). Set it
	// only when ClaudeAIAvailability says so.
	On bool
	// Connectors is the owner's ai.claude_ai.connectors switch; false keeps
	// publishing and loads no connector (ENABLE_CLAUDEAI_MCP_SERVERS=0).
	Connectors bool
}

// claudeAIOffMarkers are the child environment variables under which the CLI
// does not use the owner's claude.ai login, in the order their reason is
// reported: an API key or token takes precedence over the login, and a
// third-party provider has neither connectors nor Artifact.
var claudeAIOffMarkers = []struct{ name, uses string }{
	{"ANTHROPIC_API_KEY", "an API key"},
	{"ANTHROPIC_AUTH_TOKEN", "an API key"},
	{"CLAUDE_CODE_USE_BEDROCK", "Bedrock"},
	{"CLAUDE_CODE_USE_VERTEX", "Vertex"},
	{"CLAUDE_CODE_USE_FOUNDRY", "Foundry"},
}

// ClaudeAIAvailability reports whether a chat session may run in claude.ai
// mode: the Claude provider (provider is a resolved provider id, "claude"),
// the main chat surface (embedded chats get nothing, decision Q2) and a child
// environment env (KEY=VALUE entries, the last one of a key wins, as for
// exec.Cmd.Env) that leaves the CLI on the owner's claude.ai login. env must
// be the whole environment the child gets — os.Environ() plus
// ClaudeOptions.Env — or a key inherited from the app's own environment is
// missed. When it is off, reason says why, for the prompt and the Settings
// sidecar.
func ClaudeAIAvailability(env []string, provider, surface string) (on bool, reason string) {
	if provider != "claude" {
		return false, "claude.ai tools need the Claude provider."
	}
	if surface != "main" {
		return false, "claude.ai tools are available in the main chat only."
	}
	for _, m := range claudeAIOffMarkers {
		if envValue(env, m.name) != "" {
			return false, "claude.ai tools need a claude.ai login; this chat uses " + m.uses + "."
		}
	}
	return true, ""
}

// envValue is the value of key in env ("" when unset), the last entry
// winning.
func envValue(env []string, key string) string {
	v := ""
	for _, kv := range env {
		if k, val, ok := strings.Cut(kv, "="); ok && k == key {
			v = val
		}
	}
	return v
}

// claudeAIEnv is the environment claude.ai mode adds to the child: Artifact
// registered in print mode, the CLI never opening a browser itself (the
// Desktop shows the link card), and the connectors exactly as the owner's
// switch says — set both ways, so a value inherited from the app's own
// environment never overrides Settings. Nil when the mode is off.
func claudeAIEnv(m ClaudeAIMode) []string {
	if !m.On {
		return nil
	}
	connectors := "0"
	if m.Connectors {
		connectors = "1"
	}
	return []string{"CLAUDE_CODE_ARTIFACT=1", "CLAUDE_CODE_ARTIFACT_AUTO_OPEN=0",
		"ENABLE_CLAUDEAI_MCP_SERVERS=" + connectors}
}

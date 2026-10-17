package chat

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// claudeAITestOptions is a warm-session ClaudeOptions with every argv field
// set, so a test sees each flag claudeArgs can emit.
func claudeAITestOptions(mode ClaudeAIMode) ClaudeOptions {
	return ClaudeOptions{Model: "sonnet", Tools: "ToolSearch,WebSearch", AllowedTools: "mcp__watchtower",
		DisallowedTools: "Bash", ClaudeAI: mode}
}

// Off, the warm child's argv is byte-identical to the one before claude.ai
// mode existed: fresh and resumed.
func TestClaudeArgs_OffIsUnchanged(t *testing.T) {
	head := []string{"-p", "--input-format", "stream-json", "--output-format", "stream-json",
		"--include-partial-messages", "--verbose", "--setting-sources", "project,local", "--strict-mcp-config",
		"--model", "sonnet", "--mcp-config", "/tmp/m", "--tools", "ToolSearch,WebSearch",
		"--allowedTools", "mcp__watchtower", "--disallowedTools", "Bash"}
	o := claudeAITestOptions(ClaudeAIMode{})
	assert.Equal(t, append(append([]string{}, head...), "--system-prompt-file", "/tmp/p"),
		claudeArgs(o, "/tmp/p", "/tmp/m", ""))
	assert.Equal(t, append(append([]string{}, head...), "--resume", "sess-9"),
		claudeArgs(o, "/tmp/p", "/tmp/m", "sess-9"))
	// Connectors alone (mode not on) changes nothing.
	assert.Equal(t, claudeArgs(o, "/tmp/p", "/tmp/m", ""),
		claudeArgs(claudeAITestOptions(ClaudeAIMode{Connectors: true}), "/tmp/p", "/tmp/m", ""))
}

// On, the child loads the account's connectors (no --strict-mcp-config) and
// asks the host about every call not pre-allowed (--permission-prompt-tool
// stdio); the TCC guard (--setting-sources project,local) and every other
// flag stay as they are.
func TestClaudeArgs_ClaudeAIModeDropsStrictAndAddsGate(t *testing.T) {
	for _, connectors := range []bool{true, false} {
		for _, resume := range []string{"", "sess-9"} {
			mode := ClaudeAIMode{On: true, Connectors: connectors}
			args := claudeArgs(claudeAITestOptions(mode), "/tmp/p", "/tmp/m", resume)
			off := claudeArgs(claudeAITestOptions(ClaudeAIMode{}), "/tmp/p", "/tmp/m", resume)
			assert.NotContains(t, args, "--strict-mcp-config", "connectors=%v resume=%q", connectors, resume)
			i := indexOf(args, "--permission-prompt-tool")
			require.GreaterOrEqual(t, i, 0)
			assert.Equal(t, "stdio", args[i+1])
			assert.Equal(t, i, lastIndexOf(args, "--permission-prompt-tool"), "passed once")
			j := indexOf(args, "--setting-sources")
			require.GreaterOrEqual(t, j, 0, "the TCC guard stays")
			assert.Equal(t, "project,local", args[j+1])

			// Apart from the swapped flag, the argv is the off one.
			assert.Equal(t, without(off, "--strict-mcp-config"), without(args, "--permission-prompt-tool", "stdio"))
		}
	}
}

// without returns args minus every element in drop.
func without(args []string, drop ...string) []string {
	var out []string
	for _, a := range args {
		if !contains(drop, a) {
			out = append(out, a)
		}
	}
	return out
}

// The claude.ai mode values reach the child's environment after this
// process's own (so they win over an inherited value) and before the extra
// ClaudeOptions.Env; off adds none of them.
func TestClaudeEnv_ClaudeAIMode(t *testing.T) {
	keys := []string{"CLAUDE_CODE_ARTIFACT", "CLAUDE_CODE_ARTIFACT_AUTO_OPEN", "ENABLE_CLAUDEAI_MCP_SERVERS"}
	for _, k := range keys {
		t.Setenv(k, "inherited")
	}

	on := claudeEnv(ClaudeOptions{ClaudeAI: ClaudeAIMode{On: true, Connectors: true}})
	assert.Equal(t, "1", envValue(on, "CLAUDE_CODE_ARTIFACT"))
	assert.Equal(t, "0", envValue(on, "CLAUDE_CODE_ARTIFACT_AUTO_OPEN"), "the CLI never opens a browser itself")
	assert.Equal(t, "inherited", envValue(on, "ENABLE_CLAUDEAI_MCP_SERVERS"), "connectors on sets nothing")
	assert.Contains(t, envValue(on, "PATH"), "/", "the rich PATH is still there")

	noConn := claudeEnv(ClaudeOptions{ClaudeAI: ClaudeAIMode{On: true}})
	assert.Equal(t, "1", envValue(noConn, "CLAUDE_CODE_ARTIFACT"))
	assert.Equal(t, "0", envValue(noConn, "CLAUDE_CODE_ARTIFACT_AUTO_OPEN"))
	assert.Equal(t, "0", envValue(noConn, "ENABLE_CLAUDEAI_MCP_SERVERS"), "connectors off loads none")

	off := claudeEnv(ClaudeOptions{ClaudeAI: ClaudeAIMode{Connectors: false}})
	for _, k := range keys {
		assert.Equal(t, "inherited", envValue(off, k), "off adds no claude.ai value: %s", k)
	}

	extra := claudeEnv(ClaudeOptions{ClaudeAI: ClaudeAIMode{On: true}, Env: []string{"CLAUDE_CODE_ARTIFACT=test"}})
	assert.Equal(t, "test", envValue(extra, "CLAUDE_CODE_ARTIFACT"), "ClaudeOptions.Env comes last")
}

func TestClaudeAIAvailability(t *testing.T) {
	const apiKey = "claude.ai tools need a claude.ai login; this chat uses an API key."
	cases := []struct {
		name, provider, surface string
		env                     []string
		on                      bool
		reason                  string
	}{
		{"all clear", "claude", "main", []string{"HOME=/h", "PATH=/bin"}, true, ""},
		{"nil env", "claude", "main", nil, true, ""},
		{"empty markers", "claude", "main", []string{"ANTHROPIC_API_KEY=", "CLAUDE_CODE_USE_BEDROCK="}, true, ""},
		{"marker cleared later", "claude", "main", []string{"ANTHROPIC_API_KEY=k", "ANTHROPIC_API_KEY="}, true, ""},
		{"api key", "claude", "main", []string{"ANTHROPIC_API_KEY=k"}, false, apiKey},
		{"auth token", "claude", "main", []string{"ANTHROPIC_AUTH_TOKEN=t"}, false, apiKey},
		{"bedrock", "claude", "main", []string{"CLAUDE_CODE_USE_BEDROCK=1"}, false,
			"claude.ai tools need a claude.ai login; this chat uses Bedrock."},
		{"vertex", "claude", "main", []string{"CLAUDE_CODE_USE_VERTEX=1"}, false,
			"claude.ai tools need a claude.ai login; this chat uses Vertex."},
		{"foundry", "claude", "main", []string{"CLAUDE_CODE_USE_FOUNDRY=1"}, false,
			"claude.ai tools need a claude.ai login; this chat uses Foundry."},
		{"marker set later", "claude", "main", []string{"CLAUDE_CODE_USE_VERTEX=", "CLAUDE_CODE_USE_VERTEX=1"}, false,
			"claude.ai tools need a claude.ai login; this chat uses Vertex."},
		{"key and bedrock", "claude", "main", []string{"CLAUDE_CODE_USE_BEDROCK=1", "ANTHROPIC_API_KEY=k"}, false, apiKey},
		{"codex", "codex", "main", nil, false, "claude.ai tools need the Claude provider."},
		{"ollama", "ollama", "main", nil, false, "claude.ai tools need the Claude provider."},
		{"surface target", "claude", "target", nil, false, "claude.ai tools are available in the main chat only."},
	}
	for _, c := range cases {
		on, reason := ClaudeAIAvailability(c.env, c.provider, c.surface)
		assert.Equal(t, c.on, on, c.name)
		assert.Equal(t, c.reason, reason, c.name)
	}
}

package codex

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/providers"
)

const (
	// liveCodexEnv opts into TestCodexLive_* (=1): they run the installed
	// codex CLI against the owner's sign-in, so they need the network and
	// bill a few light-model turns. Never in CI.
	liveCodexEnv = "WATCHTOWER_LIVE_CODEX"
	// liveCodexModelEnv overrides the model (default: codex's light tier).
	liveCodexModelEnv = "WATCHTOWER_LIVE_CODEX_MODEL"
	// liveMCPNonceEnv, set on a test binary started as `<test> mcp …`, makes
	// it the fake watchtower MCP server whose get_nonce tool returns it
	// (TestMain → runFakeMCPServer).
	liveMCPNonceEnv = "WT_LIVE_MCP_NONCE"
)

// liveCodexHome is CODEX_HOME as the test process got it, before TestMain
// pointed it at a hermetic temp home; the live tests sign in through it.
var liveCodexHome string

// TestCodexLive_SystemPromptAndMCPTool runs the interactive client's real
// argv — every disabledFeatures flag but toolRunFeatures off (with
// code_mode_host off too, codex 0.159.2 answers every tool call
// "unavailable"), the system prompt as a
// model_instructions_file, the watchtower server mounted by the -c override
// — against the installed codex: the answer must carry a nonce only the
// system prompt names and one only the mounted MCP tool returns. A codex
// release that stops honouring a flag, or a launch change like #669 (the
// prompt file removed while codex still needed it), fails here and not in
// the stub-driven tests.
func TestCodexLive_SystemPromptAndMCPTool(t *testing.T) {
	bin, model := liveCodexSetup(t)
	promptNonce, toolNonce := liveNonce(t), liveNonce(t)
	t.Setenv(liveMCPNonceEnv, toolNonce)

	c := NewClient(model, filepath.Join(t.TempDir(), "live.db"), bin)
	c.SetMCPEnvVars([]string{liveMCPNonceEnv})
	sys := "You are a connectivity probe. First call the get_nonce tool of the watchtower MCP server. " +
		"Then reply with exactly two words: " + promptNonce + " and then the text the tool returned. Nothing else."
	text := liveQuery(t, c, sys, "Run the probe.")
	assert.Contains(t, text, promptNonce, "the system prompt reached the model")
	assert.Contains(t, text, toolNonce, "the mounted MCP tool was called")
}

// TestCodexLive_ChatToolStepAndUsage runs the real codex through the
// streaming Query with the chat's v2 events on: the MCP call must come back
// as one tool start/end pair under its claude-form name with the arguments
// the model sent and the tool's result text, the answer must follow, and the
// turn's usage must be streamed — the item and usage field names the
// stub-driven tests assume, checked against codex itself.
func TestCodexLive_ChatToolStepAndUsage(t *testing.T) {
	bin, model := liveCodexSetup(t)
	toolNonce := liveNonce(t)
	t.Setenv(liveMCPNonceEnv, toolNonce)

	c := NewClient(model, filepath.Join(t.TempDir(), "live.db"), bin)
	c.SetMCPEnvVars([]string{liveMCPNonceEnv})
	c.EmitToolEvents()
	sys := "You are a connectivity probe. Call the get_nonce tool of the watchtower MCP server exactly once, " +
		`with the argument label set to "probe". Then reply with only the text the tool returned.`
	ctx := context.Background()
	textCh, errCh, sidCh := c.Query(ctx, sys, "Run the probe.", "")
	var starts, ends []ai.ToolEvent
	var usage []ai.TurnUsage
	var text strings.Builder
	for ch := range textCh {
		switch {
		case ch.Tool != nil && ch.Tool.Done:
			ends = append(ends, *ch.Tool)
		case ch.Tool != nil:
			starts = append(starts, *ch.Tool)
		case ch.Usage != nil:
			usage = append(usage, *ch.Usage)
		}
		text.WriteString(ch.Text)
	}
	for range sidCh {
	}
	for err := range errCh {
		require.NoError(t, err)
	}
	t.Logf("codex answered: %q; starts %+v; ends %+v; usage %+v", text.String(), starts, ends, usage)

	require.Len(t, starts, 1, "one tool start")
	require.Len(t, ends, 1, "one tool end")
	assert.Equal(t, "mcp__watchtower__get_nonce", starts[0].Name)
	assert.JSONEq(t, `{"label":"probe"}`, string(starts[0].Args))
	assert.Equal(t, starts[0].ID, ends[0].ID)
	assert.NotEmpty(t, ends[0].ID)
	assert.Equal(t, starts[0].Name, ends[0].Name)
	assert.True(t, ends[0].OK)
	assert.Equal(t, toolNonce, ends[0].Result)
	assert.Contains(t, text.String(), toolNonce)
	require.Len(t, usage, 1)
	assert.Equal(t, model, usage[0].Model)
	assert.Positive(t, usage[0].InputTokens())
	assert.Positive(t, usage[0].OutputTokens())
}

// TestCodexLive_ReadFolder: a read-folder run (code questions, the spec
// reviewer) still reads a file through the shell with the login-shell
// snapshot and every other disabledFeatures flag off.
func TestCodexLive_ReadFolder(t *testing.T) {
	bin, model := liveCodexSetup(t)
	fileNonce := liveNonce(t)
	dir := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(dir, "nonce.txt"), []byte(fileNonce+"\n"), 0o600))

	c := NewClient(model, "", bin)
	c.SetReadFolder(dir)
	c.SetNoMCPServers()
	text := liveQuery(t, c, "Answer only with what is asked, no other words.",
		"Read the file nonce.txt in the current folder and reply with its content only.")
	assert.Contains(t, text, fileNonce)
}

// TestCodexLive_Batch: a batch call (digests, `ai test`) with the tool-less
// profile delivers its system prompt as a model_instructions_file.
func TestCodexLive_Batch(t *testing.T) {
	bin, model := liveCodexSetup(t)
	nonce := liveNonce(t)
	gen := NewCodexGenerator(model, model, bin)
	gen.SetIsolatedChild()
	ctx := context.Background()
	text, _, _, err := gen.Generate(ctx, "Reply with exactly one word: "+nonce+". Nothing else.", "Reply now.", "")
	require.NoError(t, err)
	t.Logf("codex answered: %q", text)
	assert.Contains(t, text, nonce)
}

// liveCodexSetup skips unless liveCodexEnv=1, restores the owner's codex
// home and the real version probe, and returns the codex binary and model.
func liveCodexSetup(t *testing.T) (bin, model string) {
	t.Helper()
	if os.Getenv(liveCodexEnv) != "1" {
		t.Skipf("set %s=1 to run against the installed codex CLI (network, owner sign-in)", liveCodexEnv)
	}
	useRealVersionProbe(t)
	bin = FindBinary("")
	require.NotEmpty(t, bin, "codex CLI not found")
	require.True(t, instructionsFileSupported(bin), "the installed codex must take model_instructions_file")
	t.Setenv("CODEX_HOME", liveCodexHome) // "" = codex's default ~/.codex
	if liveCodexHome == "" {
		require.NoError(t, os.Unsetenv("CODEX_HOME"))
	}
	model = os.Getenv(liveCodexModelEnv)
	if model == "" {
		model = providers.ByID("codex").DefaultLight
	}
	return bin, model
}

// liveQuery runs one QuerySync with a 3-minute budget.
func liveQuery(t *testing.T, c *Client, systemPrompt, userMessage string) string {
	t.Helper()
	ctx := context.Background()
	text, _, err := c.QuerySync(ctx, systemPrompt, userMessage, "")
	require.NoError(t, err)
	t.Logf("codex answered: %q", text)
	return text
}

func liveNonce(t *testing.T) string {
	t.Helper()
	return "n" + rand.Text()
}

// runFakeMCPServer is a minimal stdio MCP server (newline-delimited
// JSON-RPC) with one tool, get_nonce, returning nonce.
func runFakeMCPServer(nonce string) int {
	type request struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
		Params struct {
			ProtocolVersion string `json:"protocolVersion"`
		} `json:"params"`
	}
	enc := json.NewEncoder(os.Stdout)
	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 0, 1<<16), 1<<22)
	for sc.Scan() {
		var req request
		if json.Unmarshal(sc.Bytes(), &req) != nil || len(req.ID) == 0 {
			continue // a notification
		}
		var result any
		switch req.Method {
		case "initialize":
			result = map[string]any{
				"protocolVersion": req.Params.ProtocolVersion,
				"capabilities":    map[string]any{"tools": map[string]any{}},
				"serverInfo":      map[string]any{"name": "watchtower-live-fake", "version": "1"},
			}
		case "tools/list":
			result = map[string]any{"tools": []any{map[string]any{
				"name":        "get_nonce",
				"description": "Returns the probe nonce.",
				"inputSchema": map[string]any{"type": "object", "properties": map[string]any{
					"label": map[string]any{"type": "string", "description": "A label for the probe."},
				}},
			}}}
		case "tools/call":
			result = map[string]any{"content": []any{map[string]any{"type": "text", "text": nonce}}}
		case "ping":
			result = map[string]any{}
		default:
			_ = enc.Encode(map[string]any{"jsonrpc": "2.0", "id": req.ID,
				"error": map[string]any{"code": -32601, "message": "method not found"}})
			continue
		}
		_ = enc.Encode(map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": result})
	}
	if err := sc.Err(); err != nil {
		fmt.Fprintf(os.Stderr, "fake MCP server: reading stdin: %v\n", err)
		return 1
	}
	return 0
}

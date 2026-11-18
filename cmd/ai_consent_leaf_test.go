package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/aiconsent"
	"watchtower/internal/aiconsent/aiconsenttest"
	"watchtower/internal/automations"
	"watchtower/internal/chat"
	"watchtower/internal/claude"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/policy"
	"watchtower/internal/policy/policytest"
	"watchtower/internal/providers/transport"
	"watchtower/internal/tools"
)

var backgroundEnv = map[string]string{aiconsent.EnvOrigin: "background"}

// fakeChatServer is an OpenAI-compatible endpoint that counts the model
// calls it answers.
func fakeChatServer(t *testing.T) (*httptest.Server, *atomic.Int32) {
	t.Helper()
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		_, _ = w.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"done"}}],` +
			`"usage":{"prompt_tokens":12,"completion_tokens":3,"total_tokens":15}}`))
	}))
	t.Cleanup(srv.Close)
	return srv, &calls
}

// BGAI-02: a process a background unit started (EnvOrigin=background) is
// refused by every wrapper while paused, in any process role; admitted, it
// runs.
func TestPolicyCheckedGenerator_RefusesBackgroundOriginInAnyProcess(t *testing.T) {
	policytest.Set(t, nil)
	aiconsenttest.Use(t, "cli", backgroundEnv, false)
	inner := &countingGenerator{}
	gen := policyCheckedGenerator{inner: inner, provider: "claude"}
	_, _, _, err := gen.Generate(context.Background(), "", "", "")
	require.ErrorIs(t, err, aiconsent.ErrPaused)
	_, _, err = gen.GenerateWithImage(context.Background(), "", "", "", "")
	require.ErrorIs(t, err, aiconsent.ErrPaused)
	assert.Equal(t, 0, inner.calls)

	prov := policyCheckedProvider{inner: newRefusedProvider(errors.New("inner must not run")), provider: "claude"}
	_, _, err = prov.QuerySync(context.Background(), "", "", "")
	require.ErrorIs(t, err, aiconsent.ErrPaused)
	chunks, errs, ids := prov.Query(context.Background(), "", "", "")
	for range chunks {
	}
	for range ids {
	}
	require.ErrorIs(t, <-errs, aiconsent.ErrPaused)

	backend := &fakeTurnBackend{}
	var events []chat.Event
	err = policyCheckedBackend{Backend: backend, provider: "claude"}.Turn(context.Background(), chat.Command{TurnID: "t1"},
		func(e chat.Event) { events = append(events, e) })
	require.ErrorIs(t, err, aiconsent.ErrPaused)
	assert.Equal(t, 0, backend.turns)
	require.NotEmpty(t, events)
	assert.Equal(t, chat.EventError, events[len(events)-1].Type)
	assert.Equal(t, "t1", events[len(events)-1].TurnID)

	aiconsenttest.Use(t, "cli", map[string]string{aiconsent.EnvOrigin: "background", aiconsent.EnvAdmitted: "phase:digests"}, false)
	_, _, _, err = gen.Generate(context.Background(), "", "", "")
	require.NoError(t, err)
	assert.Equal(t, 1, inner.calls)
}

// BGAI-02: a command the owner typed is an owner call; paused does not stop
// the `digest generate` generator chain.
func TestBGAI02_TypedCommandNotGated(t *testing.T) {
	policytest.Set(t, nil)
	aiconsenttest.Use(t, "cli", nil, false)
	t.Setenv("HOME", t.TempDir())
	srv, calls := fakeChatServer(t)
	cfg := &config.Config{ActiveWorkspace: "test"}
	cfg.AI.Provider, cfg.AI.OllamaURL = "ollama", srv.URL

	gen, cleanup := cliPooledGenerator(cfg)
	t.Cleanup(cleanup)
	text, _, _, err := gen.Generate(context.Background(), "sys", "user", "")
	require.NoError(t, err)
	assert.Equal(t, "done", text)
	assert.Equal(t, int32(1), calls.Load())
}

// Decision 3, fail-closed side: in the daemon a call nobody marked is
// background and refused while paused; a request marked owner runs.
func TestBGAI02_DaemonUnmarkedCallStaysGated(t *testing.T) {
	policytest.Set(t, nil)
	aiconsenttest.Use(t, "daemon", nil, false)
	inner := &countingGenerator{}
	gen := policyCheckedGenerator{inner: inner, provider: "claude"}
	_, _, _, err := gen.Generate(context.Background(), "", "", "")
	require.ErrorIs(t, err, aiconsent.ErrPaused)
	assert.Equal(t, 0, inner.calls)

	_, _, _, err = gen.Generate(aiconsent.WithOwnerStarted(context.Background()), "", "", "")
	require.NoError(t, err)
	assert.Equal(t, 1, inner.calls)
}

// A paused, unadmitted agent() spawns no child and meters nothing, on both
// runners.
func TestCLIAgentRunner_PausedSpawnsNothing(t *testing.T) {
	policytest.Set(t, nil)
	aiconsenttest.Use(t, "daemon", nil, false)
	bin, marker := writeMarkerStub(t)
	cfg := &config.Config{ClaudePath: bin, CodexPath: bin, ActiveWorkspace: "test"}
	cfg.AI.Provider = "claude"
	metered := 0
	req := automations.AgentRequest{Instruction: "triage", Tools: []string{}, Deadline: time.Now().Add(time.Minute),
		BeforeModelCall: func() error { metered++; return nil }, AfterModelCall: func(int, int) {}}

	_, err := (&cliAgentRunner{cfg: cfg, provider: "claude", prepared: true}).Run(context.Background(), req)
	var sdkErr *automations.SDKError
	require.ErrorAs(t, err, &sdkErr)
	assert.Equal(t, automations.ErrNamePolicy, sdkErr.Name)
	assert.Equal(t, aiconsent.ErrPaused.Error(), sdkErr.Message)
	require.ErrorIs(t, err, aiconsent.ErrPaused)
	_, statErr := os.Stat(marker)
	assert.True(t, errors.Is(statErr, os.ErrNotExist), "no agent child started")

	srv, calls := fakeChatServer(t)
	ollamaCfg := &config.Config{}
	ollamaCfg.AI.Provider, ollamaCfg.AI.OllamaURL = "ollama", srv.URL
	_, err = (&runtimeBAgentRunner{cfg: ollamaCfg, reg: tools.NewReadRegistry(db.OpenTestDB(t))}).Run(context.Background(), req)
	require.ErrorAs(t, err, &sdkErr)
	assert.Equal(t, aiconsent.ErrPaused.Error(), sdkErr.Message)
	require.ErrorIs(t, err, aiconsent.ErrPaused)
	assert.Equal(t, int32(0), calls.Load())
	assert.Equal(t, 0, metered)
}

// D17: the plan-limit read is no model call; paused never stops it.
func TestPlanUsagePoller_NotGatedByConsent(t *testing.T) {
	aiconsenttest.Use(t, "daemon", nil, false)
	database := db.OpenTestDB(t)
	poller := newPlanUsagePoller(database, log.New(io.Discard, "", 0))
	require.NotNil(t, poller.Read)
	reads := 0
	// The production Read spawns `claude` for get_usage; the stand-in keeps
	// the poll in-process, as the token reader's fake client did.
	poller.Read = func(context.Context) (claude.UsageSnapshot, error) {
		reads++
		return claude.UsageSnapshot{Plan: "max", Windows: []claude.UsageWindow{
			{Key: "five_hour", Label: "5-hour", Group: "session", Percent: 12.5},
		}}, nil
	}

	_, err := poller.PollOnce(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, reads)
	st, err := database.GetPlanUsageStatus()
	require.NoError(t, err)
	require.NotNil(t, st)
	assert.Equal(t, "ok", st.State)
}

// BGAI-01: with the Claude↔Codex reserve on, the long-lived client is a
// toolRouteProvider (the daemon's Jira board analyzer, the actions
// registry). Paused, an unadmitted call builds no leaf.
func TestToolRouteProvider_PausedBuildsNoLeaf(t *testing.T) {
	policytest.Set(t, nil)
	aiconsenttest.Use(t, "daemon", nil, false)
	t.Setenv("HOME", t.TempDir())
	bin, marker := writeMarkerStub(t)
	cfg := &config.Config{ClaudePath: bin, CodexPath: bin, ActiveWorkspace: "test"}
	cfg.AI.Provider = "claude"
	cfg.AI.Fallback.Enabled, cfg.AI.Fallback.Provider = true, "codex"

	routed, ok := checkedAIClient(cfg, "").(*toolRouteProvider)
	require.True(t, ok, "the reserve on makes checkedAIClient a toolRouteProvider")
	built := 0
	inner := routed.build
	routed.build = func(c *config.Config) (ai.Provider, func(), error) { built++; return inner(c) }

	_, _, err := routed.QuerySync(context.Background(), "", "", "")
	require.ErrorIs(t, err, aiconsent.ErrPaused)
	chunks, errs, ids := routed.Query(context.Background(), "", "", "")
	for range chunks {
	}
	for range ids {
	}
	require.ErrorIs(t, <-errs, aiconsent.ErrPaused)
	assert.Equal(t, 0, built, "no leaf built")
	_, statErr := os.Stat(marker)
	assert.True(t, errors.Is(statErr, os.ErrNotExist), "no provider process started")
}

// BGAI-01: the owner commands' one-off clients (ask, ai query, jira boards
// analyze, jira fields, repl) refuse in a process a background unit started
// while paused; an owner process builds them as before.
func TestOneOffClients_BackgroundProcessPausedRefused(t *testing.T) {
	policytest.Set(t, nil)
	aiconsenttest.Use(t, "cli", backgroundEnv, false)
	t.Setenv("HOME", t.TempDir())
	bin, marker := writeMarkerStub(t)
	cfg := &config.Config{ClaudePath: bin, CodexPath: bin, ActiveWorkspace: "test"}
	cfg.AI.Provider = "claude"

	_, _, err := newAIClientWithModel(cfg, "", "").QuerySync(context.Background(), "", "", "")
	require.ErrorIs(t, err, aiconsent.ErrPaused)
	_, cleanup, err := newQueryClient(cfg, "", transport.Options{})
	require.ErrorIs(t, err, aiconsent.ErrPaused)
	cleanup()
	_, _, _, err = legacyCLIGenerator(cfg).Generate(context.Background(), "", "", "")
	require.ErrorIs(t, err, aiconsent.ErrPaused)
	_, statErr := os.Stat(marker)
	assert.True(t, errors.Is(statErr, os.ErrNotExist), "no provider process started")

	aiconsenttest.Use(t, "cli", nil, false)
	_, isRefused := newAIClientWithModel(cfg, "", "").(refusedProvider)
	assert.False(t, isRefused, "an owner command builds its client while paused")
	_, cleanup, err = newQueryClient(cfg, "", transport.Options{})
	require.NoError(t, err)
	cleanup()
}

// Decision 3: the daemon's chat engine titles the owner's chat in-process.
// Its generator checks consent per call, so the owner mark the Title hook
// puts on the ctx lets it run while paused; an unmarked call is refused.
func TestBGAI02_DaemonChatTitleIsOwnerCall(t *testing.T) {
	policytest.Set(t, nil)
	aiconsenttest.Use(t, "daemon", nil, false)
	srv, calls := fakeChatServer(t)
	cfg := &config.Config{ActiveWorkspace: "test"}
	cfg.AI.Provider, cfg.AI.OllamaURL = "ollama", srv.URL
	gen := daemonChatTitleGenerator(cfg)

	_, _, _, err := gen.Generate(context.Background(), "", "", "")
	require.ErrorIs(t, err, aiconsent.ErrPaused)
	assert.Equal(t, int32(0), calls.Load())
	_, _, _, err = gen.Generate(aiconsent.WithOwnerStarted(context.Background()), "", "", "")
	require.NoError(t, err)
	assert.Equal(t, int32(1), calls.Load())
}

// realConsentEnv makes a startCLI child read consent from its config.yaml
// instead of the test binary's AllowByDefault (TestMain).
const realConsentEnv = "WT_CMD_TEST_REAL_CONSENT"

// BGAI-01 end to end: a CLI a background unit started (EnvOrigin=background,
// not admitted) runs `ai query` through the real entry point (Execute →
// initProcessOrigin → wireAIConsent → newQueryClient). With background AI
// paused in its config it is refused and no provider process starts; allowed,
// the provider starts. An empty forced policy keeps a machine profile out.
func TestBGAI01_BackgroundCLIAIQueryEndToEnd(t *testing.T) {
	for _, tc := range []struct {
		answer  string
		started bool
	}{{"paused", false}, {"allowed", true}} {
		t.Run(tc.answer, func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			t.Setenv(aiconsent.EnvOrigin, "background")
			t.Setenv(aiconsent.EnvAdmitted, "")
			t.Setenv(realConsentEnv, "1")
			t.Setenv(testPolicyEnv, "{}")
			bin, marker := writeMarkerStub(t)
			dir := t.TempDir()
			cfgPath := filepath.Join(dir, "config.yaml")
			require.NoError(t, os.WriteFile(cfgPath, fmt.Appendf(nil, `active_workspace: test-ws
workspaces:
  test-ws:
    slack_token: "xoxp-test-token"
claude_path: %q
ai:
  provider: claude
  background_runs: %s
`, bin, tc.answer), 0o600))

			p := startCLI(t, "ai", "query", "--config", cfgPath, "--db-path", filepath.Join(dir, "wt.db"), "--", "hi")
			_ = p.stdin.Close()
			var out []string
			for line := range p.lines {
				out = append(out, line)
			}
			require.NoError(t, p.wait(), p.stderr.String()) // `ai query` reports on stdout
			_, statErr := os.Stat(marker)
			if tc.started {
				assert.NoError(t, statErr, "allowed: the provider starts")
				assert.NotContains(t, strings.Join(out, "\n"), aiconsent.ErrPaused.Error())
				return
			}
			assert.Contains(t, strings.Join(out, "\n"), aiconsent.ErrPaused.Error())
			assert.True(t, errors.Is(statErr, os.ErrNotExist), "no provider process started")
		})
	}
}

// The REPL keeps one client for its session: it asks consent at every call
// and caches no refusal. Built in a background process while paused it
// refuses; once background AI is allowed the next call runs; an owner or
// admitted ctx runs while paused.
func TestREPLClient_ChecksConsentPerCall(t *testing.T) {
	policytest.Set(t, nil)
	srv, calls := fakeChatServer(t)
	cfg := &config.Config{ActiveWorkspace: "test"}
	cfg.AI.Provider, cfg.AI.OllamaURL = "ollama", srv.URL
	aiconsenttest.Use(t, "cli", backgroundEnv, false)
	client := replAIProvider(cfg)

	_, _, err := client.QuerySync(context.Background(), "", "hi", "")
	require.ErrorIs(t, err, aiconsent.ErrPaused)
	chunks, errs, ids := client.Query(context.Background(), "", "hi", "")
	for range chunks {
	}
	for range ids {
	}
	require.ErrorIs(t, <-errs, aiconsent.ErrPaused)
	assert.Equal(t, int32(0), calls.Load())

	_, _, err = client.QuerySync(aiconsent.WithAdmitted(context.Background(), "run:7"), "", "hi", "")
	require.NoError(t, err)
	_, _, err = client.QuerySync(aiconsent.WithOwnerStarted(context.Background()), "", "hi", "")
	require.NoError(t, err)
	assert.Equal(t, int32(2), calls.Load())

	aiconsenttest.Use(t, "cli", backgroundEnv, true)
	_, _, err = client.QuerySync(context.Background(), "", "hi", "")
	require.NoError(t, err, "allowed later: the same client runs")
	assert.Equal(t, int32(3), calls.Load())
}

// A long-lived holder checks the configured provider's policy per call
// (mdm-policy.md): with the reserve on, a resumed REPL turn is refused when
// the policy now forbids the configured provider, though the reserve is
// allowed.
func TestREPLClient_ResumedTurnChecksConfiguredProviderPolicy(t *testing.T) {
	aiconsenttest.Use(t, "cli", nil, true)
	t.Setenv("HOME", t.TempDir())
	bin, marker := writeMarkerStub(t)
	cfg := &config.Config{ClaudePath: bin, CodexPath: bin, ActiveWorkspace: "test"}
	cfg.AI.Provider = "claude"
	cfg.AI.Fallback.Enabled, cfg.AI.Fallback.Provider = true, "codex"
	client := replAIProvider(cfg)

	policytest.Set(t, map[string]any{"AllowedAIProviders": []any{"codex"}})
	_, _, err := client.QuerySync(context.Background(), "", "hi", "session-1")
	require.ErrorIs(t, err, policy.ErrNotAllowed)
	chunks, errs, ids := client.Query(context.Background(), "", "hi", "session-1")
	for range chunks {
	}
	for range ids {
	}
	require.ErrorIs(t, <-errs, policy.ErrNotAllowed)
	_, statErr := os.Stat(marker)
	assert.True(t, errors.Is(statErr, os.ErrNotExist), "no provider process started")
}

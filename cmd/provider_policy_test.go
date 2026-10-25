package cmd

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/chat"
	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/policy"
	"watchtower/internal/policy/policytest"
)

// writeMarkerStub writes an executable that records it ran by creating
// marker. A refused provider must never start it.
func writeMarkerStub(t *testing.T) (bin, marker string) {
	t.Helper()
	dir := t.TempDir()
	marker = filepath.Join(dir, "ran")
	bin = filepath.Join(dir, "provider-stub")
	require.NoError(t, os.WriteFile(bin, []byte("#!/bin/sh\ntouch '"+marker+"'\nexit 1\n"), 0o700))
	return bin, marker
}

func claudeOnly(t *testing.T) {
	t.Helper()
	policytest.Set(t, map[string]any{"AllowedAIProviders": []any{"claude"}})
}

// TestProviderPolicy_GeneratorRefusesNoFallback pins Review Focus 3: a
// configured provider the policy forbids fails every call with the policy
// error naming the allowed providers, and no provider (not even an allowed
// one) is started.
func TestProviderPolicy_GeneratorRefusesNoFallback(t *testing.T) {
	claudeOnly(t)
	bin, marker := writeMarkerStub(t)
	cfg := &config.Config{ClaudePath: bin, CodexPath: bin, ActiveWorkspace: "test"}
	cfg.AI.Provider = "codex"
	t.Setenv("HOME", t.TempDir())

	_, _, _, err := cliGenerator(cfg).Generate(context.Background(), "sys", "user", "")
	require.ErrorIs(t, err, policy.ErrNotAllowed)
	assert.Contains(t, err.Error(), "AI provider codex is not allowed by your organization (allowed: claude)")

	gen, cleanup := cliPooledGenerator(cfg)
	t.Cleanup(cleanup)
	_, _, _, err = gen.Generate(context.Background(), "sys", "user", "")
	require.ErrorIs(t, err, policy.ErrNotAllowed)

	_, _, err = newAIClient(cfg, "").QuerySync(context.Background(), "sys", "user", "")
	require.ErrorIs(t, err, policy.ErrNotAllowed)
	chunks, errs, ids := newAIClient(cfg, "").Query(context.Background(), "sys", "user", "")
	for range chunks {
	}
	for range ids {
	}
	require.ErrorIs(t, <-errs, policy.ErrNotAllowed)

	_, _, err = newQueryClient(cfg, "")
	require.ErrorIs(t, err, policy.ErrNotAllowed)

	_, statErr := os.Stat(marker)
	assert.True(t, errors.Is(statErr, os.ErrNotExist), "no provider process started")
}

type countingGenerator struct{ calls int }

func (g *countingGenerator) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
	g.calls++
	return "ok", nil, "", nil
}

// A long-lived generator (the daemon's pipelines) follows the policy per
// call: tightened, it refuses; loosened, it runs again.
func TestProviderPolicy_LongLivedGeneratorChecksPerCall(t *testing.T) {
	inner := &countingGenerator{}
	gen := policyCheckedGenerator{inner: inner, provider: "codex"}

	policytest.Set(t, nil)
	_, _, _, err := gen.Generate(context.Background(), "", "", "")
	require.NoError(t, err)

	claudeOnly(t)
	_, _, _, err = gen.Generate(context.Background(), "", "", "")
	require.ErrorIs(t, err, policy.ErrNotAllowed)
	assert.Equal(t, 1, inner.calls)

	_, bounded := digest.CallTimeout(cliBoundedGenerator(&config.Config{}))
	assert.True(t, bounded, "the policy check sits inside the H8 bound")
}

func TestProviderPolicy_ProviderFlagRefused(t *testing.T) {
	claudeOnly(t)
	orig := flagProvider
	flagProvider = "ollama"
	t.Cleanup(func() { flagProvider = orig })
	cfg := &config.Config{}
	applyProviderOverride(cfg)
	_, _, _, err := cliGenerator(cfg).Generate(context.Background(), "", "", "")
	require.ErrorIs(t, err, policy.ErrNotAllowed)
	assert.Contains(t, err.Error(), "AI provider ollama")
}

// POLICY-03: a refused `config set` writes nothing.
func TestProviderPolicy_ConfigSetRefused(t *testing.T) {
	claudeOnly(t)
	configPath := filepath.Join(t.TempDir(), "config.yaml")
	body := []byte("active_workspace: test\n")
	require.NoError(t, os.WriteFile(configPath, body, 0o600))
	orig := flagConfig
	flagConfig = configPath
	t.Cleanup(func() { flagConfig = orig })
	configSetCmd.SetOut(&bytes.Buffer{})
	configSetCmd.SetErr(&bytes.Buffer{})

	for _, args := range [][]string{{"ai.provider", "codex"}, {"workbench.default_agent", "codex"}} {
		err := configSetCmd.RunE(configSetCmd, args)
		require.ErrorIs(t, err, policy.ErrNotAllowed, args[0])
		assert.Contains(t, err.Error(), "nothing was written")
		got, err := os.ReadFile(configPath)
		require.NoError(t, err)
		assert.Equal(t, body, got, "config.yaml unchanged")
	}
	require.NoError(t, configSetCmd.RunE(configSetCmd, []string{"ai.provider", "claude"}))
}

func TestProviderPolicy_LaunchArgsRefused(t *testing.T) {
	claudeOnly(t)
	bin, _ := writeMarkerStub(t)
	setupLaunchArgs(t, bin, func() (string, error) { return bin, nil })
	out, code := runLaunchArgs(t, "--agent", "codex", "--workbench", "1", "--json")
	assert.NotZero(t, code)
	assert.Empty(t, out)
}

type fakeTurnBackend struct{ turns int }

func (f *fakeTurnBackend) Start(context.Context) (string, error) { return "", nil }
func (f *fakeTurnBackend) Turn(_ context.Context, _ chat.Command, emit func(chat.Event)) error {
	f.turns++
	emit(chat.Event{Type: chat.EventTurnDone})
	return nil
}
func (f *fakeTurnBackend) Cancel() error { return nil }
func (f *fakeTurnBackend) Close() error  { return nil }

// A warm session asks the policy at every turn: a provider forbidden while
// the session runs answers the turn with the policy error.
func TestProviderPolicy_SessionTurnRefused(t *testing.T) {
	fake := &fakeTurnBackend{}
	b := policyCheckedBackend{Backend: fake, provider: "codex"}
	var events []chat.Event
	emit := func(e chat.Event) { events = append(events, e) }

	policytest.Set(t, nil)
	require.NoError(t, b.Turn(context.Background(), chat.Command{TurnID: "t1"}, emit))
	assert.Equal(t, 1, fake.turns)

	claudeOnly(t)
	err := b.Turn(context.Background(), chat.Command{TurnID: "t2"}, emit)
	require.ErrorIs(t, err, policy.ErrNotAllowed)
	assert.Equal(t, 1, fake.turns, "the provider never sees the turn")
	last := events[len(events)-1]
	assert.Equal(t, chat.EventError, last.Type)
	assert.Equal(t, "t2", last.TurnID, "a turn error is the turn's terminal event")
	assert.Equal(t, chat.CodeProviderUnavailable, last.Code)
	assert.Contains(t, last.Message, "allowed: claude")
}

func TestAutomationAgent_PolicyRefused(t *testing.T) {
	claudeOnly(t)
	bin, marker := writeMarkerStub(t)
	cfg := &config.Config{ClaudePath: bin, CodexPath: bin}
	cfg.AI.Provider = "ollama"
	metered := 0
	req := automations.AgentRequest{
		Instruction: "x", Deadline: time.Now().Add(time.Minute),
		BeforeModelCall: func() error { metered++; return nil },
	}
	for _, runner := range []automations.AgentRunner{
		&cliAgentRunner{cfg: cfg, provider: "codex"},
		&runtimeBAgentRunner{cfg: cfg},
	} {
		_, err := runner.Run(context.Background(), req)
		var sdk *automations.SDKError
		require.ErrorAs(t, err, &sdk, runner.Name())
		assert.Equal(t, automations.ErrNamePolicy, sdk.Name)
		assert.Contains(t, sdk.Message, "allowed: claude")
	}
	assert.Zero(t, metered, "nothing metered")
	_, statErr := os.Stat(marker)
	assert.True(t, errors.Is(statErr, os.ErrNotExist), "no agent process started")
}

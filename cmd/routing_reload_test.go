package cmd

import (
	"context"
	"errors"
	"io"
	"log"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/config"
	"watchtower/internal/daemon"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/fsutil"
	"watchtower/internal/llmusage"
	"watchtower/internal/providers"

	"github.com/stretchr/testify/require"
)

type reloadGenerator struct {
	provider string
	started  chan struct{}
	release  chan struct{}
	once     sync.Once
}

func (g *reloadGenerator) Generate(ctx context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	if g.started != nil {
		g.once.Do(func() { close(g.started) })
		select {
		case <-g.release:
		case <-ctx.Done():
			return "", nil, "", ctx.Err()
		}
	}
	return g.provider, &digest.Usage{Tokens: llmusage.Tokens{Input: 2, Output: 1}}, "", nil
}
func reloadConfig(provider string) *config.Config {
	c := &config.Config{ActiveWorkspace: "test"}
	c.AI.Provider, c.AI.ConfiguredProvider = provider, provider
	c.AI.Workers = 2
	return c
}
func testDaemonRouting(t *testing.T) *daemonRouting {
	t.Helper()
	r := newDaemonRouting(reloadConfig("claude"))
	t.Cleanup(r.pool.Close)
	r.build = func(c *config.Config) digest.Generator { return &reloadGenerator{provider: c.AI.Provider} }
	r.publish(reloadConfig("claude"))
	return r
}

func TestRoutingReloadLogicalJobsAndSDKKeepSnapshot(t *testing.T) {
	r := testDaemonRouting(t)
	blocked := &reloadGenerator{provider: "claude", started: make(chan struct{}), release: make(chan struct{})}
	r.current.Load().gen = blocked // before any job starts
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	syncCtx, fetchCtx := r.bindSync(ctx, ctx)
	database := db.OpenTestDB(t)
	recipe := agentRecipeText(`return llm("one") + "/" + llm("two")`, "")
	a := automationstest.SeedAutomation(t, database, recipe, automationstest.SeedOptions{Slug: "old-run"})
	exec := automations.NewExecutor(database, routingBackends(r.base, database, r), automations.ExecutorOptions{})
	id, _, err := database.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerManual, Now: time.Now()})
	require.NoError(t, err)
	done := make(chan error, 1)
	go func() { _, err := exec.ExecuteInline(ctx, id); done <- err }()
	select {
	case <-blocked.started:
	case <-ctx.Done():
		t.Fatal("old SDK did not start")
	}
	next := reloadConfig("codex")
	next.AI.ContextBudget, next.AI.Workers = 32000, 1
	r.publish(next)
	// Both independently-cancellable sync contexts retain exactly the old generation.
	require.Same(t, r.generation(syncCtx), r.generation(fetchCtx))
	require.Equal(t, "claude", config.RoutingSnapshot(syncCtx, nil).AI.Provider)
	require.Equal(t, "codex", config.RoutingSnapshot(r.bind(ctx), nil).AI.Provider)
	b := routingBackends(r.base, database, r)
	jobCtx, bound := b.ForJob(ctx, b)
	require.Equal(t, "codex", bound.Agent.(*pooledAutomationAgent).inner.(*cliAgentRunner).cfg.AI.Provider)
	require.Equal(t, "codex", r.generation(jobCtx).cfg.AI.Provider)
	// Old SDK completes both calls on its old factory, with its original meter/step journal.
	close(blocked.release)
	require.NoError(t, <-done)
	run, err := database.GetAutomationRun(id)
	require.NoError(t, err)
	require.Equal(t, db.RunSucceeded, run.Status)
	require.Equal(t, "claude/claude", run.Summary)
	steps, err := database.ListAutomationRunSteps(id)
	require.NoError(t, err)
	require.Len(t, steps, 2)
	require.EqualValues(t, 4, run.InputTokens)
	require.EqualValues(t, 2, run.OutputTokens)
	// Same executor and same automation, a later logical job gets the actual new provider.
	id, _, err = database.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerManual, Now: time.Now()})
	require.NoError(t, err)
	run, err = exec.ExecuteInline(ctx, id)
	require.NoError(t, err)
	require.Equal(t, "codex/codex", run.Summary)
	text, _, _, err := r.Generate(syncCtx, "", "", "")
	require.NoError(t, err)
	require.Equal(t, "claude", text)
	text, _, _, err = r.Generate(r.bind(ctx), "", "", "")
	require.NoError(t, err)
	require.Equal(t, "codex", text)
	require.Equal(t, 1, r.pool.Size())
}

func TestRoutingReloadPublishAndAckFailuresAndLatestSaved(t *testing.T) {
	r := testDaemonRouting(t)
	dir := t.TempDir()
	path := filepath.Join(dir, "config.yaml")
	logger := log.New(io.Discard, "", 0)
	save := func(provider string) {
		require.NoError(t, fsutil.WriteFileAtomic(path, []byte("ai:\n  provider: "+provider+"\n"), 0600))
	}
	var ack routingApplication
	write := func(_ string, a routingApplication) error { ack = a; return nil }
	save("claude")
	r.refresh(path, "run-one", write, logger)
	old := ack
	require.Empty(t, ack.Error)
	require.NoError(t, fsutil.WriteFileAtomic(path, []byte("ai: [invalid"), 0600))
	r.refresh(path, "run-one", write, logger)
	require.NotEmpty(t, ack.Error)
	require.Equal(t, old.Revision, r.current.Load().revision)
	save("codex")
	r.refresh(path, "run-one", func(_ string, _ routingApplication) error { return errors.New("disk refused") }, logger)
	require.Equal(t, "codex", r.current.Load().cfg.AI.Provider, "publication is not rolled back after an ack failure")
	require.Equal(t, old.Revision, ack.Revision)
	save("claude")
	require.NotEqual(t, old.SavedVersion, routingSavedVersion(path), "ABA save cannot use an old ack")
	r.refresh(path, "run-one", write, logger)
	require.Equal(t, "claude", r.current.Load().cfg.AI.Provider)
	require.Equal(t, routingSavedVersion(path), ack.SavedVersion)
	save("codex") // Retry always reads the latest saved file, never writes the old draft.
	before, err := os.ReadFile(path)
	require.NoError(t, err)
	r.refresh(path, "run-one", write, logger)
	require.Equal(t, "codex", ack.PreferredProvider)
	after, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Equal(t, before, after)
	require.Equal(t, providers.RoutingRevision(r.current.Load().cfg), ack.Revision)
}

func TestRoutingSavedVersionAtomicReplacementEqualTimestamp(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, fsutil.WriteFileAtomic(path, []byte("same"), 0600))
	now := time.Unix(100, 0)
	require.NoError(t, os.Chtimes(path, now, now))
	old := routingSavedVersion(path)
	require.NoError(t, fsutil.WriteFileAtomic(path, []byte("next"), 0600))
	require.NoError(t, os.Chtimes(path, now, now))
	require.NotEqual(t, old, routingSavedVersion(path))
}

func TestRoutingReloadExplicitProviderPinRemainsHonest(t *testing.T) {
	r := testDaemonRouting(t)
	r.providerPin = "claude"
	cfg := reloadConfig("codex")
	cfg.AI.ConfiguredProvider = ""
	r.publish(cfg)
	require.Equal(t, "claude", r.current.Load().cfg.AI.Provider)
	require.Equal(t, "codex", r.current.Load().cfg.AI.ConfiguredProviderID())
}

func TestRoutingAckIdentityLossReplacementAndCorruption(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ack.json")
	require.NoError(t, writeRoutingAck(path, routingApplication{Identity: "run-one", Revision: "new"}))
	identity := "run-one"
	current := func() (string, error) { return identity, nil }
	ack, err := readRoutingAck(path, current)
	require.NoError(t, err)
	require.Equal(t, "new", ack.Revision)
	identity = "run-two"
	ack, err = readRoutingAck(path, current)
	require.NoError(t, err)
	require.Nil(t, ack, "same revision from replaced daemon is never applied")
	identity = ""
	ack, err = readRoutingAck(path, current)
	require.NoError(t, err)
	require.Nil(t, ack, "daemon loss removes confirmation")
	_, err = readRoutingAck(path, func() (string, error) { return "", daemon.ErrIdentityUnconfirmed })
	require.ErrorIs(t, err, daemon.ErrIdentityUnconfirmed)
	identity = "run-one"
	require.NoError(t, os.WriteFile(path, []byte("bad JSON"), 0600))
	_, err = readRoutingAck(path, current)
	require.ErrorContains(t, err, "decoding")
	// A directory is a deterministic storage-read failure even under a privileged test user.
	_, err = readRoutingAck(filepath.Dir(path), current)
	require.ErrorContains(t, err, "reading")
	require.NoError(t, writeRoutingAck(path, routingApplication{Identity: "run-one"}))
	before, err := os.Stat(path)
	require.NoError(t, err)
	require.NoError(t, writeRoutingAck(path, routingApplication{Identity: "run-one"}))
	after, err := os.Stat(path)
	require.NoError(t, err)
	require.True(t, os.SameFile(before, after), "unchanged ack must not rewrite disk every poll")
	calls := 0
	ack, err = readRoutingAck(path, func() (string, error) {
		calls++
		if calls == 1 {
			return "run-one", nil
		}
		return "run-two", nil
	})
	require.NoError(t, err)
	require.Nil(t, ack, "process replacement during ack read")
}

func TestRoutingReloadRejectsStatLoadInterleave(t *testing.T) {
	r := testDaemonRouting(t)
	path := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, fsutil.WriteFileAtomic(path, []byte("ai: {provider: codex}"), 0600))
	original := r.current.Load()
	r.load = func(path string) (*config.Config, error) {
		cfg, err := config.Load(path)
		require.NoError(t, fsutil.WriteFileAtomic(path, []byte("ai: {provider: claude}"), 0600))
		return cfg, err
	}
	writes := 0
	r.refresh(path, "run", func(_ string, _ routingApplication) error { writes++; return nil }, log.New(io.Discard, "", 0))
	require.Same(t, original, r.current.Load(), "parse and file version must describe one file instance")
	require.Zero(t, writes)
}

func TestRoutingAckOwnerDiagnosticDoesNotExposeLocalPath(t *testing.T) {
	err := &os.PathError{Op: "read", Path: "private-fixture-location", Err: os.ErrPermission}
	diagnostic := routingApplicationError(err)
	require.Contains(t, diagnostic, "permission denied")
	require.NotContains(t, diagnostic, "private-fixture-location")
	require.Contains(t, routingApplicationError(daemon.ErrIdentityUnconfirmed), "identity")
}

type routingTestAgent struct{ calls int }

func (*routingTestAgent) Name() string { return "fake" }
func (a *routingTestAgent) Run(context.Context, automations.AgentRequest) (automations.AgentResult, error) {
	a.calls++
	return automations.AgentResult{Text: "new"}, nil
}

func TestRoutingReloadAgentSharesOldWorkerAndDeadline(t *testing.T) {
	r := testDaemonRouting(t)
	worker, err := r.pool.Acquire(context.Background())
	require.NoError(t, err)
	next := reloadConfig("codex")
	next.AI.Workers = 1
	r.publish(next)
	leaf := &routingTestAgent{}
	agent := &pooledAutomationAgent{inner: leaf, pool: r.pool}
	selected, err := agent.Prepare(context.Background(), "light")
	require.NoError(t, err)
	_, err = selected.Run(context.Background(), automations.AgentRequest{Deadline: time.Now().Add(20 * time.Millisecond)})
	require.ErrorIs(t, err, context.DeadlineExceeded)
	require.Zero(t, leaf.calls, "an old generation worker still occupies shared admission")
	r.pool.Release(worker)
	result, err := selected.Run(context.Background(), automations.AgentRequest{Deadline: time.Now().Add(time.Second)})
	require.NoError(t, err)
	require.Equal(t, "new", result.Text)
	require.Equal(t, 1, leaf.calls)
}

func TestRoutingAckFailureBacksOffWithoutRollingRuntimeBack(t *testing.T) {
	r := testDaemonRouting(t)
	path := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, fsutil.WriteFileAtomic(path, []byte("ai: {provider: codex}"), 0600))
	calls := 0
	fail := func(string, routingApplication) error { calls++; return os.ErrPermission }
	logger := log.New(io.Discard, "", 0)
	r.refresh(path, "run", fail, logger)
	r.refresh(path, "run", fail, logger)
	require.Equal(t, 1, calls, "unchanged failure is not retried on every poll")
	require.Equal(t, "codex", r.current.Load().cfg.AI.Provider)
	require.NoError(t, fsutil.WriteFileAtomic(path, []byte("ai: {provider: claude}"), 0600))
	r.refresh(path, "run", fail, logger)
	require.Equal(t, 2, calls, "a newer Save is eligible immediately")
}

func TestRoutingReloadSameProviderExplicitPinDisablesFallbackEveryFactory(t *testing.T) {
	r := testDaemonRouting(t)
	r.providerPin = "claude"
	saved := reloadConfig("claude")
	saved.AI.Fallback = config.AIFallbackConfig{Enabled: true, Provider: "codex"}
	r.publish(saved)
	require.False(t, r.current.Load().cfg.AI.Fallback.Enabled, "coach and all separately constructed backends must inherit the explicit pin")
	require.Equal(t, providers.RoutingRevision(saved), r.current.Load().savedRevision)
	require.NotEqual(t, r.current.Load().savedRevision, r.current.Load().revision, "effective pinned route cannot acknowledge an enabled reserve")
}

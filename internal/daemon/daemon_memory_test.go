package daemon

import (
	"context"
	"errors"
	"log"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/inbox"
	"watchtower/internal/memory"
	"watchtower/internal/targets"
)

// enabledMemoryConfig returns a MemoryConfig with the feature on and the
// documented defaults for the remaining knobs.
func enabledMemoryConfig() config.MemoryConfig {
	return config.MemoryConfig{
		Enabled:              true,
		MaxChunkMessages:     2000,
		SeedMinMessages:      20,
		MaxEpisodesPerWindow: 5,
	}
}

// newTestMemoryPipeline builds a real memory pipeline over a temp vault,
// mirroring how daemon tests wire other pipelines with a mock generator.
func newTestMemoryPipeline(t *testing.T, database *db.DB, cfg config.MemoryConfig) *memory.Pipeline {
	t.Helper()
	vault, err := memory.OpenVault(filepath.Join(t.TempDir(), "memory"))
	require.NoError(t, err)
	return memory.NewPipeline(database, vault, &mockGenerator{}, cfg, t.Logf)
}

// TestDaemon_MemoryPhaseRunsBetweenInboxAndNextStep: with memory enabled, a
// full runSync records the memory pipeline run after inbox and before
// next_step (pipeline_runs IDs are monotonic), with source="daemon".
func TestDaemon_MemoryPhaseRunsBetweenInboxAndNextStep(t *testing.T) {
	orch, _ := newTestOrchestrator(t, new(atomic.Int32))

	dir := t.TempDir()
	t.Setenv("HOME", dir)
	wsDir := dir + "/.local/share/watchtower/test-ws"
	require.NoError(t, os.MkdirAll(wsDir, 0o755))

	database := db.OpenTestDB(t)

	require.NoError(t, database.UpsertWorkspace(db.Workspace{
		ID: "T024BE7LD", Name: "test-ws", Domain: "test-ws",
	}))
	_, acctErr := database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U001"})
	require.NoError(t, acctErr)
	require.NoError(t, database.EnsureChannel("C1", "general", "public", ""))
	require.NoError(t, database.UpsertMessage(db.Message{
		ChannelID: "C1", TS: "1700000000.000001", TSUnix: 1700000000.000001,
		UserID: "U002", Text: "hello world",
	}))

	cfg := &config.Config{
		ActiveWorkspace: "test-ws",
		Workspaces: map[string]*config.WorkspaceConfig{
			"test-ws": {SlackToken: "xoxp-test"},
		},
		Sync:   config.SyncConfig{PollInterval: 10 * time.Second},
		Memory: enabledMemoryConfig(),
		// Inbox/next_step now each need their own Enabled flag (Task 3
		// demoted digest.enabled from a master switch to a per-phase gate).
		Inbox:   config.InboxConfig{Enabled: true},
		Targets: config.TargetsConfig{NextStep: config.TargetsNextStepConfig{Enabled: true}},
	}

	gen := &mockGenerator{}
	l := log.New(os.Stderr, "[memory-phase-test] ", 0)

	d := newDaemon(orch, cfg)
	d.SetLogger(l)
	d.SetDB(database)
	d.SetInboxPipeline(inbox.New(database, cfg, gen, l))
	d.SetNextStepPipeline(targets.New(database, &cfg.Targets, gen, nil, cfg.Digest.Language, l))
	d.SetMemoryPipeline(newTestMemoryPipeline(t, database, cfg.Memory))

	d.runSync(context.Background())

	ids := make(map[string]int64)
	rows, err := database.Query(`SELECT pipeline, id, source FROM pipeline_runs
		WHERE pipeline IN ('inbox', 'memory', 'next_step')`)
	require.NoError(t, err)
	defer rows.Close()
	for rows.Next() {
		var pipeline, source string
		var id int64
		require.NoError(t, rows.Scan(&pipeline, &id, &source))
		ids[pipeline] = id
		if pipeline == "memory" {
			assert.Equal(t, "daemon", source, "memory run must be labeled source=daemon")
		}
	}
	require.NoError(t, rows.Err())

	for _, name := range []string{"inbox", "memory", "next_step"} {
		require.Containsf(t, ids, name, "expected a pipeline_runs row for %q", name)
	}
	assert.Less(t, ids["inbox"], ids["memory"], "memory phase must run after inbox")
	assert.Less(t, ids["memory"], ids["next_step"], "memory phase must run before next_step")
}

// TestDaemon_MemoryPhaseDisabledSkips: with memory.enabled=false the phase is
// a no-op even when a pipeline is wired — nothing recorded, nothing written.
func TestDaemon_MemoryPhaseDisabledSkips(t *testing.T) {
	orch, cfg, _ := testDaemonWithTempHome(t)

	database := db.OpenTestDB(t)

	memCfg := enabledMemoryConfig()
	memCfg.Enabled = false
	cfg.Memory = memCfg

	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[memory-disabled-test] ", 0))
	d.SetDB(database)
	d.SetMemoryPipeline(newTestMemoryPipeline(t, database, memCfg))

	d.phaseMemory(context.Background())

	var runs int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM pipeline_runs`).Scan(&runs))
	assert.Zero(t, runs, "disabled memory phase must not record a pipeline run")

	nodes, err := database.ListMemoryNodes()
	require.NoError(t, err)
	assert.Empty(t, nodes, "disabled memory phase must not write nodes")
}

// TestDaemon_MemoryPhaseNilPipeline: no pipeline wired — the phase must be a
// silent no-op regardless of config.
func TestDaemon_MemoryPhaseNilPipeline(t *testing.T) {
	orch, cfg, _ := testDaemonWithTempHome(t)
	cfg.Memory = enabledMemoryConfig()

	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[memory-nil-test] ", 0))

	// Should not panic when no memory pipeline is installed.
	d.phaseMemory(context.Background())
}

// TestDaemon_MemoryPhaseOpenFailureIsRecordedAndRetried: a vault that fails
// to open through the opener records a failed "memory" pipeline_runs row each
// cycle (no silent skip), and a later cycle retries the open — once it
// succeeds the pipeline is installed and runs normally.
func TestDaemon_MemoryPhaseOpenFailureIsRecordedAndRetried(t *testing.T) {
	orch, cfg, _ := testDaemonWithTempHome(t)
	memCfg := enabledMemoryConfig()
	cfg.Memory = memCfg

	database := db.OpenTestDB(t)
	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[memory-open-test] ", 0))
	d.SetDB(database)

	var opens int
	openErr := errors.New("opening memory vault: permission denied")
	d.SetMemoryPipelineOpener(func() (*memory.Pipeline, error) {
		opens++
		if opens <= 2 {
			return nil, openErr
		}
		return newTestMemoryPipeline(t, database, memCfg), nil
	})

	type runRow struct{ pipeline, source, status, errMsg string }
	readRuns := func() []runRow {
		rows, err := database.Query(`SELECT pipeline, source, status, COALESCE(error_msg, '') FROM pipeline_runs ORDER BY id`)
		require.NoError(t, err)
		defer rows.Close()
		var out []runRow
		for rows.Next() {
			var r runRow
			require.NoError(t, rows.Scan(&r.pipeline, &r.source, &r.status, &r.errMsg))
			out = append(out, r)
		}
		require.NoError(t, rows.Err())
		return out
	}

	d.phaseMemory(context.Background())
	d.phaseMemory(context.Background())
	runs := readRuns()
	require.Len(t, runs, 2, "every failed cycle records a run")
	for _, r := range runs {
		assert.Equal(t, runRow{"memory", "daemon", "error", openErr.Error()}, r)
	}
	assert.Nil(t, d.memoryPipe, "a failed open installs no pipeline")

	d.phaseMemory(context.Background())
	assert.Equal(t, 3, opens, "the open is retried on the next cycle")
	require.NotNil(t, d.memoryPipe)
	runs = readRuns()
	require.Len(t, runs, 3)
	assert.Equal(t, "memory", runs[2].pipeline)
	assert.Equal(t, "daemon", runs[2].source)
	assert.Equal(t, "done", runs[2].status, "the recovered pipeline records its own successful run")

	d.phaseMemory(context.Background())
	assert.Equal(t, 3, opens, "an installed pipeline is not reopened")
}

// TestDaemon_MemoryPhaseDisabledNeverOpens: with Memory off the opener is
// never called and no run is recorded (FEAT-01).
func TestDaemon_MemoryPhaseDisabledNeverOpens(t *testing.T) {
	orch, cfg, _ := testDaemonWithTempHome(t)
	cfg.Memory = enabledMemoryConfig()
	cfg.Memory.Enabled = false

	database := db.OpenTestDB(t)
	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[memory-open-disabled-test] ", 0))
	d.SetDB(database)
	d.SetMemoryPipelineOpener(func() (*memory.Pipeline, error) {
		t.Fatal("opener called while memory is disabled")
		return nil, nil
	})

	d.phaseMemory(context.Background())

	var runs int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM pipeline_runs`).Scan(&runs))
	assert.Zero(t, runs)
}

// TestDaemon_MemoryPhaseLeavesInboxWatermark: the memory phase never touches
// inbox_last_processed_ts (INBOX-09 stays the inbox pipeline's business).
func TestDaemon_MemoryPhaseLeavesInboxWatermark(t *testing.T) {
	orch, cfg, _ := testDaemonWithTempHome(t)
	cfg.Memory = enabledMemoryConfig()

	database := db.OpenTestDB(t)

	require.NoError(t, database.UpsertWorkspace(db.Workspace{
		ID: "T024BE7LD", Name: "test-ws", Domain: "test-ws",
	}))
	require.NoError(t, database.SetInboxLastProcessedTS(1700000123.456))

	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[memory-watermark-test] ", 0))
	d.SetDB(database)
	d.SetMemoryPipeline(newTestMemoryPipeline(t, database, cfg.Memory))

	d.phaseMemory(context.Background())

	var memRuns int
	require.NoError(t, database.QueryRow(
		`SELECT COUNT(*) FROM pipeline_runs WHERE pipeline = 'memory' AND source = 'daemon'`).Scan(&memRuns))
	assert.Equal(t, 1, memRuns, "enabled memory phase must record exactly one daemon-sourced run")

	ts, err := database.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Equal(t, 1700000123.456, ts, "memory phase must not touch inbox_last_processed_ts")
}

// TestDaemon_MemoryPhaseSkipsWhenLocked: when another process (e.g. a CLI
// `memory consolidate --once`) holds the memory lock, the phase logs and
// skips the cycle — no pipeline_runs row, no panic, cycle continues.
func TestDaemon_MemoryPhaseSkipsWhenLocked(t *testing.T) {
	orch, cfg, _ := testDaemonWithTempHome(t)
	cfg.Memory = enabledMemoryConfig()

	database := db.OpenTestDB(t)

	vault, err := memory.OpenVault(filepath.Join(t.TempDir(), "memory"))
	require.NoError(t, err)
	unlock, err := vault.Lock()
	require.NoError(t, err)
	defer unlock()

	d := newDaemon(orch, cfg)
	d.SetLogger(log.New(os.Stderr, "[memory-locked-test] ", 0))
	d.SetDB(database)
	d.SetMemoryPipeline(memory.NewPipeline(database, vault, &mockGenerator{}, cfg.Memory, t.Logf))

	d.phaseMemory(context.Background())

	var runs int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM pipeline_runs`).Scan(&runs))
	assert.Zero(t, runs, "a locked-out memory phase must not record a pipeline run")
}

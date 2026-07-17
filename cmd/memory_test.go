package cmd

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	git "github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/memory"
)

// setupMemoryTestEnv creates a temp HOME with a config file (memory.enabled
// as given, seed_min_messages lowered to 1 so tiny fixtures qualify) and a
// workspace DB seeded with two channels and two users. Returns the vault path
// (WorkspaceDir()/memory — not created yet).
func setupMemoryTestEnv(t *testing.T, enabled bool) string {
	t.Helper()
	tmpDir := t.TempDir()

	configPath := filepath.Join(tmpDir, "config.yaml")
	configYAML := fmt.Sprintf(`active_workspace: test-ws
workspaces:
  test-ws:
    slack_token: "xoxp-test-token"
memory:
  enabled: %t
  seed_min_messages: 1
`, enabled)
	require.NoError(t, os.WriteFile(configPath, []byte(configYAML), 0o600))

	wsDir := filepath.Join(tmpDir, ".local", "share", "watchtower", "test-ws")
	require.NoError(t, os.MkdirAll(wsDir, 0o755))

	database, err := db.Open(filepath.Join(wsDir, "watchtower.db"))
	require.NoError(t, err)
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T001", Name: "test-ws", Domain: "test-ws"}))
	require.NoError(t, database.UpsertChannel(db.Channel{ID: "C001", Name: "general", Type: "public"}))
	require.NoError(t, database.UpsertChannel(db.Channel{ID: "C002", Name: "random", Type: "public"}))
	require.NoError(t, database.UpsertUser(db.User{ID: "U001", Name: "alice"}))
	require.NoError(t, database.UpsertUser(db.User{ID: "U002", Name: "bob"}))
	database.Close()

	t.Setenv("HOME", tmpDir)
	oldFlagConfig := flagConfig
	flagConfig = configPath
	t.Cleanup(func() { flagConfig = oldFlagConfig })

	return filepath.Join(wsDir, "memory")
}

// seedMemoryEntityFixture opens (initializing) the vault, writes one entity
// node aliased to U001, and indexes it. Returns the node ID.
func seedMemoryEntityFixture(t *testing.T, vaultPath string, database *db.DB) string {
	t.Helper()
	vault, err := memory.OpenVault(vaultPath)
	require.NoError(t, err)

	n := memory.Node{
		ID:      memory.NewID("entity"),
		Type:    "entity",
		Tier:    "long",
		Status:  "active",
		Title:   "Alice Johnson",
		Aliases: []string{"U001", "alice@example.com"},
		Body:    "# Alice Johnson\n\n## What\nTeam lead for the platform squad.\n",
	}
	_, err = vault.WriteNodes([]memory.Node{n}, memory.CommitMsg{Op: "seed", Summary: "test fixture", Cause: "seed"})
	require.NoError(t, err)
	_, err = memory.Reconcile(vault, database, t.Logf)
	require.NoError(t, err)
	return n.ID
}

// vaultCommitCount counts the commits reachable from HEAD in the vault repo.
func vaultCommitCount(t *testing.T, vaultPath string) int {
	t.Helper()
	repo, err := git.PlainOpen(vaultPath)
	require.NoError(t, err)
	head, err := repo.Head()
	require.NoError(t, err)
	iter, err := repo.Log(&git.LogOptions{From: head.Hash()})
	require.NoError(t, err)
	count := 0
	require.NoError(t, iter.ForEach(func(*object.Commit) error { count++; return nil }))
	return count
}

// countMemoryPipelineRuns counts pipeline_runs rows for the memory pipeline.
func countMemoryPipelineRuns(t *testing.T, database *db.DB) int {
	t.Helper()
	var count int
	require.NoError(t, database.QueryRow(
		`SELECT COUNT(*) FROM pipeline_runs WHERE pipeline = 'memory'`).Scan(&count))
	return count
}

// TestCLI_MemoryCommandRegistered verifies the command tree is on rootCmd.
func TestCLI_MemoryCommandRegistered(t *testing.T) {
	found := false
	for _, c := range rootCmd.Commands() {
		if c.Name() == "memory" {
			found = true
			subs := map[string]bool{}
			for _, sub := range c.Commands() {
				subs[sub.Name()] = true
			}
			for _, want := range []string{"status", "reindex", "open", "recall", "consolidate", "seed"} {
				assert.True(t, subs[want], "memory %s subcommand should be registered", want)
			}
		}
	}
	assert.True(t, found, "memory command should be registered on rootCmd")
}

// TestCLI_MemoryStatus verifies status renders node counts, the watermark,
// and the extraction-debt estimate.
func TestCLI_MemoryStatus(t *testing.T) {
	vaultPath := setupMemoryTestEnv(t, false)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	seedMemoryEntityFixture(t, vaultPath, database)
	// One extractable message above the watermark → debt of 1.
	require.NoError(t, database.UpsertMessage(db.Message{
		ChannelID: "C001", TS: "1700000100.000100", UserID: "U001", Text: "hello world",
	}))
	require.NoError(t, database.SetMemoryWatermark(1700000000))
	database.Close()

	var buf bytes.Buffer
	memoryStatusCmd.SetOut(&buf)
	require.NoError(t, memoryStatusCmd.RunE(memoryStatusCmd, nil))

	out := buf.String()
	assert.Contains(t, out, "entity/long: 1")
	assert.Contains(t, out, "1700000000")
	assert.Contains(t, out, "Extraction debt: 1")
	assert.Contains(t, out, "Last run: none")
}

// TestCLI_MemoryStatus_ExcludesTombstones verifies tombstones are excluded
// from the per-type/tier counts (matching map.md and memory_map) and reported
// on their own line.
func TestCLI_MemoryStatus_ExcludesTombstones(t *testing.T) {
	vaultPath := setupMemoryTestEnv(t, false)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	liveID := seedMemoryEntityFixture(t, vaultPath, database)

	vault, err := memory.OpenVault(vaultPath)
	require.NoError(t, err)
	stone := memory.Node{
		ID:         memory.NewID("entity"),
		Type:       "entity",
		Tier:       "long",
		Status:     "tombstone",
		RedirectTo: liveID,
		Body:       "Merged into [[" + liveID + "]].\n",
	}
	_, err = vault.WriteNodes([]memory.Node{stone}, memory.CommitMsg{Op: "merge", Summary: "tombstone fixture", Cause: "merge"})
	require.NoError(t, err)
	_, err = memory.Reconcile(vault, database, t.Logf)
	require.NoError(t, err)
	database.Close()

	var buf bytes.Buffer
	memoryStatusCmd.SetOut(&buf)
	require.NoError(t, memoryStatusCmd.RunE(memoryStatusCmd, nil))

	out := buf.String()
	assert.Contains(t, out, "Nodes: 1", "tombstone must not count as a node")
	assert.Contains(t, out, "entity/long: 1", "only the live entity is bucketed")
	assert.Contains(t, out, "Tombstones: 1")
}

// TestCLI_MemoryReindex verifies reindex rebuilds the index from the vault:
// a row dropped from the index is restored by the command.
func TestCLI_MemoryReindex(t *testing.T) {
	vaultPath := setupMemoryTestEnv(t, false)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	nodeID := seedMemoryEntityFixture(t, vaultPath, database)
	// Simulate index drift: the node file exists, the index row is gone.
	require.NoError(t, database.DeleteMemoryNode(nodeID))
	_, err = database.GetMemoryNode(nodeID)
	require.Error(t, err)
	database.Close()

	var buf bytes.Buffer
	memoryReindexCmd.SetOut(&buf)
	require.NoError(t, memoryReindexCmd.RunE(memoryReindexCmd, nil))
	assert.Contains(t, buf.String(), "Reindexed")

	database, err = openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	row, err := database.GetMemoryNode(nodeID)
	require.NoError(t, err)
	assert.Equal(t, "Alice Johnson", row.Title)
}

// TestCLI_MemoryOpen_Alias verifies open resolves an alias to the node and
// prints its summary line and body.
func TestCLI_MemoryOpen_Alias(t *testing.T) {
	vaultPath := setupMemoryTestEnv(t, false)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	nodeID := seedMemoryEntityFixture(t, vaultPath, database)
	database.Close()

	var buf bytes.Buffer
	memoryOpenCmd.SetOut(&buf)
	require.NoError(t, memoryOpenCmd.RunE(memoryOpenCmd, []string{"U001"}))

	out := buf.String()
	assert.Contains(t, out, nodeID)
	assert.Contains(t, out, "entity/long")
	assert.Contains(t, out, "Team lead for the platform squad.")
}

// TestCLI_MemoryRecall verifies recall returns a seeded FTS hit.
func TestCLI_MemoryRecall(t *testing.T) {
	vaultPath := setupMemoryTestEnv(t, false)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	nodeID := seedMemoryEntityFixture(t, vaultPath, database)
	database.Close()

	var buf bytes.Buffer
	memoryRecallCmd.SetOut(&buf)
	require.NoError(t, memoryRecallCmd.RunE(memoryRecallCmd, []string{"platform", "squad"}))

	out := buf.String()
	assert.Contains(t, out, nodeID)
	assert.Contains(t, out, "Alice Johnson")
}

// TestCLI_MemoryConsolidate_Disabled verifies that with memory.enabled=false
// the command prints a clear message, exits 0, and runs no pipeline (no
// pipeline_runs row, no vault created).
func TestCLI_MemoryConsolidate_Disabled(t *testing.T) {
	vaultPath := setupMemoryTestEnv(t, false)

	var buf bytes.Buffer
	memoryConsolidateCmd.SetOut(&buf)

	require.NoError(t, memoryConsolidateCmd.RunE(memoryConsolidateCmd, nil))
	assert.Contains(t, buf.String(), "disabled")

	_, err := os.Stat(vaultPath)
	assert.True(t, os.IsNotExist(err), "disabled consolidate must not create the vault")

	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	assert.Equal(t, 0, countMemoryPipelineRuns(t, database))
}

// TestCLI_MemoryConsolidateOnce_RunsPipeline verifies the enabled path runs
// one pipeline pass (via the factory seam, with no generator) and records a
// pipeline_runs row with source=cli.
func TestCLI_MemoryConsolidateOnce_RunsPipeline(t *testing.T) {
	vaultPath := setupMemoryTestEnv(t, true)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	seedMemoryEntityFixture(t, vaultPath, database)
	database.Close()

	oldFactory := newMemoryPipelineFactory
	t.Cleanup(func() { newMemoryPipelineFactory = oldFactory })
	newMemoryPipelineFactory = func(d *db.DB, v *memory.Vault, cfg *config.Config, logf func(string, ...any)) *memory.Pipeline {
		return memory.NewPipeline(d, v, nil, cfg.Memory, logf)
	}

	var buf bytes.Buffer
	memoryConsolidateCmd.SetOut(&buf)

	require.NoError(t, memoryConsolidateCmd.RunE(memoryConsolidateCmd, nil))
	assert.Contains(t, buf.String(), "Consolidation done")

	database, err = openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()

	var source, status string
	require.NoError(t, database.QueryRow(
		`SELECT source, status FROM pipeline_runs WHERE pipeline = 'memory' ORDER BY id DESC LIMIT 1`).
		Scan(&source, &status))
	assert.Equal(t, "cli", source)
	assert.Equal(t, "done", status)
}

// TestCLI_MemoryConsolidate_OnceFlagRemoved: the mandatory --once flag was
// dropped (Task 13) — consolidate runs a single pass unflagged, and --once is
// now an unrecognized flag.
func TestCLI_MemoryConsolidate_OnceFlagRemoved(t *testing.T) {
	assert.Nil(t, memoryConsolidateCmd.Flags().Lookup("once"), "the --once flag is gone")
	assert.Error(t, memoryConsolidateCmd.Flags().Set("once", "true"), "--once is now an unknown flag")
}

// TestCLI_MemorySeedDryRun verifies seed --dry-run lists what would be
// created without writing: vault commit count and index row count unchanged.
func TestCLI_MemorySeedDryRun(t *testing.T) {
	vaultPath := setupMemoryTestEnv(t, false)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	// Alice already has an entity page (alias U001) — must be skipped.
	seedMemoryEntityFixture(t, vaultPath, database)
	// Recent traffic from bob in #random → two fresh candidates
	// (seed_min_messages is 1 in the test config).
	ts := fmt.Sprintf("%d.000100", time.Now().Unix())
	require.NoError(t, database.UpsertMessage(db.Message{
		ChannelID: "C002", TS: ts, UserID: "U002", Text: "hi there",
	}))
	nodesBefore, err := database.ListMemoryNodes()
	require.NoError(t, err)
	database.Close()

	commitsBefore := vaultCommitCount(t, vaultPath)

	var buf bytes.Buffer
	memorySeedCmd.SetOut(&buf)
	require.NoError(t, memorySeedCmd.Flags().Set("dry-run", "true"))
	t.Cleanup(func() { _ = memorySeedCmd.Flags().Set("dry-run", "false") })

	require.NoError(t, memorySeedCmd.RunE(memorySeedCmd, nil))

	out := buf.String()
	assert.Contains(t, out, "bob")
	assert.Contains(t, out, "#random")
	assert.NotContains(t, out, "Alice Johnson", "already-seeded entity must be skipped")

	assert.Equal(t, commitsBefore, vaultCommitCount(t, vaultPath), "dry-run must not commit to the vault")

	database, err = openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	nodesAfter, err := database.ListMemoryNodes()
	require.NoError(t, err)
	assert.Len(t, nodesAfter, len(nodesBefore), "dry-run must not write index rows")
}

// TestCLI_MemoryOpen_NoVault verifies the read path never creates a vault:
// open on a workspace without one prints a clean message and leaves no
// directory behind (G8 — reads must not git-init as a side effect).
func TestCLI_MemoryOpen_NoVault(t *testing.T) {
	vaultPath := setupMemoryTestEnv(t, false)

	var buf bytes.Buffer
	memoryOpenCmd.SetOut(&buf)
	require.NoError(t, memoryOpenCmd.RunE(memoryOpenCmd, []string{"U001"}))

	assert.Contains(t, buf.String(), "not initialized")
	_, err := os.Stat(vaultPath)
	assert.True(t, os.IsNotExist(err), "memory open must not create the vault")
}

// TestCLI_MemoryReindex_NoVault: same contract for reindex.
func TestCLI_MemoryReindex_NoVault(t *testing.T) {
	vaultPath := setupMemoryTestEnv(t, false)

	var buf bytes.Buffer
	memoryReindexCmd.SetOut(&buf)
	require.NoError(t, memoryReindexCmd.RunE(memoryReindexCmd, nil))

	assert.Contains(t, buf.String(), "not initialized")
	_, err := os.Stat(vaultPath)
	assert.True(t, os.IsNotExist(err), "memory reindex must not create the vault")
}

// TestCLI_MemoryFactoryPassesLogf verifies the default pipeline factory wires
// the caller's logf into the pipeline (daemon: logger.Printf, CLI: stderr) —
// a production pipeline must never be constructed silent.
func TestCLI_MemoryFactoryPassesLogf(t *testing.T) {
	vaultPath := setupMemoryTestEnv(t, true)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	defer database.Close()
	vault, err := memory.OpenVault(vaultPath)
	require.NoError(t, err)
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)

	var logged bytes.Buffer
	pipe := newMemoryPipelineFactory(database, vault, cfg, func(format string, args ...any) {
		fmt.Fprintf(&logged, format+"\n", args...)
	})
	_, err = pipe.Run(context.Background())
	require.NoError(t, err)
	assert.Contains(t, logged.String(), "memory: run done",
		"the factory must pass logf through to the pipeline")
}

// TestCLI_MemoryIndex prints the mechanical index.md (the browsing surface of
// the two-tier world map).
func TestCLI_MemoryIndex(t *testing.T) {
	vaultPath := setupMemoryTestEnv(t, false)

	vault, err := memory.OpenVault(vaultPath)
	require.NoError(t, err)
	_, err = vault.WriteFile("index.md", []byte("# Memory Index\n\n## Counts\n- entity: 3 (short 0, long 3)\n"),
		memory.CommitMsg{Op: "index", Summary: "seed", Cause: "test"})
	require.NoError(t, err)

	var buf bytes.Buffer
	memoryIndexCmd.SetOut(&buf)
	require.NoError(t, memoryIndexCmd.RunE(memoryIndexCmd, nil))

	out := buf.String()
	assert.Contains(t, out, "# Memory Index")
	assert.Contains(t, out, "- entity: 3 (short 0, long 3)")
}

// TestCLI_MemoryIndex_NotGenerated reports cleanly when index.md does not exist
// yet (no vault / no consolidation run).
func TestCLI_MemoryIndex_NotGenerated(t *testing.T) {
	setupMemoryTestEnv(t, false)

	var buf bytes.Buffer
	memoryIndexCmd.SetOut(&buf)
	require.NoError(t, memoryIndexCmd.RunE(memoryIndexCmd, nil))
	assert.Contains(t, buf.String(), "not generated yet")
}

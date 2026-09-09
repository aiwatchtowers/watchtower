package tools

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/memory"
)

// Fixture nodes mirror internal/mcp/memory_test.go: entPayments carries the
// "pay-svc" alias but never mentions the term in its body, so a recall hit for
// it can only come from alias resolution.
var (
	tPayments = memory.Node{
		ID: "ent_01ARZ3NDEKTSV4RRFFQ69G5MP1", Type: "entity", Tier: "long", Status: "active",
		Title: "Payments Service", Aliases: []string{"pay-svc", "payments"},
		Body: "# Payments Service\n\n## What\nOwns the checkout flow.\n\nKickoff: [[ep_01ARZ3NDEKTSV4RRFFQ69G5MP3|kickoff]].\n",
	}
	tKickoff = memory.Node{
		ID: "ep_01ARZ3NDEKTSV4RRFFQ69G5MP3", Type: "episode", Tier: "short", Status: "active",
		Title: "Kickoff", Body: "# Kickoff\n\nDiscussed the pay-svc rollout plan.\n",
	}
)

// seedVault builds a temp vault with the fixture nodes and mirrors them into the
// SQLite index, the way consolidation would. Returns the vault path.
func seedVault(t *testing.T, database *db.DB) string {
	t.Helper()
	vaultPath := t.TempDir()
	v, err := memory.OpenVault(vaultPath)
	require.NoError(t, err)
	_, err = v.WriteNodes([]memory.Node{tPayments, tKickoff}, memory.CommitMsg{Op: "extract", Summary: "seed", Cause: "seed"})
	require.NoError(t, err)
	_, err = memory.Reconcile(v, database, t.Logf)
	require.NoError(t, err)
	return vaultPath
}

func statsRows(t *testing.T, database *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(`SELECT count(*) FROM memory_node_stats`).Scan(&n))
	return n
}

// memory_map returns map.md verbatim plus live node counts (tombstones aside).
func TestMemoryMap_ReturnsMapAndCounts(t *testing.T) {
	database := openDB(t)
	vaultPath := seedVault(t, database)

	reg := New(database)
	require.NoError(t, reg.Register(NewMemoryMap(vaultPath)))

	data, err := reg.CallRead(context.Background(), "memory_map", nil)
	require.NoError(t, err)
	b, _ := json.Marshal(data)
	assert.Contains(t, string(b), `"type":"entity"`)
	assert.Contains(t, string(b), `"type":"episode"`)
}

// memory_open resolves an alias to the canonical node and bumps usage stats
// once on a writable connection.
func TestMemoryOpen_ResolvesAliasAndBumpsStats(t *testing.T) {
	database := openDB(t)
	vaultPath := seedVault(t, database)

	reg := New(database)
	require.NoError(t, reg.Register(NewMemoryOpen(vaultPath)))

	data, err := reg.CallRead(context.Background(), "memory_open", json.RawMessage(`{"ref":"PAY-SVC"}`))
	require.NoError(t, err)
	b, _ := json.Marshal(data)
	assert.Contains(t, string(b), tPayments.ID)
	assert.Contains(t, string(b), "Owns the checkout flow")
	assert.Equal(t, 1, statsRows(t, database), "open bumps stats exactly once")
}

// The bump is best-effort: on a read-only (query_only) connection the write
// fails silently and the open still returns the node — the DEV-01 telemetry
// exception behaving as documented, a path the mcp integration tests (writable
// sessions) never exercise.
func TestMemoryOpen_ReadOnlyConnectionStillReturnsNode(t *testing.T) {
	database := openDB(t)
	vaultPath := seedVault(t, database)
	require.NoError(t, database.SetReadOnly())

	reg := New(database)
	require.NoError(t, reg.Register(NewMemoryOpen(vaultPath)))

	data, err := reg.CallRead(context.Background(), "memory_open", json.RawMessage(`{"ref":"pay-svc"}`))
	require.NoError(t, err)
	b, _ := json.Marshal(data)
	assert.Contains(t, string(b), tPayments.ID)
	assert.Equal(t, 0, statsRows(t, database), "the bump must fail silently on a read-only connection")
}

// A blank ref is a model-facing ValidationError; an unknown ref is a plain
// not-found error that names the ref and never leaks the raw SQL sentinel.
func TestMemoryOpen_BadRefs(t *testing.T) {
	database := openDB(t)
	vaultPath := seedVault(t, database)
	reg := New(database)
	require.NoError(t, reg.Register(NewMemoryOpen(vaultPath)))

	_, err := reg.CallRead(context.Background(), "memory_open", json.RawMessage(`{"ref":"  "}`))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)

	_, err = reg.CallRead(context.Background(), "memory_open", json.RawMessage(`{"ref":"no-such-alias"}`))
	require.Error(t, err)
	assert.NotErrorAs(t, err, &verr, "not-found is a plain error, not a validation error")
	assert.Contains(t, err.Error(), "no-such-alias")
	assert.NotContains(t, err.Error(), "sql: no rows")
}

// memory_recall ranks an exact alias match first, FTS hits following.
func TestMemoryRecall_AliasFirst(t *testing.T) {
	database := openDB(t)
	vaultPath := seedVault(t, database)
	reg := New(database)
	require.NoError(t, reg.Register(NewMemoryRecall(vaultPath, nil)))

	data, err := reg.CallRead(context.Background(), "memory_recall", json.RawMessage(`{"query":"Pay-Svc"}`))
	require.NoError(t, err)
	var hits []memoryHitResult
	require.NoError(t, remarshal(data, &hits))
	require.Len(t, hits, 2)
	assert.Equal(t, tPayments.ID, hits[0].ID, "alias hit first")
	assert.Equal(t, tKickoff.ID, hits[1].ID, "FTS hit second")
	assert.Equal(t, 0, statsRows(t, database), "recall never bumps stats")
}

// A recall that finds nothing returns an empty JSON array, never null — the
// adapter marshals the Execute result with jsonResult, so a nil slice would
// serialize as null. Guards the [] contract at the tool boundary.
func TestMemoryRecall_EmptyIsArrayNotNull(t *testing.T) {
	database := openDB(t)
	vaultPath := seedVault(t, database)
	reg := New(database)
	require.NoError(t, reg.Register(NewMemoryRecall(vaultPath, nil)))

	data, err := reg.CallRead(context.Background(), "memory_recall", json.RawMessage(`{"query":"zzzznomatch"}`))
	require.NoError(t, err)
	b, _ := json.Marshal(data)
	assert.Equal(t, "[]", string(b))
}

// With a shadow handle wired (the memory.retrieve.recall_compare flag on),
// recall writes exactly one shadow row; with nil it writes none. The live
// response is unaffected either way.
func TestMemoryRecall_ShadowGate(t *testing.T) {
	t.Run("off writes no shadow", func(t *testing.T) {
		database := openDB(t)
		vaultPath := seedVault(t, database)
		reg := New(database)
		require.NoError(t, reg.Register(NewMemoryRecall(vaultPath, nil)))

		_, err := reg.CallRead(context.Background(), "memory_recall", json.RawMessage(`{"query":"pay-svc"}`))
		require.NoError(t, err)
		rows, err := database.ListMemoryRetrieveShadow("recall", time.Time{})
		require.NoError(t, err)
		assert.Empty(t, rows)
	})
	t.Run("on writes one shadow row", func(t *testing.T) {
		database := openDB(t)
		vaultPath := seedVault(t, database)
		reg := New(database)
		// Same writable handle as shadow, mirroring newMemorySessionCompare.
		require.NoError(t, reg.Register(NewMemoryRecall(vaultPath, database)))

		_, err := reg.CallRead(context.Background(), "memory_recall", json.RawMessage(`{"query":"pay-svc"}`))
		require.NoError(t, err)
		rows, err := database.ListMemoryRetrieveShadow("recall", time.Time{})
		require.NoError(t, err)
		assert.Len(t, rows, 1)
	})
}

// An unusable vault (empty path, or a path with no .git) makes every memory
// tool answer "not initialized" rather than erroring hard.
func TestMemory_NotInitialized(t *testing.T) {
	database := openDB(t)
	reg := New(database)
	require.NoError(t, reg.Register(NewMemoryMap("")))
	require.NoError(t, reg.Register(NewMemoryOpen("")))
	require.NoError(t, reg.Register(NewMemoryRecall("", nil)))

	for _, c := range []struct {
		name string
		args json.RawMessage
	}{
		{"memory_map", nil},
		{"memory_open", json.RawMessage(`{"ref":"x"}`)},
		{"memory_recall", json.RawMessage(`{"query":"x"}`)},
	} {
		_, err := reg.CallRead(context.Background(), c.name, c.args)
		require.Error(t, err, c.name)
		assert.Contains(t, err.Error(), "memory not initialized", c.name)
	}
}

// remarshal round-trips data through JSON into out — the tools return curated
// structs, so this reads them back the way a caller would.
func remarshal(data, out any) error {
	b, err := json.Marshal(data)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, out)
}

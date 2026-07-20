package mcp

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
	"watchtower/internal/memory"
)

// Shared fixture nodes. entPayments carries the "pay-svc" alias but never
// mentions the term in title or body, so a recall hit for it can only come
// from alias resolution — the discriminating case for alias-first ranking.
// entBilling has an alias that ALSO appears in its body, so an alias hit and
// an FTS hit collide and must be deduplicated.
var (
	entPayments = memory.Node{
		ID:      "ent_01ARZ3NDEKTSV4RRFFQ69G5MP1",
		Type:    "entity",
		Tier:    "long",
		Status:  "active",
		Title:   "Payments Service",
		Aliases: []string{"pay-svc", "payments"},
		Body:    "# Payments Service\n\n## What\nOwns the checkout flow.\n\nKickoff: [[ep_01ARZ3NDEKTSV4RRFFQ69G5MP3|kickoff]].\n",
	}
	entBilling = memory.Node{
		ID:      "ent_01ARZ3NDEKTSV4RRFFQ69G5MP2",
		Type:    "entity",
		Tier:    "long",
		Status:  "active",
		Title:   "Billing",
		Aliases: []string{"billing-team"},
		Body:    "# Billing\n\nHandles invoices and billing-team escalations.\n",
	}
	epKickoff = memory.Node{
		ID:     "ep_01ARZ3NDEKTSV4RRFFQ69G5MP3",
		Type:   "episode",
		Tier:   "short",
		Status: "active",
		Title:  "Kickoff",
		Body:   "# Kickoff\n\nDiscussed the pay-svc rollout plan.\n",
	}
)

// newMemorySession wires an in-memory MCP client to a server that knows the
// memory vault path. Unlike newTestSession the connection stays writable:
// memory_open records usage stats (the one deliberate write on this surface)
// and these tests assert that write actually happened.
func newMemorySession(t *testing.T, database *db.DB, vaultPath string) *mcpsdk.ClientSession {
	t.Helper()
	ctx := context.Background()
	srv := NewServer(database, WithMemoryVault(vaultPath))
	client := mcpsdk.NewClient(&mcpsdk.Implementation{Name: "test", Version: "v0"}, nil)
	st, ct := mcpsdk.NewInMemoryTransports()
	if _, err := srv.s.Connect(ctx, st, nil); err != nil {
		t.Fatalf("server connect: %v", err)
	}
	cs, err := client.Connect(ctx, ct, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { _ = cs.Close() })
	return cs
}

// seedMemoryFixture builds a temp vault holding the shared fixture nodes and
// mirrors them into the SQLite index, the same way consolidation would.
func seedMemoryFixture(t *testing.T, database *db.DB) (*memory.Vault, string) {
	t.Helper()
	vaultPath := t.TempDir()
	v, err := memory.OpenVault(vaultPath)
	if err != nil {
		t.Fatalf("opening test vault: %v", err)
	}
	if _, err := v.WriteNodes([]memory.Node{entPayments, entBilling, epKickoff}, memory.CommitMsg{
		Op: "extract", Summary: "seed test nodes", Cause: "seed",
	}); err != nil {
		t.Fatalf("writing test nodes: %v", err)
	}
	if _, err := memory.Reconcile(v, database, t.Logf); err != nil {
		t.Fatalf("indexing test vault: %v", err)
	}
	return v, vaultPath
}

// memoryStatsState reads the stats table: total row count plus the
// access_count for one node (0 when the node has no row).
func memoryStatsState(t *testing.T, database *db.DB, nodeID string) (rows, count int) {
	t.Helper()
	if err := database.QueryRow(`SELECT count(*) FROM memory_node_stats`).Scan(&rows); err != nil {
		t.Fatalf("counting stats rows: %v", err)
	}
	err := database.QueryRow(`SELECT COALESCE(
		(SELECT access_count FROM memory_node_stats WHERE node_id = ?), 0)`, nodeID).Scan(&count)
	if err != nil {
		t.Fatalf("reading access_count for %s: %v", nodeID, err)
	}
	return rows, count
}

// callMemoryTool invokes one memory tool, fails the test on a transport or
// tool error, and unmarshals the JSON payload into out.
func callMemoryTool(t *testing.T, cs *mcpsdk.ClientSession, name string, args map[string]any, out any) {
	t.Helper()
	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		t.Fatalf("call %s: %v", name, err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	if err := json.Unmarshal([]byte(textContent(t, res)), out); err != nil {
		t.Fatalf("unmarshaling payload: %v", err)
	}
}

// memoryToolCalls are one valid argument set per memory tool, for tests that
// sweep all three.
var memoryToolCalls = map[string]map[string]any{
	"memory_map":    {},
	"memory_open":   {"ref": "ent_01ARZ3NDEKTSV4RRFFQ69G5MP1"},
	"memory_recall": {"query": "anything"},
}

// TestMemoryToolsNotInitialized: with memory disabled (no vault configured)
// or a configured-but-absent vault, every memory tool answers with a clear
// message instead of erroring the server.
func TestMemoryToolsNotInitialized(t *testing.T) {
	t.Run("no vault configured", func(t *testing.T) {
		cs := newTestSession(t, seedDB(t)) // plain server, no WithMemoryVault
		assertMemoryNotInitialized(t, cs)
	})
	t.Run("vault dir missing", func(t *testing.T) {
		// The path is configured but no vault was ever created there.
		cs := newMemorySession(t, seedDB(t), t.TempDir())
		assertMemoryNotInitialized(t, cs)
	})
}

func assertMemoryNotInitialized(t *testing.T, cs *mcpsdk.ClientSession) {
	t.Helper()
	for name, args := range memoryToolCalls {
		res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{Name: name, Arguments: args})
		if err != nil {
			t.Fatalf("call %s: %v", name, err)
		}
		if !res.IsError {
			t.Errorf("%s should report memory not initialized, got: %s", name, textContent(t, res))
			continue
		}
		if msg := textContent(t, res); !strings.Contains(msg, "memory not initialized") {
			t.Errorf("%s error should say memory not initialized, got: %s", name, msg)
		}
	}
}

// TestMemoryMapContentAndCounts: memory_map returns the vault's map.md verbatim
// plus live node counts by type/tier from the index (tombstones excluded).
func TestMemoryMapContentAndCounts(t *testing.T) {
	database := seedDB(t)
	v, vaultPath := seedMemoryFixture(t, database)
	mapContent := "# Memory Map\n\n- hand-rendered test map\n"
	if _, err := v.WriteFile("map.md", []byte(mapContent), memory.CommitMsg{
		Op: "map", Summary: "test map", Cause: "seed",
	}); err != nil {
		t.Fatalf("writing map.md: %v", err)
	}
	cs := newMemorySession(t, database, vaultPath)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{Name: "memory_map"})
	if err != nil {
		t.Fatalf("call memory_map: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	var payload struct {
		Map    string `json:"map"`
		Counts []struct {
			Type  string `json:"type"`
			Tier  string `json:"tier"`
			Count int    `json:"count"`
		} `json:"counts"`
	}
	if err := json.Unmarshal([]byte(textContent(t, res)), &payload); err != nil {
		t.Fatalf("unmarshaling payload: %v", err)
	}
	if payload.Map != mapContent {
		t.Errorf("map content mismatch: got %q, want %q", payload.Map, mapContent)
	}
	if len(payload.Counts) != 2 {
		t.Fatalf("expected 2 count buckets, got %+v", payload.Counts)
	}
	if c := payload.Counts[0]; c.Type != "entity" || c.Tier != "long" || c.Count != 2 {
		t.Errorf("counts[0] = %+v, want entity/long/2", c)
	}
	if c := payload.Counts[1]; c.Type != "episode" || c.Tier != "short" || c.Count != 1 {
		t.Errorf("counts[1] = %+v, want episode/short/1", c)
	}
}

// TestMemoryMapEmptyVault: a freshly initialized vault answers with the
// placeholder map (a helpful "nothing consolidated yet" message) and an empty
// counts array — not an error.
func TestMemoryMapEmptyVault(t *testing.T) {
	database := seedDB(t)
	vaultPath := t.TempDir()
	if _, err := memory.OpenVault(vaultPath); err != nil {
		t.Fatalf("initializing vault: %v", err)
	}
	cs := newMemorySession(t, database, vaultPath)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{Name: "memory_map"})
	if err != nil {
		t.Fatalf("call memory_map: %v", err)
	}
	if res.IsError {
		t.Fatalf("empty vault should not be an error: %s", textContent(t, res))
	}
	got := textContent(t, res)
	if !strings.Contains(got, "Empty vault") {
		t.Errorf("expected the placeholder map text, got: %s", got)
	}
	if !strings.Contains(got, `"counts": []`) {
		t.Errorf("counts should serialize as [] (not null), got: %s", got)
	}
}

// TestMemoryOpenAliasBumpsStatsOnce: opening via an alias (case-insensitive)
// resolves to the canonical node, returns the full payload, and bumps
// memory_node_stats exactly once for the canonical id.
func TestMemoryOpenAliasBumpsStatsOnce(t *testing.T) {
	database := seedDB(t)
	_, vaultPath := seedMemoryFixture(t, database)
	cs := newMemorySession(t, database, vaultPath)

	var payload struct {
		ID      string   `json:"id"`
		Type    string   `json:"type"`
		Tier    string   `json:"tier"`
		Status  string   `json:"status"`
		Title   string   `json:"title"`
		Aliases []string `json:"aliases"`
		Links   []struct {
			ID    string `json:"id"`
			Label string `json:"label"`
		} `json:"links"`
		Body string `json:"body"`
	}
	callMemoryTool(t, cs, "memory_open", map[string]any{"ref": "PAY-SVC"}, &payload)
	if payload.ID != entPayments.ID {
		t.Errorf("id = %q, want canonical %q", payload.ID, entPayments.ID)
	}
	if payload.Type != "entity" || payload.Tier != "long" || payload.Status != "active" {
		t.Errorf("type/tier/status = %s/%s/%s, want entity/long/active",
			payload.Type, payload.Tier, payload.Status)
	}
	if payload.Title != "Payments Service" {
		t.Errorf("title = %q, want %q", payload.Title, "Payments Service")
	}
	if len(payload.Aliases) != 2 || payload.Aliases[0] != "pay-svc" {
		t.Errorf("aliases = %v, want the frontmatter aliases", payload.Aliases)
	}
	if !strings.Contains(payload.Body, "Owns the checkout flow") {
		t.Errorf("body missing markdown content: %q", payload.Body)
	}
	if len(payload.Links) != 1 || payload.Links[0].ID != epKickoff.ID || payload.Links[0].Label != "kickoff" {
		t.Errorf("links = %+v, want one link to %s labeled kickoff", payload.Links, epKickoff.ID)
	}

	rows, count := memoryStatsState(t, database, entPayments.ID)
	if rows != 1 || count != 1 {
		t.Errorf("stats after open: %d rows, access_count %d — want exactly one bump for the canonical node", rows, count)
	}
}

// TestMemoryOpenTombstoneChase: opening a tombstoned old id transparently
// returns the merge winner, with the winner's current id in the payload so
// callers can self-heal.
func TestMemoryOpenTombstoneChase(t *testing.T) {
	database := seedDB(t)
	v, vaultPath := seedMemoryFixture(t, database)
	if err := memory.Merge(v, database, entBilling.ID, entPayments.ID); err != nil {
		t.Fatalf("merging fixture nodes: %v", err)
	}
	cs := newMemorySession(t, database, vaultPath)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "memory_open",
		Arguments: map[string]any{"ref": entBilling.ID},
	})
	if err != nil {
		t.Fatalf("call memory_open: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	var payload struct {
		ID     string `json:"id"`
		Status string `json:"status"`
	}
	if err := json.Unmarshal([]byte(textContent(t, res)), &payload); err != nil {
		t.Fatalf("unmarshaling payload: %v", err)
	}
	if payload.ID != entPayments.ID {
		t.Errorf("id = %q, want the merge winner %q", payload.ID, entPayments.ID)
	}
	if payload.Status != "active" {
		t.Errorf("status = %q, want active (the winner, not the tombstone)", payload.Status)
	}

	// The bump lands on the winner — the node actually used.
	rows, count := memoryStatsState(t, database, entPayments.ID)
	if rows != 1 || count != 1 {
		t.Errorf("stats after tombstone chase: %d rows, access_count %d — want one bump on the winner", rows, count)
	}
}

// TestMemoryOpenBadRefs: unknown refs get a friendly error (no raw SQL
// sentinel), and an empty ref is rejected up front.
func TestMemoryOpenBadRefs(t *testing.T) {
	database := seedDB(t)
	_, vaultPath := seedMemoryFixture(t, database)
	cs := newMemorySession(t, database, vaultPath)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "memory_open",
		Arguments: map[string]any{"ref": "no-such-alias"},
	})
	if err != nil {
		t.Fatalf("call memory_open: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected error for unknown ref, got: %s", textContent(t, res))
	}
	msg := textContent(t, res)
	if !strings.Contains(msg, "no-such-alias") {
		t.Errorf("error should name the ref, got: %s", msg)
	}
	if strings.Contains(msg, "sql: no rows") {
		t.Errorf("not-found leaked the raw SQL sentinel: %s", msg)
	}

	res, err = cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "memory_open",
		Arguments: map[string]any{"ref": "  "},
	})
	if err != nil {
		t.Fatalf("call memory_open: %v", err)
	}
	if !res.IsError || !strings.Contains(textContent(t, res), "ref is required") {
		t.Errorf("blank ref should be rejected, got: %s", textContent(t, res))
	}
}

// TestMemoryRecallAliasFirstNoBump: an exact (case-insensitive) alias match
// ranks first even though FTS alone would never return that node, FTS hits
// follow, and recall bumps NO stats (browsing is not use).
func TestMemoryRecallAliasFirstNoBump(t *testing.T) {
	database := seedDB(t)
	_, vaultPath := seedMemoryFixture(t, database)
	cs := newMemorySession(t, database, vaultPath)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "memory_recall",
		Arguments: map[string]any{"query": "Pay-Svc"},
	})
	if err != nil {
		t.Fatalf("call memory_recall: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	var hits []struct {
		ID    string `json:"id"`
		Title string `json:"title"`
		Type  string `json:"type"`
	}
	if err := json.Unmarshal([]byte(textContent(t, res)), &hits); err != nil {
		t.Fatalf("unmarshaling hits: %v", err)
	}
	if len(hits) != 2 {
		t.Fatalf("expected alias hit + FTS hit, got %+v", hits)
	}
	if hits[0].ID != entPayments.ID {
		t.Errorf("hits[0] = %+v, want the alias match %s first", hits[0], entPayments.ID)
	}
	if hits[1].ID != epKickoff.ID {
		t.Errorf("hits[1] = %+v, want the FTS hit %s", hits[1], epKickoff.ID)
	}

	if rows, _ := memoryStatsState(t, database, entPayments.ID); rows != 0 {
		t.Errorf("recall must not bump stats, found %d stats rows", rows)
	}
}

// TestMemoryRecallDedupesAliasHit: when the alias-matched node is also an FTS
// hit it appears once, not twice.
func TestMemoryRecallDedupesAliasHit(t *testing.T) {
	database := seedDB(t)
	_, vaultPath := seedMemoryFixture(t, database)
	cs := newMemorySession(t, database, vaultPath)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "memory_recall",
		Arguments: map[string]any{"query": "billing-team"},
	})
	if err != nil {
		t.Fatalf("call memory_recall: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	var hits []struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal([]byte(textContent(t, res)), &hits); err != nil {
		t.Fatalf("unmarshaling hits: %v", err)
	}
	if len(hits) != 1 || hits[0].ID != entBilling.ID {
		t.Errorf("expected exactly one deduplicated hit for %s, got %+v", entBilling.ID, hits)
	}
}

// TestMemoryRecallLimit: limit truncates the combined list; the alias hit
// survives because it ranks first.
func TestMemoryRecallLimit(t *testing.T) {
	database := seedDB(t)
	_, vaultPath := seedMemoryFixture(t, database)
	cs := newMemorySession(t, database, vaultPath)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "memory_recall",
		Arguments: map[string]any{"query": "pay-svc", "limit": 1},
	})
	if err != nil {
		t.Fatalf("call memory_recall: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	var hits []struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal([]byte(textContent(t, res)), &hits); err != nil {
		t.Fatalf("unmarshaling hits: %v", err)
	}
	if len(hits) != 1 || hits[0].ID != entPayments.ID {
		t.Errorf("limit=1 should keep only the alias hit, got %+v", hits)
	}
}

// newMemorySessionCompare is newMemorySession plus a writable shadowDB
// wired via WithMemoryRetrieveCompare — the Task 8 dark-wiring seam.
func newMemorySessionCompare(t *testing.T, database, shadowDB *db.DB, vaultPath string) *mcpsdk.ClientSession {
	t.Helper()
	ctx := context.Background()
	srv := NewServer(database, WithMemoryVault(vaultPath), WithMemoryRetrieveCompare(shadowDB))
	client := mcpsdk.NewClient(&mcpsdk.Implementation{Name: "test", Version: "v0"}, nil)
	st, ct := mcpsdk.NewInMemoryTransports()
	if _, err := srv.s.Connect(ctx, st, nil); err != nil {
		t.Fatalf("server connect: %v", err)
	}
	cs, err := client.Connect(ctx, ct, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })
	return cs
}

// TestMemoryRecallCompare_ShadowWrittenResponseUnchanged: with
// memory.retrieve.recall_compare wired on (via a second writable handle),
// memory_recall ALSO runs the new RetrieveByQuery-based ranking and writes
// one memory_retrieve_shadow row with sane diff metrics — but the actual MCP
// response returned to the caller is BYTE-IDENTICAL to the flag-off legacy
// response (the single most important behavioral guarantee this task adds).
//
// Query is "billing-team", not the alias-only "pay-svc" used elsewhere in
// this file: RetrieveByQuery is pure FTS and "knows nothing about aliases"
// (internal/memory/retrieve.go), so a query whose only legacy hit comes from
// alias resolution (entPayments, by fixture design) can never show
// coverage_ok=true here — that would be a real, expected divergence, not a
// wiring bug. entBilling's alias also appears in its own body, so both the
// legacy alias+FTS path and the new FTS-only path find it, exercising
// coverage_ok=true on genuinely identical underlying data.
func TestMemoryRecallCompare_ShadowWrittenResponseUnchanged(t *testing.T) {
	database := seedDB(t)
	_, vaultPath := seedMemoryFixture(t, database)

	// Baseline: flag off, capture the legacy response bytes.
	csOff := newMemorySession(t, database, vaultPath)
	resOff, err := csOff.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name: "memory_recall", Arguments: map[string]any{"query": "billing-team"},
	})
	if err != nil || resOff.IsError {
		t.Fatalf("baseline call failed: err=%v res=%+v", err, resOff)
	}
	baseline := textContent(t, resOff)

	// Compare mode on: same query, same DB/vault state.
	csOn := newMemorySessionCompare(t, database, database, vaultPath)
	resOn, err := csOn.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name: "memory_recall", Arguments: map[string]any{"query": "billing-team"},
	})
	if err != nil || resOn.IsError {
		t.Fatalf("compare-mode call failed: err=%v res=%+v", err, resOn)
	}
	if got := textContent(t, resOn); got != baseline {
		t.Fatalf("compare mode changed the live response:\n legacy: %s\n got:    %s", baseline, got)
	}

	rows, err := database.ListMemoryRetrieveShadow("recall", time.Time{})
	if err != nil {
		t.Fatalf("ListMemoryRetrieveShadow: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected exactly one recall shadow row, got %d", len(rows))
	}
	var diff memory.RecallDiff
	if err := json.Unmarshal([]byte(rows[0].DiffMetricsJSON), &diff); err != nil {
		t.Fatalf("unmarshaling diff metrics: %v", err)
	}
	if !diff.CoverageOK {
		t.Errorf("expected coverage_ok on an identical-vault comparison, got false (diff=%+v)", diff)
	}
}

// TestMemoryRecallCompare_GateOffWritesNoShadow: without
// WithMemoryRetrieveCompare, memory_recall never touches memory_retrieve_shadow
// — byte-identical to before this task existed.
func TestMemoryRecallCompare_GateOffWritesNoShadow(t *testing.T) {
	database := seedDB(t)
	_, vaultPath := seedMemoryFixture(t, database)
	cs := newMemorySession(t, database, vaultPath) // no compare option

	_, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name: "memory_recall", Arguments: map[string]any{"query": "Pay-Svc"},
	})
	if err != nil {
		t.Fatalf("call memory_recall: %v", err)
	}
	rows, err := database.ListMemoryRetrieveShadow("recall", time.Time{})
	if err != nil {
		t.Fatalf("ListMemoryRetrieveShadow: %v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("expected no shadow rows with the option absent, got %d", len(rows))
	}
}

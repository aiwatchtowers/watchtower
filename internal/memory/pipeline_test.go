package memory

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	git "github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// pipelineTestConfig is a permissive enabled config for pipeline tests.
// BatchMaxChannels: 1 disables cross-channel batching so these tests keep
// exercising the per-window MEM-01/04 semantics they were written against;
// batch-specific behavior (several channels sharing one call) has its own
// tests below (TestBatch*).
func pipelineTestConfig() config.MemoryConfig {
	return config.MemoryConfig{
		Enabled:              true,
		MaxChunkMessages:     2000,
		SeedMinMessages:      1,
		MaxEpisodesPerWindow: 5,
		MaxWindowMessages:    200,
		BatchMaxChannels:     1,
		BatchMaxMessages:     1500,
	}
}

// fakeGen is a scripted digest.Generator: reply picks the response by user
// prompt; every call reports the same fixed usage.
type fakeGen struct {
	calls []string
	reply func(user string) (string, error)
	usage digest.Usage
}

func (g *fakeGen) Generate(_ context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	g.calls = append(g.calls, user)
	out, err := g.reply(user)
	if err != nil {
		return "", nil, "", err
	}
	u := g.usage
	return out, &u, "", nil
}

// seedWorkspaceRow creates the singleton workspace row the watermark
// accessors read.
func seedWorkspaceRow(t *testing.T, d *db.DB) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO workspace (id, name) VALUES ('T1', 'test')`)
	require.NoError(t, err)
}

func seedChannelRow(t *testing.T, d *db.DB, id, name string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO channels (id, name, type) VALUES (?, ?, 'public')`, id, name)
	require.NoError(t, err)
}

func seedUserRow(t *testing.T, d *db.DB, id, name string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO users (id, name) VALUES (?, ?)`, id, name)
	require.NoError(t, err)
}

func seedMessageRow(t *testing.T, d *db.DB, channelID, ts, userID, text string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES (?, ?, ?, ?)`,
		channelID, ts, userID, text)
	require.NoError(t, err)
}

// pipelineFixture seeds a workspace, two users, and two channels with two
// recent messages each (channel C1GEN strictly earlier than C2OPS). Returns
// the base unix second of the first message; message ts values are
// base+0/60 (C1GEN) and base+120/180 (C2OPS) with fixed fractional suffixes.
func pipelineFixture(t *testing.T, d *db.DB) int64 {
	t.Helper()
	seedWorkspaceRow(t, d)
	seedUserRow(t, d, "U1ALICE", "alice")
	seedUserRow(t, d, "U2BOB", "bob")
	seedChannelRow(t, d, "C1GEN", "general")
	seedChannelRow(t, d, "C2OPS", "ops")

	base := time.Now().Add(-time.Hour).Unix()
	seedMessageRow(t, d, "C1GEN", fmt.Sprintf("%d.000100", base), "U1ALICE", "the deploy to prod failed")
	seedMessageRow(t, d, "C1GEN", fmt.Sprintf("%d.000200", base+60), "U2BOB", "rolling back now")
	seedMessageRow(t, d, "C2OPS", fmt.Sprintf("%d.000300", base+120), "U1ALICE", "postmortem scheduled")
	seedMessageRow(t, d, "C2OPS", fmt.Sprintf("%d.000400", base+180), "U2BOB", "doc drafted")
	return base
}

// episodeJSON renders a one-episode extractor reply with a single ref and a
// single entity hint.
func episodeJSON(title, channelID, ts, hint string) string {
	return fmt.Sprintf(`[{"title": %q, "story": "Something happened.", "outcome": "resolved",
		"participants": ["U1ALICE", "U2BOB"],
		"refs": [{"channel_id": %q, "ts": %q}],
		"entity_hints": [%q]}]`, title, channelID, ts, hint)
}

func memoryPipelineRunRow(t *testing.T, d *db.DB) (id int64, status string, items, inTok, outTok, totalAPI, cacheRead, cacheCreation int, model string) {
	t.Helper()
	err := d.QueryRow(`SELECT id, status, items_found, input_tokens, output_tokens,
			total_api_tokens, cache_read_tokens, cache_creation_tokens, model
		FROM pipeline_runs WHERE pipeline = 'memory'`).
		Scan(&id, &status, &items, &inTok, &outTok, &totalAPI, &cacheRead, &cacheCreation, &model)
	require.NoError(t, err)
	return
}

func TestPipelineDisabledNoOp(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	pipelineFixture(t, d)
	gen := &fakeGen{reply: func(string) (string, error) { return "[]", nil }}

	cfg := pipelineTestConfig()
	cfg.Enabled = false
	p := NewPipeline(d, v, gen, cfg, t.Logf)

	stats, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, RunStats{}, stats)
	assert.Empty(t, gen.calls, "no AI calls when disabled")

	var runs int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM pipeline_runs`).Scan(&runs))
	assert.Zero(t, runs, "no pipeline_runs row when disabled")

	nodes, err := d.ListMemoryNodes()
	require.NoError(t, err)
	assert.Empty(t, nodes, "nothing written when disabled")
	assert.Equal(t, 1, commitCount(t, openTestRepo(t, v.path)), "only the init commit")

	wm, err := d.MemoryWatermark()
	require.NoError(t, err)
	assert.Zero(t, wm)
}

func TestPipelineHappyPath(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	base := pipelineFixture(t, d)
	ts1 := fmt.Sprintf("%d.000100", base)
	ts3 := fmt.Sprintf("%d.000300", base+120)

	gen := &fakeGen{
		usage: digest.Usage{InputTokens: 100, OutputTokens: 20, TotalAPITokens: 150, Model: "haiku"},
		reply: func(user string) (string, error) {
			if strings.Contains(user, "(C1GEN)") {
				return episodeJSON("Prod deploy failed", "C1GEN", ts1, "C1GEN"), nil
			}
			return episodeJSON("Postmortem scheduled", "C2OPS", ts3, "U1ALICE"), nil
		},
	}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	stats, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 4, stats.Seeded, "alice, bob, #general, #ops")
	assert.Equal(t, 2, stats.Episodes)
	assert.Equal(t, 2, stats.Windows)
	assert.Zero(t, stats.WindowsFailed)
	require.Len(t, gen.calls, 2)

	// Watermark == last processed message ts (both windows fully processed).
	wm, err := d.MemoryWatermark()
	require.NoError(t, err)
	assert.Equal(t, float64(base+180), wm)

	// Episodes are in the vault and index with validated provenance.
	nodes, err := d.ListMemoryNodes()
	require.NoError(t, err)
	var episodeTitles []string
	for _, n := range nodes {
		if n.Type == "episode" {
			episodeTitles = append(episodeTitles, n.Title)
		}
	}
	assert.ElementsMatch(t, []string{"Prod deploy failed", "Postmortem scheduled"}, episodeTitles)

	// The hinted entity pages link back to the new episodes.
	ent, err := Resolve(v, d, "C1GEN")
	require.NoError(t, err)
	assert.Contains(t, ent.Body, "## Links\n- [[ep_", "episode linked from the hinted channel entity")
	assert.Contains(t, ent.Body, "|Prod deploy failed]]")
	person, err := Resolve(v, d, "U1ALICE")
	require.NoError(t, err)
	assert.Contains(t, person.Body, "|Postmortem scheduled]]")

	// index.md rendered mechanically at the end of the run (the strong-tier
	// map.md is wired separately behind memory.semantic.enabled).
	indexContent, err := os.ReadFile(filepath.Join(v.path, "index.md"))
	require.NoError(t, err)
	assert.Contains(t, string(indexContent), "# Memory Index")
	assert.Contains(t, string(indexContent), "- entity: 4 (short 0, long 4)")
	assert.Contains(t, string(indexContent), "- episode: 2 (short 2, long 0)")
	assert.Contains(t, string(indexContent), "## People")
	assert.Contains(t, string(indexContent), "[[ent_")
	assert.Contains(t, string(indexContent), "#general")
	assert.Contains(t, string(indexContent), "## Recent open episodes")
	assert.Contains(t, string(indexContent), "Prod deploy failed")

	// pipeline_runs row with accumulated token accounting incl. the split
	// cache columns (cache-side residual recorded under cache_read_tokens).
	_, status, items, inTok, outTok, totalAPI, cacheRead, cacheCreation, model := memoryPipelineRunRow(t, d)
	assert.Equal(t, "done", status)
	assert.Equal(t, 2, items)
	assert.Equal(t, 200, inTok)
	assert.Equal(t, 40, outTok)
	assert.Equal(t, 300, totalAPI)
	assert.Equal(t, 100, cacheRead)
	assert.Zero(t, cacheCreation)
	assert.Equal(t, "haiku", model)
}

// TestMemory04_WatermarkFreezeOnAIFailure guards MEM-04: a generator failure
// on a later window leaves the watermark at the end of the last fully
// committed earlier window — never past the unprocessed one — while the
// earlier window's episodes stay committed and the run still completes.
func TestMemory04_WatermarkFreezeOnAIFailure(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	base := pipelineFixture(t, d)
	ts1 := fmt.Sprintf("%d.000100", base)

	gen := &fakeGen{
		usage: digest.Usage{InputTokens: 100, OutputTokens: 20, TotalAPITokens: 150, Model: "haiku"},
		reply: func(user string) (string, error) {
			if strings.Contains(user, "(C2OPS)") {
				return "", fmt.Errorf("model exploded")
			}
			return episodeJSON("Prod deploy failed", "C1GEN", ts1, "C1GEN"), nil
		},
	}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	stats, err := p.Run(context.Background())
	require.NoError(t, err, "window isolation: a per-window AI failure never fails the run")
	assert.Equal(t, 1, stats.Episodes)
	assert.Equal(t, 1, stats.WindowsFailed)

	// Watermark == end of channel 1's window, never past channel 2.
	wm, err := d.MemoryWatermark()
	require.NoError(t, err)
	assert.Equal(t, float64(base+60), wm)

	// Channel 1's episode is committed.
	nodes, err := d.ListMemoryNodes()
	require.NoError(t, err)
	found := false
	for _, n := range nodes {
		if n.Type == "episode" && n.Title == "Prod deploy failed" {
			found = true
		}
	}
	assert.True(t, found, "channel 1's episode committed despite channel 2's failure")

	// Run row is done (partial success); the failure is noted in a step row.
	runID, status, items, _, _, _, _, _, _ := memoryPipelineRunRow(t, d)
	assert.Equal(t, "done", status)
	assert.Equal(t, 1, items)
	steps, err := d.GetPipelineSteps(runID)
	require.NoError(t, err)
	require.Len(t, steps, 2)
	assert.Equal(t, "done", steps[0].Status)
	assert.Equal(t, "C1GEN", steps[0].ChannelID)
	assert.Equal(t, "error", steps[1].Status)
	assert.Equal(t, "C2OPS", steps[1].ChannelID)
}

func TestPipelineChunkCapLeavesDebt(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	seedUserRow(t, d, "U1ALICE", "alice")
	seedChannelRow(t, d, "C1GEN", "general")
	base := time.Now().Add(-time.Hour).Unix()
	for i := 0; i < 5; i++ {
		seedMessageRow(t, d, "C1GEN", fmt.Sprintf("%d.%06d", base+int64(i)*60, i+1), "U1ALICE",
			fmt.Sprintf("message number %d", i+1))
	}

	gen := &fakeGen{
		usage: digest.Usage{InputTokens: 10, OutputTokens: 2, TotalAPITokens: 10},
		reply: func(string) (string, error) { return "[]", nil },
	}
	cfg := pipelineTestConfig()
	cfg.MaxChunkMessages = 3
	p := NewPipeline(d, v, gen, cfg, t.Logf)

	stats, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 3, stats.Messages, "only the first max_chunk_messages consumed")
	require.Len(t, gen.calls, 1)
	assert.Contains(t, gen.calls[0], "message number 3")
	assert.NotContains(t, gen.calls[0], "message number 4", "capped: later messages not fed to the model")

	// Watermark stops at the 3rd message; the remaining two stay as debt.
	wm, err := d.MemoryWatermark()
	require.NoError(t, err)
	assert.Equal(t, float64(base+120), wm)

	// A second run drains the debt.
	stats, err = p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 2, stats.Messages)
	wm, err = d.MemoryWatermark()
	require.NoError(t, err)
	assert.Equal(t, float64(base+240), wm)
}

// TestPipelineAIFailureKeepsPriorCommits: reconcile/seed/ingest commits are
// already on disk when extraction fails — an AI failure never rolls them back.
func TestPipelineAIFailureKeepsPriorCommits(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	pipelineFixture(t, d)
	sitID := seedIngestSituation(t, d, "Billing outage")

	gen := &fakeGen{reply: func(string) (string, error) { return "", fmt.Errorf("model down") }}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	stats, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Zero(t, stats.Episodes)
	assert.Equal(t, stats.Windows, stats.WindowsFailed, "every window failed")

	// Seeded entities and the ingested situation episode survive.
	_, err = Resolve(v, d, "C1GEN")
	require.NoError(t, err, "seeded channel entity committed")
	sit, err := Resolve(v, d, fmt.Sprintf("situation:%d", sitID))
	require.NoError(t, err, "ingested situation episode committed")
	assert.Equal(t, "episode", sit.Type)

	// Watermark untouched: no window succeeded.
	wm, err := d.MemoryWatermark()
	require.NoError(t, err)
	assert.Zero(t, wm)

	_, status, _, _, _, _, _, _, _ := memoryPipelineRunRow(t, d)
	assert.Equal(t, "done", status, "partial success: window failures do not fail the run")
}

// TestPipelineOwnerEditsCommittedFirstAndIndexed guards the MEM-03 ordering
// inside Run: the owner's manual vault edit is committed as its own
// owner-edit commit before any machine write, and the subsequent Reconcile
// absorbs it into the index.
func TestPipelineOwnerEditsCommittedFirstAndIndexed(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	seedUserRow(t, d, "U1ALICE", "alice")
	seedChannelRow(t, d, "C1GEN", "general")
	base := time.Now().Add(-time.Hour).Unix()
	seedMessageRow(t, d, "C1GEN", fmt.Sprintf("%d.000100", base), "U1ALICE", "hello there")

	// Run once to seed entity pages (nil generator: extraction skipped).
	p := NewPipeline(d, v, nil, pipelineTestConfig(), t.Logf)
	_, err := p.Run(context.Background())
	require.NoError(t, err)

	// Owner hand-edits the channel entity page.
	entID, err := d.LookupMemoryAlias("C1GEN")
	require.NoError(t, err)
	rel, err := nodeRelPath(entID)
	require.NoError(t, err)
	abs := filepath.Join(v.path, filepath.FromSlash(rel))
	raw, err := os.ReadFile(abs)
	require.NoError(t, err)
	edited := strings.Replace(string(raw), "## What\n", "## What\nownernote handbook lives here\n", 1)
	require.NoError(t, os.WriteFile(abs, []byte(edited), 0o644))

	_, err = p.Run(context.Background())
	require.NoError(t, err)

	// The owner-edit commit exists and contains only the owner's change.
	repo := openTestRepo(t, v.path)
	iter, err := repo.Log(&git.LogOptions{})
	require.NoError(t, err)
	var ownerFiles []string
	require.NoError(t, iter.ForEach(func(c *object.Commit) error {
		if strings.HasPrefix(c.Message, "memory(owner-edit)") {
			ownerFiles = commitFiles(t, c)
		}
		return nil
	}))
	assert.Equal(t, []string{rel}, ownerFiles, "owner-edit commit carries exactly the hand-edited file")

	// Reconcile (after the owner-edit commit) absorbed the edit into the index.
	hits, err := d.SearchMemoryFTS("ownernote", 5)
	require.NoError(t, err)
	require.Len(t, hits, 1)
	assert.Equal(t, entID, hits[0].ID)
}

// TestVaultWriteFileSkipsUnchanged covers the additive Vault.WriteFile used
// for the mechanical map.md render: one commit per change, no commit when the
// content is byte-identical.
func TestVaultWriteFileSkipsUnchanged(t *testing.T) {
	v := newTestVault(t)
	repo := openTestRepo(t, v.path)
	before := commitCount(t, repo)

	msg := CommitMsg{Op: "map", Summary: "render world map", Cause: "run:1"}
	changed, err := v.WriteFile("map.md", []byte("# Memory Map\n\ncontent\n"), msg)
	require.NoError(t, err)
	assert.True(t, changed)
	assert.Equal(t, before+1, commitCount(t, repo))

	changed, err = v.WriteFile("map.md", []byte("# Memory Map\n\ncontent\n"), msg)
	require.NoError(t, err)
	assert.False(t, changed, "byte-identical content is a no-op")
	assert.Equal(t, before+1, commitCount(t, repo))

	raw, err := os.ReadFile(filepath.Join(v.path, "map.md"))
	require.NoError(t, err)
	assert.Equal(t, "# Memory Map\n\ncontent\n", string(raw))
}

// TestMemory04_ShapeDegenerateJSONFreezesWatermark extends MEM-04: extractor
// JSON that parses but carries episodes with zero refs (e.g. a misnamed
// "references" key) is a malformed reply, not routine chatter — the window
// must FAIL and the watermark must freeze, exactly like an AI error. A
// genuinely empty [] remains a clean no-episode window and advances.
func TestMemory04_ShapeDegenerateJSONFreezesWatermark(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	pipelineFixture(t, d)

	gen := &fakeGen{
		usage: digest.Usage{InputTokens: 10, OutputTokens: 2, TotalAPITokens: 10},
		reply: func(user string) (string, error) {
			if strings.Contains(user, "(C1GEN)") {
				// Misnamed refs key: unmarshals to episodes with zero refs.
				return `[{"title": "Prod deploy failed", "story": "It broke.", "references": [{"channel_id": "C1GEN", "ts": "x"}]}]`, nil
			}
			return "[]", nil // routine chatter — clean window
		},
	}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	stats, err := p.Run(context.Background())
	require.NoError(t, err, "window isolation: a malformed window never fails the run")
	assert.Equal(t, 1, stats.WindowsFailed, "shape-degenerate reply is a failed window")
	assert.Zero(t, stats.Episodes)
	assert.Equal(t, 1, stats.Malformed, "malformed episode count exposed in RunStats")

	// Watermark frozen below the malformed C1GEN window (its messages are the
	// earliest); the clean C2OPS [] window cannot pull it past them.
	wm, err := d.MemoryWatermark()
	require.NoError(t, err)
	assert.Zero(t, wm, "watermark frozen: malformed window owns the earliest messages")

	// No episode node reached the vault.
	nodes, err := d.ListMemoryNodes()
	require.NoError(t, err)
	for _, n := range nodes {
		assert.NotEqual(t, "episode", n.Type, "no episode written from a shape-degenerate reply")
	}
}

// TestPipelineEmptyArrayAdvancesWatermark: [] from the extractor is a clean
// no-episode window — the watermark advances past it (contrast with the
// shape-degenerate case above).
func TestPipelineEmptyArrayAdvancesWatermark(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	base := pipelineFixture(t, d)

	gen := &fakeGen{reply: func(string) (string, error) { return "[]", nil }}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	stats, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Zero(t, stats.WindowsFailed)
	assert.Zero(t, stats.Malformed)

	wm, err := d.MemoryWatermark()
	require.NoError(t, err)
	assert.Equal(t, float64(base+180), wm, "clean [] windows advance the watermark")
}

// TestMemory04_SameSecondChunkCapNeverSkips extends MEM-04 for the whole-
// second granularity of ts_unix: with MORE same-second messages than the
// chunk cap (cap=3, five messages sharing one second across two channels),
// the boundary second must be drained in full — across two runs no message
// is ever permanently skipped by the watermark's strict > reload.
func TestMemory04_SameSecondChunkCapNeverSkips(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	seedUserRow(t, d, "U1ALICE", "alice")
	seedChannelRow(t, d, "C1GEN", "general")
	seedChannelRow(t, d, "C2OPS", "ops")
	base := time.Now().Add(-time.Hour).Unix()
	texts := []string{"tie one", "tie two", "tie three", "tie four", "tie five"}
	channels := []string{"C1GEN", "C1GEN", "C2OPS", "C2OPS", "C1GEN"}
	for i, text := range texts {
		seedMessageRow(t, d, channels[i], fmt.Sprintf("%d.%06d", base, i+1), "U1ALICE", text)
	}

	gen := &fakeGen{reply: func(string) (string, error) { return "[]", nil }}
	cfg := pipelineTestConfig()
	cfg.MaxChunkMessages = 3
	p := NewPipeline(d, v, gen, cfg, t.Logf)

	stats, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 5, stats.Messages, "the chunk-cap cut inside the second drains the whole second")

	stats, err = p.Run(context.Background())
	require.NoError(t, err)
	assert.Zero(t, stats.Messages, "nothing left as debt")

	seen := strings.Join(gen.calls, "\n")
	for _, text := range texts {
		assert.Contains(t, seen, text, "message %q must never be skipped", text)
	}
	wm, err := d.MemoryWatermark()
	require.NoError(t, err)
	assert.Equal(t, float64(base), wm)
}

// TestMemory04_InterleavedWindowFreeze extends MEM-04 for time-interleaved
// windows: window A (C1GEN) holds ts {base+10, base+40} and succeeds; window
// B (C2OPS) holds ts {base+20, base+30} and fails. The watermark must stay at
// or below base+10 — never inside B's span — and BOTH B messages must be
// re-extracted on the next run.
func TestMemory04_InterleavedWindowFreeze(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	seedUserRow(t, d, "U1ALICE", "alice")
	seedChannelRow(t, d, "C1GEN", "general")
	seedChannelRow(t, d, "C2OPS", "ops")
	base := time.Now().Add(-time.Hour).Unix()
	seedMessageRow(t, d, "C1GEN", fmt.Sprintf("%d.000001", base+10), "U1ALICE", "a first")
	seedMessageRow(t, d, "C2OPS", fmt.Sprintf("%d.000002", base+20), "U1ALICE", "b first")
	seedMessageRow(t, d, "C2OPS", fmt.Sprintf("%d.000003", base+30), "U1ALICE", "b second")
	seedMessageRow(t, d, "C1GEN", fmt.Sprintf("%d.000004", base+40), "U1ALICE", "a second")

	fail := true
	gen := &fakeGen{reply: func(user string) (string, error) {
		if fail && strings.Contains(user, "(C2OPS)") {
			return "", fmt.Errorf("model exploded")
		}
		return "[]", nil
	}}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	stats, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, stats.WindowsFailed)

	wm, err := d.MemoryWatermark()
	require.NoError(t, err)
	assert.LessOrEqual(t, wm, float64(base+10), "watermark must not enter the failed window's span")

	// Next run (B healthy now): both B messages come back for extraction.
	fail = false
	firstRunCalls := len(gen.calls)
	_, err = p.Run(context.Background())
	require.NoError(t, err)
	rerun := strings.Join(gen.calls[firstRunCalls:], "\n")
	assert.Contains(t, rerun, "b first", "failed window's first message re-extracted")
	assert.Contains(t, rerun, "b second", "failed window's second message re-extracted")
	wm, err = d.MemoryWatermark()
	require.NoError(t, err)
	assert.Equal(t, float64(base+40), wm)
}

// TestMemory01_LookupErrorFreezesWatermark extends the MEM-01 guard family at
// pipeline level: when the provenance lookup ERRORS (the check cannot run),
// the window must FAIL and the watermark freeze — never advance past refs
// that were only "unverified", and never write the episode.
func TestMemory01_LookupErrorFreezesWatermark(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	base := pipelineFixture(t, d)
	ts1 := fmt.Sprintf("%d.000100", base)

	gen := &fakeGen{reply: func(user string) (string, error) {
		if strings.Contains(user, "(C1GEN)") {
			return episodeJSON("Prod deploy failed", "C1GEN", ts1, "C1GEN"), nil
		}
		return "[]", nil
	}}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)
	p.checkMsg = errCheckerAfter{db: d, failTS: ts1} // lookup ERROR on the episode's ref

	stats, err := p.Run(context.Background())
	require.NoError(t, err, "window isolation: the lookup failure never fails the run")
	assert.Equal(t, 1, stats.WindowsFailed, "lookup error fails the window")
	assert.Zero(t, stats.Episodes)
	assert.Zero(t, stats.RefsRejected, "an errored lookup is not a rejected ref")

	wm, err := d.MemoryWatermark()
	require.NoError(t, err)
	assert.Zero(t, wm, "watermark frozen: the failed window owns the earliest messages")

	nodes, err := d.ListMemoryNodes()
	require.NoError(t, err)
	for _, n := range nodes {
		assert.NotEqual(t, "episode", n.Type, "no episode written when its refs could not be verified")
	}
}

// TestBuildWindowsSplitsOversizedChannel: max_window_messages bounds one
// window; a busier channel forms multiple sequential windows in chronological
// order (M3 poison-window bound).
func TestBuildWindowsSplitsOversizedChannel(t *testing.T) {
	var msgs []db.MemoryExtractMessage
	for i := 0; i < 5; i++ {
		msgs = append(msgs, db.MemoryExtractMessage{
			ChannelID: "C1GEN", ChannelName: "general",
			TS: fmt.Sprintf("%d.000001", 1000+i), TSUnix: float64(1000 + i),
			Author: "alice", Text: fmt.Sprintf("m%d", i+1),
		})
	}
	windows := buildWindows(msgs, 2)
	require.Len(t, windows, 3, "5 messages at cap 2 → windows of 2/2/1")
	assert.Len(t, windows[0].Messages, 2)
	assert.Len(t, windows[1].Messages, 2)
	assert.Len(t, windows[2].Messages, 1)
	assert.Equal(t, "m1", windows[0].Messages[0].Text)
	assert.Equal(t, "m3", windows[1].Messages[0].Text)
	assert.Equal(t, "m5", windows[2].Messages[0].Text)

	windows = buildWindows(msgs, 0)
	require.Len(t, windows, 1, "cap 0 = unbounded")
}

// TestMemory04_LaterWindowNeverPassesEarlierFailedWindow: when a channel is
// split into sequential windows (max_window_messages), a later window's
// success must not advance the watermark past an earlier failed window of
// the same channel.
func TestMemory04_LaterWindowNeverPassesEarlierFailedWindow(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	seedUserRow(t, d, "U1ALICE", "alice")
	seedChannelRow(t, d, "C1GEN", "general")
	base := time.Now().Add(-time.Hour).Unix()
	for i := 0; i < 4; i++ {
		seedMessageRow(t, d, "C1GEN", fmt.Sprintf("%d.%06d", base+int64(i)*60, i+1), "U1ALICE",
			fmt.Sprintf("split message %d", i+1))
	}

	gen := &fakeGen{reply: func(user string) (string, error) {
		if strings.Contains(user, "split message 1") {
			return "", fmt.Errorf("poison window")
		}
		return "[]", nil
	}}
	cfg := pipelineTestConfig()
	cfg.MaxWindowMessages = 2
	p := NewPipeline(d, v, gen, cfg, t.Logf)

	stats, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 2, stats.Windows, "channel split into two sequential windows")
	assert.Equal(t, 1, stats.WindowsFailed)
	require.Len(t, gen.calls, 2)
	assert.NotContains(t, gen.calls[0], "split message 3", "the split keeps the giant window bounded")

	wm, err := d.MemoryWatermark()
	require.NoError(t, err)
	assert.Zero(t, wm, "later window of the same channel must not advance past the earlier failed one")
}

// The cross-process memory lock: with the lock held by another holder (a
// concurrent daemon phase or CLI command), Run refuses cleanly — ErrLocked,
// no pipeline_runs row, no AI call — and proceeds once the lock is free.
func TestPipelineRefusesWhenLocked(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	pipelineFixture(t, d)
	gen := &fakeGen{reply: func(string) (string, error) { return "[]", nil }}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	unlock, err := v.Lock()
	require.NoError(t, err)

	_, err = p.Run(context.Background())
	assert.ErrorIs(t, err, ErrLocked)

	var runs int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM pipeline_runs WHERE pipeline = 'memory'`).Scan(&runs))
	assert.Zero(t, runs, "a locked-out run must not record a pipeline_runs row")
	assert.Empty(t, gen.calls, "a locked-out run must not call the AI")

	unlock()
	_, err = p.Run(context.Background())
	require.NoError(t, err, "run proceeds once the lock is released")
}

// A quarantined vault file surfaces in RunStats and does not fail the run.
func TestPipelineSurfacesQuarantinedFiles(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	require.NoError(t, os.WriteFile(
		filepath.Join(v.path, "entities", "ent_01ARZ3NDEKTSV4RRFFQ69G5QP1.md"),
		[]byte("not a node at all"), 0o644))

	p := NewPipeline(d, v, nil, pipelineTestConfig(), t.Logf)
	stats, err := p.Run(context.Background())
	require.NoError(t, err, "a malformed vault file must not fail the phase")
	assert.Equal(t, 1, stats.Reconciled.Quarantined)
	assert.Equal(t, []string{"entities/ent_01ARZ3NDEKTSV4RRFFQ69G5QP1.md"}, stats.Reconciled.QuarantinedPaths)
}

// TestGroupWindowsIntoBatches unit-tests the grouping function used to pack
// quiet channels into one extraction call (digest-pipeline precedent).
func TestGroupWindowsIntoBatches(t *testing.T) {
	mk := func(n int) runWindow {
		w := runWindow{channelWindow: channelWindow{ChannelID: "C", ChannelName: "c"}}
		for i := 0; i < n; i++ {
			w.Messages = append(w.Messages, extractMsg{})
			w.tsUnix = append(w.tsUnix, float64(i))
		}
		return w
	}

	t.Run("packs small windows up to maxMessages", func(t *testing.T) {
		windows := []runWindow{mk(5), mk(5), mk(5)}
		batches := groupWindowsIntoBatches(windows, 20, 12)
		require.Len(t, batches, 2, "5+5 fits in 12, the third 5 starts a new batch")
		assert.Equal(t, []int{0, 1}, batches[0])
		assert.Equal(t, []int{2}, batches[1])
	})

	t.Run("packs up to maxChannels even under maxMessages", func(t *testing.T) {
		windows := []runWindow{mk(1), mk(1), mk(1)}
		batches := groupWindowsIntoBatches(windows, 2, 1000)
		require.Len(t, batches, 2)
		assert.Equal(t, []int{0, 1}, batches[0])
		assert.Equal(t, []int{2}, batches[1])
	})

	t.Run("an oversized window still gets its own batch", func(t *testing.T) {
		windows := []runWindow{mk(1), mk(50), mk(1)}
		batches := groupWindowsIntoBatches(windows, 20, 10)
		require.Len(t, batches, 3, "the 50-message window can't join either neighbor but isn't dropped")
		assert.Equal(t, []int{1}, batches[1])
	})

	t.Run("maxChannels <= 0 means one batch with everything", func(t *testing.T) {
		windows := []runWindow{mk(1), mk(1)}
		batches := groupWindowsIntoBatches(windows, 0, 1000)
		require.Len(t, batches, 1)
		assert.Equal(t, []int{0, 1}, batches[0])
	})

	t.Run("empty input yields no batches", func(t *testing.T) {
		assert.Nil(t, groupWindowsIntoBatches(nil, 20, 1000))
	})
}

// TestBuildExtractPromptsNeverStartWithDash guards against the bug found on
// the first live E2E run: internal/ai/client.go passes the user message as a
// raw "-p" argv token, so a message beginning with "-" is misparsed by the
// claude CLI as an unrecognized flag instead of -p's value. Both prompt
// builders must always open with non-dash text, for any input shape.
func TestBuildExtractPromptsNeverStartWithDash(t *testing.T) {
	w := channelWindow{
		ChannelID: "C1", ChannelName: "general",
		Messages: []extractMsg{{TS: "1.0", Author: "alice", Text: "hi"}},
	}
	_, user := buildExtractPrompt("%s %d", "en", w, 5)
	assert.False(t, strings.HasPrefix(user, "-"), "single-channel prompt must not start with '-'")

	_, user = buildBatchExtractPrompt("%s %d", "en", []channelWindow{w, w}, 5)
	assert.False(t, strings.HasPrefix(user, "-"), "batch prompt must not start with '-'")
	assert.Contains(t, user, "=== #general (C1) ===")
}

// batchTestConfig enables cross-channel batching (unlike pipelineTestConfig,
// which pins BatchMaxChannels to 1 to preserve the per-window tests above).
func batchTestConfig() config.MemoryConfig {
	cfg := pipelineTestConfig()
	cfg.BatchMaxChannels = 20
	cfg.BatchMaxMessages = 1500
	return cfg
}

// TestBatchGroupsQuietChannelsIntoOneCall: two quiet channels share a single
// AI call, and the reply's per-episode refs still route each episode's
// entity back-links correctly by channel — batching must not blur provenance.
func TestBatchGroupsQuietChannelsIntoOneCall(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	base := pipelineFixture(t, d)
	ts1 := fmt.Sprintf("%d.000100", base)
	ts3 := fmt.Sprintf("%d.000300", base+120)

	gen := &fakeGen{
		usage: digest.Usage{InputTokens: 100, OutputTokens: 20, TotalAPITokens: 150, Model: "haiku"},
		reply: func(user string) (string, error) {
			require.False(t, strings.HasPrefix(user, "-"), "the user message must never start with '-': the claude CLI wrapper passes it as a raw \"-p\" argv value (internal/ai/client.go), and a leading dash is parsed as an unrecognized flag instead of -p's value — this broke every batch call on the first live E2E run")
			require.Contains(t, user, "=== #general (C1GEN) ===", "both channels must appear in one prompt")
			require.Contains(t, user, "=== #ops (C2OPS) ===")
			return fmt.Sprintf(`[
				{"title": "Prod deploy failed", "story": "s", "outcome": "resolved", "participants": ["U1ALICE"], "refs": [{"channel_id": "C1GEN", "ts": %q}], "entity_hints": []},
				{"title": "Postmortem scheduled", "story": "s", "outcome": null, "participants": ["U1ALICE"], "refs": [{"channel_id": "C2OPS", "ts": %q}], "entity_hints": []}
			]`, ts1, ts3), nil
		},
	}
	p := NewPipeline(d, v, gen, batchTestConfig(), t.Logf)

	stats, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 2, stats.Windows, "still two per-channel windows built")
	assert.Equal(t, 2, stats.Episodes)
	require.Len(t, gen.calls, 1, "one call covers both quiet channels")

	runID, status, _, _, _, _, _, _, _ := memoryPipelineRunRow(t, d)
	assert.Equal(t, "done", status)
	steps, err := d.GetPipelineSteps(runID)
	require.NoError(t, err)
	require.Len(t, steps, 1, "one pipeline_steps row for the whole batch")
	assert.Equal(t, "done", steps[0].Status)
	assert.Contains(t, steps[0].ChannelName, "general")
	assert.Contains(t, steps[0].ChannelName, "ops")

	wm, err := d.MemoryWatermark()
	require.NoError(t, err)
	assert.Equal(t, float64(base+180), wm, "both windows committed, watermark clears the whole chunk")
}

// TestBatchFailureFreezesAllChannelsInBatch: when channels share a batch, one
// failed AI call freezes the watermark for every channel in it (the approved
// coarser-than-per-channel MEM-04 granularity — see docs/inventory/memory.md).
func TestBatchFailureFreezesAllChannelsInBatch(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	pipelineFixture(t, d)

	gen := &fakeGen{reply: func(string) (string, error) { return "", fmt.Errorf("model down") }}
	p := NewPipeline(d, v, gen, batchTestConfig(), t.Logf)

	stats, err := p.Run(context.Background())
	require.NoError(t, err, "a batch failure never fails the run")
	assert.Equal(t, 2, stats.WindowsFailed, "both channels' windows are frozen together")
	require.Len(t, gen.calls, 1)

	wm, err := d.MemoryWatermark()
	require.NoError(t, err)
	assert.Zero(t, wm, "neither channel advances past the shared failed batch")
}

// TestBatchCrossChannelEpisodeRejected: an episode whose refs span two
// channels (the model conflating one batch's separate conversations, or
// hallucinating a ref's channel_id) is schema-degenerate — same as a
// zero-ref episode — and must never be committed to the vault.
func TestBatchCrossChannelEpisodeRejected(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	base := pipelineFixture(t, d)
	ts1 := fmt.Sprintf("%d.000100", base)
	ts3 := fmt.Sprintf("%d.000300", base+120)

	gen := &fakeGen{reply: func(string) (string, error) {
		// One episode whose refs mix C1GEN and C2OPS — invalid regardless of
		// each individual ref resolving to a real message.
		return fmt.Sprintf(`[{"title": "Mixed", "story": "s", "outcome": null, "participants": [],
			"refs": [{"channel_id": "C1GEN", "ts": %q}, {"channel_id": "C2OPS", "ts": %q}], "entity_hints": []}]`,
			ts1, ts3), nil
	}}
	p := NewPipeline(d, v, gen, batchTestConfig(), t.Logf)

	stats, err := p.Run(context.Background())
	require.NoError(t, err, "a schema-degenerate batch never fails the run")
	assert.Equal(t, 1, stats.Malformed, "cross-channel episode counted as malformed")
	assert.Zero(t, stats.Episodes)
	assert.Equal(t, 2, stats.WindowsFailed, "both channels frozen — the batch never committed")

	wm, err := d.MemoryWatermark()
	require.NoError(t, err)
	assert.Zero(t, wm)

	nodes, err := d.ListMemoryNodes()
	require.NoError(t, err)
	for _, n := range nodes {
		assert.NotEqual(t, "episode", n.Type, "the cross-channel episode must never reach the vault")
	}
}

// TestMemory04_InterruptedRunKeepsCommittedBatchesBehindWatermark reproduces
// the E2E watermark-loss incident (docs/specs/memory-e2e-report.md, "Second
// issue found"): a run is interrupted (process kill / AI failure) at its LAST
// batch after earlier batches already committed to the vault. The committed
// batches' fully-covered messages must be behind a DURABLY persisted watermark
// — losing the entire run's advance together means every committed batch is
// silently re-extracted next run, producing duplicate episode nodes.
//
// The incident geometry: one long-spanning window (a channel with a message
// near the run's start AND its end) plus quiet channels in between. Windows
// must be ordered so that completing the early-starting windows first lifts
// safeWatermark's pending-window bound; ordering by LAST ts instead parks the
// long-spanning window in the final batch, whose early first-ts clamps the
// bound at the run's start and suppresses every per-batch watermark write.
func TestMemory04_InterruptedRunKeepsCommittedBatchesBehindWatermark(t *testing.T) {
	// File-backed DB (not :memory:) so a second, independent connection can
	// verify the per-batch watermark write is durably on disk — the incident
	// report doubted WAL durability; this pins the write down at the SQL level.
	dbPath := filepath.Join(t.TempDir(), "watchtower.db")
	d, err := db.Open(dbPath)
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	v := newTestVault(t)

	seedWorkspaceRow(t, d)
	seedUserRow(t, d, "U1ALICE", "alice")
	seedChannelRow(t, d, "C0SPAN", "spanner")
	seedChannelRow(t, d, "C1QUIET", "quiet1")
	seedChannelRow(t, d, "C2QUIET", "quiet2")
	base := time.Now().Add(-time.Hour).Unix()
	seedMessageRow(t, d, "C0SPAN", fmt.Sprintf("%d.000001", base), "U1ALICE", "span first")
	seedMessageRow(t, d, "C1QUIET", fmt.Sprintf("%d.000002", base+60), "U1ALICE", "q1 one")
	seedMessageRow(t, d, "C1QUIET", fmt.Sprintf("%d.000003", base+70), "U1ALICE", "q1 two")
	seedMessageRow(t, d, "C2QUIET", fmt.Sprintf("%d.000004", base+120), "U1ALICE", "q2 one")
	seedMessageRow(t, d, "C2QUIET", fmt.Sprintf("%d.000005", base+130), "U1ALICE", "q2 two")
	seedMessageRow(t, d, "C0SPAN", fmt.Sprintf("%d.000006", base+300), "U1ALICE", "span last")

	// Batch 1 commits an episode to the vault; the SECOND call dies mid-flight
	// (the in-test analogue of the incident's SIGKILL during a later batch's
	// AI call — everything written before it must already be durable).
	tsQ1 := fmt.Sprintf("%d.000002", base+60)
	killed := false
	gen := &fakeGen{reply: func(string) (string, error) {
		if killed {
			return "", fmt.Errorf("process killed mid-flight")
		}
		killed = true
		return episodeJSON("Quiet channel decision", "C1QUIET", tsQ1, "C1QUIET"), nil
	}}
	cfg := batchTestConfig()
	cfg.BatchMaxChannels = 2
	p := NewPipeline(d, v, gen, cfg, t.Logf)

	stats, err := p.Run(context.Background())
	require.NoError(t, err, "batch isolation: the interrupted batch never fails the run")
	require.Len(t, gen.calls, 2, "geometry must yield exactly two batches")
	assert.Equal(t, 1, stats.Episodes, "batch 1's episode committed to the vault before the interruption")

	// The heart of the incident: batch 1 committed, so the watermark must
	// already trail its fully-covered messages (q1 two, base+70) instead of
	// sitting at the pre-run value until the whole run finishes.
	wm, err := d.MemoryWatermark()
	require.NoError(t, err)
	assert.Equal(t, float64(base+70), wm,
		"committed batches must advance the watermark before the run ends — losing the whole run's advance re-extracts every committed batch")

	// Durability: a second, independent connection to the same file sees the
	// advance (WAL + synchronous=NORMAL survives an app-level kill; the write
	// is an autocommit UPDATE, so once Exec returned it is on disk).
	d2, err := db.Open(dbPath)
	require.NoError(t, err)
	wm2, err := d2.MemoryWatermark()
	require.NoError(t, d2.Close())
	require.NoError(t, err)
	assert.Equal(t, wm, wm2, "watermark advance must be durable across connections")

	// Next run: messages behind the watermark are NOT re-extracted (no
	// duplicate episodes for committed work); the interrupted batch and the
	// spanner's uncovered tail (span last, above the watermark) come back.
	firstRunCalls := len(gen.calls)
	killed = false
	gen.reply = func(string) (string, error) { return "[]", nil }
	_, err = p.Run(context.Background())
	require.NoError(t, err)
	rerun := strings.Join(gen.calls[firstRunCalls:], "\n")
	assert.NotContains(t, rerun, "span first", "message behind the watermark must not be re-extracted")
	assert.NotContains(t, rerun, "q1 one", "committed batch must not be re-extracted")
	assert.NotContains(t, rerun, "q1 two", "committed batch must not be re-extracted")
	assert.Contains(t, rerun, "q2 one", "interrupted batch is re-extracted (MEM-04 freeze)")
	assert.Contains(t, rerun, "span last", "uncovered tail above the watermark is re-extracted (duplicates tolerated over skips)")
}

// TestBuildWindowsOrdersByFirstTS: windows are processed in ascending
// first-message order so that safeWatermark's pending-window bound rises as
// early-starting windows complete — the property that makes per-batch
// watermark advances possible at all (see the incident test above).
func TestBuildWindowsOrdersByFirstTS(t *testing.T) {
	msgs := []db.MemoryExtractMessage{
		{ChannelID: "CB", ChannelName: "b", TS: "1.000001", TSUnix: 1, Author: "a", Text: "b first"},
		{ChannelID: "CA", ChannelName: "a", TS: "5.000002", TSUnix: 5, Author: "a", Text: "a only"},
		{ChannelID: "CB", ChannelName: "b", TS: "10.000003", TSUnix: 10, Author: "a", Text: "b last"},
	}
	windows := buildWindows(msgs, 0)
	require.Len(t, windows, 2)
	assert.Equal(t, "CB", windows[0].ChannelID, "the long-spanning window starts earliest and must be processed first")
	assert.Equal(t, "CA", windows[1].ChannelID)
}

// TestBatchOneDegenerateChannelFailsWholeBatch: a batch mixing one channel's
// healthy reply with another's schema-degenerate one must not let the
// degenerate channel's malformed episode slip through uncounted while the
// batch otherwise "succeeds" — the whole batch fails together (v1's
// all-or-nothing shape check, now applied per batch instead of per channel).
func TestBatchOneDegenerateChannelFailsWholeBatch(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	base := pipelineFixture(t, d)
	ts1 := fmt.Sprintf("%d.000100", base)

	gen := &fakeGen{reply: func(string) (string, error) {
		return fmt.Sprintf(`[
			{"title": "Prod deploy failed", "story": "s", "outcome": "resolved", "participants": [], "refs": [{"channel_id": "C1GEN", "ts": %q}], "entity_hints": []},
			{"title": "Degenerate", "story": "s", "outcome": null, "participants": [], "refs": [], "entity_hints": []}
		]`, ts1), nil
	}}
	p := NewPipeline(d, v, gen, batchTestConfig(), t.Logf)

	stats, err := p.Run(context.Background())
	require.NoError(t, err, "a schema-degenerate batch never fails the run")
	assert.Equal(t, 1, stats.Malformed)
	assert.Zero(t, stats.Episodes, "the otherwise-valid episode must NOT be committed alongside a malformed sibling")
	assert.Equal(t, 2, stats.WindowsFailed)

	wm, err := d.MemoryWatermark()
	require.NoError(t, err)
	assert.Zero(t, wm, "no partial success — the whole batch retries next run")

	nodes, err := d.ListMemoryNodes()
	require.NoError(t, err)
	for _, n := range nodes {
		assert.NotEqual(t, "episode", n.Type, "no episode written when any sibling in the batch is malformed")
	}
}

// ── Phase-3 semantic-tier wiring (Task 11) ──────────────────────────────────

// semanticTestConfig enables the semantic tier on top of pipelineTestConfig,
// with the documented per-run caps and a generous output budget.
func semanticTestConfig() config.MemoryConfig {
	cfg := pipelineTestConfig()
	cfg.Semantic = config.MemorySemanticConfig{
		Enabled:            true,
		RewriteMaxEntities: 10,
		BeliefsMax:         20,
		DedupeMaxMerges:    20,
		EvictAfterDays:     45,
		EvictMax:           50,
		ConceptMinEpisodes: 5,
		ConceptMaxCreate:   10,
		OutputBudget:       200000,
	}
	return cfg
}

// semanticReply is a fake generator reply that answers each semantic prompt
// type with a valid, empty-effect response and extraction with "[]".
func semanticReply(user string) (string, error) {
	switch {
	case strings.Contains(user, "Existing beliefs:"):
		return `{"ops": []}`, nil
	case strings.Contains(user, "Entity page:"):
		return `{"what": "w", "current": "c", "facts": [], "markers": []}`, nil
	case strings.Contains(user, "Top entities:"):
		return "# Hot map\n\nsummary\n", nil
	default:
		return "[]", nil // extraction
	}
}

// dupEpisode builds an active short episode in one channel with a single shared
// provenance ref, for exercising the dedupe step.
func dupEpisode(id, channel, ts string) Node {
	body := fmt.Sprintf("# %s\n\n## Story\ns\n\n## Provenance\n- %s %s\n", id, channel, ts)
	return Node{ID: id, Type: "episode", Tier: "short", Status: "active", Title: id, Body: body}
}

func semanticStepNames(t *testing.T, d *db.DB, runID int64) []string {
	t.Helper()
	steps, err := d.GetPipelineSteps(runID)
	require.NoError(t, err)
	var names []string
	for _, s := range steps {
		if s.ChannelName == "dedupe" || s.ChannelName == "promote" || s.ChannelName == "rewrite" ||
			s.ChannelName == "beliefs" || s.ChannelName == "evict" {
			names = append(names, s.ChannelName)
		}
	}
	return names
}

// TestMemorySemanticDisabledByteIdentical guards that a semantic-off run behaves
// exactly as before Phase 3: no semantic pipeline_steps rows, the generator is
// called only for extraction, and RunStats' semantic counters stay zero.
func TestMemorySemanticDisabledByteIdentical(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	pipelineFixture(t, d)

	gen := &fakeGen{reply: semanticReply}                     // semantic disabled → only extraction hits it
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf) // Semantic.Enabled == false

	stats, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Zero(t, stats.Deduped)
	assert.Zero(t, stats.Promoted)
	assert.Zero(t, stats.Rewritten)
	assert.Zero(t, stats.BeliefOps)
	assert.Zero(t, stats.Evicted)

	// The generator saw only extraction calls (each carries a channel marker).
	require.Len(t, gen.calls, 2)
	for _, c := range gen.calls {
		assert.True(t, strings.Contains(c, "(C1GEN)") || strings.Contains(c, "(C2OPS)"),
			"only extraction calls when semantic is off, got: %s", c)
	}

	runID, _, _, _, _, _, _, _, _ := memoryPipelineRunRow(t, d)
	assert.Empty(t, semanticStepNames(t, d, runID), "no semantic pipeline_steps rows when disabled")
}

// TestMemorySemanticEnabledRunsInOrder verifies the semantic sub-steps run in
// the spec order (dedupe → promote → rewrite → beliefs → evict), each emitting a
// pipeline_steps row after the extraction rows, and that RunStats counters are
// populated (a pre-seeded duplicate pair is merged).
func TestMemorySemanticEnabledRunsInOrder(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	pipelineFixture(t, d)

	// A duplicate episode pair in an isolated channel, merged by the dedupe step.
	writeAndIndex(t, v, d, dupEpisode("ep_01ARZ3NDEKTSV4RRFFQ69G5DA1", "C9DUP", "1000.000100"))
	writeAndIndex(t, v, d, dupEpisode("ep_01ARZ3NDEKTSV4RRFFQ69G5DB2", "C9DUP", "1000.000100"))

	gen := &fakeGen{
		usage: digest.Usage{InputTokens: 10, OutputTokens: 2, TotalAPITokens: 10},
		reply: semanticReply,
	}
	p := NewPipeline(d, v, gen, semanticTestConfig(), t.Logf)

	stats, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, stats.Deduped, "the duplicate pair was merged")

	runID, status, _, _, _, _, _, _, _ := memoryPipelineRunRow(t, d)
	assert.Equal(t, "done", status)
	assert.Equal(t, []string{"dedupe", "promote", "rewrite", "beliefs", "evict"},
		semanticStepNames(t, d, runID), "semantic steps run and record in the spec order")

	// The newer episode now redirects to the older one (dedupe via Merge).
	resolved, err := Resolve(v, d, "ep_01ARZ3NDEKTSV4RRFFQ69G5DB2")
	require.NoError(t, err)
	assert.Equal(t, "ep_01ARZ3NDEKTSV4RRFFQ69G5DA1", resolved.ID)
}

// TestMemorySemanticStepFailureIsolated: one semantic step failing (here the
// belief pass' AI call) is logged and skipped, and the remaining steps still run
// — the run completes and eviction still records its row.
func TestMemorySemanticStepFailureIsolated(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	pipelineFixture(t, d)

	gen := &fakeGen{reply: func(user string) (string, error) {
		if strings.Contains(user, "Existing beliefs:") {
			return "", fmt.Errorf("belief model exploded")
		}
		return semanticReply(user)
	}}
	p := NewPipeline(d, v, gen, semanticTestConfig(), t.Logf)

	_, err := p.Run(context.Background())
	require.NoError(t, err, "a semantic step failure never fails the run")

	runID, status, _, _, _, _, _, _, _ := memoryPipelineRunRow(t, d)
	assert.Equal(t, "done", status)

	steps, err := d.GetPipelineSteps(runID)
	require.NoError(t, err)
	byName := map[string]string{}
	for _, s := range steps {
		byName[s.ChannelName] = s.Status
	}
	assert.Equal(t, "error", byName["beliefs"], "the failed step is recorded as error")
	assert.Equal(t, "done", byName["evict"], "eviction still ran after the belief failure")
	assert.Equal(t, "done", byName["dedupe"])
	assert.Equal(t, "done", byName["promote"])
}

// TestMemorySemanticBudgetStopsAISteps: once the run's accumulated output tokens
// exceed memory.semantic.output_budget, no further strong-tier AI step launches
// — rewrite and belief pass are skipped (no rows, no AI calls), while the
// mechanical steps still run.
func TestMemorySemanticBudgetStopsAISteps(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	pipelineFixture(t, d)

	cfg := semanticTestConfig()
	cfg.Semantic.OutputBudget = 5 // tiny budget

	// Each extraction call reports a large output, blowing the budget before the
	// semantic AI steps.
	gen := &fakeGen{
		usage: digest.Usage{InputTokens: 10, OutputTokens: 500, TotalAPITokens: 20},
		reply: semanticReply,
	}
	p := NewPipeline(d, v, gen, cfg, t.Logf)

	_, err := p.Run(context.Background())
	require.NoError(t, err)

	// Only the two extraction calls happened — no beliefs/rewrite/map AI calls.
	require.Len(t, gen.calls, 2)
	for _, c := range gen.calls {
		assert.False(t, strings.Contains(c, "Existing beliefs:"), "belief pass skipped over budget")
		assert.False(t, strings.Contains(c, "Top entities:"), "strong map render skipped over budget")
	}

	runID, _, _, _, _, _, _, _, _ := memoryPipelineRunRow(t, d)
	names := semanticStepNames(t, d, runID)
	assert.NotContains(t, names, "rewrite", "rewrite skipped over budget (no step row)")
	assert.NotContains(t, names, "beliefs", "belief pass skipped over budget (no step row)")
	assert.Contains(t, names, "dedupe", "mechanical steps still run")
	assert.Contains(t, names, "promote")
	assert.Contains(t, names, "evict")
}

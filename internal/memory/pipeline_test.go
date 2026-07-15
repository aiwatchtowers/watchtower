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
func pipelineTestConfig() config.MemoryConfig {
	return config.MemoryConfig{
		Enabled:              true,
		MaxChunkMessages:     2000,
		SeedMinMessages:      1,
		MaxEpisodesPerWindow: 5,
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

	// map.md rendered mechanically at the end of the run.
	mapContent, err := os.ReadFile(filepath.Join(v.path, "map.md"))
	require.NoError(t, err)
	assert.Contains(t, string(mapContent), "# Memory Map")
	assert.Contains(t, string(mapContent), "- entity: 4 (short 0, long 4)")
	assert.Contains(t, string(mapContent), "- episode: 2 (short 2, long 0)")
	assert.Contains(t, string(mapContent), "## People")
	assert.Contains(t, string(mapContent), "[[ent_")
	assert.Contains(t, string(mapContent), "#general")
	assert.Contains(t, string(mapContent), "## Recent open episodes")
	assert.Contains(t, string(mapContent), "Prod deploy failed")

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

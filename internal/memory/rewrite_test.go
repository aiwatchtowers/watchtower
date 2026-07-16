package memory

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/digest"
)

// rewriteNow is a fixed run time used by the rewrite tests; entity ids are
// chosen so they are due for a rewrite at exactly this time.
var rewriteNow = time.Date(2026, 3, 15, 12, 0, 0, 0, time.UTC)

// dueEntityIDs returns count deterministic entity ids that are all due for a
// rewrite at now.
func dueEntityIDs(now time.Time, count int) []string {
	var ids []string
	for i := 0; len(ids) < count; i++ {
		id := fmt.Sprintf("ent_%026d", i)
		if dueForRewrite(id, now) {
			ids = append(ids, id)
		}
	}
	return ids
}

// rewriteEpisodeNode builds a short active episode with one provenance ref.
func rewriteEpisodeNode(id, channel, ts string) Node {
	body := fmt.Sprintf("# Episode\n\n## Story\nThe migration shipped.\n\n## Outcome\nDone cleanly.\n\n## Provenance\n- %s %s\n", channel, ts)
	return Node{ID: id, Type: "episode", Tier: "short", Status: "active", Title: "Episode", Body: body}
}

const rewriteTail = "## Links\n- [[ep_00000000000000000000000001]]\n\n## Open loops\n- migrate the legacy jobs\n"

// rewriteEntityNode builds an entity page with the full skeleton, one existing
// fact, a link to epID, and a non-empty ## Open loops section.
func rewriteEntityNode(id, title, epID string) Node {
	body := "# " + title + "\n\n## What\nold what\n\n## Current\nold current\n\n## Facts\n- existing fact\n\n## Links\n- [[" + epID + "]]\n\n## Open loops\n- migrate the legacy jobs\n"
	return Node{ID: id, Type: "entity", Tier: "long", Status: "active", Title: title, Aliases: []string{title}, Body: body}
}

func rewriteReplyJSON(t *testing.T, what, current string, facts []string, markers []episodeRef) string {
	t.Helper()
	b, err := json.Marshal(rewriteResult{What: what, Current: current, Facts: facts, Markers: markers})
	require.NoError(t, err)
	return string(b)
}

func TestRewriteEntityPagesHappyPath(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	entID := dueEntityIDs(rewriteNow, 1)[0]
	epID := "ep_00000000000000000000000001"
	ep := rewriteEpisodeNode(epID, "C1CHAN", "1710000000.000100")
	writeAndIndex(t, v, d, ep)
	writeAndIndex(t, v, d, rewriteEntityNode(entID, "Acme", epID))

	gen := &fakeGen{
		usage: digest.Usage{InputTokens: 80, OutputTokens: 30, TotalAPITokens: 120, Model: "sonnet"},
		reply: func(string) (string, error) {
			return rewriteReplyJSON(t, "new what", "new current",
				[]string{"new fact"}, []episodeRef{{ChannelID: "C1CHAN", TS: "1710000000.000100"}}), nil
		},
	}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	n, usage, err := p.RewriteEntityPages(context.Background(), 10, rewriteNow)
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	require.NotNil(t, usage)
	assert.Equal(t, 30, usage.OutputTokens)
	require.Len(t, gen.calls, 1)

	page, err := v.ReadNode(entID)
	require.NoError(t, err)
	assert.Contains(t, page.Body, "## What\nnew what")
	assert.Contains(t, page.Body, "## Current\nnew current")
	assert.Contains(t, page.Body, "Provenance: C1CHAN 1710000000.000100")
	// Owner-preservation: the model's new fact AND the existing bullet survive.
	assert.Contains(t, page.Body, "- new fact")
	assert.Contains(t, page.Body, "- existing fact")
	// Links + Open loops preserved byte-for-byte.
	assert.True(t, strings.HasSuffix(page.Body, rewriteTail), "tail preserved, got:\n%s", page.Body)
}

func TestRewriteEntityPagesDropsInventedMarker(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	entID := dueEntityIDs(rewriteNow, 1)[0]
	epID := "ep_00000000000000000000000001"
	writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", "1710000000.000100"))
	writeAndIndex(t, v, d, rewriteEntityNode(entID, "Acme", epID))

	gen := &fakeGen{reply: func(string) (string, error) {
		return rewriteReplyJSON(t, "new what", "new current", []string{"f"}, []episodeRef{
			{ChannelID: "C1CHAN", TS: "1710000000.000100"}, // valid
			{ChannelID: "CFAKE", TS: "9999.000000"},        // invented
		}), nil
	}}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	n, _, err := p.RewriteEntityPages(context.Background(), 10, rewriteNow)
	require.NoError(t, err)
	assert.Equal(t, 1, n, "page still written with the valid marker")

	page, err := v.ReadNode(entID)
	require.NoError(t, err)
	assert.Contains(t, page.Body, "C1CHAN 1710000000.000100")
	assert.NotContains(t, page.Body, "CFAKE", "invented marker dropped (MEM-01)")
}

func TestRewriteEntityPagesGarbageJSONSkips(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	entID := dueEntityIDs(rewriteNow, 1)[0]
	epID := "ep_00000000000000000000000001"
	writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", "1710000000.000100"))
	writeAndIndex(t, v, d, rewriteEntityNode(entID, "Acme", epID))
	before, err := v.ReadNode(entID)
	require.NoError(t, err)
	repo := openTestRepo(t, v.path)
	commitsBefore := commitCount(t, repo)

	gen := &fakeGen{reply: func(string) (string, error) { return "not json at all", nil }}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	n, _, err := p.RewriteEntityPages(context.Background(), 10, rewriteNow)
	require.NoError(t, err)
	assert.Zero(t, n)

	after, err := v.ReadNode(entID)
	require.NoError(t, err)
	assert.Equal(t, before.Body, after.Body, "page byte-identical after a failed rewrite")
	assert.Equal(t, commitsBefore, commitCount(t, repo), "no commit for the skipped entity")
}

func TestRewriteEntityPagesStaggerGate(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	// Choose an entity due at rewriteNow, then run at a day when it is NOT due.
	entID := dueEntityIDs(rewriteNow, 1)[0]
	var notDue time.Time
	for i := 1; i < rewriteStaggerDays; i++ {
		cand := rewriteNow.AddDate(0, 0, i)
		if !dueForRewrite(entID, cand) {
			notDue = cand
			break
		}
	}
	epID := "ep_00000000000000000000000001"
	writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", "1710000000.000100"))
	writeAndIndex(t, v, d, rewriteEntityNode(entID, "Acme", epID))

	gen := &fakeGen{reply: func(string) (string, error) { return "{}", nil }}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	n, _, err := p.RewriteEntityPages(context.Background(), 10, notDue)
	require.NoError(t, err)
	assert.Zero(t, n)
	assert.Empty(t, gen.calls, "an entity not in its stagger slot is skipped without an AI call")
}

func TestRewriteEntityPagesCapRespected(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	ids := dueEntityIDs(rewriteNow, 2)
	epID := "ep_00000000000000000000000001"
	writeAndIndex(t, v, d, rewriteEpisodeNode(epID, "C1CHAN", "1710000000.000100"))
	for i, id := range ids {
		writeAndIndex(t, v, d, rewriteEntityNode(id, fmt.Sprintf("Ent%d", i), epID))
	}

	gen := &fakeGen{reply: func(string) (string, error) {
		return rewriteReplyJSON(t, "w", "c", []string{"f"}, []episodeRef{{ChannelID: "C1CHAN", TS: "1710000000.000100"}}), nil
	}}
	p := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf)

	n, _, err := p.RewriteEntityPages(context.Background(), 1, rewriteNow)
	require.NoError(t, err)
	assert.Equal(t, 1, n, "cap respected")
	assert.Len(t, gen.calls, 1)
}

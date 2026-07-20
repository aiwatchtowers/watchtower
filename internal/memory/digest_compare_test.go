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

	"watchtower/internal/db"
)

// indexEpisodeWithProvenance commits an episode node to the vault AND mirrors it
// into the index WITH its memory_provenance rows (the compare's window query
// reads that index). writeAndIndex's indexNode omits provenance, so the compare
// tests use this instead.
func indexEpisodeWithProvenance(t *testing.T, v *Vault, d *db.DB, n Node) {
	t.Helper()
	_, err := v.WriteNodes([]Node{n}, CommitMsg{Op: "seed", Summary: "test episode", Cause: "seed", NodeIDs: []string{n.ID}})
	require.NoError(t, err)
	rel, err := nodeRelPath(n.ID)
	require.NoError(t, err)
	require.NoError(t, d.UpsertMemoryNode(db.MemoryNodeRow{
		ID: n.ID, Type: n.Type, Tier: n.Tier, Status: n.Status,
		RedirectTo: n.RedirectTo, Title: n.Title, Path: rel,
		ContentHash: "test-hash", IndexedAt: "2026-07-15T00:00:00Z",
	}, n.Body, n.Aliases, provenanceRows(n, nil)...))
}

// episodeNode builds an episode node body (H1, Story, Outcome, Provenance) for
// the given channel + provenance ts values.
func episodeNode(id, title, channel, story, outcome string, tss ...string) Node {
	var b strings.Builder
	fmt.Fprintf(&b, "# %s\n\n## Story\n%s\n\n## Outcome\n%s\n\n## Provenance\n", title, story, outcome)
	for _, ts := range tss {
		fmt.Fprintf(&b, "- %s %s\n", channel, ts)
	}
	return Node{ID: id, Type: "episode", Tier: "short", Status: "active", Title: title, Body: b.String()}
}

// seedLegacyChannelDigest inserts a legacy channel digest + its topics so the
// compare has a window to render against. Returns the digest id.
func seedLegacyChannelDigest(t *testing.T, d *db.DB, channelID string, from, to float64, topics []db.DigestTopic) int64 {
	t.Helper()
	id, err := d.UpsertDigest(db.Digest{
		ChannelID: channelID, Type: "channel", PeriodFrom: from, PeriodTo: to,
		Summary: "legacy summary", MessageCount: 4, Model: "haiku",
	})
	require.NoError(t, err)
	if len(topics) > 0 {
		require.NoError(t, d.InsertDigestTopics(id, topics))
	}
	return id
}

// compareFixture seeds a workspace, a channel, four messages, and one legacy
// channel digest over the message window. Returns the base unix second, the
// window bounds, and the digest id. Two episodes covering the first two
// messages are indexed by the caller.
func compareFixture(t *testing.T, d *db.DB) (base int64, from, to float64, digestID int64) {
	t.Helper()
	seedWorkspaceRow(t, d)
	seedUserRow(t, d, "U1ALICE", "alice")
	seedUserRow(t, d, "U2BOB", "bob")
	seedChannelRow(t, d, "C0AAA", "general")

	base = time.Now().Add(-time.Hour).Unix()
	seedMessageRow(t, d, "C0AAA", fmt.Sprintf("%d.000100", base), "U1ALICE", "the deploy failed")
	seedMessageRow(t, d, "C0AAA", fmt.Sprintf("%d.000200", base+10), "U2BOB", "rolling back")
	seedMessageRow(t, d, "C0AAA", fmt.Sprintf("%d.000300", base+20), "U1ALICE", "budget approved")
	seedMessageRow(t, d, "C0AAA", fmt.Sprintf("%d.000400", base+30), "U2BOB", "signed off")

	from = float64(base) - 1
	to = float64(base + 30)
	digestID = seedLegacyChannelDigest(t, d, "C0AAA", from, to, []db.DigestTopic{
		{Title: "Rollout", Summary: "deploy broke", KeyMessages: `["` + fmt.Sprintf("%d.000100", base) + `"]`, Decisions: "[]"},
		// A hallucinated key_message ts (well-formed but never a real message).
		{Title: "Ghost", Summary: "invented", KeyMessages: `["9999999999.000000"]`, Decisions: "[]"},
	})
	return base, from, to, digestID
}

// TestCompareDigestsHappyPath: a legacy channel digest with two overlapping
// episodes yields one shadow row whose key_messages are all episode-cited, whose
// coverage reflects the covered/total ratio, and leaves the legacy tables
// untouched.
func TestCompareDigestsHappyPath(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	base, _, _, digestID := compareFixture(t, d)

	// Two episodes cover the first two messages (base+0, base+10); the last two
	// (base+20, base+30) are a coverage gap.
	indexEpisodeWithProvenance(t, v, d, episodeNode("ep_00000000000000000000000001", "Rollout incident", "C0AAA",
		"The deploy broke prod.", "Rolled back.", fmt.Sprintf("%d.000100", base)))
	indexEpisodeWithProvenance(t, v, d, episodeNode("ep_00000000000000000000000002", "Recovery", "C0AAA",
		"Team recovered.", "Stable.", fmt.Sprintf("%d.000200", base+10)))

	// The render cites only shown timestamps (the two episode ts).
	reply := func(string) (string, error) {
		return fmt.Sprintf(`{"summary":"rendered","topics":[
			{"title":"Rollout","summary":"broke and recovered","decisions":[],"action_items":[],"situations":[],"key_messages":["%d.000100","%d.000200"]}
		]}`, base, base+10), nil
	}
	p := NewPipeline(d, v, &fakeGen{reply: reply}, pipelineTestConfig(), t.Logf)

	cs, err := p.CompareDigests(context.Background(), time.Now().Add(-24*time.Hour))
	require.NoError(t, err)
	assert.Equal(t, 1, cs.ShadowsWritten)
	assert.Equal(t, 0, cs.Failed)
	require.Len(t, cs.Channels, 1)

	cc := cs.Channels[0]
	assert.Equal(t, "C0AAA", cc.ChannelID)
	assert.Equal(t, digestID, cc.LegacyDigestID)
	assert.Equal(t, 1, cc.MemoryTopics)
	assert.Equal(t, 2, cc.MemoryRefs, "both key_messages are episode-cited")
	assert.Equal(t, 0, cc.MemoryRefsRejected)
	// Coverage: 2 of 4 window messages are covered by episode provenance.
	assert.InDelta(t, 0.5, cc.Coverage, 0.001)
	// Legacy ref-validity: 1 of 2 legacy key_messages resolves (the Ghost topic's
	// ts is a hallucination).
	assert.Equal(t, 2, cc.LegacyRefs)
	assert.Equal(t, 1, cc.LegacyRefsValid)

	// A shadow row was written.
	rows, err := d.ListDigestShadow("1970-01-01T00:00:00Z")
	require.NoError(t, err)
	require.Len(t, rows, 1)
	assert.Equal(t, "C0AAA", rows[0].ChannelID)
	assert.InDelta(t, 0.5, rows[0].Coverage, 0.001)
	var rd renderedDigest
	require.NoError(t, json.Unmarshal([]byte(rows[0].RenderedJSON), &rd))
	require.Len(t, rd.Topics, 1)
	assert.Equal(t, []string{fmt.Sprintf("%d.000100", base), fmt.Sprintf("%d.000200", base+10)}, rd.Topics[0].KeyMessages)
}

// TestCompareDigestsNoEpisodes: a legacy digest whose window has NO memory
// episodes records a coverage-0 shadow row and never calls the generator.
func TestCompareDigestsNoEpisodes(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	compareFixture(t, d) // no episodes indexed

	p := NewPipeline(d, v, noCallGen(t), pipelineTestConfig(), t.Logf)
	cs, err := p.CompareDigests(context.Background(), time.Now().Add(-24*time.Hour))
	require.NoError(t, err)
	assert.Equal(t, 1, cs.ShadowsWritten)
	require.Len(t, cs.Channels, 1)
	assert.InDelta(t, 0.0, cs.Channels[0].Coverage, 0.001)
	assert.Equal(t, 0, cs.Channels[0].MemoryTopics)

	rows, err := d.ListDigestShadow("1970-01-01T00:00:00Z")
	require.NoError(t, err)
	require.Len(t, rows, 1)
	assert.InDelta(t, 0.0, rows[0].Coverage, 0.001)
}

// TestCompareDigestsRenderFailureIsolated: a render error on one channel is
// isolated (counted, no shadow row) while another channel still shadows.
func TestCompareDigestsRenderFailureIsolated(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	base := time.Now().Add(-time.Hour).Unix()
	seedWorkspaceRow(t, d)
	seedUserRow(t, d, "U1ALICE", "alice")
	seedChannelRow(t, d, "C0AAA", "general")
	seedChannelRow(t, d, "C0BBB", "ops")
	seedMessageRow(t, d, "C0AAA", fmt.Sprintf("%d.000100", base), "U1ALICE", "aaa msg")
	seedMessageRow(t, d, "C0BBB", fmt.Sprintf("%d.000100", base), "U1ALICE", "bbb msg")

	from, to := float64(base)-1, float64(base+1)
	seedLegacyChannelDigest(t, d, "C0AAA", from, to, nil)
	seedLegacyChannelDigest(t, d, "C0BBB", from, to, nil)

	indexEpisodeWithProvenance(t, v, d, episodeNode("ep_0000000000000000000000000A", "A", "C0AAA", "story", "out", fmt.Sprintf("%d.000100", base)))
	indexEpisodeWithProvenance(t, v, d, episodeNode("ep_0000000000000000000000000B", "B", "C0BBB", "story", "out", fmt.Sprintf("%d.000100", base)))

	// C0AAA's render returns garbage (error, isolated); C0BBB renders fine.
	reply := func(user string) (string, error) {
		if strings.Contains(user, "C0AAA") {
			return "not json", nil
		}
		return fmt.Sprintf(`{"summary":"ok","topics":[{"title":"B","summary":"x","decisions":[],"action_items":[],"situations":[],"key_messages":["%d.000100"]}]}`, base), nil
	}
	p := NewPipeline(d, v, &fakeGen{reply: reply}, pipelineTestConfig(), t.Logf)

	cs, err := p.CompareDigests(context.Background(), time.Now().Add(-24*time.Hour))
	require.NoError(t, err)
	assert.Equal(t, 1, cs.Failed, "the garbage-render channel is counted as failed")
	assert.Equal(t, 1, cs.ShadowsWritten, "the other channel still shadows")

	rows, err := d.ListDigestShadow("1970-01-01T00:00:00Z")
	require.NoError(t, err)
	require.Len(t, rows, 1)
	assert.Equal(t, "C0BBB", rows[0].ChannelID)
}

// TestDigestCompare_LegacyTablesByteIdentical is the legacy-untouched structural
// guard (CATCHUP-01 / MEM-05): a full compare run leaves the digests and
// digest_topics tables byte-identical and moves no digest bound.
func TestDigestCompare_LegacyTablesByteIdentical(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	base, _, _, _ := compareFixture(t, d)
	indexEpisodeWithProvenance(t, v, d, episodeNode("ep_00000000000000000000000001", "E", "C0AAA", "s", "o", fmt.Sprintf("%d.000100", base)))

	before := dumpDigestTables(t, d)

	reply := func(string) (string, error) {
		return fmt.Sprintf(`{"summary":"r","topics":[{"title":"T","summary":"x","decisions":[],"action_items":[],"situations":[],"key_messages":["%d.000100"]}]}`, base), nil
	}
	p := NewPipeline(d, v, &fakeGen{reply: reply}, pipelineTestConfig(), t.Logf)
	_, err := p.CompareDigests(context.Background(), time.Now().Add(-24*time.Hour))
	require.NoError(t, err)

	after := dumpDigestTables(t, d)
	assert.Equal(t, before, after, "the legacy digests/digest_topics tables must be byte-identical across a compare run")
}

// dumpDigestTables serializes the full contents of the digests + digest_topics
// tables for the byte-identical comparison.
func dumpDigestTables(t *testing.T, d *db.DB) string {
	t.Helper()
	var b strings.Builder
	rows, err := d.Query(`SELECT id, channel_id, period_from, period_to, type, summary, topics, decisions, action_items, message_count, created_at FROM digests ORDER BY id`)
	require.NoError(t, err)
	defer rows.Close()
	for rows.Next() {
		var id, msgCount int
		var ch, typ, summary, topics, decisions, actions, createdAt string
		var from, to float64
		require.NoError(t, rows.Scan(&id, &ch, &from, &to, &typ, &summary, &topics, &decisions, &actions, &msgCount, &createdAt))
		fmt.Fprintf(&b, "D|%d|%s|%v|%v|%s|%s|%s|%s|%s|%d|%s\n", id, ch, from, to, typ, summary, topics, decisions, actions, msgCount, createdAt)
	}
	require.NoError(t, rows.Err())
	trows, err := d.Query(`SELECT id, digest_id, idx, title, summary, decisions, action_items, situations, key_messages FROM digest_topics ORDER BY id`)
	require.NoError(t, err)
	defer trows.Close()
	for trows.Next() {
		var id, digestID, idx int
		var title, summary, decisions, actions, situations, keyMsgs string
		require.NoError(t, trows.Scan(&id, &digestID, &idx, &title, &summary, &decisions, &actions, &situations, &keyMsgs))
		fmt.Fprintf(&b, "T|%d|%d|%d|%s|%s|%s|%s|%s|%s\n", id, digestID, idx, title, summary, decisions, actions, situations, keyMsgs)
	}
	require.NoError(t, trows.Err())
	return b.String()
}

// TestRunDigestCompareGateOff: with memory.renders.digest_compare false, a full
// pipeline Run writes no shadow rows (the daemon tail is a no-op).
func TestRunDigestCompareGateOff(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	base, _, _, _ := compareFixture(t, d)
	indexEpisodeWithProvenance(t, v, d, episodeNode("ep_00000000000000000000000001", "E", "C0AAA", "s", "o", fmt.Sprintf("%d.000100", base)))

	cfg := pipelineTestConfig()
	cfg.Renders.DigestCompare = false
	p := NewPipeline(d, v, &fakeGen{reply: func(string) (string, error) {
		return `{"episodes":[]}`, nil
	}}, cfg, t.Logf)
	stats, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 0, stats.DigestsCompared)

	rows, err := d.ListDigestShadow("1970-01-01T00:00:00Z")
	require.NoError(t, err)
	assert.Empty(t, rows, "gate off writes no shadow rows")
}

// ── Task 6: metric math + report rendering ──────────────────────────────────

func TestRefValidityRate(t *testing.T) {
	assert.InDelta(t, 0.0, refValidityRate(0, 0), 0.001, "no refs → 0 (not NaN)")
	assert.InDelta(t, 1.0, refValidityRate(3, 3), 0.001)
	assert.InDelta(t, 0.5, refValidityRate(1, 2), 0.001)
}

func TestLengthRatio(t *testing.T) {
	assert.InDelta(t, 0.0, lengthRatio(100, 0), 0.001, "no legacy chars → 0")
	assert.InDelta(t, 0.5, lengthRatio(50, 100), 0.001)
}

// TestRenderCompareReport: the report renders a per-channel section and an
// aggregate section deterministically from a CompareStats.
func TestRenderCompareReport(t *testing.T) {
	cs := CompareStats{
		ShadowsWritten: 2,
		Channels: []ChannelCompare{
			{ChannelID: "C0AAA", LegacyDigestID: 1, LegacyTopics: 3, MemoryTopics: 2,
				LegacyRefs: 10, LegacyRefsValid: 1, MemoryRefs: 5, MemoryRefsRejected: 2,
				Episodes: 2, Coverage: 0.75, LegacyChars: 400, MemoryChars: 200},
			{ChannelID: "C0BBB", LegacyDigestID: 2, LegacyTopics: 1, MemoryTopics: 1,
				LegacyRefs: 4, LegacyRefsValid: 0, MemoryRefs: 2, MemoryRefsRejected: 0,
				Episodes: 0, Coverage: 1.0, LegacyChars: 100, MemoryChars: 80},
		},
	}
	at := time.Date(2026, 7, 16, 12, 0, 0, 0, time.UTC)
	report := RenderCompareReport(cs, at)

	assert.Contains(t, report, "# Digest compare report")
	assert.Contains(t, report, "2026-07-16")
	assert.Contains(t, report, "C0AAA")
	assert.Contains(t, report, "C0BBB")
	// Aggregate ref-validity: legacy 1/14, memory 7/7 (100%).
	assert.Contains(t, report, "Aggregate")
	assert.Contains(t, report, "hand-review", "the report points at the hand-review protocol")
	// Span-semantics coverage column.
	if !strings.Contains(report, "Coverage (episode span)") {
		t.Errorf("report missing span-semantics column header; got:\n%s", report)
	}
	// Windows with episodes aggregate: 1 of 2 channels have Episodes > 0.
	if !strings.Contains(report, "Windows with episodes: **1/2**") {
		t.Errorf("report missing span aggregate; got:\n%s", report)
	}
	// Deterministic: rendering twice yields the same bytes.
	assert.Equal(t, report, RenderCompareReport(cs, at))
}

// TestCompareDigestsSkipsFreshShadow: a second compare pass over the same
// legacy digest must not re-spend an AI call — the fresh shadow row short-
// circuits it (panel review 2026-07-16, MINOR-1).
func TestCompareDigestsSkipsFreshShadow(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	base, _, _, _ := compareFixture(t, d)
	indexEpisodeWithProvenance(t, v, d, episodeNode("ep_00000000000000000000000031", "Rollout incident", "C0AAA",
		"The deploy broke prod.", "Rolled back.", fmt.Sprintf("%d.000100", base)))

	calls := 0
	reply := func(string) (string, error) {
		calls++
		return fmt.Sprintf(`{"summary":"rendered","topics":[{"title":"Rollout","summary":"s","decisions":[],"action_items":[],"situations":[],"key_messages":["%d.000100"]}]}`, base), nil
	}
	p := NewPipeline(d, v, &fakeGen{reply: reply}, pipelineTestConfig(), t.Logf)

	cs1, err := p.CompareDigests(context.Background(), time.Now().Add(-24*time.Hour))
	require.NoError(t, err)
	assert.Equal(t, 1, cs1.ShadowsWritten)
	assert.Equal(t, 1, calls)

	cs2, err := p.CompareDigests(context.Background(), time.Now().Add(-24*time.Hour))
	require.NoError(t, err)
	assert.Equal(t, 0, cs2.ShadowsWritten, "fresh shadow short-circuits the window")
	assert.Equal(t, 1, cs2.Skipped)
	assert.Equal(t, 1, calls, "no second AI call")
}

// TestSplitCoverageSpans: span-based coverage (2026-07-20 instrument fix) —
// a message inside ANY selected episode's [from,to] span is covered even when
// its exact ts was never cited; messages outside every span are the raw gap
// fed to the render prompt.
func TestSplitCoverageSpans(t *testing.T) {
	msgs := []db.MemoryExtractMessage{
		{TS: "100.000100", TSUnix: 100, Author: "a", Text: "at span start"},
		{TS: "150.000100", TSUnix: 150, Author: "a", Text: "inside span, uncited"},
		{TS: "200.000100", TSUnix: 200, Author: "a", Text: "at span end"},
		{TS: "250.000100", TSUnix: 250, Author: "a", Text: "outside every span"},
	}
	gap, covered := splitCoverage(msgs, []tsSpan{{from: 100, to: 200}})
	if covered != 3 {
		t.Errorf("covered = %d, want 3 (span bounds inclusive both ends)", covered)
	}
	if len(gap) != 1 || gap[0].TS != "250.000100" {
		t.Errorf("gap = %+v, want the single out-of-span message", gap)
	}
	// No spans (no episodes): everything is gap, coverage 0.
	gap, covered = splitCoverage(msgs, nil)
	if covered != 0 || len(gap) != 4 {
		t.Errorf("no-span split = covered %d / gap %d, want 0/4", covered, len(gap))
	}
}

// TestLoadRenderEpisodesFloorsSpanToPeriodSeconds: span endpoints are floored
// to whole seconds to match messages.ts_unix's second-truncated granularity.
// An episode whose earliest cited ref has a fractional suffix (e.g. "N.000050")
// must produce span.from == N so that a message at that same second's TSUnix
// is covered — the message that generated the ref itself must be inside the span.
func TestLoadRenderEpisodesFloorsSpanToPeriodSeconds(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	seedChannelRow(t, d, "C0AAA", "general")

	base := int64(1719230400) // arbitrary base unix second
	// Episode cites a fractional-part ref and a whole-second ref.
	indexEpisodeWithProvenance(t, v, d, episodeNode("ep_00000000000000000000000099", "Test flooring", "C0AAA",
		"A story with fractional refs.", "Outcome.",
		fmt.Sprintf("%d.000050", base),      // fractional: would parse as base.00005
		fmt.Sprintf("%d.000200", base+100))) // another second

	p := NewPipeline(d, v, &fakeGen{reply: func(string) (string, error) { return `{"summary":"","topics":[]}`, nil }}, pipelineTestConfig(), t.Logf)

	episodes, spans, err := p.loadRenderEpisodes("C0AAA", []string{"ep_00000000000000000000000099"})
	require.NoError(t, err)
	require.Len(t, episodes, 1)
	require.Len(t, spans, 1)

	// The span must be [base, base+100] (floored seconds), NOT [base.00005, base+100.0002].
	span := spans[0]
	assert.Equal(t, float64(base), span.from, "earliest ref floored to whole second")
	assert.Equal(t, float64(base+100), span.to, "latest ref floored to whole second")

	// Now verify that a message at TSUnix==base (same second as the fractional ref)
	// is covered by the span.
	msgs := []db.MemoryExtractMessage{
		{TS: fmt.Sprintf("%d.000100", base), TSUnix: float64(base), Author: "a", Text: "at the fractional ref's second"},
		{TS: fmt.Sprintf("%d.000100", base+200), TSUnix: float64(base + 200), Author: "a", Text: "outside span"},
	}
	gap, covered := splitCoverage(msgs, spans)
	assert.Equal(t, 1, covered, "message at the fractional ref's second is covered by the floored span")
	assert.Len(t, gap, 1, "message outside the span is gap")
	assert.Equal(t, fmt.Sprintf("%d.000100", base+200), gap[0].TS)
}

// TestCompareDigestsSpanSelectsBetweenRefs: the live 0%-window artifact (the
// 2026-07-19 compare: 29/56 windows read coverage 0 while their stories were
// in the vault) — a legacy window that falls strictly BETWEEN an episode's two
// cited refs must still select that episode (span overlap), render, and report
// full span coverage.
func TestCompareDigestsSpanSelectsBetweenRefs(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	seedUserRow(t, d, "U1ALICE", "alice")
	seedChannelRow(t, d, "C0AAA", "general")

	base := time.Now().Add(-time.Hour).Unix()
	// The digest window's messages sit strictly between the episode's refs.
	seedMessageRow(t, d, "C0AAA", fmt.Sprintf("%d.000100", base+10), "U1ALICE", "mid-story update")
	seedMessageRow(t, d, "C0AAA", fmt.Sprintf("%d.000200", base+20), "U1ALICE", "another mid-story message")
	digestID := seedLegacyChannelDigest(t, d, "C0AAA", float64(base+5), float64(base+25), []db.DigestTopic{
		{Title: "Mid", Summary: "mid-window", KeyMessages: "[]", Decisions: "[]"},
	})

	// The episode cites only the story's endpoints — both OUTSIDE (base+5, base+25].
	indexEpisodeWithProvenance(t, v, d, episodeNode("ep_00000000000000000000000003", "Long story", "C0AAA",
		"A story spanning the whole hour.", "Resolved.",
		fmt.Sprintf("%d.000050", base), fmt.Sprintf("%d.000300", base+30)))

	reply := func(string) (string, error) {
		return fmt.Sprintf(`{"summary":"rendered","topics":[
			{"title":"Long story","summary":"the mid-window part","decisions":[],"action_items":[],"situations":[],"key_messages":["%d.000050"]}
		]}`, base), nil
	}
	p := NewPipeline(d, v, &fakeGen{reply: reply}, pipelineTestConfig(), t.Logf)

	cs, err := p.CompareDigests(context.Background(), time.Now().Add(-24*time.Hour))
	require.NoError(t, err)
	require.Len(t, cs.Channels, 1)
	cc := cs.Channels[0]
	assert.Equal(t, digestID, cc.LegacyDigestID)
	assert.Equal(t, 1, cc.MemoryTopics, "render RAN — the old refs-in-window query skipped this window entirely")
	assert.InDelta(t, 1.0, cc.Coverage, 0.001, "both window messages inside the [base, base+30] story span")
	assert.Equal(t, 1, cc.MemoryRefs, "the episode-cited endpoint ref survives render validation")
	assert.Equal(t, 0, cc.MemoryRefsRejected)
}

package memory

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// operationalConfig is pipelineTestConfig with the operational-mirror source ON.
func operationalConfig() config.MemoryConfig {
	cfg := pipelineTestConfig()
	cfg.Sources.Operational = true
	return cfg
}

// mirrorNoCallGen fails the test if the generator is ever invoked — the
// operational-mirror step is mechanical and must make NO AI call.
func mirrorNoCallGen(t *testing.T) *fakeGen {
	return &fakeGen{reply: func(string) (string, error) {
		t.Fatal("operational mirror must not call the generator")
		return "", nil
	}}
}

// setUpdatedAt forces a row's updated_at to an explicit RFC3339 value (test
// control over the terminal re-scan window).
func setUpdatedAt(t *testing.T, d *db.DB, table string, id int, at string) {
	t.Helper()
	_, err := d.Exec("UPDATE "+table+" SET updated_at = ? WHERE id = ?", at, id)
	require.NoError(t, err)
}

// TestMirrorOpenTargetShape: an open target becomes an entity aliased
// target:<id> with Refs.Targets, a populated ## Current and ## Open loops, and
// no AI call.
func TestMirrorOpenTargetShape(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)

	id, err := d.CreateTarget(db.Target{
		Text:     "Ship the billing rewrite",
		Intent:   "Unblock enterprise deals",
		Level:    "week",
		Status:   "in_progress",
		Priority: "high", Ownership: "mine", SourceType: "manual",
		BallOn:   "me",
		DueDate:  "2026-08-01",
		SubItems: `[{"text":"draft the schema","done":false},{"text":"migrate rows","done":true}]`,
	})
	require.NoError(t, err)

	gen := mirrorNoCallGen(t)
	p := NewPipeline(d, v, gen, operationalConfig(), t.Logf)
	var stats RunStats
	recorded, err := p.runOperationalMirrors(1, 0, &stats)
	require.NoError(t, err)
	assert.Equal(t, 1, recorded, "one pipeline_steps row recorded")
	assert.Equal(t, 1, stats.Mirrored)
	assert.Zero(t, stats.MirrorsFailed)
	assert.Empty(t, gen.calls, "no AI call")

	n, err := Resolve(v, d, targetMirrorAlias(int(id)))
	require.NoError(t, err)
	assert.Equal(t, "entity", n.Type)
	assert.Equal(t, "long", n.Tier)
	assert.Equal(t, "active", n.Status)
	assert.Equal(t, []int64{id}, n.Refs.Targets, "target mirror stamps Refs.Targets")
	assert.Contains(t, n.Body, "Ship the billing rewrite")
	assert.Contains(t, n.Body, "Unblock enterprise deals")
	assert.Contains(t, n.Body, "## Current\nStatus: in_progress")
	assert.Contains(t, n.Body, "Priority: high")
	assert.Contains(t, n.Body, "## Open loops\n")
	assert.Contains(t, n.Body, "- draft the schema", "open sub-item is an open loop")
	assert.NotContains(t, n.Body, "- migrate rows", "done sub-item is not an open loop")
	assert.Contains(t, n.Body, "due 2026-08-01", "ball-on/due line in open loops")
}

// TestMirrorConversionCrossLink: a target converted from a situation gains a
// ## Links line to that situation's episode.
func TestMirrorConversionCrossLink(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)

	tid, err := d.CreateTarget(db.Target{Text: "Roll out SSO", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	sid, err := d.CreateSituation(db.DashboardSituation{Title: "SSO outage thread", Status: "open"})
	require.NoError(t, err)
	require.NoError(t, d.MarkSituationConverted(int(sid), int(tid), 0))

	// The situation episode already exists in the vault (ingested earlier).
	epID := "ep_00000000000000000000000042"
	writeAndIndex(t, v, d, Node{
		ID: epID, Type: "episode", Tier: "long", Status: "closed",
		Title: "SSO outage thread", Aliases: []string{fmt.Sprintf("situation:%d", sid)},
		Body: "# SSO outage thread\n\n## Story\nlong story\n",
	})

	p := NewPipeline(d, v, mirrorNoCallGen(t), operationalConfig(), t.Logf)
	var stats RunStats
	_, err = p.runOperationalMirrors(1, 0, &stats)
	require.NoError(t, err)

	n, err := Resolve(v, d, targetMirrorAlias(int(tid)))
	require.NoError(t, err)
	assert.Contains(t, n.Body, "[["+epID+"|", "mirror links its originating situation episode")
}

// TestMirrorCurrentRefreshAndTerminalClearsLoops: a status change refreshes
// ## Current; a terminal transition clears ## Open loops (heading kept, empty).
func TestMirrorCurrentRefreshAndTerminalClearsLoops(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)

	id, err := d.CreateTarget(db.Target{
		Text: "Fix flaky CI", Status: "todo", Priority: "low", Ownership: "mine", SourceType: "manual",
		SubItems: `[{"text":"quarantine the test","done":false}]`,
	})
	require.NoError(t, err)

	p := NewPipeline(d, v, mirrorNoCallGen(t), operationalConfig(), t.Logf)
	var s1 RunStats
	_, err = p.runOperationalMirrors(1, 0, &s1)
	require.NoError(t, err)
	repo := openTestRepo(t, v.path)
	afterFirst := commitCount(t, repo)

	n1, err := Resolve(v, d, targetMirrorAlias(int(id)))
	require.NoError(t, err)
	assert.Contains(t, n1.Body, "Status: todo")
	assert.Contains(t, n1.Body, "- quarantine the test")

	// A status change refreshes ## Current and commits once.
	require.NoError(t, d.UpdateTargetStatus(int(id), "in_progress"))
	var s2 RunStats
	_, err = p.runOperationalMirrors(2, 0, &s2)
	require.NoError(t, err)
	assert.Equal(t, 1, s2.Mirrored)
	assert.Equal(t, afterFirst+1, commitCount(t, repo), "one commit on the refresh")
	n2, err := Resolve(v, d, targetMirrorAlias(int(id)))
	require.NoError(t, err)
	assert.Contains(t, n2.Body, "Status: in_progress", "Current refreshed")

	// A terminal transition clears ## Open loops.
	require.NoError(t, d.UpdateTargetStatus(int(id), "done"))
	var s3 RunStats
	_, err = p.runOperationalMirrors(3, 0, &s3)
	require.NoError(t, err)
	n3, err := Resolve(v, d, targetMirrorAlias(int(id)))
	require.NoError(t, err)
	assert.Contains(t, n3.Body, "## Open loops\n", "heading kept")
	assert.NotContains(t, n3.Body, "- quarantine the test", "open loops cleared when terminal")
}

// TestMirrorUnchangedRescanNoCommit: a re-scan with no change commits nothing.
func TestMirrorUnchangedRescanNoCommit(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	_, err := d.CreateTarget(db.Target{Text: "Stable target", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)

	p := NewPipeline(d, v, mirrorNoCallGen(t), operationalConfig(), t.Logf)
	var s1 RunStats
	_, err = p.runOperationalMirrors(1, 0, &s1)
	require.NoError(t, err)
	require.Equal(t, 1, s1.Mirrored)

	repo := openTestRepo(t, v.path)
	afterFirst := commitCount(t, repo)

	var s2 RunStats
	_, err = p.runOperationalMirrors(2, 0, &s2)
	require.NoError(t, err)
	assert.Zero(t, s2.Mirrored, "unchanged re-scan mirrors nothing")
	assert.Equal(t, afterFirst, commitCount(t, repo), "no empty commit on an unchanged re-scan")
}

// TestMirrorTrackSymmetry: a track mirrors as track:<id> with its open sub-items
// in ## Open loops and progress in ## Current.
func TestMirrorTrackSymmetry(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)

	id, err := d.UpsertTrack(db.Track{
		Text: "Migrate to the new API", Category: "task", Ownership: "mine", Priority: "high",
		BallOn:   "U9",
		SubItems: `[{"text":"update the client","status":"open"},{"text":"delete old code","status":"done"}]`,
	})
	require.NoError(t, err)

	p := NewPipeline(d, v, mirrorNoCallGen(t), operationalConfig(), t.Logf)
	var stats RunStats
	_, err = p.runOperationalMirrors(1, 0, &stats)
	require.NoError(t, err)
	assert.Equal(t, 1, stats.Mirrored)

	n, err := Resolve(v, d, trackMirrorAlias(int(id)))
	require.NoError(t, err)
	assert.Equal(t, "entity", n.Type)
	assert.Empty(t, n.Refs.Targets, "track mirror does not stamp Refs.Targets")
	assert.Contains(t, n.Body, "Migrate to the new API")
	assert.Contains(t, n.Body, "Category: task")
	assert.Contains(t, n.Body, "Sub-items: 1/2 done", "progress in Current")
	assert.Contains(t, n.Body, "- update the client", "open sub-item is an open loop")
	assert.NotContains(t, n.Body, "- delete old code", "done sub-item is not an open loop")
}

// TestMirrorDismissedLongAgoSkip: a target dismissed outside the terminal window
// is never mirrored.
func TestMirrorDismissedLongAgoSkip(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)

	id, err := d.CreateTarget(db.Target{Text: "Ancient dismissed goal", Status: "todo", Priority: "low", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	require.NoError(t, d.UpdateTargetStatus(int(id), "dismissed"))
	old := time.Now().AddDate(0, 0, -60).UTC().Format(time.RFC3339)
	setUpdatedAt(t, d, "targets", int(id), old)

	p := NewPipeline(d, v, mirrorNoCallGen(t), operationalConfig(), t.Logf)
	var stats RunStats
	_, err = p.runOperationalMirrors(1, 0, &stats)
	require.NoError(t, err)
	assert.Zero(t, stats.Mirrored, "a long-dismissed target is not mirrored")

	_, err = Resolve(v, d, targetMirrorAlias(int(id)))
	require.Error(t, err, "no mirror node for a long-dismissed target")
}

// TestMirrorGateOffNoWork: with memory.sources.operational off, a full Run does
// no mirror work; flipping it on then builds the mirror.
func TestMirrorGateOffNoWork(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)
	id, err := d.CreateTarget(db.Target{Text: "Gated target", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)

	cfg := operationalConfig()
	cfg.Sources.Operational = false
	p := NewPipeline(d, v, nil, cfg, t.Logf)
	_, err = p.Run(context.Background())
	require.NoError(t, err)
	_, err = Resolve(v, d, targetMirrorAlias(int(id)))
	require.Error(t, err, "gate off → no mirror")

	cfg.Sources.Operational = true
	p2 := NewPipeline(d, v, nil, cfg, t.Logf)
	_, err = p2.Run(context.Background())
	require.NoError(t, err)
	_, err = Resolve(v, d, targetMirrorAlias(int(id)))
	require.NoError(t, err, "gate on → the mirror is built")
}

// TestMemory14_MirrorNeverWritesOperationalTables: the mirror step is a pure
// reader of the operational tables — full dumps of targets/tracks/day_plans/
// day_plan_items/inbox_items/situations/situation_signals are byte-identical
// across the run and inbox_last_processed_ts is unmoved.
func TestMemory14_MirrorNeverWritesOperationalTables(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedWorkspaceRow(t, d)

	// Targets (incl. one converted-from-situation), tracks, situations.
	tid, err := d.CreateTarget(db.Target{Text: "Converted goal", Status: "in_progress", Priority: "high", Ownership: "mine", SourceType: "manual",
		SubItems: `[{"text":"do the thing","done":false}]`})
	require.NoError(t, err)
	_, err = d.CreateTarget(db.Target{Text: "Plain goal", Status: "todo", Priority: "low", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	kid, err := d.UpsertTrack(db.Track{Text: "A track", Category: "task", Ownership: "mine", Priority: "medium",
		SubItems: `[{"text":"step one","status":"open"}]`})
	require.NoError(t, err)
	sid, err := d.CreateSituation(db.DashboardSituation{Title: "Origin story", Status: "open"})
	require.NoError(t, err)
	require.NoError(t, d.MarkSituationConverted(int(sid), int(tid), 0))
	writeAndIndex(t, v, d, Node{
		ID: "ep_00000000000000000000000099", Type: "episode", Tier: "long", Status: "closed",
		Title: "Origin story", Aliases: []string{fmt.Sprintf("situation:%d", sid)},
		Body: "# Origin story\n\n## Story\ns\n",
	})

	// A situation signal (part of the MEM-05 dump set).
	item := seedInboxItem(t, d, "C1", "111.1")
	require.NoError(t, d.AddSituationSignals(int(sid), []int{item}))

	// A day plan + item.
	_, err = d.Exec(`INSERT INTO day_plans (id, user_id, plan_date, generated_at) VALUES (1, 'U1', '2026-07-17', '2026-07-17T00:00:00Z')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO day_plan_items (day_plan_id, kind, source_type, title) VALUES (1, 'timeblock', 'task', 'block')`)
	require.NoError(t, err)

	// inbox_last_processed_ts to a nonzero sentinel.
	_, err = d.Exec(`UPDATE workspace SET inbox_last_processed_ts = 4242 WHERE id = 'T1'`)
	require.NoError(t, err)

	_ = kid
	tables := []string{"targets", "tracks", "day_plans", "day_plan_items", "inbox_items", "situations", "situation_signals"}
	before := map[string]string{}
	for _, tb := range tables {
		before[tb] = dumpTable(t, d, tb)
	}

	p := NewPipeline(d, v, mirrorNoCallGen(t), operationalConfig(), t.Logf)
	var stats RunStats
	_, err = p.runOperationalMirrors(1, 0, &stats)
	require.NoError(t, err)
	require.Positive(t, stats.Mirrored, "the step actually did mirror work")

	for _, tb := range tables {
		assert.Equal(t, before[tb], dumpTable(t, d, tb), "MEM-14: %s unchanged by the mirror step", tb)
	}
	var wm float64
	require.NoError(t, d.QueryRow(`SELECT inbox_last_processed_ts FROM workspace WHERE id = 'T1'`).Scan(&wm))
	assert.Equal(t, float64(4242), wm, "inbox watermark unmoved")
}

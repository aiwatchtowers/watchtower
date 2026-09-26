package kb

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func countDocs(t *testing.T, d *db.DB, source string) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(`SELECT count(*) FROM kb_documents WHERE source = ?`, source).Scan(&n))
	return n
}

func TestRun_IndexesAndIsIdempotent(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSlack(t, d)
	seedJira(t, d)
	now := time.Unix(1758000600, 0)
	st, err := Run(ctx, d, Options{Now: now})
	require.NoError(t, err)
	assert.False(t, st.Incomplete)
	assert.Equal(t, 3, st.Written) // slack thread + DM day + jira issue (C1 day has only a join row → nil)
	assert.Equal(t, 2, countDocs(t, d, "slack"))
	st, err = Run(ctx, d, Options{Now: now})
	require.NoError(t, err)
	assert.Equal(t, 0, st.Written, "second run over unchanged data writes nothing")
}

// Review focus #4: an in-place edit/delete within the tail is picked up.
func TestRun_TailRescanCatchesInPlaceDelete(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSlack(t, d)
	now := time.Unix(1758000600, 0)
	_, err := Run(ctx, d, Options{Now: now})
	require.NoError(t, err)
	exec(t, d, `UPDATE messages SET is_deleted = 1 WHERE channel_id = '1:D1'`)
	st, err := Run(ctx, d, Options{Now: now})
	require.NoError(t, err)
	assert.Equal(t, 1, st.Deleted)
	assert.Equal(t, 1, countDocs(t, d, "slack"))
}

func TestRun_BudgetStopsAndResumes(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSlack(t, d)
	seedJira(t, d)
	st, err := Run(ctx, d, Options{Now: time.Unix(1758000600, 0), Budget: time.Nanosecond})
	require.NoError(t, err)
	assert.True(t, st.Incomplete)
	st, err = Run(ctx, d, Options{Now: time.Unix(1758000600, 0)})
	require.NoError(t, err)
	assert.False(t, st.Incomplete)
	assert.Equal(t, 2, countDocs(t, d, "slack"))
	assert.Equal(t, 1, countDocs(t, d, "jira"))
}

// Hard deletes move no change marker; the small sources reconcile on every
// run, so a deleted row's document leaves search within one cycle.
func TestRun_ReconcileDeletesVanishedEveryRun(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedJira(t, d)
	seedIdea(t, d)
	day1 := time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)
	_, err := Run(ctx, d, Options{Now: day1})
	require.NoError(t, err)
	require.Equal(t, 1, countDocs(t, d, "idea"))
	exec(t, d, `DELETE FROM idea_mentions`)
	exec(t, d, `DELETE FROM ideas`) // hard delete: no marker moves
	exec(t, d, `DELETE FROM jira_comments`)
	exec(t, d, `DELETE FROM jira_issues`)
	st, err := Run(ctx, d, Options{Now: day1.Add(time.Hour)}) // same UTC day
	require.NoError(t, err)
	assert.Equal(t, 2, st.Deleted)
	assert.Equal(t, 0, countDocs(t, d, "idea"), "a hard-deleted idea is gone after the next run, same day")
	assert.Equal(t, 0, countDocs(t, d, "jira"))

	st, err = Run(ctx, d, Options{Now: day1.Add(2 * time.Hour)})
	require.NoError(t, err)
	assert.Equal(t, Stats{}, st, "nothing left to reconcile")
}

// Slack's Keys() scans every message, so it reconciles once per UTC day.
func TestRun_SlackReconcilesOncePerDay(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSlack(t, d)
	day1 := time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC) // seedSlack rows are far outside the 48h tail
	_, err := Run(ctx, d, Options{Now: day1})
	require.NoError(t, err)
	require.Equal(t, 2, countDocs(t, d, "slack"))
	exec(t, d, `DELETE FROM messages WHERE channel_id = '1:D1'`) // hard delete: no rowid, no tail
	_, err = Run(ctx, d, Options{Now: day1.Add(time.Hour)})
	require.NoError(t, err)
	assert.Equal(t, 2, countDocs(t, d, "slack"), "same day: slack reconcile already ran")
	st, err := Run(ctx, d, Options{Now: day1.Add(24 * time.Hour)})
	require.NoError(t, err)
	assert.Equal(t, 1, st.Deleted)
	assert.Equal(t, 1, countDocs(t, d, "slack"))
}

// Markers have one-second resolution: a row written in the same second as
// the stored cursor, after the run that set it, is still indexed (>=).
func TestRun_SameSecondWriteAfterCursorIsIndexed(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedIdea(t, d)
	_, err := Run(ctx, d, Options{Now: testNow(), Sources: []string{"idea"}})
	require.NoError(t, err)
	cursor := cursorOf(t, d, "idea")
	require.Equal(t, "2026-09-11T10:00:00Z", cursor)
	exec(t, d, `INSERT INTO ideas (id, kind, title, essence, status, last_mention_at, updated_at)
		VALUES (10, 'idea', 'Шардирование', 'Разнести базу', 'active', '', ?)`, cursor)
	st, err := Run(ctx, d, Options{Now: testNow(), Sources: []string{"idea"}})
	require.NoError(t, err)
	assert.Equal(t, 1, st.Written, "only the new same-second row is written; the re-listed one is hash-gated")
	assert.Equal(t, 2, countDocs(t, d, "idea"))
}

func TestRun_EmptyDatabase(t *testing.T) {
	st, err := Run(context.Background(), db.OpenTestDB(t), Options{Now: testNow()})
	require.NoError(t, err)
	assert.Equal(t, Stats{}, st)
}

func TestReindex_UnknownSourceFailsFirst(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedJira(t, d)
	_, err := Run(ctx, d, Options{Now: testNow()})
	require.NoError(t, err)
	_, err = Reindex(ctx, d, []string{"jira", "nope"}, testNow())
	assert.Error(t, err)
	assert.Equal(t, 1, countDocs(t, d, "jira"), "nothing is deleted when any name is unknown")
}

func TestReindex_RebuildsSource(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedJira(t, d)
	_, err := Run(ctx, d, Options{Now: testNow()})
	require.NoError(t, err)
	st, err := Reindex(ctx, d, []string{"jira"}, testNow())
	require.NoError(t, err)
	assert.Equal(t, 1, st.Written)
	var chunks int
	require.NoError(t, d.QueryRow(`SELECT count(*) FROM kb_chunks WHERE doc_id LIKE 'jira:%'`).Scan(&chunks))
	assert.Equal(t, 1, chunks, "old chunks are gone, only the rebuilt doc's chunk remains")
}

func TestRun_IndexesDerivedSources(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedDigest(t, d)
	seedStreamDigest(t, d)
	st, err := Run(ctx, d, Options{Now: testNow(), Sources: []string{"digest", "stream_digest"}})
	require.NoError(t, err)
	assert.Equal(t, 5, st.Written) // 3 digest topics + 2 stream topics
	// A re-upsert drops topic 1 of digest 5 and bumps created_at: the dropped
	// topic's document is removed on the next run, not at reconcile.
	exec(t, d, `DELETE FROM digest_topics WHERE digest_id = 5 AND idx = 1`)
	exec(t, d, `UPDATE digests SET created_at = '2026-09-12T10:00:00Z' WHERE id = 5`)
	st, err = Run(ctx, d, Options{Now: testNow(), Sources: []string{"digest"}})
	require.NoError(t, err)
	assert.Equal(t, 1, st.Deleted)
	assert.Equal(t, 0, st.Written)
	assert.Equal(t, 2, countDocs(t, d, "digest"))
}

func TestRun_ContextCanceled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := Run(ctx, db.OpenTestDB(t), Options{Now: testNow()})
	assert.ErrorIs(t, err, context.Canceled)
}

// stubSource reports one changed key whose Build fails (or a custom Changed).
type stubSource struct {
	name    string
	changed func(ctx context.Context) ([]string, string, bool, error)
}

func (s stubSource) Name() string { return s.name }

func (s stubSource) Changed(ctx context.Context, _ Queryer, _ string, _ time.Time) ([]string, string, bool, error) {
	if s.changed != nil {
		return s.changed(ctx)
	}
	return []string{s.name + ":1"}, "c1", true, nil
}

func (s stubSource) Keys(context.Context, Queryer) ([]string, error) { return nil, nil }

func (s stubSource) Build(context.Context, Queryer, string) (*Doc, error) {
	return nil, errors.New("stub build failed")
}

// failOnKey wraps a real source and fails Build for one key.
type failOnKey struct {
	Source
	failKey string
}

func (f failOnKey) Build(ctx context.Context, q Queryer, key string) (*Doc, error) {
	if key == f.failKey {
		return nil, errors.New("boom")
	}
	return f.Source.Build(ctx, q, key)
}

func testRunner(sources ...Source) runner {
	return runner{sources: func() []Source { return sources }, clock: time.Now}
}

func cursorOf(t *testing.T, d *db.DB, source string) string {
	t.Helper()
	st, err := loadState(context.Background(), d, source)
	require.NoError(t, err)
	return st.Cursor
}

// seedThreads inserts n single-message threads whose refs sort by i.
func seedThreads(t *testing.T, d *db.DB, n int) []string {
	t.Helper()
	exec(t, d, `INSERT INTO channels (id, name, type) VALUES ('1:C9','bulk','public')`)
	refs := make([]string, n)
	for i := range n {
		ts := fmt.Sprintf("%d.000100", 1758000000+i)
		msg(t, d, "1:C9", ts, "1:U1", fmt.Sprintf("thread %d", i), ts, "")
		refs[i] = slackThreadRef("1:C9", ts)
	}
	return refs
}

// Pins: the cursor is saved only with a range's last batch (a failure in
// batch ≥1 leaves it untouched), and the failing batch's transaction leaves
// no partial writes; a later clean run completes the range.
func TestRun_MidRangeFailureKeepsCursorAndRollsBackBatch(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	refs := seedThreads(t, d, 250)
	require.Greater(t, len(refs), batchSize)

	failing := testRunner(failOnKey{Source: newSlackSource(), failKey: refs[230]})
	_, err := failing.run(ctx, d, Options{Now: testNow()})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "boom")
	assert.Equal(t, "", cursorOf(t, d, "slack"), "cursor must not move before the range's last batch commits")
	// Batch 0 holds the threads' root channel-day key (thread promotion; it
	// sorts first and renders nothing — no top-level message) plus 199 threads.
	assert.Equal(t, batchSize-1, countDocs(t, d, "slack"), "batch 0 committed; the failing batch wrote nothing")
	var n int
	require.NoError(t, d.QueryRow(`SELECT count(*) FROM kb_documents WHERE id = ?`, refs[210]).Scan(&n))
	assert.Equal(t, 0, n, "a doc built earlier in the failing batch was rolled back")

	st, err := testRunner(newSlackSource()).run(ctx, d, Options{Now: testNow()})
	require.NoError(t, err)
	assert.False(t, st.Incomplete)
	assert.Equal(t, 250, countDocs(t, d, "slack"))
	assert.Equal(t, "250", cursorOf(t, d, "slack"))
}

// steppingClock advances by step on every read, so the budget check count
// is deterministic.
func steppingClock(step time.Duration) func() time.Time {
	now := time.Unix(0, 0)
	return func() time.Time {
		now = now.Add(step)
		return now
	}
}

// Pins R1: the budget is checked between ranges; a spent budget stops after
// the completed range with its cursor saved, and the next run finishes.
func TestRun_BudgetStopsBetweenRanges(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	// A rowid gap makes two Slack ranges: (0, slackRange] and (slackRange, 30000].
	exec(t, d, `INSERT INTO messages (rowid, channel_id, ts, user_id, text, thread_ts) VALUES
		(1, '1:C1', '1758000000.000100', '1:U1', 'first range', '1758000000.000100'),
		(30000, '1:C1', '1758000100.000100', '1:U1', 'second range', '1758000100.000100')`)
	// Reads: start=1s, pre-source check=2s (1s used, within 1.5s), after
	// range 1 = 3s (2s used, over budget).
	r := runner{sources: func() []Source { return []Source{newSlackSource()} }, clock: steppingClock(time.Second)}
	st, err := r.run(ctx, d, Options{Now: testNow(), Budget: 1500 * time.Millisecond})
	require.NoError(t, err)
	assert.True(t, st.Incomplete)
	assert.Equal(t, strconv.Itoa(slackRange), cursorOf(t, d, "slack"), "cursor = end of the completed first range")
	assert.Equal(t, 1, countDocs(t, d, "slack"))

	st, err = Run(ctx, d, Options{Now: testNow(), Sources: []string{"slack"}})
	require.NoError(t, err)
	assert.False(t, st.Incomplete)
	assert.Equal(t, 2, countDocs(t, d, "slack"))
	assert.Equal(t, "30000", cursorOf(t, d, "slack"))
}

// Pins: an erroring source never stops the sources after it.
func TestRun_SourceErrorDoesNotStopLaterSources(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedJira(t, d)
	st, err := testRunner(stubSource{name: "stub"}, jiraSource{}).run(ctx, d, Options{Now: testNow()})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "stub")
	assert.Equal(t, 1, st.Written)
	assert.Equal(t, 1, countDocs(t, d, "jira"))
	assert.Equal(t, "", cursorOf(t, d, "stub"), "a failed batch saves no cursor")
}

func TestRun_NoProgressIsAnError(t *testing.T) {
	// The stub gives up after a few calls with its own error, so a missing
	// no-progress guard fails this test instead of hanging it.
	calls := 0
	stuck := stubSource{name: "stuck", changed: func(context.Context) ([]string, string, bool, error) {
		calls++
		if calls > 3 {
			return nil, "", false, errors.New("runaway: the indexer kept calling a source that never advances")
		}
		return nil, "", false, nil
	}}
	_, err := testRunner(stuck).run(context.Background(), db.OpenTestDB(t), Options{Now: testNow()})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no progress")
	assert.Equal(t, 1, calls, "the guard stops at the first non-advancing call")
}

func TestRun_CancelMidSourceReportedOnce(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	cancelling := stubSource{name: "cancelling", changed: func(ctx context.Context) ([]string, string, bool, error) {
		cancel()
		return nil, "", false, ctx.Err()
	}}
	_, err := testRunner(cancelling, jiraSource{}).run(ctx, db.OpenTestDB(t), Options{Now: testNow()})
	require.ErrorIs(t, err, context.Canceled)
	assert.Equal(t, 1, strings.Count(err.Error(), context.Canceled.Error()), err.Error())
}

func TestRun_UnknownSourceName(t *testing.T) {
	_, err := Run(context.Background(), db.OpenTestDB(t), Options{Now: testNow(), Sources: []string{"nope"}})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "nope")
}

package kb

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func dirtyCount(t *testing.T, d *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(`SELECT count(*) FROM kb_dirty`).Scan(&n))
	return n
}

// docText joins the chunk bodies of one document ("" when it has none).
func docText(t *testing.T, d *db.DB, id string) string {
	t.Helper()
	rows, err := d.Query(`SELECT body FROM kb_chunks WHERE doc_id = ? ORDER BY idx`, id)
	require.NoError(t, err)
	defer rows.Close()
	var b strings.Builder
	for rows.Next() {
		var s string
		require.NoError(t, rows.Scan(&s))
		b.WriteString(s)
	}
	require.NoError(t, rows.Err())
	return b.String()
}

func docExists(t *testing.T, d *db.DB, id string) bool {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(`SELECT count(*) FROM kb_documents WHERE id = ?`, id).Scan(&n))
	return n > 0
}

// oldDM seeds one DM with top-level messages ten days before the run time.
func oldDM(t *testing.T, d *db.DB, now time.Time, texts ...string) (day string, tss []string) {
	t.Helper()
	exec(t, d, `INSERT INTO channels (id, name, type) VALUES ('1:D7','','dm')`)
	exec(t, d, `INSERT INTO users (id, name, display_name) VALUES ('1:U1','anna','Anna')`)
	base := now.Add(-10 * 24 * time.Hour).Truncate(24 * time.Hour).Add(time.Hour)
	for i, text := range texts {
		ts := fmt.Sprintf("%d.%06d", base.Unix()+int64(i)*60, 100)
		tss = append(tss, ts)
		msg(t, d, "1:D7", ts, "1:U1", text, "", "")
	}
	return base.Format("2006-01-02"), tss
}

func TestDrainDirty_OldSlackEditReachesIndex(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	now := testNow()
	day, tss := oldDM(t, d, now, "alpha")
	_, err := Run(ctx, d, Options{Now: now})
	require.NoError(t, err)
	id := slackDayRef("1:D7", day)
	require.Contains(t, docText(t, d, id), "alpha")

	exec(t, d, `UPDATE messages SET text = 'beta' WHERE ts = ?`, tss[0])
	require.Equal(t, 1, dirtyCount(t, d))
	_, err = Run(ctx, d, Options{Now: now})
	require.NoError(t, err)
	got := docText(t, d, id)
	assert.Contains(t, got, "beta")
	assert.NotContains(t, got, "alpha")
	assert.Zero(t, dirtyCount(t, d))
}

func TestDrainDirty_TombstoneRemovesTextFromDayDoc(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	now := testNow()
	day, tss := oldDM(t, d, now, "alpha", "gamma")
	_, err := Run(ctx, d, Options{Now: now})
	require.NoError(t, err)

	exec(t, d, `UPDATE messages SET is_deleted = 1, text = '' WHERE ts = ?`, tss[0])
	_, err = Run(ctx, d, Options{Now: now})
	require.NoError(t, err)
	got := docText(t, d, slackDayRef("1:D7", day))
	assert.Contains(t, got, "gamma")
	assert.NotContains(t, got, "alpha")
}

func TestDrainDirty_LastMessageGoneDeletesDoc(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	now := testNow()
	exec(t, d, `INSERT INTO channels (id, name, type) VALUES ('1:C7','ops','public')`)
	exec(t, d, `INSERT INTO users (id, name, display_name) VALUES ('1:U1','anna','Anna')`)
	root := fmt.Sprintf("%d.000100", now.Add(-10*24*time.Hour).Unix())
	reply := fmt.Sprintf("%d.000200", now.Add(-10*24*time.Hour).Unix()+60)
	msg(t, d, "1:C7", root, "1:U1", "root text", root, "")
	msg(t, d, "1:C7", reply, "1:U1", "reply text", root, "")
	_, err := Run(ctx, d, Options{Now: now})
	require.NoError(t, err)
	id := slackThreadRef("1:C7", root)
	require.True(t, docExists(t, d, id))

	exec(t, d, `UPDATE messages SET is_deleted = 1, text = '' WHERE channel_id = '1:C7'`)
	_, err = Run(ctx, d, Options{Now: now})
	require.NoError(t, err)
	assert.False(t, docExists(t, d, id))
	assert.Empty(t, docText(t, d, id))
}

func TestDrainDirty_GmailPartialThreadDelete(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedGmail(t, d)
	exec(t, d, `UPDATE gmail_messages SET body_text = 'unique-second-body' WHERE id = 'm2'`)
	_, err := Run(ctx, d, Options{Now: testNow()})
	require.NoError(t, err)
	require.Contains(t, docText(t, d, "gmail:1:t1"), "unique-second-body")

	exec(t, d, `DELETE FROM gmail_messages WHERE id = 'm2'`)
	_, err = Run(ctx, d, Options{Now: testNow()})
	require.NoError(t, err)
	got := docText(t, d, "gmail:1:t1")
	assert.NotContains(t, got, "unique-second-body")
	assert.Contains(t, got, "Предлагаю урезать")
	assert.Zero(t, dirtyCount(t, d))
}

func TestDrainDirty_HealedMessageReturnsToIndex(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	now := testNow()
	_, tss := oldDM(t, d, now, "zebrafish")
	_, err := Run(ctx, d, Options{Now: now})
	require.NoError(t, err)
	exec(t, d, `UPDATE messages SET is_deleted = 1, text = '' WHERE ts = ?`, tss[0])
	_, err = Run(ctx, d, Options{Now: now})
	require.NoError(t, err)
	search := func() int {
		res, err := Search(ctx, d, Request{Queries: []string{"zebrafish"}, Now: now})
		require.NoError(t, err)
		return len(res.Hits)
	}
	require.Zero(t, search())

	exec(t, d, `UPDATE messages SET is_deleted = 0, text = 'zebrafish' WHERE ts = ?`, tss[0])
	_, err = Run(ctx, d, Options{Now: now})
	require.NoError(t, err)
	assert.Equal(t, 1, search())
}

// bumpSource re-marks its own key while rendering it.
type bumpSource struct {
	stubSource
	d *db.DB
}

func (b bumpSource) Changed(context.Context, Queryer, string, time.Time) ([]string, string, bool, error) {
	return nil, "c1", true, nil
}

func (b bumpSource) Build(ctx context.Context, _ Queryer, key string) (*Doc, error) {
	_, err := b.d.ExecContext(ctx, `INSERT INTO kb_dirty (source, key) VALUES ('slack', ?) ON CONFLICT (source, key) DO UPDATE SET gen = gen + 1`, key)
	return nil, err
}

func TestDrainDirty_ReMarkDuringRenderSurvives(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	exec(t, d, `INSERT INTO kb_dirty (source, key) VALUES ('slack', 'slack:day:1:C1:2025-01-01')`)
	r := testRunner(bumpSource{stubSource: stubSource{name: "slack"}, d: d})
	// The re-mark outlives the pass; a stale row would otherwise be drained
	// forever, so only the first pass is run.
	_, err := r.run(ctx, d, Options{Now: testNow()})
	require.NoError(t, err)
	var gen int
	require.NoError(t, d.QueryRow(`SELECT gen FROM kb_dirty WHERE key = 'slack:day:1:C1:2025-01-01'`).Scan(&gen))
	assert.Positive(t, gen, "the row kept its moved gen")
}

func TestDrainDirty_MissingSourceDocIsADelete(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedGmail(t, d)
	_, err := Run(ctx, d, Options{Now: testNow()})
	require.NoError(t, err)
	require.True(t, docExists(t, d, "gmail:1:t1"))
	// A purge removes the account and its mail; the dirty rows stay behind.
	exec(t, d, `DELETE FROM gmail_messages`)
	exec(t, d, `INSERT INTO kb_dirty (source, key) VALUES ('jira', 'jira:9:GONE-1'), ('gmail', 'gmail:9:t9')`)
	_, err = Run(ctx, d, Options{Now: testNow()})
	require.NoError(t, err)
	assert.False(t, docExists(t, d, "gmail:1:t1"))
	assert.Zero(t, dirtyCount(t, d))
}

func TestDrainDirty_BudgetStopsAfterABatch(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	for i := range batchSize + 5 {
		exec(t, d, `INSERT INTO kb_dirty (source, key) VALUES ('jira', ?)`, fmt.Sprintf("jira:1:K-%04d", i))
	}
	var st Stats
	caughtUp, err := drainDirty(ctx, d, jiraSource{}, func() bool { return true }, &st)
	require.NoError(t, err)
	assert.False(t, caughtUp)
	assert.Equal(t, 5, dirtyCount(t, d))
	caughtUp, err = drainDirty(ctx, d, jiraSource{}, func() bool { return false }, &st)
	require.NoError(t, err)
	assert.True(t, caughtUp)
	assert.Zero(t, dirtyCount(t, d))
}

// TestKBDirtyTriggerKeysMatchSourceKeys pins the Go-to-SQL dual path: the
// keys the migration's triggers write are the keys the sources use.
func TestKBDirtyTriggerKeysMatchSourceKeys(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSlack(t, d)
	seedGmail(t, d)
	seedJira(t, d)
	exec(t, d, `DELETE FROM kb_dirty`)

	dirty := func() map[string]bool {
		rows, err := d.Query(`SELECT key FROM kb_dirty`)
		require.NoError(t, err)
		defer rows.Close()
		out := map[string]bool{}
		for rows.Next() {
			var k string
			require.NoError(t, rows.Scan(&k))
			out[k] = true
		}
		return out
	}

	// A reply (thread key) and a top-level message (day key).
	exec(t, d, `UPDATE messages SET text = 'edited' WHERE ts IN ('1758000100.000200', '1758000400.000500')`)
	got := dirty()
	assert.True(t, got[SlackDocRef("1:C1", "1758000000.000100", 1758000100)], "reply: %v", got)
	assert.True(t, got[SlackDocRef("1:D1", "", 1758000400)], "top-level: %v", got)

	// Threaded and threadless Gmail rows.
	exec(t, d, `DELETE FROM kb_dirty`)
	gKeys, err := gmailSource{}.Keys(ctx, d)
	require.NoError(t, err)
	exec(t, d, `DELETE FROM gmail_messages WHERE id IN ('m1', 'm3')`)
	got = dirty()
	require.Len(t, got, 2)
	for k := range got {
		assert.Contains(t, gKeys, k)
	}

	// A Jira comment.
	exec(t, d, `DELETE FROM kb_dirty`)
	jKeys, err := jiraSource{}.Keys(ctx, d)
	require.NoError(t, err)
	exec(t, d, `DELETE FROM jira_comments WHERE id = 'c1'`)
	got = dirty()
	require.Len(t, got, 1)
	for k := range got {
		assert.Contains(t, jKeys, k)
	}
}

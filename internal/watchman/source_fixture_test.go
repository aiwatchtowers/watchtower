package watchman

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// Shared fixtures of the database source tests. Workbench 1 is the one read;
// workbench 2 holds rows that must never show up.

var srcT0 = time.Date(2026, 11, 1, 9, 0, 0, 0, time.UTC)

func stamp(t time.Time) string { return t.UTC().Format(time.RFC3339) }

func openSourceDB(t *testing.T) *db.DB {
	t.Helper()
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	for _, id := range []int64{1, 2} {
		_, err := d.Exec(`INSERT INTO projects (id, name, folder_path) VALUES (?, 'acme', ?)`, id, fmt.Sprintf("/tmp/acme-%d", id))
		require.NoError(t, err)
	}
	return d
}

func seedSession(t *testing.T, d *db.DB, wb int64, automationRun any) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, automation_run_id) VALUES (?, 'shell', 's', '/tmp/acme', ?)`,
		wb, automationRun)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func seedAutomationRun(t *testing.T, d *db.DB) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO automations (slug, scope, project_id, path) VALUES ('nightly', 'workbench', 1, '/tmp/acme/nightly.md')`)
	require.NoError(t, err)
	aid, err := res.LastInsertId()
	require.NoError(t, err)
	res, err = d.Exec(`INSERT INTO automation_runs (automation_id, trigger, status, queued_at) VALUES (?, 'manual', 'succeeded', ?)`, aid, stamp(srcT0))
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

type askSeed struct {
	wb                     int64
	session, automationRun any
	kind, title, summary   string
	payload, answer        string
	docPath, docSnapshot   string
	status                 string
	answeredAt             time.Time
}

const questionPayload = `{"focus":[],"questions":[{"id":"q1","question":"Which cache should the importer use?","options":[{"label":"sqlite","recommended":true},{"label":"redis"}]}],"checklist":[]}`

func questionAnswer(label, note string) string {
	return fmt.Sprintf(`{"answers":[{"id":"q1","labels":[%q],"other":""}],"checklist":[],"comments":[],"note":%q,"verdict":""}`, label, note)
}

func seedAsk(t *testing.T, d *db.DB, a askSeed) int64 {
	t.Helper()
	if a.wb == 0 {
		a.wb = 1
	}
	if a.kind == "" {
		a.kind = "question"
	}
	if a.title == "" {
		a.title = "Pick a cache"
	}
	if a.payload == "" {
		a.payload = questionPayload
	}
	if a.status == "" {
		a.status = "answered"
	}
	if a.answer == "" && a.status != "open" && a.status != "withdrawn" {
		a.answer = questionAnswer("sqlite", "")
	}
	answered := ""
	if !a.answeredAt.IsZero() {
		answered = stamp(a.answeredAt)
	}
	res, err := d.Exec(`INSERT INTO owner_asks (project_id, session_id, kind, title, summary, payload, doc_path, doc_snapshot,
			status, answer, answered_at, automation_run_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		a.wb, a.session, a.kind, a.title, a.summary, a.payload, a.docPath, a.docSnapshot, a.status, a.answer, answered, a.automationRun)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func keys(ps []db.WatchmanPrecedent) []string {
	out := make([]string, 0, len(ps))
	for _, p := range ps {
		out = append(out, p.SourceKey)
	}
	return out
}

// checkNewestFirst seeds five rows (seed returns each row's source key),
// walks them two at a time newest first, then adds a sixth, newer row and
// checks it comes before the rest of the backfill.
func checkNewestFirst(t *testing.T, d *db.DB, src Source, seed func(i int, at time.Time) string) {
	t.Helper()
	ctx := context.Background()
	k := map[int]string{}
	for i := 1; i <= 5; i++ {
		k[i] = seed(i, srcT0.Add(time.Duration(i)*time.Hour))
	}
	ps, cur, done, err := src.Next(ctx, d, 1, "", 2)
	require.NoError(t, err)
	require.Equal(t, []string{k[5], k[4]}, keys(ps))
	require.False(t, done)

	ps, cur, done, err = src.Next(ctx, d, 1, cur, 2)
	require.NoError(t, err)
	require.Equal(t, []string{k[3], k[2]}, keys(ps))
	require.False(t, done)

	k[6] = seed(6, srcT0.Add(6*time.Hour))
	ps, cur, _, err = src.Next(ctx, d, 1, cur, 2)
	require.NoError(t, err)
	require.Equal(t, []string{k[6], k[1]}, keys(ps), "the new row comes first, then the backfill")

	ps, cur, done, err = src.Next(ctx, d, 1, cur, 2)
	require.NoError(t, err)
	require.Empty(t, ps)
	require.True(t, done)

	ps, _, done, err = src.Next(ctx, d, 1, cur, 2)
	require.NoError(t, err)
	require.Empty(t, ps, "nothing is returned twice")
	require.True(t, done)
}

// captureLog sends the standard logger to a buffer for the test.
func captureLog(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(prev) })
	return &buf
}

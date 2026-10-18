package agentlogdb

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

type moveFixture struct {
	dir  string
	main *db.DB
	al   *DB
}

func newMoveFixture(t *testing.T) *moveFixture {
	t.Helper()
	dir := t.TempDir()
	main, err := db.Open(filepath.Join(dir, "watchtower.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = main.Close() })
	al, err := Open(filepath.Join(dir, "agentlog.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = al.Close() })
	return &moveFixture{dir: dir, main: main, al: al}
}

func (f *moveFixture) lockPath() string { return MoveLockPath(filepath.Join(f.dir, "agentlog.db")) }

func (f *moveFixture) move(t *testing.T) error {
	t.Helper()
	return MoveFromMain(context.Background(), f.main, f.al, f.lockPath())
}

// seed writes files and sessions (one transcript each, none on disk) into
// watchtower.db's agent_log_* tables, with perSession events per session.
func (f *moveFixture) seed(t *testing.T, sessions, perSession int) {
	t.Helper()
	tx, err := f.main.Begin()
	require.NoError(t, err)
	defer func() { _ = tx.Rollback() }()
	stmt, err := tx.Prepare(`INSERT INTO agent_log_events (session_uuid, key, kind, ts, name, outcome, input_tokens, output_tokens, cost_usd, src_path, src_offset, spawned_agent_id, background)
		VALUES (?, ?, ?, '2026-10-01T10:30:00Z', ?, ?, ?, 5, 0.01, ?, ?, 'a1', ?)`)
	require.NoError(t, err)
	defer stmt.Close()
	for s := range sessions {
		path := fmt.Sprintf("/gone/s%d.jsonl", s)
		_, err := tx.Exec(`INSERT INTO agent_log_files (path, agent, size, mtime, read_offset, parser_version, missing_at, scanned_at)
			VALUES (?, 'claude', 100, '2026-10-01T10:00:00Z', 100, 3, '2026-10-02T10:00:00Z', '2026-10-01T10:00:00Z')`, path)
		require.NoError(t, err)
		_, err = tx.Exec(`INSERT INTO agent_log_sessions (session_uuid, agent, folder_path, home_cwd, source_path, model, started_at, ended_at, reported_cost_usd)
			VALUES (?, 'claude', '/x/proj', '/x/proj', ?, 'claude-opus-5-5', '2026-10-01T10:00:00Z', '2026-10-01T11:00:00Z', 1.5)`,
			fmt.Sprintf("s%d", s), path)
		require.NoError(t, err)
		for e := range perSession {
			kind, outcome := "api_call", ""
			if e%3 == 1 {
				kind, outcome = "tool", "error"
			}
			_, err = stmt.Exec(fmt.Sprintf("s%d", s), fmt.Sprintf("s%d:%d", s, e), kind, "Bash", outcome, e, path, e*10, e%2)
			require.NoError(t, err)
		}
	}
	require.NoError(t, tx.Commit())
}

type querier interface {
	QueryRow(query string, args ...any) *sql.Row
	Query(query string, args ...any) (*sql.Rows, error)
}

func count(t *testing.T, q querier, table string) int {
	t.Helper()
	var n int
	require.NoError(t, q.QueryRow(`SELECT COUNT(*) FROM `+table).Scan(&n))
	return n
}

// dump is every row of query, as strings, for comparing two databases.
func dump(t *testing.T, q querier, query string) []string {
	t.Helper()
	rows, err := q.Query(query)
	require.NoError(t, err)
	defer rows.Close()
	cols, err := rows.Columns()
	require.NoError(t, err)
	var out []string
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		require.NoError(t, rows.Scan(ptrs...))
		out = append(out, fmt.Sprint(vals...))
	}
	require.NoError(t, rows.Err())
	return out
}

var moved = []string{"agent_log_files", "agent_log_sessions", "agent_log_events"}

func (f *moveFixture) counts(t *testing.T, q querier) []int {
	t.Helper()
	out := make([]int, len(moved))
	for i, table := range moved {
		out[i] = count(t, q, table)
	}
	return out
}

func (f *moveFixture) assertMainEmpty(t *testing.T) {
	t.Helper()
	for _, table := range moved {
		has, err := f.main.HasTable(table)
		require.NoError(t, err)
		assert.True(t, has, "%s stays in watchtower.db this release", table)
		assert.Zero(t, count(t, f.main, table), table)
	}
}

func (f *moveFixture) assertMoved(t *testing.T) {
	t.Helper()
	ok, err := f.al.Moved()
	require.NoError(t, err)
	assert.True(t, ok)
}

// setMoveSeams overrides the chunk size and the hook for one test.
func setMoveSeams(t *testing.T, chunk int, h func(step string) error) {
	t.Helper()
	prevChunk, prevHook := moveChunk, moveHook
	moveChunk, moveHook = chunk, h
	t.Cleanup(func() { moveChunk, moveHook = prevChunk, prevHook })
}

func TestMoveFromMain_CopiesAllRows(t *testing.T) {
	f := newMoveFixture(t)
	f.seed(t, 3, 4)
	want := f.counts(t, f.main)
	const totals = `SELECT * FROM agent_log_session_totals ORDER BY session_uuid`
	wantTotals := dump(t, f.main, totals)
	wantSessions := dump(t, f.main, `SELECT * FROM agent_log_sessions ORDER BY session_uuid`)
	wantEvents := dump(t, f.main, `SELECT * FROM agent_log_events ORDER BY id`)

	require.NoError(t, f.move(t))

	assert.Equal(t, []int{3, 3, 12}, want)
	assert.Equal(t, want, f.counts(t, f.al))
	assert.Equal(t, wantTotals, dump(t, f.al, totals))
	assert.Equal(t, wantSessions, dump(t, f.al, `SELECT * FROM agent_log_sessions ORDER BY session_uuid`),
		"sessions whose transcript is gone are moved as they are")
	assert.Equal(t, wantEvents, dump(t, f.al, `SELECT * FROM agent_log_events ORDER BY id`))
	f.assertMainEmpty(t)
	f.assertMoved(t)
}

func TestMoveFromMain_InterruptedMidCopyResumes(t *testing.T) {
	f := newMoveFixture(t)
	f.seed(t, 3, 3)
	want := f.counts(t, f.main)
	boom := errors.New("boom")
	setMoveSeams(t, 2, func(step string) error {
		if step == "copy agent_log_events" {
			return boom
		}
		return nil
	})
	require.ErrorIs(t, f.move(t), boom)
	ok, err := f.al.Moved()
	require.NoError(t, err)
	assert.False(t, ok, "no marker before the last chunk")
	assert.Equal(t, 2, count(t, f.al, "agent_log_events"), "the first chunk committed")
	assert.Equal(t, want, f.counts(t, f.main), "nothing deleted before the copy completed")

	moveHook = nil
	require.NoError(t, f.move(t))
	assert.Equal(t, want, f.counts(t, f.al))
	var dup int
	require.NoError(t, f.al.QueryRow(`SELECT COUNT(*) - COUNT(DISTINCT key) FROM agent_log_events`).Scan(&dup))
	assert.Zero(t, dup)
	f.assertMainEmpty(t)
	f.assertMoved(t)
}

func TestMoveFromMain_InterruptedBeforeDeleteResumes(t *testing.T) {
	f := newMoveFixture(t)
	f.seed(t, 2, 3)
	want := f.counts(t, f.main)
	boom := errors.New("boom")
	setMoveSeams(t, 2, func(step string) error {
		if strings.HasPrefix(step, "delete ") {
			return boom
		}
		return nil
	})
	require.ErrorIs(t, f.move(t), boom)
	f.assertMoved(t)
	assert.Equal(t, want, f.counts(t, f.main), "rows still in watchtower.db")

	var copies int
	moveHook = func(step string) error {
		if strings.HasPrefix(step, "copy ") {
			copies++
		}
		return nil
	}
	require.NoError(t, f.move(t))
	assert.Zero(t, copies, "a marked move copies nothing")
	assert.Equal(t, want, f.counts(t, f.al))
	f.assertMainEmpty(t)
}

func TestMoveFromMain_FreshInstall(t *testing.T) {
	f := newMoveFixture(t)
	require.NoError(t, f.move(t))
	f.assertMoved(t)
	assert.Equal(t, []int{0, 0, 0}, f.counts(t, f.al))
	f.assertMainEmpty(t)
}

func TestMoveFromMain_TwoMoversOneCopy(t *testing.T) {
	f := newMoveFixture(t)
	f.seed(t, 3, 50)
	want := f.counts(t, f.main)

	var wg sync.WaitGroup
	errs := make([]error, 2)
	for i := range errs {
		wg.Go(func() {
			main, err := db.Open(filepath.Join(f.dir, "watchtower.db"))
			if err != nil {
				errs[i] = err
				return
			}
			defer main.Close()
			al, err := Open(filepath.Join(f.dir, "agentlog.db"))
			if err != nil {
				errs[i] = err
				return
			}
			defer al.Close()
			errs[i] = MoveFromMain(context.Background(), main, al, f.lockPath())
		})
	}
	wg.Wait()
	require.NoError(t, errs[0])
	require.NoError(t, errs[1])
	assert.Equal(t, want, f.counts(t, f.al))
	var dup int
	require.NoError(t, f.al.QueryRow(`SELECT COUNT(*) - COUNT(DISTINCT key) FROM agent_log_events`).Scan(&dup))
	assert.Zero(t, dup)
	f.assertMainEmpty(t)
	f.assertMoved(t)
}

func TestMoveFromMain_DeleteSlicesShortTx(t *testing.T) {
	f := newMoveFixture(t)
	f.seed(t, 1, 12000)
	deletes := map[string]int{}
	setMoveSeams(t, moveChunk, func(step string) error {
		if table, ok := strings.CutPrefix(step, "delete "); ok {
			deletes[table]++
		}
		return nil
	})
	require.NoError(t, f.move(t))
	assert.Equal(t, 5000, moveChunk)
	assert.GreaterOrEqual(t, deletes["agent_log_events"], 3, "12,000 events leave in slices of 5,000")
	assert.Equal(t, 1, deletes["agent_log_sessions"])
	assert.Equal(t, 1, deletes["agent_log_files"])
	assert.Equal(t, 12000, count(t, f.al, "agent_log_events"))
	f.assertMainEmpty(t)
}

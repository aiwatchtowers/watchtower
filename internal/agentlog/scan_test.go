package agentlog

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/db"
)

type fixture struct {
	t      *testing.T
	d      *db.DB // watchtower.db
	al     *agentlogdb.DB
	claude string
	folder string
	wb     int64
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	dir := t.TempDir()
	d, err := db.Open(filepath.Join(dir, "w.db"))
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	al, err := agentlogdb.Open(filepath.Join(dir, "agentlog.db"))
	require.NoError(t, err)
	t.Cleanup(func() { al.Close() })
	_, err = agentlogdb.MoveFromMain(context.Background(), d, al, filepath.Join(dir, "agentlog.db.move.lock"))
	require.NoError(t, err)
	folder := t.TempDir()
	folder, _ = filepath.EvalSymlinks(folder)
	wb, err := d.CreateWorkbench("app", folder)
	require.NoError(t, err)
	require.NoError(t, d.SetWorkbenchAgentAnalytics(wb, true))
	return &fixture{t: t, d: d, al: al, claude: t.TempDir(), folder: folder, wb: wb}
}

// write appends content to the transcript of session sid whose cwd is cwd.
func (f *fixture) write(cwd, rel, content string) string {
	dir := filepath.Join(f.claude, "projects", Slug(cwd))
	p := filepath.Join(dir, rel)
	require.NoError(f.t, os.MkdirAll(filepath.Dir(p), 0o755))
	fh, err := os.OpenFile(p, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	require.NoError(f.t, err)
	_, err = fh.WriteString(content)
	require.NoError(f.t, err)
	require.NoError(f.t, fh.Close())
	return p
}

func (f *fixture) scan() *Result {
	r, err := Scan(context.Background(), f.d, f.al, f.wb, Options{ClaudeDir: f.claude})
	require.NoError(f.t, err)
	return r
}

func (f *fixture) totals() (calls, out int64) {
	require.NoError(f.t, f.al.QueryRow(`SELECT COUNT(*), COALESCE(SUM(output_tokens),0) FROM agent_log_events WHERE kind='api_call'`).Scan(&calls, &out))
	return
}

func call(t *testing.T, sid, cwd, uuid, msg, req string, out int64) string {
	a := assistant(sid, uuid, msg, req, out)
	a["cwd"] = cwd
	return line(t, a)
}

func TestScan_BackfillThenIncremental(t *testing.T) {
	f := newFixture(t)
	f.write(f.folder, "s1.jsonl", call(t, "s1", f.folder, "u1", "m1", "r1", 5))
	r := f.scan()
	assert.Equal(t, 1, r.Sessions)
	f.write(f.folder, "s1.jsonl", call(t, "s1", f.folder, "u2", "m2", "r2", 7))
	f.scan()
	calls, out := f.totals()
	assert.Equal(t, int64(2), calls)
	assert.Equal(t, int64(12), out)
	r = f.scan() // nothing changed
	assert.Equal(t, 1, r.FilesSkipped)
}

func TestScan_PartialLineCompletedLater(t *testing.T) {
	f := newFixture(t)
	full := call(t, "s1", f.folder, "u1", "m1", "r1", 5)
	f.write(f.folder, "s1.jsonl", full[:len(full)/2])
	f.scan()
	calls, _ := f.totals()
	assert.Zero(t, calls)
	f.write(f.folder, "s1.jsonl", full[len(full)/2:])
	f.scan()
	calls, _ = f.totals()
	assert.Equal(t, int64(1), calls)
}

func TestScan_ShrunkFileReparsedWithoutDuplicates(t *testing.T) {
	f := newFixture(t)
	p := f.write(f.folder, "s1.jsonl", call(t, "s1", f.folder, "u1", "m1", "r1", 5)+call(t, "s1", f.folder, "u2", "m2", "r2", 5))
	f.scan()
	require.NoError(t, os.WriteFile(p, []byte(call(t, "s1", f.folder, "u1", "m1", "r1", 5)), 0o600))
	f.scan()
	calls, _ := f.totals()
	assert.Equal(t, int64(2), calls) // m2 stays (AGENTLOG-03), m1 not doubled
}

func TestScan_ForkReplayCountsOnceInEitherOrder(t *testing.T) {
	for _, order := range [][]string{{"orig", "fork"}, {"fork", "orig"}} {
		f := newFixture(t)
		lines := map[string]string{
			"orig": call(t, "orig", f.folder, "u1", "m1", "r1", 5),
			"fork": call(t, "fork", f.folder, "u1", "m1", "r1", 5) + call(t, "fork", f.folder, "u9", "m9", "r9", 3),
		}
		for _, sid := range order {
			f.write(f.folder, sid+".jsonl", lines[sid])
			f.scan()
		}
		calls, out := f.totals()
		assert.Equal(t, int64(2), calls)
		assert.Equal(t, int64(8), out)
	}
}

func TestScan_SubagentReplayOfParentSkipped(t *testing.T) {
	f := newFixture(t)
	f.write(f.folder, "s1.jsonl", call(t, "s1", f.folder, "u1", "m1", "r1", 5))
	f.write(f.folder, "s1/subagents/agent-a1.jsonl", call(t, "s1", f.folder, "u1", "m1", "rX", 5)+call(t, "s1", f.folder, "u2", "m2", "r2", 4))
	f.scan()
	calls, out := f.totals()
	assert.Equal(t, int64(2), calls)
	assert.Equal(t, int64(9), out)
}

func TestScan_NestedWorkbenchesLongestWins(t *testing.T) {
	f := newFixture(t)
	inner := filepath.Join(f.folder, "inner")
	require.NoError(t, os.Mkdir(inner, 0o755))
	innerWB, err := f.d.CreateWorkbench("inner", inner)
	require.NoError(t, err)
	f.write(inner, "s1.jsonl", call(t, "s1", inner, "u1", "m1", "r1", 5))
	f.scan() // outer: the session is inner's, not read, no file row
	calls, _ := f.totals()
	assert.Zero(t, calls)
	require.NoError(t, f.d.SetWorkbenchAgentAnalytics(innerWB, true))
	_, err = Scan(context.Background(), f.d, f.al, innerWB, Options{ClaudeDir: f.claude})
	require.NoError(t, err)
	calls, _ = f.totals()
	assert.Equal(t, int64(1), calls)
}

func TestScan_UnrelatedProjectNeverOpened(t *testing.T) {
	f := newFixture(t)
	other := filepath.Join(f.claude, "projects", "-somewhere-else")
	require.NoError(t, os.MkdirAll(other, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(other, "x.jsonl"), []byte("{}\n"), 0o000)) // unreadable: opening it would fail the test
	f.scan()
	fr, err := f.al.GetAgentLogFile(filepath.Join(other, "x.jsonl"))
	require.NoError(t, err)
	assert.Nil(t, fr)
}

func TestScan_DeletedFileKeepsRowsAndParserBumpRereadsPresentOnly(t *testing.T) {
	f := newFixture(t)
	p := f.write(f.folder, "s1.jsonl", call(t, "s1", f.folder, "u1", "m1", "r1", 5))
	f.scan()
	require.NoError(t, os.Remove(p))
	r := f.scan()
	assert.Equal(t, 1, r.MissingFiles)
	calls, _ := f.totals()
	assert.Equal(t, int64(1), calls)
}

func TestScan_ConcurrentWritersCountOnce(t *testing.T) {
	f := newFixture(t)
	for i := range 20 {
		f.write(f.folder, "s1.jsonl", call(t, "s1", f.folder, "u"+string(rune('a'+i)), "m"+string(rune('a'+i)), "r", 1))
	}
	var wg sync.WaitGroup
	for range 2 {
		wg.Go(func() { _, _ = Scan(context.Background(), f.d, f.al, f.wb, Options{ClaudeDir: f.claude}) })
	}
	wg.Wait()
	calls, out := f.totals()
	assert.Equal(t, int64(20), calls)
	assert.Equal(t, int64(20), out)
}

func TestScan_RepricesOlderRows(t *testing.T) {
	f := newFixture(t)
	f.write(f.folder, "s1.jsonl", call(t, "s1", f.folder, "u1", "m1", "r1", 5))
	f.scan()
	_, err := f.al.Exec(`UPDATE agent_log_events SET price_version = 0, cost_usd = 99`)
	require.NoError(t, err)
	r := f.scan()
	assert.Equal(t, 1, r.Repriced)
	var usd float64
	require.NoError(t, f.al.QueryRow(`SELECT cost_usd FROM agent_log_events`).Scan(&usd))
	assert.Less(t, usd, 1.0)
}

func TestScan_BudgetStopDoesNotMarkUnreadFilesMissing(t *testing.T) {
	f := newFixture(t)
	f.write(f.folder, "s1.jsonl", call(t, "s1", f.folder, "u1", "m1", "r1", 5))
	f.write(f.folder, "s2.jsonl", call(t, "s2", f.folder, "u2", "m2", "r2", 5))
	f.scan()
	clock := time.Date(2026, 10, 1, 10, 0, 0, 0, time.UTC)
	now := func() time.Time { clock = clock.Add(time.Minute); return clock }
	r, err := Scan(context.Background(), f.d, f.al, f.wb, Options{ClaudeDir: f.claude, Budget: time.Second, Now: now})
	require.NoError(t, err)
	assert.True(t, r.Incomplete)
	assert.Zero(t, r.MissingFiles)
	for _, sid := range []string{"s1", "s2"} {
		fr, err := f.al.GetAgentLogFile(filepath.Join(f.claude, "projects", Slug(f.folder), sid+".jsonl"))
		require.NoError(t, err)
		require.NotNil(t, fr)
		assert.Empty(t, fr.MissingAt)
	}
}

func TestScan_ConcurrentScansBothSucceed(t *testing.T) {
	f := newFixture(t)
	for i := range 20 {
		f.write(f.folder, "s1.jsonl", call(t, "s1", f.folder, "u"+string(rune('a'+i)), "m"+string(rune('a'+i)), "r", 1))
	}
	errs := make([]error, 2)
	var wg sync.WaitGroup
	for i := range errs {
		wg.Go(func() {
			_, errs[i] = Scan(context.Background(), f.d, f.al, f.wb, Options{ClaudeDir: f.claude})
		})
	}
	wg.Wait()
	assert.NoError(t, errs[0])
	assert.NoError(t, errs[1])
}

func TestScan_ParserBumpRereadsPresentFilesOnly(t *testing.T) {
	f := newFixture(t)
	keep := f.write(f.folder, "s1.jsonl", call(t, "s1", f.folder, "u1", "m1", "r1", 5)+call(t, "s1", f.folder, "u2", "m2", "r2", 7))
	gone := f.write(f.folder, "s2.jsonl", call(t, "s2", f.folder, "u3", "m3", "r3", 11))
	f.scan()
	require.NoError(t, os.Remove(gone))
	_, err := f.al.Exec(`UPDATE agent_log_files SET parser_version = ?`, ParserVersion-1)
	require.NoError(t, err)
	// A reread from 0 rewrites m1's row; a read from the stored offset would not touch it.
	_, err = f.al.Exec(`UPDATE agent_log_events SET input_tokens = 0 WHERE src_path = ? AND src_offset = 0`, keep)
	require.NoError(t, err)
	f.write(f.folder, "s1.jsonl", call(t, "s1", f.folder, "u4", "m4", "r4", 13))
	r := f.scan()
	assert.Equal(t, 1, r.FilesScanned)
	assert.Equal(t, 1, r.MissingFiles)
	calls, out := f.totals()
	assert.Equal(t, int64(4), calls) // m1, m2 once each + m4 new + m3 kept (AGENTLOG-03)
	assert.Equal(t, int64(36), out)
	var in0 int64
	require.NoError(t, f.al.QueryRow(`SELECT input_tokens FROM agent_log_events WHERE src_path = ? AND src_offset = 0`, keep).Scan(&in0))
	assert.Equal(t, int64(10), in0) // restored: the file was reread from offset 0

	kr, err := f.al.GetAgentLogFile(keep)
	require.NoError(t, err)
	require.NotNil(t, kr)
	assert.Equal(t, ParserVersion, kr.ParserVersion)
	fi, err := os.Stat(keep)
	require.NoError(t, err)
	assert.Equal(t, fi.Size(), kr.ReadOffset)
	assert.Empty(t, kr.MissingAt)

	gr, err := f.al.GetAgentLogFile(gone)
	require.NoError(t, err)
	require.NotNil(t, gr)
	assert.Equal(t, ParserVersion-1, gr.ParserVersion) // not reread
	assert.NotEmpty(t, gr.MissingAt)
}

// AGENTLOG-02/03 robustness: a session-less record is counted, not stored,
// and never stops the files after it.
func TestScan_SessionlessRecordDoesNotStopOtherFiles(t *testing.T) {
	f := newFixture(t)
	bad := assistant("", "u0", "m0", "r0", 5)
	delete(bad, "sessionId")
	bad["cwd"] = f.folder
	f.write(f.folder, "a.jsonl", line(t, bad)+call(t, "a", f.folder, "u1", "m1", "r1", 5))
	f.write(f.folder, "b.jsonl", call(t, "b", f.folder, "u2", "m2", "r2", 7))
	r := f.scan()
	assert.Zero(t, r.FailedFiles)
	assert.Equal(t, 1, r.UnknownRecords["<no-session>"])
	calls, out := f.totals()
	assert.Equal(t, int64(2), calls)
	assert.Equal(t, int64(12), out)
}

// AGENTLOG-03 robustness: a batch that fails to store is counted and
// retried next scan; the remaining files are still read.
func TestScan_FailedBatchSkipsFileAndContinues(t *testing.T) {
	f := newFixture(t)
	_, err := f.al.Exec(`CREATE TRIGGER test_fail_a BEFORE INSERT ON agent_log_events WHEN NEW.session_uuid = 'a'
		BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END`)
	require.NoError(t, err)
	f.write(f.folder, "a.jsonl", call(t, "a", f.folder, "u1", "m1", "r1", 5))
	f.write(f.folder, "b.jsonl", call(t, "b", f.folder, "u2", "m2", "r2", 7))
	r := f.scan()
	assert.Equal(t, 1, r.FailedFiles)
	calls, out := f.totals()
	assert.Equal(t, int64(1), calls)
	assert.Equal(t, int64(7), out)
	fr, err := f.al.GetAgentLogFile(filepath.Join(f.claude, "projects", Slug(f.folder), "a.jsonl"))
	require.NoError(t, err)
	assert.Nil(t, fr, "the failed file keeps no offset, so the next scan retries it")
}

func TestScan_SlashSkillAfterListingInEarlierScan(t *testing.T) {
	f := newFixture(t)
	listing := line(t, map[string]any{"type": "attachment", "sessionId": "s1",
		"attachment": map[string]any{"type": "skill_listing", "names": []string{"review"}}})
	f.write(f.folder, "s1.jsonl", listing+call(t, "s1", f.folder, "u1", "m1", "r1", 5))
	f.scan()
	f.write(f.folder, "s1.jsonl", line(t, map[string]any{"type": "user", "sessionId": "s1", "uuid": "o1", "cwd": f.folder,
		"message": map[string]any{"role": "user", "content": "<command-name>/review</command-name>"}}))
	f.scan()
	var n int
	require.NoError(t, f.al.QueryRow(`SELECT COUNT(*) FROM agent_log_events WHERE kind = 'skill' AND name = 'review' AND trigger = 'slash'`).Scan(&n))
	assert.Equal(t, 1, n)
}

// A removed worktree known only from terminal_session_worktrees still has
// its transcripts read.
func TestScan_LedgerWorktreeRootIsRead(t *testing.T) {
	f := newFixture(t)
	base, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	gone := filepath.Join(base, "wt-removed")
	res, err := f.d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id) VALUES (?, 'claude', 's', ?, 's1')`, f.wb, f.folder)
	require.NoError(t, err)
	sid, err := res.LastInsertId()
	require.NoError(t, err)
	_, err = f.d.RecordSessionWorktree(context.Background(), nil, sid, gone, "feat/x", "2026-10-12T12:00:00.000Z")
	require.NoError(t, err)
	f.write(gone, "s1.jsonl", call(t, "s1", gone, "u1", "m1", "r1", 5))
	f.scan()
	calls, _ := f.totals()
	assert.Equal(t, int64(1), calls)
}

func TestScan_ParserVersionBumpReparsesNewTargets(t *testing.T) {
	f := newFixture(t)
	a := assistant("s1", "u1", "m1", "r1", 5,
		toolUse("t1", "Agent", map[string]any{"subagent_type": "Explore", "run_in_background": true}),
		toolUse("t2", "mcp__watchtower-workbench__update_target", map[string]any{"target_id": 298}))
	a["cwd"] = f.folder
	f.write(f.folder, "s1.jsonl", line(t, a)+toolResultLine(t, "s1", "r2", "t1", "ok", false,
		map[string]any{"toolUseResult": map[string]any{"agentId": "a1", "isAsync": true}})+
		line(t, map[string]any{"type": "user", "sessionId": "s1", "uuid": "n1", "cwd": f.folder, "timestamp": "2026-10-01T10:00:09.000Z",
			"message": map[string]any{"role": "user", "content": "<task-notification>x</task-notification>"}}))
	f.scan()
	_, err := f.al.Exec(`UPDATE agent_log_files SET parser_version = 1`)
	require.NoError(t, err)
	_, err = f.al.Exec(`UPDATE agent_log_events SET target = '', spawned_agent_id = '', background = 0 WHERE kind = 'tool'`)
	require.NoError(t, err)
	_, err = f.al.Exec(`UPDATE agent_log_events SET trigger = '' WHERE kind = 'owner_turn'`)
	require.NoError(t, err)
	f.scan()
	var trig string
	var bg bool
	require.NoError(t, f.al.QueryRow(`SELECT trigger FROM agent_log_events WHERE kind = 'owner_turn'`).Scan(&trig))
	assert.Equal(t, "notification", trig)
	require.NoError(t, f.al.QueryRow(`SELECT background FROM agent_log_events WHERE name = 'Agent'`).Scan(&bg))
	assert.True(t, bg)
	rows, err := f.al.Query(`SELECT name, target, spawned_agent_id FROM agent_log_events WHERE kind = 'tool' ORDER BY name`)
	require.NoError(t, err)
	defer rows.Close()
	var got []string
	for rows.Next() {
		var n, tg, sp string
		require.NoError(t, rows.Scan(&n, &tg, &sp))
		got = append(got, n+"|"+tg+"|"+sp)
	}
	assert.Equal(t, []string{"Agent|Explore|a1", "mcp__watchtower-workbench__update_target|#298|"}, got)
}

// #571: a transcript is stored in short slices, each with its own offset
// compare-and-set; a stop between slices resumes from the last committed one,
// and slicing never changes what is counted (a streaming duplicate and a
// tool result on the far side of a slice boundary still fold and pair).
func TestScan_LongTranscriptCommittedInSlicesAndResumes(t *testing.T) {
	old := batchRows
	batchRows = 2
	t.Cleanup(func() { batchRows = old })
	f := newFixture(t)
	a := assistant("s1", "u1", "m1", "r1", 5, toolUse("t1", "Bash", map[string]any{"command": "make test"}))
	a["cwd"] = f.folder
	var body strings.Builder
	body.WriteString(line(t, a) + // api_call m1 + tool t1: one full slice
		call(t, "s1", f.folder, "u2", "m1", "r1", 9) + // streaming repeat of m1 in the next slice
		toolResultLine(t, "s1", "r1", "t1", "ok", false, nil))
	for i := range 6 {
		body.WriteString(call(t, "s1", f.folder, "v"+string(rune('a'+i)), "n"+string(rune('a'+i)), "r", 1))
	}
	p := f.write(f.folder, "s1.jsonl", body.String())

	// Out of time as soon as the first slice is committed (the file row
	// exists), whatever the number of clock reads before it.
	start := time.Date(2026, 10, 1, 10, 0, 0, 0, time.UTC)
	now := func() time.Time {
		if fr, err := f.al.GetAgentLogFile(p); err == nil && fr != nil {
			return start.Add(time.Hour)
		}
		return start
	}
	r, err := Scan(context.Background(), f.d, f.al, f.wb, Options{ClaudeDir: f.claude, Budget: time.Second, Now: now})
	require.NoError(t, err)
	assert.True(t, r.Incomplete)
	assert.Equal(t, 2, r.EventsWritten)
	fr, err := f.al.GetAgentLogFile(p)
	require.NoError(t, err)
	require.NotNil(t, fr)
	fi, err := os.Stat(p)
	require.NoError(t, err)
	assert.Less(t, fr.ReadOffset, fi.Size())
	assert.Empty(t, fr.MTime, "a partly read file must not look unchanged to the next scan")

	r = f.scan()
	assert.False(t, r.Incomplete)
	fr, err = f.al.GetAgentLogFile(p)
	require.NoError(t, err)
	assert.Equal(t, fi.Size(), fr.ReadOffset)
	n, out := f.totals()
	assert.Equal(t, int64(7), n)    // m1 once + six more
	assert.Equal(t, int64(15), out) // m1's later record (9) + 6×1
	var outcome string
	require.NoError(t, f.al.QueryRow(`SELECT outcome FROM agent_log_events WHERE key = 'tool:t1'`).Scan(&outcome))
	assert.Equal(t, "ok", outcome)
	assert.Equal(t, 1, f.scan().FilesSkipped)
}

// #571 review: a slash command in a later slice of an incremental read still
// finds the skill_listing that sits before the read's start offset.
func TestScan_SlashSkillInLaterSliceOfIncrementalRead(t *testing.T) {
	old := batchRows
	batchRows = 2
	t.Cleanup(func() { batchRows = old })
	f := newFixture(t)
	listing := line(t, map[string]any{"type": "attachment", "sessionId": "s1",
		"attachment": map[string]any{"type": "skill_listing", "names": []string{"review"}}})
	f.write(f.folder, "s1.jsonl", listing+call(t, "s1", f.folder, "u1", "m1", "r1", 5))
	f.scan()
	f.write(f.folder, "s1.jsonl", call(t, "s1", f.folder, "u2", "m2", "r2", 5)+call(t, "s1", f.folder, "u3", "m3", "r3", 5)+
		line(t, map[string]any{"type": "user", "sessionId": "s1", "uuid": "o1", "cwd": f.folder,
			"message": map[string]any{"role": "user", "content": "<command-name>/review</command-name>"}}))
	f.scan()
	var n int
	require.NoError(t, f.al.QueryRow(`SELECT COUNT(*) FROM agent_log_events WHERE kind = 'skill' AND name = 'review' AND trigger = 'slash'`).Scan(&n))
	assert.Equal(t, 1, n)
}

// Spec D3: terminal_session_id is resolved from watchtower.db before the
// slice's transaction — the Claude terminal session that recorded the
// session uuid, NULL when none did.
func TestScan_TerminalSessionIDResolvedFromMain(t *testing.T) {
	f := newFixture(t)
	res, err := f.d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id) VALUES (?, 'claude', 's', ?, 's1')`, f.wb, f.folder)
	require.NoError(t, err)
	sid, err := res.LastInsertId()
	require.NoError(t, err)
	f.write(f.folder, "s1.jsonl", call(t, "s1", f.folder, "u1", "m1", "r1", 5))
	f.write(f.folder, "s2.jsonl", call(t, "s2", f.folder, "u2", "m2", "r2", 5))
	f.scan()
	ts := func(uuid string) sql.NullInt64 {
		t.Helper()
		var v sql.NullInt64
		require.NoError(t, f.al.QueryRow(`SELECT terminal_session_id FROM agent_log_sessions WHERE session_uuid = ?`, uuid).Scan(&v))
		return v
	}
	assert.Equal(t, sql.NullInt64{Int64: sid, Valid: true}, ts("s1"))
	assert.False(t, ts("s2").Valid)
}

// G2: a scan only reads watchtower.db. Under a query_only handle any write
// there fails, so a full scan (workbench and worktree-ledger reads, a
// terminal session lookup) must still succeed and store its rows in
// agentlog.db.
func TestScan_NoWriteTxOnMain(t *testing.T) {
	f := newFixture(t)
	_, err := f.d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id) VALUES (?, 'claude', 's', ?, 's1')`, f.wb, f.folder)
	require.NoError(t, err)
	f.write(f.folder, "s1.jsonl", call(t, "s1", f.folder, "u1", "m1", "r1", 5))
	var path string
	require.NoError(t, f.d.QueryRow(`SELECT file FROM pragma_database_list WHERE name = 'main'`).Scan(&path))
	ro, err := db.OpenExisting(path, time.Second)
	require.NoError(t, err)
	t.Cleanup(func() { _ = ro.Close() })
	require.NoError(t, ro.SetReadOnly())

	r, err := Scan(context.Background(), ro, f.al, f.wb, Options{ClaudeDir: f.claude})
	require.NoError(t, err)
	assert.Equal(t, 1, r.Sessions)
	assert.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	calls, _ := f.totals()
	assert.Equal(t, int64(1), calls)
}

// Spec D4: before the move a scan would reparse every transcript from 0, so
// it refuses and stores nothing.
func TestScan_RefusesBeforeMove(t *testing.T) {
	dir := t.TempDir()
	d, err := db.Open(filepath.Join(dir, "w.db"))
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	al, err := agentlogdb.Open(filepath.Join(dir, "agentlog.db"))
	require.NoError(t, err)
	t.Cleanup(func() { al.Close() })
	folder, _ := filepath.EvalSymlinks(t.TempDir())
	wb, err := d.CreateWorkbench("app", folder)
	require.NoError(t, err)
	f := &fixture{t: t, d: d, al: al, claude: t.TempDir(), folder: folder, wb: wb}
	f.write(folder, "s1.jsonl", call(t, "s1", folder, "u1", "m1", "r1", 5))

	_, err = Scan(context.Background(), d, al, wb, Options{ClaudeDir: f.claude})
	require.ErrorIs(t, err, agentlogdb.ErrNotMoved)
	var n int
	require.NoError(t, al.QueryRow(`SELECT COUNT(*) FROM agent_log_files`).Scan(&n))
	assert.Zero(t, n)

	_, err = agentlogdb.MoveFromMain(context.Background(), d, al, filepath.Join(dir, "agentlog.db.move.lock"))
	require.NoError(t, err)
	r := f.scan()
	assert.Equal(t, 1, r.Sessions, "the scan runs once the move is done")
}

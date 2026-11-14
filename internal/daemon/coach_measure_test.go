package daemon

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/coach"
	"watchtower/internal/db"
)

// The measure check (spec 2026-11-12 C3, C8, C10): a repository change
// accepted through a session is measured from its PR's merge, a memory
// cleanup from its session's end, and a settings change turned back on
// outside Watchtower gets reverted_outside. No test reaches the network:
// the PR refresher is a stub, the homes and folders are temporary.

const (
	measureMemBefore = "# Memory\n- [Alpha](alpha.md) — the alpha note\n- [Beta](beta.md) — the beta note\n"
	measureMemAfter  = "# Memory\n- [Alpha](alpha.md) — the alpha note\n- [Archive](archive.md) — older notes\n"
)

// measureNow is a whole second (the coach stamps are RFC 3339 seconds).
func measureNow() time.Time { return time.Now().UTC().Truncate(time.Second) }

// refreshStub replaces the PR refresher: it counts its calls, stores state
// (when set) as the branch's fresh cache row, and returns err.
type refreshStub struct {
	calls int
	err   error
	state string
}

func stubRefresh(t *testing.T, s *refreshStub) *refreshStub {
	t.Helper()
	prev := coachRefreshPR
	coachRefreshPR = func(_ context.Context, database *db.DB, wb int64, branch string) error {
		s.calls++
		if s.err != nil {
			return s.err
		}
		if s.state != "" {
			return database.UpsertPRState(db.PRState{WorkbenchID: wb, Ref: "branch:" + branch, State: s.state,
				CheckedAt: time.Now().UTC().Format(time.RFC3339)})
		}
		return nil
	}
	t.Cleanup(func() { coachRefreshPR = prev })
	return s
}

// noHeadReads fails the test when the legacy HEAD rule reads git.
func noHeadReads(t *testing.T) {
	t.Helper()
	prev := coachFileAtHead
	coachFileAtHead = func(context.Context, string, string) (string, bool, error) {
		t.Error("a session row must never use the HEAD rule")
		return "", false, nil
	}
	t.Cleanup(func() { coachFileAtHead = prev })
}

func measureWorkbench(t *testing.T, database *db.DB) (int64, string) {
	t.Helper()
	folder := t.TempDir()
	wb, err := database.CreateWorkbench("acme-"+filepath.Base(folder), folder)
	require.NoError(t, err)
	w, err := database.GetWorkbench(wb)
	require.NoError(t, err)
	return wb, w.FolderPath
}

func measureSession(t *testing.T, database *db.DB, wb int64, branch string) int64 {
	t.Helper()
	res, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 'Session', '/tmp/acme', 'uuid')`, wb)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	if branch != "" {
		measureBranch(t, database, id, branch)
	}
	return id
}

func measureBranch(t *testing.T, database *db.DB, sess int64, branch string) {
	t.Helper()
	_, err := database.Exec(`INSERT INTO terminal_session_worktrees (session_id, root, branch, first_at)
		VALUES (?, '/tmp/acme-wt', ?, '2026-11-01T09:00:00.000Z')`, sess, branch)
	require.NoError(t, err)
}

func deleteSession(t *testing.T, database *db.DB, sess int64) {
	t.Helper()
	_, err := database.Exec(`DELETE FROM terminal_sessions WHERE id = ?`, sess)
	require.NoError(t, err)
}

// repoViaSession is a CLAUDE.md restructure of wb accepted through session
// sess at decided.
func repoViaSession(t *testing.T, database *db.DB, wb, sess int64, decided time.Time) int64 {
	t.Helper()
	id, err := database.InsertContextCoachProposal(db.CoachProposal{Fingerprint: "repo-" + time.Now().String(),
		Kind: "restructure", Destination: coach.DestRepoClaudeMD, WorkbenchID: wb, Title: "Slim CLAUDE.md",
		Why: "It is 24 KB.", Metric: "start_tokens"}, decided)
	require.NoError(t, err)
	require.NoError(t, database.AcceptCoachThroughSession(id, db.CoachSessionLink{SessionID: sess, WorkbenchID: wb}, decided))
	return id
}

// memoryViaSession is a memory cleanup of wb (folder) accepted through
// session sess at decided, its index (under home) measureMemBefore.
func memoryViaSession(t *testing.T, database *db.DB, home string, wb int64, folder string, sess int64,
	decided time.Time) (int64, string) {
	t.Helper()
	path := coach.MemoryIndexPath(home, folder)
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o700))
	require.NoError(t, os.WriteFile(path, []byte(measureMemBefore), 0o600))
	id, err := database.InsertContextCoachProposal(db.CoachProposal{Fingerprint: "mem-" + folder, Kind: "restructure",
		Destination: coach.DestMemoryIndex, WorkbenchID: wb, SourceKey: "memory", Title: "Archive stale memory lines",
		Why: "The index is 9.0 KB.", Metric: "start_tokens", BeforeText: measureMemBefore}, decided)
	require.NoError(t, err)
	before := measureMemBefore
	require.NoError(t, database.AcceptCoachThroughSession(id,
		db.CoachSessionLink{SessionID: sess, WorkbenchID: wb, Before: &before}, decided))
	return id, path
}

// writeMemory writes the index as of at (its modification time).
func writeMemory(t *testing.T, path, text string, at time.Time) {
	t.Helper()
	require.NoError(t, os.WriteFile(path, []byte(text), 0o600))
	require.NoError(t, os.Chtimes(path, at, at))
}

func prState(t *testing.T, database *db.DB, wb int64, branch, state, mergedAt string, checked time.Time) {
	t.Helper()
	require.NoError(t, database.UpsertPRState(db.PRState{WorkbenchID: wb, Ref: "branch:" + branch, State: state,
		MergedAt: mergedAt, CheckedAt: checked.UTC().Format(time.RFC3339)}))
}

func getProposal(t *testing.T, database *db.DB, id int64) db.CoachProposal {
	t.Helper()
	p, err := database.GetCoachProposal(id)
	require.NoError(t, err)
	return p
}

func TestMeasureCheck_MergedPR(t *testing.T) {
	d, database := coachDaemon(t)
	r := stubRefresh(t, &refreshStub{})
	noHeadReads(t)
	now := measureNow()
	wb, _ := measureWorkbench(t, database)
	sess := measureSession(t, database, wb, "wt/slim-claude-md")
	id := repoViaSession(t, database, wb, sess, now.Add(-72*time.Hour))
	merged := now.Add(-24 * time.Hour)
	prState(t, database, wb, "wt/slim-claude-md", "merged", merged.Format(time.RFC3339), now.Add(-10*time.Minute))

	require.True(t, d.coachMeasureCheck(context.Background(), now))
	p := getProposal(t, database, id)
	assert.True(t, p.MeasureFrom.Equal(merged), "measured from the merge, not from the check")
	assert.Empty(t, p.Verdict)
	assert.Zero(t, r.calls, "a cache under an hour old is not refreshed")
}

// A merged branch whose merge time the cache lacks (git saw the merge, no
// gh) is measured from when the check saw it.
func TestMeasureCheck_MergedWithoutTimeFromNow(t *testing.T) {
	d, database := coachDaemon(t)
	stubRefresh(t, &refreshStub{})
	now := measureNow()
	wb, _ := measureWorkbench(t, database)
	sess := measureSession(t, database, wb, "wt/a")
	id := repoViaSession(t, database, wb, sess, now.Add(-72*time.Hour))
	prState(t, database, wb, "wt/a", "merged", "", now)

	d.coachMeasureCheck(context.Background(), now)
	assert.True(t, getProposal(t, database, id).MeasureFrom.Equal(now))
}

func TestMeasureCheck_ClosedPR(t *testing.T) {
	d, database := coachDaemon(t)
	stubRefresh(t, &refreshStub{})
	now := measureNow()
	wb, _ := measureWorkbench(t, database)
	sess := measureSession(t, database, wb, "wt/a")
	id := repoViaSession(t, database, wb, sess, now.Add(-72*time.Hour))
	prState(t, database, wb, "wt/a", "closed", "", now)

	d.coachMeasureCheck(context.Background(), now)
	p := getProposal(t, database, id)
	assert.Equal(t, "too_little_data", p.Verdict, "closed unmerged: not merged")
	assert.Nil(t, p.VerdictValue)
	assert.True(t, p.MeasureFrom.IsZero())
}

func TestMeasureCheck_OpenPRWaits(t *testing.T) {
	d, database := coachDaemon(t)
	r := stubRefresh(t, &refreshStub{state: "open"})
	now := measureNow()
	wb, _ := measureWorkbench(t, database)
	sess := measureSession(t, database, wb, "wt/a")
	id := repoViaSession(t, database, wb, sess, now.Add(-72*time.Hour))
	prState(t, database, wb, "wt/a", "open", "", now.Add(-2*time.Hour))

	require.True(t, d.coachMeasureCheck(context.Background(), now))
	assert.Equal(t, 1, r.calls, "a cache over an hour old is refreshed for that branch")
	p := getProposal(t, database, id)
	assert.True(t, p.MeasureFrom.IsZero())
	assert.Empty(t, p.Verdict)

	// A refresh that finds the merge measures in the same pass.
	r.state = "merged"
	prState(t, database, wb, "wt/a", "open", "", now.Add(-2*time.Hour))
	d.coachMeasureCheck(context.Background(), now)
	assert.False(t, getProposal(t, database, id).MeasureFrom.IsZero())
}

// A row accepted before this change (no session) keeps the HEAD rule.
func TestMeasureCheck_LegacyRowUsesHead(t *testing.T) {
	d, database := coachDaemon(t)
	r := stubRefresh(t, &refreshStub{})
	folder, id := acceptedRepoEdit(t, database)
	now := measureNow()

	d.coachMeasureCheck(context.Background(), now)
	assert.True(t, measureFrom(t, database, id).IsZero(), "written, not committed")
	commitGit(t, folder, "commit", "-q", "-am", "owner commits")
	d.coachMeasureCheck(context.Background(), now)
	assert.True(t, measureFrom(t, database, id).Equal(now))
	assert.Zero(t, r.calls, "no PR is looked up for a legacy row")
}

func TestMeasureCheck_MemoryChanged(t *testing.T) {
	d, database := coachDaemon(t)
	home, err := os.UserHomeDir()
	require.NoError(t, err)
	now := measureNow()
	wb, folder := measureWorkbench(t, database)
	sess := measureSession(t, database, wb, "")
	id, path := memoryViaSession(t, database, home, wb, folder, sess, now.Add(-3*time.Hour))
	end := now.Add(-time.Hour)
	writeMemory(t, path, measureMemAfter, end.Add(-time.Minute))
	require.NoError(t, database.FinishTerminalSession(sess, "archived", end))

	d.coachMeasureCheck(context.Background(), now)
	p := getProposal(t, database, id)
	assert.True(t, p.MeasureFrom.Equal(end), "measured from the session's end")
	assert.Equal(t, measureMemAfter, p.AfterText, "the index as the session left it")
	assert.Empty(t, p.Verdict)
}

// Another session's auto-memory writes the index while the cleanup session
// still runs: nothing is recorded.
func TestMeasureCheck_MemoryWaitsForSessionEnd(t *testing.T) {
	d, database := coachDaemon(t)
	home, err := os.UserHomeDir()
	require.NoError(t, err)
	now := measureNow()
	wb, folder := measureWorkbench(t, database)
	sess := measureSession(t, database, wb, "")
	id, path := memoryViaSession(t, database, home, wb, folder, sess, now.Add(-3*time.Hour))
	writeMemory(t, path, measureMemBefore+"- [Gamma](gamma.md) — new\n", now.Add(-time.Hour))

	d.coachMeasureCheck(context.Background(), now)
	p := getProposal(t, database, id)
	assert.True(t, p.MeasureFrom.IsZero())
	assert.Empty(t, p.AfterText)
	assert.Empty(t, p.Verdict)
}

// The session ended and the index is as before: no measure_from (the card's
// "Session ended without a change"); a later write by another session does
// not count as the cleanup's.
func TestMeasureCheck_MemoryUnchangedAtSessionEnd(t *testing.T) {
	d, database := coachDaemon(t)
	home, err := os.UserHomeDir()
	require.NoError(t, err)
	now := measureNow()
	wb, folder := measureWorkbench(t, database)
	sess := measureSession(t, database, wb, "")
	id, path := memoryViaSession(t, database, home, wb, folder, sess, now.Add(-3*time.Hour))
	end := now.Add(-2 * time.Hour)
	writeMemory(t, path, measureMemBefore, end.Add(-time.Hour))
	require.NoError(t, database.FinishTerminalSession(sess, "nothing stale", end))

	d.coachMeasureCheck(context.Background(), now)
	p := getProposal(t, database, id)
	assert.True(t, p.MeasureFrom.IsZero())
	assert.Empty(t, p.Verdict)
	assert.Equal(t, measureMemBefore, p.AfterText, "decided once: ended without a change")

	writeMemory(t, path, measureMemBefore+"- [Gamma](gamma.md) — new\n", now.Add(-time.Minute))
	d.coachMeasureCheck(context.Background(), now)
	assert.True(t, getProposal(t, database, id).MeasureFrom.IsZero(), "written after the session ended")

	// 30 days without a change: too_little_data.
	d.coachMeasureCheck(context.Background(), now.Add(31*24*time.Hour))
	assert.Equal(t, "too_little_data", getProposal(t, database, id).Verdict)
}

// The session row was deleted: taken as ended when the check first sees it.
func TestMeasureCheck_MemorySessionRowDeleted(t *testing.T) {
	d, database := coachDaemon(t)
	home, err := os.UserHomeDir()
	require.NoError(t, err)
	now := measureNow()
	wb, folder := measureWorkbench(t, database)
	sess := measureSession(t, database, wb, "")
	id, path := memoryViaSession(t, database, home, wb, folder, sess, now.Add(-3*time.Hour))
	writeMemory(t, path, measureMemAfter, now.Add(-time.Hour))
	deleteSession(t, database, sess)
	require.Nil(t, getProposal(t, database, id).SessionID)

	d.coachMeasureCheck(context.Background(), now)
	p := getProposal(t, database, id)
	assert.True(t, p.MeasureFrom.Equal(now), "measured from the check that saw it gone")
	assert.Equal(t, measureMemAfter, p.AfterText)
}

// The branch was copied while the session row existed: its merged PR is
// still found after the row is deleted.
func TestMeasureCheck_RepoSessionRowDeletedAfterBranchCopied(t *testing.T) {
	d, database := coachDaemon(t)
	stubRefresh(t, &refreshStub{})
	noHeadReads(t)
	now := measureNow()
	wb, _ := measureWorkbench(t, database)
	sess := measureSession(t, database, wb, "")
	id := repoViaSession(t, database, wb, sess, now.Add(-72*time.Hour))
	measureBranch(t, database, sess, "wt/later") // the worktree came after the Accept

	d.coachMeasureCheck(context.Background(), now)
	assert.Equal(t, "wt/later", getProposal(t, database, id).SessionBranch, "copied from the live session")

	deleteSession(t, database, sess)
	merged := now.Add(-time.Hour)
	prState(t, database, wb, "wt/later", "merged", merged.Format(time.RFC3339), now)
	d.coachMeasureCheck(context.Background(), now)
	p := getProposal(t, database, id)
	assert.Nil(t, p.SessionID)
	assert.True(t, p.MeasureFrom.Equal(merged))
}

// The session row went before its branch was copied: no PR can be found,
// never the HEAD rule; 30 days end it as too_little_data.
func TestMeasureCheck_RepoSessionRowDeletedBeforeBranch(t *testing.T) {
	d, database := coachDaemon(t)
	r := stubRefresh(t, &refreshStub{})
	noHeadReads(t)
	now := measureNow()
	decided := now.Add(-72 * time.Hour)
	wb, _ := measureWorkbench(t, database)
	sess := measureSession(t, database, wb, "")
	id := repoViaSession(t, database, wb, sess, decided)
	deleteSession(t, database, sess)

	d.coachMeasureCheck(context.Background(), decided.Add(29*24*time.Hour))
	p := getProposal(t, database, id)
	assert.True(t, p.MeasureFrom.IsZero())
	assert.Empty(t, p.Verdict)
	assert.Zero(t, r.calls)

	d.coachMeasureCheck(context.Background(), decided.Add(31*24*time.Hour))
	assert.Equal(t, "too_little_data", getProposal(t, database, id).Verdict)
}

func TestMeasureCheck_ThirtyDays(t *testing.T) {
	d, database := coachDaemon(t)
	stubRefresh(t, &refreshStub{state: "open"})
	now := measureNow()
	decided := now.Add(-31 * 24 * time.Hour)
	wb, _ := measureWorkbench(t, database)
	sess := measureSession(t, database, wb, "wt/a")
	id := repoViaSession(t, database, wb, sess, decided)
	prState(t, database, wb, "wt/a", "open", "", now)

	d.coachMeasureCheck(context.Background(), now)
	p := getProposal(t, database, id)
	assert.Equal(t, "too_little_data", p.Verdict, "not merged within repoCommitWait")
	assert.Nil(t, p.VerdictValue)
	assert.True(t, p.MeasureFrom.IsZero())
}

func TestMeasureCheck_RefreshErrorKeepsWaiting(t *testing.T) {
	d, database := coachDaemon(t)
	var logs bytes.Buffer
	d.logger.SetOutput(&logs)
	r := stubRefresh(t, &refreshStub{err: errors.New("gh: not signed in")})
	now := measureNow()
	wb, folder := measureWorkbench(t, database)
	sess := measureSession(t, database, wb, "wt/secret-branch")
	id := repoViaSession(t, database, wb, sess, now.Add(-72*time.Hour))

	require.True(t, d.coachMeasureCheck(context.Background(), now))
	assert.Equal(t, 1, r.calls)
	p := getProposal(t, database, id)
	assert.True(t, p.MeasureFrom.IsZero())
	assert.Empty(t, p.Verdict)
	out := logs.String()
	assert.Contains(t, out, "not refreshed")
	assert.NotContains(t, out, "wt/secret-branch", "ids only in the log")
	assert.NotContains(t, out, folder)

	// Retried on the next check.
	d.coachMeasureCheck(context.Background(), now)
	assert.Equal(t, 2, r.calls)
}

func TestMeasureCheck_SettingsRevertedOutside(t *testing.T) {
	d, database := coachDaemon(t)
	home, err := os.UserHomeDir()
	require.NoError(t, err)
	settings := filepath.Join(home, ".claude", "settings.json")
	require.NoError(t, os.MkdirAll(filepath.Dir(settings), 0o700))
	now := measureNow()
	accepted := func(source string) int64 {
		id, err := database.InsertContextCoachProposal(db.CoachProposal{Fingerprint: "plugin-" + source, Kind: "cut",
			Destination: coach.DestPluginOff, SourceKey: source, Title: "Turn off", Why: "Unused.",
			Metric: "start_tokens", BeforeText: "true", AfterText: "false"}, now)
		require.NoError(t, err)
		require.NoError(t, database.MarkCoachAccepted(id, "false", "", nil, 0, now.Add(-time.Hour)))
		return id
	}
	back, off := accepted("alpha@example-market"), accepted("beta@example-market")
	// A running Claude Code wrote its in-memory copy back: alpha is on again.
	require.NoError(t, os.WriteFile(settings,
		[]byte(`{"enabledPlugins":{"alpha@example-market":true,"beta@example-market":false},"model":"opus"}`), 0o600))

	d.coachMeasureCheck(context.Background(), now)
	p := getProposal(t, database, back)
	assert.Equal(t, "reverted_outside", p.Verdict)
	assert.Equal(t, "accepted", p.Status)
	assert.Empty(t, getProposal(t, database, off).Verdict, "still off: measured as usual")
}

// A settings row the judge left at a provisional too_little_data is still
// checked: the key back on reads reverted_outside, not a later no_effect.
// Any other verdict is final and never looked at again.
func TestMeasureCheck_SettingsRevertedAfterTooLittleData(t *testing.T) {
	d, database := coachDaemon(t)
	home, err := os.UserHomeDir()
	require.NoError(t, err)
	settings := filepath.Join(home, ".claude", "settings.json")
	require.NoError(t, os.MkdirAll(filepath.Dir(settings), 0o700))
	now := measureNow()
	accepted := func(source, verdict string) int64 {
		id, err := database.InsertContextCoachProposal(db.CoachProposal{Fingerprint: "plugin-" + source, Kind: "cut",
			Destination: coach.DestPluginOff, SourceKey: source, Title: "Turn off", Why: "Unused.",
			Metric: "start_tokens", BeforeText: "true", AfterText: "false"}, now)
		require.NoError(t, err)
		require.NoError(t, database.MarkCoachAccepted(id, "false", "", nil, 0, now.Add(-20*24*time.Hour)))
		require.NoError(t, database.SetCoachVerdict(id, verdict, nil, now.Add(-time.Hour)))
		return id
	}
	provisional, final := accepted("alpha@example-market", "too_little_data"), accepted("beta@example-market", "works")
	require.NoError(t, os.WriteFile(settings,
		[]byte(`{"enabledPlugins":{"alpha@example-market":true,"beta@example-market":true}}`), 0o600))

	d.coachMeasureCheck(context.Background(), now)
	assert.Equal(t, "reverted_outside", getProposal(t, database, provisional).Verdict)
	assert.Equal(t, "works", getProposal(t, database, final).Verdict, "a final verdict is not re-checked")
}

// idleSession marks sess's agent as waiting since lastActive.
func idleSession(t *testing.T, database *db.DB, sess int64, lastActive time.Time) {
	t.Helper()
	_, err := database.Exec(`UPDATE terminal_sessions SET agent_state = 'waiting', last_active_at = ? WHERE id = ?`,
		lastActive.UTC().Format("2006-01-02T15:04:05Z"), sess)
	require.NoError(t, err)
}

// A cleanup session never finish_session'ed but idle for an hour or more
// counts as ended at its last activity.
func TestMeasureCheck_MemoryIdleSessionCountsAsEnded(t *testing.T) {
	d, database := coachDaemon(t)
	home, err := os.UserHomeDir()
	require.NoError(t, err)
	now := measureNow()
	wb, folder := measureWorkbench(t, database)
	sess := measureSession(t, database, wb, "")
	id, path := memoryViaSession(t, database, home, wb, folder, sess, now.Add(-5*time.Hour))
	last := now.Add(-2 * time.Hour)
	writeMemory(t, path, measureMemAfter, last.Add(-time.Minute))
	idleSession(t, database, sess, last)

	d.coachMeasureCheck(context.Background(), now)
	p := getProposal(t, database, id)
	assert.True(t, p.MeasureFrom.Equal(last), "measured from the last activity")
	assert.Equal(t, measureMemAfter, p.AfterText)
}

// Idle for 20 minutes is still running: nothing is recorded.
func TestMeasureCheck_MemoryRecentlyActiveNotEnded(t *testing.T) {
	d, database := coachDaemon(t)
	home, err := os.UserHomeDir()
	require.NoError(t, err)
	now := measureNow()
	wb, folder := measureWorkbench(t, database)
	sess := measureSession(t, database, wb, "")
	id, path := memoryViaSession(t, database, home, wb, folder, sess, now.Add(-5*time.Hour))
	last := now.Add(-20 * time.Minute)
	writeMemory(t, path, measureMemAfter, last.Add(-time.Minute))
	idleSession(t, database, sess, last)

	d.coachMeasureCheck(context.Background(), now)
	p := getProposal(t, database, id)
	assert.True(t, p.MeasureFrom.IsZero())
	assert.Empty(t, p.AfterText)
}

// The session row is gone and the index is unchanged at the first check
// that sees it: recorded once as ended without a change; a later write by
// another session's auto-memory is never stamped as the cleanup.
func TestMeasureCheck_MemorySessionRowDeletedUnchangedDecidedOnce(t *testing.T) {
	d, database := coachDaemon(t)
	home, err := os.UserHomeDir()
	require.NoError(t, err)
	now := measureNow()
	wb, folder := measureWorkbench(t, database)
	sess := measureSession(t, database, wb, "")
	id, path := memoryViaSession(t, database, home, wb, folder, sess, now.Add(-3*time.Hour))
	deleteSession(t, database, sess)

	d.coachMeasureCheck(context.Background(), now)
	p := getProposal(t, database, id)
	assert.True(t, p.MeasureFrom.IsZero())
	assert.Equal(t, measureMemBefore, p.AfterText, "ended without a change, decided")

	next := now.Add(24 * time.Hour)
	writeMemory(t, path, measureMemBefore+"- [Gamma](gamma.md) — auto-memory\n", next.Add(-time.Hour))
	d.coachMeasureCheck(context.Background(), next)
	p = getProposal(t, database, id)
	assert.True(t, p.MeasureFrom.IsZero(), "a later write is not the cleanup's")
	assert.Equal(t, measureMemBefore, p.AfterText)
	assert.Empty(t, p.Verdict)
}

// A merge time before the Accept (a reused branch name's older PR) never
// starts the window before the change: measured from the Accept.
func TestMeasureCheck_MergeBeforeAcceptClamped(t *testing.T) {
	d, database := coachDaemon(t)
	stubRefresh(t, &refreshStub{})
	now := measureNow()
	decided := now.Add(-72 * time.Hour)
	wb, _ := measureWorkbench(t, database)
	sess := measureSession(t, database, wb, "wt/a")
	id := repoViaSession(t, database, wb, sess, decided)
	prState(t, database, wb, "wt/a", "merged", decided.Add(-24*time.Hour).Format(time.RFC3339), now)

	d.coachMeasureCheck(context.Background(), now)
	assert.True(t, getProposal(t, database, id).MeasureFrom.Equal(decided))
}

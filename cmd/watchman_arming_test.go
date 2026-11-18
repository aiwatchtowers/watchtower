package cmd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/watchman"
	"watchtower/internal/watchmanact"
)

// armSession inserts a terminal session of workbench wb; kind shell or a
// finished session is never armed.
func armSession(t *testing.T, wb int64, kind string, target any, finished bool) (id int64, folder string) {
	t.Helper()
	var path string
	d := openAgentsTestMain(t, &path)
	folder = t.TempDir()
	var fin any
	if finished {
		fin = "2026-11-01T10:00:00.000Z"
	}
	var sid any // a claude row carries its agent session id
	if kind == "claude" {
		sid = "sid-" + filepath.Base(folder)
	}
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, target_id, folder_path, finished_at, claude_session_id)
		VALUES (?, ?, 'acme', ?, ?, ?, ?)`, wb, kind, target, folder, fin, sid)
	require.NoError(t, err)
	id, err = res.LastInsertId()
	require.NoError(t, err)
	return id, folder
}

func resetWatchmanArmFlags() {
	watchmanArmFlagSession, watchmanArmFlagTarget = 0, 0
	watchmanArmFlagAllRunning, watchmanArmFlagCheck, watchmanArmFlagJSON = false, false, false
	watchmanDisarmFlagSession, watchmanDisarmFlagTarget = 0, 0
	watchmanDisarmFlagAll, watchmanDisarmFlagJSON = false, false
}

func armCLI(t *testing.T, args ...string) (watchmanArmJSON, string, error) {
	t.Helper()
	t.Cleanup(resetWatchmanArmFlags)
	out, err := runWatchman(t, args...)
	resetWatchmanArmFlags()
	var r watchmanArmJSON
	if out != "" && json.Valid([]byte(out)) {
		require.NoError(t, json.Unmarshal([]byte(out), &r))
	}
	return r, out, err
}

func armingRows(t *testing.T) []db.WatchmanArming {
	t.Helper()
	var path string
	d := openAgentsTestMain(t, &path)
	rows, err := d.ListWatchmanArming()
	require.NoError(t, err)
	return rows
}

func testSidecarPath(t *testing.T) string {
	t.Helper()
	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	return watchmanact.SidecarPath(cfg.WorkspaceDir())
}

func readTestSidecar(t *testing.T) watchmanact.Sidecar {
	t.Helper()
	sc, err := watchmanact.ReadSidecar(testSidecarPath(t))
	require.NoError(t, err)
	return sc
}

func TestWatchmanArm_FirstArmTurnsAnalyticsAndLearningOn(t *testing.T) {
	wb, gen := watchmanFixture(t)
	s1, _ := armSession(t, wb, "claude", nil, false)
	s2, _ := armSession(t, wb, "codex", nil, false)

	r, out, err := armCLI(t, "arm", "--session", strconv.FormatInt(s1, 10), "--json")
	require.NoError(t, err, out)
	assert.True(t, r.OK)
	assert.True(t, r.FirstTime)
	assert.True(t, r.AnalyticsTurnedOn)
	assert.True(t, r.LearningStarted)
	enabled, precedents, analytics := watchmanState(t, wb)
	assert.True(t, enabled)
	assert.True(t, analytics)
	assert.Zero(t, precedents, "arm leaves the backfill to the daemon")
	assert.Zero(t, gen.calls, "arm never runs the learning pass")

	// Watchman is on, not learned yet: still the first time, nothing turned on again.
	r, out, err = armCLI(t, "arm", "--session", strconv.FormatInt(s2, 10), "--json")
	require.NoError(t, err, out)
	assert.True(t, r.FirstTime)
	assert.False(t, r.AnalyticsTurnedOn)
	assert.False(t, r.LearningStarted)

	// The text form says the D21 line once.
	require.NoError(t, func() error {
		var path string
		d := openAgentsTestMain(t, &path)
		if err := d.SetWorkbenchAgentAnalytics(wb, false); err != nil {
			return err
		}
		_, err := d.Exec(`DELETE FROM watchman_workbenches WHERE workbench_id = ?`, wb)
		return err
	}())
	_, out, err = armCLI(t, "arm", "--session", strconv.FormatInt(s1, 10))
	require.NoError(t, err, out)
	assert.Contains(t, out, "Agent analytics turned on — Watchman learns from your sessions")
	_, out, err = armCLI(t, "arm", "--session", strconv.FormatInt(s1, 10))
	require.NoError(t, err, out)
	assert.NotContains(t, out, "Agent analytics turned on")
}

func TestWatchmanArm_CheckReportsEstimateOnFirstArm(t *testing.T) {
	wb, gen := watchmanFixture(t)
	s1, _ := armSession(t, wb, "claude", nil, false)
	r, out, err := armCLI(t, "arm", "--session", strconv.FormatInt(s1, 10), "--check", "--json")
	require.NoError(t, err, out)
	assert.True(t, r.OK)
	assert.True(t, r.FirstTime)
	// The same estimate `watchman learn` shows for the workbench.
	var path string
	d := openAgentsTestMain(t, &path)
	est, err := watchman.Estimate(context.Background(), d, watchmanGit, wb)
	require.NoError(t, err)
	require.NotNil(t, r.Estimate)
	assert.Equal(t, watchman.EstimateStatus(est), *r.Estimate)
	assert.Positive(t, r.Estimate.Decisions)
	assert.Zero(t, gen.calls)

	// A learned workbench: not the first time, no estimate.
	require.NoError(t, d.EnableWatchmanWorkbench(wb, time.Now(), 4))
	require.NoError(t, d.MarkWatchmanLearned(wb, time.Now()))
	r, out, err = armCLI(t, "arm", "--session", strconv.FormatInt(s1, 10), "--check", "--json")
	require.NoError(t, err, out)
	assert.False(t, r.FirstTime)
	assert.Nil(t, r.Estimate)
}

func TestWatchmanArm_JSONKeysPinned(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, _ := armSession(t, wb, "claude", nil, false)
	_, out, err := armCLI(t, "arm", "--session", strconv.FormatInt(s1, 10), "--json")
	require.NoError(t, err, out)
	assert.Equal(t, []string{"analytics_turned_on", "armed", "error", "estimate", "first_time", "learning_started", "ok",
		"protection_warning"}, jsonKeys(t, out))
	var raw struct {
		Armed []map[string]json.RawMessage `json:"armed"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &raw))
	require.Len(t, raw.Armed, 1)
	assert.Equal(t, []string{"armed_at", "id", "scope"}, mapKeys(raw.Armed[0]))

	_, out, err = armCLI(t, "arm", "--session", strconv.FormatInt(s1, 10), "--check", "--json")
	require.NoError(t, err, out)
	assert.Equal(t, []string{"analytics_turned_on", "armed", "error", "estimate", "first_time", "learning_started", "ok",
		"protection_warning"}, jsonKeys(t, out))

	_, out, err = armCLI(t, "disarm", "--session", strconv.FormatInt(s1, 10), "--json")
	require.NoError(t, err, out)
	assert.Equal(t, []string{"armed", "error", "ok"}, jsonKeys(t, out))

	// A refused arm still prints its JSON.
	_, out, err = armCLI(t, "arm", "--session", "999", "--json")
	require.Error(t, err)
	assert.Equal(t, []string{"analytics_turned_on", "armed", "error", "estimate", "first_time", "learning_started", "ok",
		"protection_warning"}, jsonKeys(t, out))
}

func TestWatchmanArm_RefusedUnderAgent(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, _ := armSession(t, wb, "claude", nil, false)
	t.Setenv(agentEnvMarkers[0], "1")
	for _, args := range [][]string{
		{"arm", "--session", strconv.FormatInt(s1, 10)},
		{"arm", "--all-running"},
		{"disarm", "--all"},
	} {
		_, _, err := armCLI(t, args...)
		require.Error(t, err, args)
		assert.Contains(t, err.Error(), agentEnvMarkers[0])
	}
	assert.Empty(t, armingRows(t))
	enabled, _, analytics := watchmanState(t, wb)
	assert.False(t, enabled)
	assert.False(t, analytics)
	_, err := os.Stat(testSidecarPath(t))
	assert.ErrorIs(t, err, os.ErrNotExist)
}

func TestWatchmanArm_WritesRowThenSidecar(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, folder := armSession(t, wb, "claude", nil, false)
	r, out, err := armCLI(t, "arm", "--session", strconv.FormatInt(s1, 10), "--json")
	require.NoError(t, err, out)
	rows := armingRows(t)
	require.Len(t, rows, 1)
	assert.Equal(t, "session", rows[0].Scope)
	assert.Equal(t, s1, rows[0].RefID)
	assert.Equal(t, "cli", rows[0].ArmedBy)
	require.Len(t, r.Armed, 1)
	assert.Equal(t, "session", r.Armed[0].Scope)
	assert.Equal(t, s1, r.Armed[0].ID)
	_, err = time.Parse(time.RFC3339, r.Armed[0].ArmedAt)
	require.NoError(t, err)
	assert.Equal(t, watchmanact.Sidecar{Sessions: []int64{s1}, Worktrees: []string{folder}}, readTestSidecar(t))

	// A target: its subtree's sessions and the targets-armed line.
	var path string
	d := openAgentsTestMain(t, &path)
	res, err := d.Exec(`INSERT INTO targets (text, period_start, period_end, project_id) VALUES ('acme', '2026-11-01', '2026-11-30', ?)`, wb)
	require.NoError(t, err)
	target, err := res.LastInsertId()
	require.NoError(t, err)
	s2, folder2 := armSession(t, wb, "claude", target, false)
	_, out, err = armCLI(t, "arm", "--target", strconv.FormatInt(target, 10), "--json")
	require.NoError(t, err, out)
	assert.Equal(t, watchmanact.Sidecar{Sessions: []int64{s1, s2}, Worktrees: []string{folder, folder2}, TargetsArmed: true},
		readTestSidecar(t))
}

func TestWatchmanArm_RefusesWhatCannotBeArmed(t *testing.T) {
	wb, _ := watchmanFixture(t)
	shell, _ := armSession(t, wb, "shell", nil, false)
	done, _ := armSession(t, wb, "claude", nil, true)
	var path string
	d := openAgentsTestMain(t, &path)
	res, err := d.Exec(`INSERT INTO targets (text, period_start, period_end) VALUES ('acme', '2026-11-01', '2026-11-30')`)
	require.NoError(t, err)
	personal, err := res.LastInsertId()
	require.NoError(t, err)
	for _, args := range [][]string{
		{"arm", "--session", strconv.FormatInt(shell, 10)},
		{"arm", "--session", strconv.FormatInt(done, 10)},
		{"arm", "--session", "999"},
		{"arm", "--target", strconv.FormatInt(personal, 10)},
		{"arm", "--target", "999"},
		{"arm"},
		{"arm", "--session", "1", "--all-running"},
	} {
		_, _, err := armCLI(t, args...)
		require.Error(t, err, args)
	}
	assert.Empty(t, armingRows(t))
}

func TestWatchmanArm_CheckWritesNothing(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, _ := armSession(t, wb, "claude", nil, false)
	r, out, err := armCLI(t, "arm", "--session", strconv.FormatInt(s1, 10), "--check", "--json")
	require.NoError(t, err, out)
	assert.Empty(t, r.Armed)
	assert.False(t, r.AnalyticsTurnedOn)
	assert.False(t, r.LearningStarted)
	assert.Empty(t, armingRows(t))
	enabled, _, analytics := watchmanState(t, wb)
	assert.False(t, enabled)
	assert.False(t, analytics)
	_, err = os.Stat(testSidecarPath(t))
	assert.ErrorIs(t, err, os.ErrNotExist)
}

func TestWatchmanDisarm_RemovesRowAndSidecarLine(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, _ := armSession(t, wb, "claude", nil, false)
	s2, folder2 := armSession(t, wb, "claude", nil, false)
	for _, s := range []int64{s1, s2} {
		_, out, err := armCLI(t, "arm", "--session", strconv.FormatInt(s, 10))
		require.NoError(t, err, out)
	}
	r, out, err := armCLI(t, "disarm", "--session", strconv.FormatInt(s1, 10), "--json")
	require.NoError(t, err, out)
	assert.True(t, r.OK)
	require.Len(t, r.Armed, 1)
	assert.Equal(t, s2, r.Armed[0].ID)
	rows := armingRows(t)
	require.Len(t, rows, 1)
	assert.Equal(t, s2, rows[0].RefID)
	assert.Equal(t, watchmanact.Sidecar{Sessions: []int64{s2}, Worktrees: []string{folder2}}, readTestSidecar(t))

	_, out, err = armCLI(t, "disarm", "--all")
	require.NoError(t, err, out)
	assert.Empty(t, armingRows(t))
	assert.Equal(t, watchmanact.Sidecar{}, readTestSidecar(t))
	raw, err := os.ReadFile(testSidecarPath(t))
	require.NoError(t, err)
	assert.Empty(t, raw)
}

func TestWatchmanArm_AllRunningArmsEachLiveSession(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, f1 := armSession(t, wb, "claude", nil, false)
	s2, f2 := armSession(t, wb, "codex", nil, false)
	_, _ = armSession(t, wb, "shell", nil, false)
	_, _ = armSession(t, wb, "claude", nil, true)
	r, out, err := armCLI(t, "arm", "--all-running", "--json")
	require.NoError(t, err, out)
	require.Len(t, r.Armed, 2)
	ids := []int64{r.Armed[0].ID, r.Armed[1].ID}
	assert.ElementsMatch(t, []int64{s1, s2}, ids)
	for _, a := range r.Armed {
		assert.Equal(t, "session", a.Scope)
	}
	assert.True(t, r.AnalyticsTurnedOn)
	sc := readTestSidecar(t)
	assert.Equal(t, []int64{s1, s2}, sc.Sessions)
	assert.Equal(t, []string{f1, f2}, sc.Worktrees)
	assert.Equal(t, filepath.Clean(f1), f1)
}

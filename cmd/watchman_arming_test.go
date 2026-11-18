package cmd

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
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
	watchmanArmFlagOnly = nil
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
	assert.Equal(t, []string{"analytics_turned_on", "armed", "error", "estimate", "first_time", "hooks_warning", "learning_started", "ok",
		"protection_warning", "sessions", "sidecar_error"}, jsonKeys(t, out))
	var raw struct {
		Armed []map[string]json.RawMessage `json:"armed"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &raw))
	require.Len(t, raw.Armed, 1)
	assert.Equal(t, []string{"armed_at", "id", "scope"}, mapKeys(raw.Armed[0]))

	_, out, err = armCLI(t, "arm", "--session", strconv.FormatInt(s1, 10), "--check", "--json")
	require.NoError(t, err, out)
	assert.Equal(t, []string{"analytics_turned_on", "armed", "error", "estimate", "first_time", "hooks_warning", "learning_started", "ok",
		"protection_warning", "sessions", "sidecar_error"}, jsonKeys(t, out))

	_, out, err = armCLI(t, "disarm", "--session", strconv.FormatInt(s1, 10), "--json")
	require.NoError(t, err, out)
	assert.Equal(t, []string{"armed", "error", "ok", "sidecar_error"}, jsonKeys(t, out))

	// A refused arm still prints its JSON.
	_, out, err = armCLI(t, "arm", "--session", "999", "--json")
	require.Error(t, err)
	assert.Equal(t, []string{"analytics_turned_on", "armed", "error", "estimate", "first_time", "hooks_warning", "learning_started", "ok",
		"protection_warning", "sessions", "sidecar_error"}, jsonKeys(t, out))
}

func TestWatchmanArm_RefusedUnderAgent(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, _ := armSession(t, wb, "claude", nil, false)
	t.Setenv(agentEnvMarkers[0], "1")
	for _, args := range [][]string{
		{"arm", "--session", strconv.FormatInt(s1, 10)},
		{"arm", "--all-running"},
		{"disarm", "--all"},
		{"disarm", "--session", strconv.FormatInt(s1, 10)},
		{"disarm", "--target", "1"},
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

	// --check only reads: it stays open under an agent.
	r, out, err := armCLI(t, "arm", "--session", strconv.FormatInt(s1, 10), "--check", "--json")
	require.NoError(t, err, out)
	assert.True(t, r.OK)
	assert.True(t, r.FirstTime)
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

// TestWatchmanArm_AllRunningOnlyArmsTheConfirmedSet: --check reports the
// sessions it covers; --only arms just those, so a session started after
// the owner saw the sheet is left out.
func TestWatchmanArm_AllRunningOnlyArmsTheConfirmedSet(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, _ := armSession(t, wb, "claude", nil, false)
	r, out, err := armCLI(t, "arm", "--all-running", "--check", "--json")
	require.NoError(t, err, out)
	assert.Equal(t, []int64{s1}, r.Sessions)
	s2, _ := armSession(t, wb, "claude", nil, false) // started while the sheet is open
	r, out, err = armCLI(t, "arm", "--all-running", "--only", strconv.FormatInt(s1, 10), "--json")
	require.NoError(t, err, out)
	assert.Equal(t, []int64{s1}, r.Sessions)
	rows := armingRows(t)
	require.Len(t, rows, 1)
	assert.Equal(t, s1, rows[0].RefID)
	assert.NotEqual(t, s2, rows[0].RefID)

	_, out, err = armCLI(t, "arm", "--session", strconv.FormatInt(s2, 10), "--only", "1", "--json")
	require.Error(t, err, out)
	assert.Contains(t, out, "--only goes with --all-running")
}

// countArmingNudges replaces the daemon nudge with a counter.
func countArmingNudges(t *testing.T) *int {
	t.Helper()
	n := 0
	prev := watchmanArmingNudge
	watchmanArmingNudge = func(*cobra.Command, *config.Config) { n++ }
	t.Cleanup(func() { watchmanArmingNudge = prev })
	return &n
}

// Every arming change nudges the daemon, so its upkeep takes or releases
// the keep-awake hold now; a call that changed nothing does not.
func TestWatchmanArm_NudgesDaemonOnEveryChange(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, _ := armSession(t, wb, "claude", nil, false)
	nudges := countArmingNudges(t)
	id := strconv.FormatInt(s1, 10)
	steps := []struct {
		args []string
		want int
	}{
		{[]string{"arm", "--session", id, "--check"}, 0},
		{[]string{"arm", "--session", id}, 1},
		{[]string{"arm", "--session", id}, 1}, // already armed: no change
		{[]string{"disarm", "--session", id}, 2},
		{[]string{"disarm", "--all"}, 2}, // nothing left: no change
		{[]string{"arm", "--all-running"}, 3},
		{[]string{"disarm", "--all"}, 4},
	}
	for _, st := range steps {
		_, out, err := armCLI(t, st.args...)
		require.NoError(t, err, out)
		assert.Equal(t, st.want, *nudges, st.args)
	}
}

// --check never creates or migrates the database.
func TestWatchmanArm_CheckNeverCreatesTheDatabase(t *testing.T) {
	d := writeActionsConfig(t)
	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	require.NoError(t, d.Close())
	for _, suffix := range []string{"", "-wal", "-shm"} {
		require.NoError(t, os.RemoveAll(cfg.DBPath()+suffix))
	}
	r, out, err := armCLI(t, "arm", "--session", "1", "--check", "--json")
	require.Error(t, err)
	assert.False(t, r.OK, out)
	_, err = os.Stat(cfg.DBPath())
	assert.ErrorIs(t, err, os.ErrNotExist)
}

// Re-arming an armed session keeps its armed_at ("Sleep since" stays).
func TestWatchmanArm_RearmKeepsArmedAt(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, _ := armSession(t, wb, "claude", nil, false)
	var path string
	d := openAgentsTestMain(t, &path)
	at := time.Date(2026, 11, 17, 23, 40, 0, 0, time.UTC)
	require.NoError(t, d.UpsertWatchmanArming(db.WatchmanArming{Scope: "session", RefID: s1, ArmedAt: at, ArmedBy: "desktop"}))
	r, out, err := armCLI(t, "arm", "--session", strconv.FormatInt(s1, 10), "--json")
	require.NoError(t, err, out)
	require.Len(t, r.Armed, 1)
	assert.Equal(t, at.Format(time.RFC3339), r.Armed[0].ArmedAt)
	rows := armingRows(t)
	require.Len(t, rows, 1)
	assert.True(t, rows[0].ArmedAt.Equal(at))
	assert.Equal(t, "desktop", rows[0].ArmedBy)
}

// A sidecar that cannot be rewritten after the rows were written: ok, with
// sidecar_error (the rows exist; the daemon's upkeep rewrites it).
func TestWatchmanArm_SidecarFailureStillOK(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, _ := armSession(t, wb, "claude", nil, false)
	// A non-empty directory where the sidecar goes: the rename over it fails.
	require.NoError(t, os.MkdirAll(filepath.Join(testSidecarPath(t), "x"), 0o755))
	r, out, err := armCLI(t, "arm", "--session", strconv.FormatInt(s1, 10), "--json")
	require.NoError(t, err, out)
	assert.True(t, r.OK)
	assert.Empty(t, r.Error)
	assert.NotEmpty(t, r.SidecarError)
	require.Len(t, r.Armed, 1)
	assert.Len(t, armingRows(t), 1)

	var d watchmanDisarmJSON
	_, out, err = armCLI(t, "disarm", "--session", strconv.FormatInt(s1, 10), "--json")
	require.NoError(t, err, out)
	require.NoError(t, json.Unmarshal([]byte(out), &d))
	assert.True(t, d.OK)
	assert.NotEmpty(t, d.SidecarError)
	assert.Empty(t, armingRows(t))
}

// The sidecar's lock cannot be taken (refresh returns no rows): the arm
// still says ok with sidecar_error, lists the rows and nudges the daemon.
func TestWatchmanArm_SidecarLockFailureStillOK(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, _ := armSession(t, wb, "claude", nil, false)
	nudges := countArmingNudges(t)
	// A directory where the lock file goes: it cannot be opened for writing.
	require.NoError(t, os.MkdirAll(testSidecarPath(t)+".lock", 0o755))
	r, out, err := armCLI(t, "arm", "--session", strconv.FormatInt(s1, 10), "--json")
	require.NoError(t, err, out)
	assert.True(t, r.OK)
	assert.Contains(t, r.SidecarError, "lock")
	require.Len(t, r.Armed, 1)
	assert.Equal(t, s1, r.Armed[0].ID)
	assert.Equal(t, 1, *nudges)
}

// gitRepoSession makes an armable session whose folder is a git repository
// (the developer's global git config kept out).
func gitRepoSession(t *testing.T, wb int64) (id int64, folder string) {
	t.Helper()
	t.Setenv("GIT_CONFIG_GLOBAL", filepath.Join(t.TempDir(), "gitconfig"))
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	id, folder = armSession(t, wb, "claude", nil, false)
	out, err := exec.Command("git", "init", "-q", folder).CombinedOutput()
	require.NoError(t, err, string(out))
	return id, folder
}

// worktreeHooksPath is the folder's worktree-level core.hooksPath; "" = unset.
func worktreeHooksPath(t *testing.T, folder string) string {
	t.Helper()
	out, err := exec.Command("git", "-C", folder, "config", "--worktree", "--get", "core.hooksPath").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func testHooksDir(t *testing.T) string {
	t.Helper()
	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	return watchmanact.HooksDir(cfg.WorkspaceDir())
}

// withFakeGh puts a gh on PATH that names main the default branch and
// answers its protection: "unprotected" is GitHub's 404, "protected"
// requires an approving review with admins enforced.
func withFakeGh(t *testing.T, mode string) {
	t.Helper()
	dir := t.TempDir()
	script := `#!/bin/sh
case $* in
*"--jq .default_branch") echo main ;;
*/protection)
	if [ "` + mode + `" = protected ]; then
		echo '{"required_pull_request_reviews":{"required_approving_review_count":1},"enforce_admins":{"enabled":true}}'
	else
		echo '{"message":"Branch not protected","status":"404"}'
		exit 1
	fi
	;;
*) exit 2 ;;
esac
`
	require.NoError(t, os.WriteFile(filepath.Join(dir, "gh"), []byte(script), 0o755)) // #nosec G306 -- an executable fake
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	prev := watchmanProtectionRun
	watchmanProtectionRun = execCommandOutput
	t.Cleanup(func() { watchmanProtectionRun = prev })
}

func TestWatchmanArm_InstallsHooks(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, folder := gitRepoSession(t, wb)
	_, out, err := armCLI(t, "arm", "--session", strconv.FormatInt(s1, 10))
	require.NoError(t, err, out)
	assert.Equal(t, testHooksDir(t), worktreeHooksPath(t, folder))
	for _, name := range watchmanact.ClientHookNames {
		assert.FileExists(t, filepath.Join(testHooksDir(t), name))
	}
	// --check installs nothing.
	s2, folder2 := gitRepoSession(t, wb)
	_, out, err = armCLI(t, "arm", "--session", strconv.FormatInt(s2, 10), "--check")
	require.NoError(t, err, out)
	assert.Empty(t, worktreeHooksPath(t, folder2))
}

func TestWatchmanArm_ProtectionWarningInJSON(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, _ := armSession(t, wb, "claude", nil, false)
	withFakeGh(t, "unprotected")
	for _, check := range []bool{true, false} {
		args := []string{"arm", "--session", strconv.FormatInt(s1, 10), "--json"}
		if check {
			args = append(args, "--check")
		}
		r, out, err := armCLI(t, args...)
		require.NoError(t, err, out)
		assert.Equal(t, "main is not protected on GitHub — an agent's gh pr merge cannot be stopped here", r.ProtectionWarning, "check=%v", check)
	}
	// Text mode says it too.
	out, err := runWatchman(t, "arm", "--session", strconv.FormatInt(s1, 10), "--check")
	resetWatchmanArmFlags()
	require.NoError(t, err, out)
	assert.Contains(t, out, "main is not protected on GitHub")

	withFakeGh(t, "protected")
	r, out, err := armCLI(t, "arm", "--session", strconv.FormatInt(s1, 10), "--check", "--json")
	require.NoError(t, err, out)
	assert.Empty(t, r.ProtectionWarning)
}

func TestWatchmanDisarm_RestoresHooks(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, folder1 := gitRepoSession(t, wb)
	s2, folder2 := gitRepoSession(t, wb)
	for _, s := range []int64{s1, s2} {
		_, out, err := armCLI(t, "arm", "--session", strconv.FormatInt(s, 10))
		require.NoError(t, err, out)
	}
	require.Equal(t, testHooksDir(t), worktreeHooksPath(t, folder1))

	_, out, err := armCLI(t, "disarm", "--session", strconv.FormatInt(s1, 10))
	require.NoError(t, err, out)
	assert.Empty(t, worktreeHooksPath(t, folder1), "the disarmed worktree kept Watchman's hooks")
	assert.Equal(t, testHooksDir(t), worktreeHooksPath(t, folder2), "a still-armed worktree lost its hooks")

	_, out, err = armCLI(t, "disarm", "--all")
	require.NoError(t, err, out)
	assert.Empty(t, worktreeHooksPath(t, folder2))
}

// setSessionFolder points a session at folder.
func setSessionFolder(t *testing.T, id int64, folder string) {
	t.Helper()
	var path string
	_, err := openAgentsTestMain(t, &path).Exec(`UPDATE terminal_sessions SET folder_path = ? WHERE id = ?`, folder, id)
	require.NoError(t, err)
}

// Two sessions on one worktree by different paths: disarming one keeps the
// other's guard.
func TestWatchmanDisarm_KeepsHooksOfAnotherSessionOnTheSameWorktree(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, folder := gitRepoSession(t, wb)
	s2, _ := armSession(t, wb, "claude", nil, false)
	link := filepath.Join(t.TempDir(), "same-worktree")
	require.NoError(t, os.Symlink(folder, link))
	setSessionFolder(t, s2, link)
	for _, s := range []int64{s1, s2} {
		_, out, err := armCLI(t, "arm", "--session", strconv.FormatInt(s, 10))
		require.NoError(t, err, out)
	}
	_, out, err := armCLI(t, "disarm", "--session", strconv.FormatInt(s1, 10))
	require.NoError(t, err, out)
	assert.Equal(t, testHooksDir(t), worktreeHooksPath(t, folder), "the still-armed session lost its guard")
	_, out, err = armCLI(t, "disarm", "--session", strconv.FormatInt(s2, 10))
	require.NoError(t, err, out)
	assert.Empty(t, worktreeHooksPath(t, folder))
}

// A shared core.worktree: no extension, no hooks, and the arm says so.
func TestWatchmanArm_HooksWarningForUnsupportedLayout(t *testing.T) {
	wb, _ := watchmanFixture(t)
	s1, _ := gitRepoSession(t, wb)
	var path string
	w, err := openAgentsTestMain(t, &path).GetWorkbench(wb)
	require.NoError(t, err)
	repo := w.FolderPath
	out, gerr := exec.Command("git", "init", "-q", repo).CombinedOutput()
	require.NoError(t, gerr, string(out))
	out, gerr = exec.Command("git", "-C", repo, "config", "core.worktree", repo).CombinedOutput()
	require.NoError(t, gerr, string(out))
	setSessionFolder(t, s1, repo)
	want := "Watchman's git guard cannot be installed in " + repo + ": shared core.worktree/core.bare — the other layers still apply"
	for _, check := range []bool{true, false} {
		args := []string{"arm", "--session", strconv.FormatInt(s1, 10), "--json"}
		if check {
			args = append(args, "--check")
		}
		r, raw, err := armCLI(t, args...)
		require.NoError(t, err, raw)
		assert.True(t, r.OK)
		assert.Equal(t, want, r.HooksWarning, "check=%v", check)
	}
	assert.Empty(t, worktreeHooksPath(t, repo))
	_, gerr = exec.Command("git", "-C", repo, "config", "--get", "extensions.worktreeConfig").Output()
	assert.Error(t, gerr, "the extension was enabled")
	text, err := runWatchman(t, "arm", "--session", strconv.FormatInt(s1, 10), "--check")
	resetWatchmanArmFlags()
	require.NoError(t, err, text)
	assert.Contains(t, text, want)
}

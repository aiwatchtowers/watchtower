package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/fsutil"
	"watchtower/internal/instructions"
	"watchtower/internal/sessionfeed"
	"watchtower/internal/watchman"
)

// watchmanLabelGen answers every label call with one category per item, or
// fails with err.
type watchmanLabelGen struct {
	calls int
	err   error
}

func (g *watchmanLabelGen) Generate(_ context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	g.calls++
	if g.err != nil {
		return "", nil, "", g.err
	}
	return `[{"category": "scope", "decision": true, "parked": false}]`, &digest.Usage{}, "", nil
}

// watchmanFixture is a workbench with one answered question ask (it needs a
// label), no git repository and no transcripts; the generator and git are
// fakes.
func watchmanFixture(t *testing.T) (int64, *watchmanLabelGen) {
	t.Helper()
	wb := agentsFixture(t)
	var path string
	d := openAgentsTestMain(t, &path)
	_, err := d.Exec(`INSERT INTO owner_asks (project_id, kind, title, payload, status, answer, answered_at)
		VALUES (?, 'question', 'Pick a cache',
			'{"focus":[],"questions":[{"id":"q1","question":"Which cache?","options":[{"label":"sqlite"},{"label":"redis"}]}],"checklist":[]}',
			'answered', '{"answers":[{"id":"q1","labels":["sqlite"],"other":""}],"checklist":[],"comments":[],"note":"","verdict":""}',
			'2026-11-01T09:00:00Z')`, wb)
	require.NoError(t, err)
	gen := &watchmanLabelGen{}
	prevGen, prevGit, prevFeed := watchmanGeneratorFactory, watchmanGit, watchmanFeedReader
	watchmanGeneratorFactory = func(*config.Config) digest.Generator { return gen }
	watchmanGit = func(context.Context, string, ...string) ([]byte, error) { return []byte("3\n"), nil }
	watchmanFeedReader = func(context.Context, *db.DB) instructions.FeedReader {
		return func(db.RecentWorkbenchSession) ([]sessionfeed.Entry, error) { return nil, nil }
	}
	t.Cleanup(func() { watchmanGeneratorFactory, watchmanGit, watchmanFeedReader = prevGen, prevGit, prevFeed })
	return wb, gen
}

func runWatchman(t *testing.T, args ...string) (string, error) {
	t.Helper()
	t.Cleanup(func() {
		watchmanFlagWorkbench, watchmanFlagStart, watchmanFlagJSON = 0, false, false
		watchmanStatusFlagWorkbench, watchmanStatusFlagJSON = 0, false
		rootCmd.SetArgs(nil)
	})
	var out, errOut bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errOut)
	rootCmd.SetArgs(append([]string{"watchman"}, args...))
	err := rootCmd.Execute()
	watchmanFlagWorkbench, watchmanFlagStart, watchmanFlagJSON = 0, false, false
	watchmanStatusFlagWorkbench, watchmanStatusFlagJSON = 0, false
	return out.String(), err
}

func watchmanState(t *testing.T, wb int64) (enabled bool, precedents int, analytics bool) {
	t.Helper()
	var path string
	d := openAgentsTestMain(t, &path)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM watchman_workbenches WHERE workbench_id = ?`, wb).Scan(&n))
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM watchman_precedents WHERE workbench_id = ?`, wb).Scan(&precedents))
	on, err := d.WorkbenchAgentAnalytics(wb)
	require.NoError(t, err)
	return n == 1, precedents, on
}

func TestWatchmanLearn_NoStartOnlyEstimates(t *testing.T) {
	wb, gen := watchmanFixture(t)
	out, err := runWatchman(t, "learn", "--workbench", strconv.FormatInt(wb, 10))
	require.NoError(t, err)
	assert.Contains(t, out, "~4 decisions") // 1 ask + 3 commits, no sessions
	assert.Contains(t, out, "--start")
	enabled, precedents, analytics := watchmanState(t, wb)
	assert.False(t, enabled)
	assert.Zero(t, precedents)
	assert.False(t, analytics)
	assert.Zero(t, gen.calls)
}

func TestWatchmanLearn_EstimateKeysPinned(t *testing.T) {
	wb, _ := watchmanFixture(t)
	out, err := runWatchman(t, "learn", "--workbench", strconv.FormatInt(wb, 10), "--json")
	require.NoError(t, err)
	assert.Equal(t, []string{"decisions", "need_labels", "ok", "tokens", "workbench"}, jsonKeys(t, out))
	var r watchmanEstimateJSON
	require.NoError(t, json.Unmarshal([]byte(out), &r))
	assert.Equal(t, watchmanEstimateJSON{OK: true, Workbench: wb, Decisions: 4, NeedLabels: 4, Tokens: 4 * 350}, r)
}

func TestWatchmanLearn_JSONKeysPinned(t *testing.T) {
	wb, gen := watchmanFixture(t)
	out, err := runWatchman(t, "learn", "--workbench", strconv.FormatInt(wb, 10), "--start", "--json")
	require.NoError(t, err)
	assert.Equal(t, []string{"analytics_turned_on", "by_source", "incomplete", "ok", "unlabelled", "workbench", "written"}, jsonKeys(t, out))
	var r watchmanLearnJSON
	require.NoError(t, json.Unmarshal([]byte(out), &r))
	assert.Equal(t, watchmanLearnJSON{OK: true, Workbench: wb, Written: 1,
		BySource: map[string]int{"ask": 1, "review": 0, "spec": 0, "permission": 0, "turn": 0, "git": 0}, AnalyticsTurnedOn: true}, r)
	assert.Equal(t, 1, gen.calls)
	enabled, precedents, analytics := watchmanState(t, wb)
	assert.True(t, enabled)
	assert.Equal(t, 1, precedents)
	assert.True(t, analytics)

	// Analytics is already on: not turned on again.
	out, err = runWatchman(t, "learn", "--workbench", strconv.FormatInt(wb, 10), "--start", "--json")
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal([]byte(out), &r))
	assert.False(t, r.AnalyticsTurnedOn)
	assert.Zero(t, r.Written)
}

func TestWatchmanLearn_StartSaysAnalyticsOnce(t *testing.T) {
	wb, _ := watchmanFixture(t)
	out, err := runWatchman(t, "learn", "--workbench", strconv.FormatInt(wb, 10), "--start")
	require.NoError(t, err)
	assert.Equal(t, 1, strings.Count(out, "Agent analytics turned on — Watchman learns from your sessions"))
	out, err = runWatchman(t, "learn", "--workbench", strconv.FormatInt(wb, 10), "--start")
	require.NoError(t, err)
	assert.NotContains(t, out, "Agent analytics turned on")
}

func TestWatchmanLearn_RefusedUnderAgent(t *testing.T) {
	wb, gen := watchmanFixture(t)
	t.Setenv(agentEnvMarkers[0], "1")
	_, err := runWatchman(t, "learn", "--workbench", strconv.FormatInt(wb, 10), "--start")
	require.Error(t, err)
	assert.Contains(t, err.Error(), agentEnvMarkers[0])
	enabled, precedents, analytics := watchmanState(t, wb)
	assert.False(t, enabled)
	assert.Zero(t, precedents)
	assert.False(t, analytics)
	assert.Zero(t, gen.calls)

	// The estimate only reads: it stays open.
	_, err = runWatchman(t, "learn", "--workbench", strconv.FormatInt(wb, 10))
	require.NoError(t, err)
}

// A failed first pass still tells the owner Watchman and analytics are on.
func TestWatchmanLearn_FailureSaysWatchmanIsOn(t *testing.T) {
	wb, gen := watchmanFixture(t)
	gen.err = errors.New("provider unavailable")
	out, err := runWatchman(t, "learn", "--workbench", strconv.FormatInt(wb, 10), "--start")
	require.Error(t, err)
	assert.Contains(t, out, "Watchman and Agent analytics are on for workbench")

	out, err = runWatchman(t, "learn", "--workbench", strconv.FormatInt(wb, 10), "--start", "--json")
	require.Error(t, err)
	assert.Equal(t, []string{"analytics_on", "analytics_turned_on", "error", "ok", "watchman_on", "workbench"}, jsonKeys(t, out))
	var r watchmanLearnFailureJSON
	require.NoError(t, json.Unmarshal([]byte(out), &r))
	assert.False(t, r.OK)
	assert.True(t, r.WatchmanOn)
	assert.True(t, r.AnalyticsOn)
	enabled, _, analytics := watchmanState(t, wb)
	assert.True(t, enabled)
	assert.True(t, analytics)
}

func TestWatchmanStatus_JSONKeysPinned(t *testing.T) {
	wb, _ := watchmanFixture(t)
	t.Setenv(agentEnvMarkers[0], "1") // a read verb: allowed under an agent
	out, err := runWatchman(t, "status", "--json")
	require.NoError(t, err)
	assert.Equal(t, []string{"armed", "daemon_running", "mode", "mode_since", "ok", "workbenches"}, jsonKeys(t, out))
	var raw struct {
		Workbenches []map[string]json.RawMessage `json:"workbenches"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &raw))
	require.Len(t, raw.Workbenches, 1)
	assert.Equal(t, []string{"analytics_on", "backtest", "enabled_at", "estimate", "last_done", "learning", "name", "precedents",
		"running", "sleep_window", "sleep_window_pinned", "sources", "workbench"}, mapKeys(raw.Workbenches[0]))
	assert.Equal(t, "null", string(raw.Workbenches[0]["enabled_at"]))
	assert.Equal(t, "null", string(raw.Workbenches[0]["learning"]))
	var est map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(raw.Workbenches[0]["estimate"], &est))
	assert.Equal(t, []string{"decisions", "need_labels", "tokens"}, mapKeys(est))

	// Learning turned on: learning replaces the estimate; a backtest has its keys.
	t.Setenv(agentEnvMarkers[0], "")
	_, err = runWatchman(t, "learn", "--workbench", strconv.FormatInt(wb, 10), "--start")
	require.NoError(t, err)
	var path string
	d := openAgentsTestMain(t, &path)
	_, err = d.InsertWatchmanBacktest(db.WatchmanBacktest{WorkbenchID: wb, StartedAt: time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC),
		Status: "running", Rows: []db.WatchmanBacktestRow{{Category: "scope", Status: "not_measured"}}})
	require.NoError(t, err)
	out, err = runWatchman(t, "status", "--workbench", strconv.FormatInt(wb, 10), "--json")
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal([]byte(out), &raw))
	w := raw.Workbenches[0]
	assert.Equal(t, "null", string(w["estimate"]))
	var learning, bt map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(w["learning"], &learning))
	assert.Equal(t, []string{"done", "estimated", "relabel_pending", "written"}, mapKeys(learning))
	require.NoError(t, json.Unmarshal(w["backtest"], &bt))
	assert.Equal(t, []string{"categories", "cost_usd", "error", "finished_at", "id", "progress", "started_at", "status", "verdict"}, mapKeys(bt))
	assert.JSONEq(t, `"interrupted"`, string(bt["status"]))
	var cats []map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(bt["categories"], &cats))
	require.Len(t, cats, 1)
	assert.Equal(t, []string{"acceptable", "agree", "bad", "baseline", "category", "cost_usd", "handed", "rec_baseline", "status", "total",
		"wrong_high"}, mapKeys(cats[0]))
	var src map[string]map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(w["sources"], &src))
	assert.Equal(t, []string{"done", "written"}, mapKeys(src["ask"]))
}

func TestWatchmanStatus_RunningWhileLocked(t *testing.T) {
	wb, _ := watchmanFixture(t)
	args := []string{"status", "--workbench", strconv.FormatInt(wb, 10), "--json"}
	var r watchman.StatusReport
	out, err := runWatchman(t, args...)
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal([]byte(out), &r))
	assert.False(t, r.Workbenches[0].Running)

	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	unlock, ok, err := fsutil.TryLockFile(watchman.LockPath(cfg.WorkspaceDir()))
	require.NoError(t, err)
	require.True(t, ok)
	defer unlock()
	out, err = runWatchman(t, args...)
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal([]byte(out), &r))
	assert.True(t, r.Workbenches[0].Running)

	out, err = runWatchman(t, "status")
	require.NoError(t, err)
	assert.Contains(t, out, "Watchman is off; ~4 decisions to learn from.")
}

func TestStatus_TextShowsRelabelLeft(t *testing.T) {
	wb, _ := watchmanFixture(t)
	_, err := runWatchman(t, "learn", "--workbench", strconv.FormatInt(wb, 10), "--start")
	require.NoError(t, err)
	out, err := runWatchman(t, "status", "--workbench", strconv.FormatInt(wb, 10))
	require.NoError(t, err)
	assert.NotContains(t, out, "relabelling earlier decisions", "nothing pending: no line")

	var path string
	d := openAgentsTestMain(t, &path)
	_, err = d.Exec(`UPDATE watchman_precedents SET flags_at = NULL WHERE workbench_id = ?`, wb)
	require.NoError(t, err)
	out, err = runWatchman(t, "status", "--workbench", strconv.FormatInt(wb, 10))
	require.NoError(t, err)
	assert.Contains(t, out, "relabelling earlier decisions: 1 left")
}

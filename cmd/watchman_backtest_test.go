package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
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
	"watchtower/internal/prompts"
	"watchtower/internal/watchman"
)

// watchmanBacktestGen answers the profile with one rule and every decision
// as the owner did: "deny" for an rm -rf, else "allow".
type watchmanBacktestGen struct{ calls int }

func (g *watchmanBacktestGen) Generate(ctx context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	g.calls++
	if src, _ := digest.SourceFromContext(ctx); src == prompts.WatchmanProfile {
		return `{"rules":["Allows reads in the repository"]}`, &digest.Usage{}, "", nil
	}
	choice := "allow"
	if strings.Contains(user, "rm -rf") {
		choice = "deny"
	}
	return `{"choice":"` + choice + `","rationale":"r","precedent_ids":[],"confidence":"high","category":"permission","importance":"low"}`,
		&digest.Usage{}, "", nil
}

// watchmanBacktestFixture is a workbench with 30 permission precedents (the
// rest of the categories are not measured) and a fake generator; it returns
// the workbench, the generator and the workspace folder.
func watchmanBacktestFixture(t *testing.T) (int64, *watchmanBacktestGen, string) {
	t.Helper()
	wb := agentsFixture(t)
	var path string
	d := openAgentsTestMain(t, &path)
	tx, err := d.Begin()
	require.NoError(t, err)
	var ps []db.WatchmanPrecedent
	for i := 0; i < watchman.HiddenPerCategory; i++ {
		situation, choice := "Tool: Bash go test "+strconv.Itoa(i), "allow"
		if i%3 == 0 { // a third denied: the base rate is 2/3
			situation, choice = "Tool: Bash rm -rf build"+strconv.Itoa(i), "deny"
		}
		ps = append(ps, db.WatchmanPrecedent{WorkbenchID: wb, Source: "permission", SourceKey: fmt.Sprint(i + 1),
			Category: "permission", Situation: situation, Choice: choice,
			DecidedAt: time.Date(2026, 10, 1, i, 0, 0, 0, time.UTC), Weight: 1})
	}
	require.NoError(t, d.UpsertWatchmanPrecedents(tx, ps))
	require.NoError(t, tx.Commit())
	require.NoError(t, d.EnableWatchmanWorkbench(wb, time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC), 30))
	require.NoError(t, d.MarkWatchmanLearned(wb, time.Date(2026, 10, 2, 0, 0, 0, 0, time.UTC)))
	gen := &watchmanBacktestGen{}
	prev := watchmanGeneratorFactory
	watchmanGeneratorFactory = func(*config.Config) digest.Generator { return gen }
	t.Cleanup(func() { watchmanGeneratorFactory = prev })
	return wb, gen, filepath.Dir(path)
}

func runWatchmanBacktestCmd(t *testing.T, wb int64, extra ...string) (string, error) {
	t.Helper()
	reset := func() {
		watchmanBacktestFlagWorkbench, watchmanBacktestFlagJSON, watchmanBacktestFlagForce = 0, false, false
		rootCmd.SetArgs(nil)
	}
	t.Cleanup(reset)
	var out, errOut bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errOut)
	rootCmd.SetArgs(append([]string{"watchman", "backtest", "--workbench", strconv.FormatInt(wb, 10)}, extra...))
	err := rootCmd.Execute()
	reset()
	return out.String(), err
}

func TestWatchmanBacktest_JSONKeysPinned(t *testing.T) {
	wb, gen, dir := watchmanBacktestFixture(t)
	out, err := runWatchmanBacktestCmd(t, wb, "--json")
	require.NoError(t, err)
	assert.Equal(t, []string{"backtest_id", "categories", "cost_usd", "ok", "report_error", "report_path", "status", "verdict", "workbench"},
		jsonKeys(t, out))
	var raw struct {
		Categories []map[string]any `json:"categories"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &raw))
	require.Len(t, raw.Categories, len(watchman.Categories))
	keys := make([]string, 0)
	for k := range raw.Categories[0] {
		keys = append(keys, k)
	}
	assert.ElementsMatch(t, []string{"category", "total", "agree", "acceptable", "bad", "wrong_high", "cost_usd", "baseline",
		"rec_baseline", "status", "handed"}, keys)
	var r watchmanBacktestJSON
	require.NoError(t, json.Unmarshal([]byte(out), &r))
	assert.True(t, r.OK)
	assert.Equal(t, wb, r.Workbench)
	assert.Positive(t, r.BacktestID)
	assert.Equal(t, "done", r.Status)
	assert.Equal(t, "stop", r.Verdict, "one strong category is not go")
	var dbPath string
	b, _, err := openAgentsTestMain(t, &dbPath).WatchmanBacktestByID(wb, r.BacktestID)
	require.NoError(t, err)
	require.NotNil(t, b)
	assert.Equal(t, watchman.BacktestReportPath(dir, r.BacktestID, b.StartedAt), r.ReportPath, "the run report lives in the workspace folder")
	assert.Empty(t, r.ReportError)
	assert.FileExists(t, r.ReportPath)
	for _, c := range r.Categories {
		if c.Category == "permission" {
			assert.InDelta(t, 2.0/3, c.Baseline, 1e-9)
			c.Baseline = 0
			assert.Equal(t, watchmanBacktestRowJSON{Category: "permission", Total: 30, Agree: 30, Status: "strong"}, c)
		} else {
			assert.Equal(t, "not_measured", c.Status, c.Category)
		}
	}
	assert.Equal(t, 30, gen.calls) // 30 decisions; nothing older for a profile, no judge for allow/deny

	assert.False(t, readStampFile(t, watchman.BacktestStampPath(dir, wb)).IsZero(), "a finished run stamps the week")

	out, err = runWatchmanBacktestCmd(t, wb)
	require.NoError(t, err)
	assert.Contains(t, out, "permission   strong: 30 same / 0 acceptable / 0 bad (0 bad while sure) · 0 handed · recommended-pick 0 % (~$0.00)")
	assert.Contains(t, out, "Review approvals, hunk undos, merges and your own rewrites are not measured in phase 1")
	assert.Contains(t, out, "review_code is measured on your review comments only")
	assert.Contains(t, out, "Verdict: stop (cost ~$0.00, an estimate")
	lines := strings.Split(strings.TrimSpace(out), "\n")
	last := lines[len(lines)-1]
	assert.True(t, strings.HasPrefix(last, "Report: "+filepath.Join(dir, "watchman", fmt.Sprintf("backtest-%d-", r.BacktestID+1))) &&
		strings.HasSuffix(last, ".jsonl"), "the text output ends with the report path: %q", out)
}

// TestWatchmanBacktest_ReportErrorShown: a report that cannot be written
// leaves report_path empty and report_error set; the run is kept.
func TestWatchmanBacktest_ReportErrorShown(t *testing.T) {
	wb, _, dir := watchmanBacktestFixture(t)
	require.NoError(t, os.WriteFile(filepath.Join(dir, "watchman"), []byte("not a folder"), 0o600))
	out, err := runWatchmanBacktestCmd(t, wb, "--json")
	require.NoError(t, err)
	var r watchmanBacktestJSON
	require.NoError(t, json.Unmarshal([]byte(out), &r))
	assert.Equal(t, "done", r.Status)
	assert.Empty(t, r.ReportPath)
	assert.Contains(t, r.ReportError, "writing the backtest report")

	out, err = runWatchmanBacktestCmd(t, wb)
	require.NoError(t, err)
	assert.Contains(t, out, "Report not written: writing the backtest report")
}

func readStampFile(t *testing.T, path string) time.Time {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		return time.Time{}
	}
	n, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	require.NoError(t, err)
	return time.Unix(n, 0)
}

func TestLaunchWatchmanBacktest_MissingBinary(t *testing.T) {
	logs := filepath.Join(t.TempDir(), "logs")
	err := LaunchWatchmanBacktest(filepath.Join(t.TempDir(), "no-such-binary"), 7, "acme", "", logs)
	require.ErrorContains(t, err, "starting the backtest")
	_, statErr := os.Stat(filepath.Join(logs, "watchman-backtest.log"))
	require.NoError(t, statErr)
}

func TestWatchmanBacktest_BusyLock(t *testing.T) {
	wb, gen, dir := watchmanBacktestFixture(t)
	unlock, ok, err := fsutil.TryLockFile(watchman.LockPath(dir))
	require.NoError(t, err)
	require.True(t, ok)
	defer unlock()
	out, err := runWatchmanBacktestCmd(t, wb, "--json")
	require.Error(t, err)
	assert.JSONEq(t, `{"ok":false,"error":"busy"}`, strings.TrimSpace(out))
	assert.Zero(t, gen.calls)
	assert.True(t, readStampFile(t, watchman.BacktestStampPath(dir, wb)).IsZero(), "a busy run stamps nothing")
}

func TestWatchmanBacktest_RefusedUnderAgent(t *testing.T) {
	wb, gen, _ := watchmanBacktestFixture(t)
	t.Setenv(agentEnvMarkers[0], "1")
	_, err := runWatchmanBacktestCmd(t, wb, "--json")
	require.Error(t, err)
	assert.Contains(t, err.Error(), agentEnvMarkers[0])
	assert.Zero(t, gen.calls)
}

func TestWatchmanBacktestArgs_PassWorkspaceAndConfig(t *testing.T) {
	assert.Equal(t, []string{"watchman", "backtest", "--workbench", "7", "--workspace", "acme", "--config", "/etc/wt.yaml"},
		watchmanBacktestArgs(7, "acme", "/etc/wt.yaml"))
	assert.Equal(t, []string{"watchman", "backtest", "--workbench", "7"}, watchmanBacktestArgs(7, "", ""))
}

func TestWatchmanBacktest_RefusedUntilLearned(t *testing.T) {
	wb, gen, _ := watchmanBacktestFixture(t)
	var path string
	d := openAgentsTestMain(t, &path)
	_, err := d.Exec(`UPDATE watchman_workbenches SET learned_through = NULL WHERE workbench_id = ?`, wb)
	require.NoError(t, err)
	_, err = runWatchmanBacktestCmd(t, wb, "--json")
	require.ErrorContains(t, err, "has not finished learning")
	require.ErrorContains(t, err, "--force")
	assert.Zero(t, gen.calls)

	out, err := runWatchmanBacktestCmd(t, wb, "--json", "--force")
	require.NoError(t, err)
	assert.Contains(t, out, `"status": "done"`)
	assert.Positive(t, gen.calls)
}

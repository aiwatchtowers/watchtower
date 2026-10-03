package cmd

import (
	"encoding/json"
	"errors"
	"flag"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/sessionreport"
)

var updateSessionReportGolden = flag.Bool("update", false, "rewrite the cmd/testdata/session_report_*.json goldens")

// board314 is the sessionreport #314 fixture: workbench 1, session 1.
var board314 = filepath.Join("..", "internal", "sessionreport", "testdata", "board_314.sql")

// sessionReportWorkbench loads the #314 fixture into the command's database
// and binds the workbench to folder.
func sessionReportWorkbench(t *testing.T, folder string) {
	t.Helper()
	loadSessionReportFixture(t, board314, folder)
}

// loadSessionReportFixture loads the SQL fixture at path into the command's
// database and binds workbench 1 to folder.
func loadSessionReportFixture(t *testing.T, path, folder string) {
	t.Helper()
	database := writeActionsConfig(t)
	script, err := os.ReadFile(path)
	require.NoError(t, err)
	_, err = database.Exec(string(script))
	require.NoError(t, err)
	_, err = database.Exec(`UPDATE projects SET folder_path = ? WHERE id = 1`, folder)
	require.NoError(t, err)
}

func runSessionReport(t *testing.T, args ...string) (string, error) {
	t.Helper()
	out, _, err := runWorkbenchAs(t, "workbench", append([]string{"session-report"}, args...)...)
	return out, err
}

// sessionReportGH puts a fake gh first on PATH and returns a reader of the
// calls it got. authOK says whether `gh auth status` succeeds. The stub
// answers at once and starts no child, and every call is waited for before
// the command returns, so no gh process outlives the run.
func sessionReportGH(t *testing.T, authOK bool) func() []string {
	t.Helper()
	dir := t.TempDir()
	logPath := filepath.Join(dir, "calls.log")
	auth := "exit 0"
	if !authOK {
		auth = "echo 'not logged in' >&2; exit 1"
	}
	script := "#!/bin/sh\necho \"$*\" >> '" + logPath + "'\ncase \"$*\" in\n" +
		"\"auth status\") " + auth + " ;;\n" +
		"\"pr view 147 --json state,title,additions,deletions,mergedAt\") " +
		"echo '{\"state\":\"OPEN\",\"title\":\"Session report\",\"additions\":1200,\"deletions\":80,\"mergedAt\":null}' ;;\n" +
		"*) echo '[]' ;;\nesac\n"
	require.NoError(t, os.WriteFile(filepath.Join(dir, "gh"), []byte(script), 0o755))
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	return func() []string {
		b, err := os.ReadFile(logPath)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		require.NoError(t, err)
		return strings.Split(strings.TrimSpace(string(b)), "\n")
	}
}

func decodeSessionReport(t *testing.T, out string) map[string]any {
	t.Helper()
	var got map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &got), out)
	return got
}

func TestWorkbenchSessionReport_NeedsExactlyOneOfSessionAndSummary(t *testing.T) {
	sessionReportWorkbench(t, t.TempDir())

	_, err := runSessionReport(t, "--workbench", "1")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "session")
	assert.Contains(t, err.Error(), "summary")

	_, err = runSessionReport(t, "--workbench", "1", "--session", "1", "--summary")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "session")

	_, err = runSessionReport(t, "--workbench", "1", "--session", "1", "--json")
	require.NoError(t, err)
	_, err = runSessionReport(t, "--workbench", "1", "--summary", "--json")
	require.NoError(t, err)
}

func TestWorkbenchSessionReport_UnknownWorkbenchOrSessionFails(t *testing.T) {
	sessionReportWorkbench(t, t.TempDir())

	for _, args := range [][]string{
		{"--workbench", "9", "--session", "1"},
		{"--workbench", "9", "--summary"},
		{"--workbench", "1", "--session", "99"},
		{"--workbench", "0", "--summary"},
	} {
		_, err := runSessionReport(t, args...)
		assert.Error(t, err, "%v", args)
	}
}

// A gh failure is a note, never an exit code.
func TestWorkbenchSessionReport_GHFailureExitsZeroWithANote(t *testing.T) {
	repo := gitBranchRepo(t)
	sessionReportWorkbench(t, repo)
	calls := sessionReportGH(t, false)

	out, err := runSessionReport(t, "--workbench", "1", "--session", "1", "--json")
	require.NoError(t, err, out)
	got := decodeSessionReport(t, out)
	assert.Contains(t, got["pr_note"], "gh CLI is not signed in or failed")
	assert.Equal(t, []string{"auth status"}, calls())
}

// --summary reads the cache only; --session on the same workbench does run
// gh, so the stub is live.
func TestWorkbenchSessionReport_SummaryNeverRunsGH(t *testing.T) {
	repo := gitBranchRepo(t)
	sessionReportWorkbench(t, repo)
	calls := sessionReportGH(t, true)

	out, err := runSessionReport(t, "--workbench", "1", "--summary", "--json")
	require.NoError(t, err, out)
	var rows []map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &rows), out)
	require.Len(t, rows, 1)
	assert.Equal(t, "PR #147 open", rows[0]["pr_line"])
	assert.EqualValues(t, 14, rows[0]["done"])
	assert.EqualValues(t, 15, rows[0]["total"])
	assert.Empty(t, calls(), "--summary never runs gh")

	_, err = runSessionReport(t, "--workbench", "1", "--summary")
	require.NoError(t, err)
	assert.Empty(t, calls())

	_, err = runSessionReport(t, "--workbench", "1", "--session", "1", "--no-network", "--json")
	require.NoError(t, err)
	assert.Empty(t, calls(), "--no-network never runs gh")

	_, err = runSessionReport(t, "--workbench", "1", "--session", "1", "--json")
	require.NoError(t, err)
	assert.Contains(t, calls(), "auth status")
	assert.Contains(t, calls(), "pr view 147 --json state,title,additions,deletions,mergedAt")
}

// The reports as JSON, byte for byte; the Desktop's decoder tests read the
// same files. A plain folder keeps the refresh from running git or gh, so the
// cache rows and the note are fixed. "finished" fills every key of the
// report: a finish summary, an open ask, a merged and an open PR.
func TestWorkbenchSessionReport_JSONGoldens(t *testing.T) {
	for _, tc := range []struct {
		name, fixture, session, golden string
	}{
		{"314", board314, "1", "testdata/session_report_314.json"},
		{"finished", filepath.Join("testdata", "session_report_finished.sql"), "3", "testdata/session_report_finished.json"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			loadSessionReportFixture(t, tc.fixture, t.TempDir())

			out, err := runSessionReport(t, "--workbench", "1", "--session", tc.session, "--json")
			require.NoError(t, err)
			if *updateSessionReportGolden {
				require.NoError(t, os.WriteFile(tc.golden, []byte(out), 0o644))
			}
			want, err := os.ReadFile(tc.golden)
			require.NoError(t, err, "run with -update to create it")
			assert.Equal(t, string(want), out)

			got := decodeSessionReport(t, out)
			for _, key := range []string{"session", "progress", "on_you", "now", "next", "phases", "prs", "pr_note"} {
				assert.Contains(t, got, key)
			}
		})
	}
}

// The finished golden leaves no Part 6 field empty, so the decoder sees
// every one filled at least once.
func TestWorkbenchSessionReport_FinishedGoldenFillsEveryField(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("testdata", "session_report_finished.json"))
	require.NoError(t, err)
	got := decodeSessionReport(t, string(b))
	session := got["session"].(map[string]any)
	for _, key := range []string{"id", "title", "target_id", "kind", "created_at", "last_active_at", "agent_state",
		"agent_state_at", "finished_at", "finish_summary"} {
		assert.NotEmpty(t, session[key], "session.%s", key)
	}
	assert.Equal(t, map[string]any{"done": float64(3), "total": float64(5)}, got["progress"])
	assert.NotEmpty(t, got["pr_note"])
	// Each key is filled on at least one entry of the list.
	filled := func(list string, keys ...string) {
		items := got[list].([]any)
		require.NotEmpty(t, items, list)
		for _, key := range keys {
			assert.True(t, slices.ContainsFunc(items, func(it any) bool {
				v := it.(map[string]any)[key]
				return v != nil && v != "" && v != float64(0)
			}), "%s[].%s is never filled", list, key)
		}
	}
	filled("on_you", "id", "kind", "title", "target_id", "created_at")
	filled("now", "id", "text", "status", "branch", "since")
	filled("next", "id", "text", "status")
	filled("phases", "target_id", "text", "done", "total", "started_at", "finished_at", "items")
	filled("prs", "ref", "pr_number", "title", "state", "additions", "deletions", "merged_at", "checked_at", "targets")
	assert.True(t, slices.ContainsFunc(got["prs"].([]any), func(it any) bool {
		return it.(map[string]any)["state"] == "merged"
	}), "a merged PR")
}

func TestWorkbenchSessionReport_TextPrintsTheSectionsInOrder(t *testing.T) {
	sessionReportWorkbench(t, t.TempDir())

	out, err := runSessionReport(t, "--workbench", "1", "--session", "1")
	require.NoError(t, err)
	assert.True(t, strings.HasPrefix(out, "Session 1 Session report (target #314)\n"), out)
	at := -1
	for _, section := range []string{"progress: 14 / 15 tasks", "\nOn you\n", "\nNow\n", "\nPull requests\n",
		"\nDone\n", "\nAgent's last word\n"} {
		i := strings.Index(out, section)
		require.Greater(t, i, at, "%q out of order in:\n%s", section, out)
		at = i
	}
	assert.Contains(t, out, "Nothing — the agent is not waiting for you.")
	assert.Contains(t, out, "#342 [blocked] Task C2 · feature/session-report-ui · since 2026-10-02T15:00:00Z")
	assert.Contains(t, out, "PR #147 open — Session report +1200/−80")
	assert.Contains(t, out, "#320 Phase A: data layer  7/7  2026-09-29T09:01:00Z -> 2026-09-29T11:07:00Z")
	assert.Contains(t, out, "#340 Phase C: desktop view  1/2  since 2026-10-01T09:00:00Z")
}

func TestWorkbenchSessionReport_LegacyProjectSpelling(t *testing.T) {
	sessionReportWorkbench(t, t.TempDir())

	out, _, err := runWorkbenchAs(t, "project", "session-report", "--project", "1", "--summary", "--json")
	require.NoError(t, err, out)
	var rows []map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &rows), out)
	assert.Len(t, rows, 1)

	out, _, err = runWorkbenchAs(t, "project", "session-report", "--project", "1", "--session", "1", "--json")
	require.NoError(t, err, out)
	assert.EqualValues(t, 1, decodeSessionReport(t, out)["session"].(map[string]any)["id"])

	_, _, err = runWorkbenchAs(t, "project", "session-report", "--project", "0", "--summary")
	require.ErrorContains(t, err, "--project: a positive workbench id is required")

	help, _, err := runWorkbenchAs(t, "workbench", "session-report", "--help")
	require.NoError(t, err)
	assert.Contains(t, help, "`project session-report --project N`")
}

// A never-checked branch reads "not checked", like the Desktop's PR line;
// "no PR yet" is kept for a checked, unmerged branch without a PR.
func TestWorkbenchSessionReport_UnknownBranchReadsNotChecked(t *testing.T) {
	assert.Equal(t, "feature/x not checked",
		prReportLine(sessionreport.PR{Ref: "branch:feature/x", State: "unknown"}))
	assert.Equal(t, "feature/x open (no PR yet)",
		prReportLine(sessionreport.PR{Ref: "branch:feature/x", State: "open"}))
	assert.Equal(t, "feature/x no PR yet",
		prReportLine(sessionreport.PR{Ref: "branch:feature/x", State: "none"}), "gh checked it and found no PR")
	assert.Equal(t, "feature/x merged",
		prReportLine(sessionreport.PR{Ref: "branch:feature/x", State: "merged"}))
}

// A merged PR or branch says "merged" once, with its date beside it.
func TestWorkbenchSessionReport_MergedReadsOnce(t *testing.T) {
	n := int64(147)
	assert.Equal(t, "feature/x merged 2026-10-02T12:00:00Z",
		prReportLine(sessionreport.PR{Ref: "branch:feature/x", State: "merged", MergedAt: "2026-10-02T12:00:00Z"}))
	assert.Equal(t, "PR #147 merged 2026-10-02T12:00:00Z — Session report",
		prReportLine(sessionreport.PR{Ref: "pr:147", PRNumber: &n, State: "merged", Title: "Session report",
			MergedAt: "2026-10-02T12:00:00Z"}))
}

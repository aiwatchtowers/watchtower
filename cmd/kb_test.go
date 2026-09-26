package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/spf13/pflag"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/kb"
)

// writeKBConfig points flagConfig at a temp workspace whose DB path lives
// under a temp HOME (the writeActionsConfig precedent).
func writeKBConfig(t *testing.T) *db.DB {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "config.yaml")
	require.NoError(t, os.WriteFile(configPath, []byte("active_workspace: test\n"), 0o600))
	original := flagConfig
	flagConfig = configPath
	t.Cleanup(func() { flagConfig = original })
	database, err := openDBFromConfig()
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	return database
}

// runKB executes `kb <args...>` through rootCmd (the runActions precedent)
// with the daemon check stubbed to "none running", then resets every kb flag
// (variable and cobra's Changed mark) so tests never bleed into each other.
func runKB(t *testing.T, args ...string) (string, error) {
	t.Helper()
	return runKBWithDaemon(t, 0, args...)
}

func runKBWithDaemon(t *testing.T, daemonPID int, args ...string) (string, error) {
	t.Helper()
	origPID := kbDaemonPID
	kbDaemonPID = func() (int, error) { return daemonPID, nil }
	defer func() { kbDaemonPID = origPID }()
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetArgs(append([]string{"kb"}, args...))
	err := rootCmd.Execute()
	rootCmd.SetArgs(nil)
	resetKBFlags()
	return out.String(), err
}

func resetKBFlags() {
	kbStatusJSON, kbReindexForce, kbSearchJSON = false, false, false
	kbReindexSources, kbSearchSources = nil, nil
	kbSearchFrom, kbSearchTo, kbSearchLimit = "", "", 0
	for _, c := range kbCmd.Commands() {
		c.Flags().VisitAll(func(f *pflag.Flag) { f.Changed = false })
	}
}

// seedKBJiraIssue seeds one indexable Jira issue directly (the internal/kb
// seedJira fixture's shape — kb's own test helper is unexported).
func seedKBJiraIssue(t *testing.T, database *db.DB) {
	t.Helper()
	_, err := database.Exec(`INSERT INTO jira_accounts (id, cloud_id, site_url) VALUES (1, 'c1', 'https://acme.atlassian.net/')`)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO jira_issues (account_id, key, project_key, summary, description_text, status, status_category, created_at, updated_at, synced_at)
		VALUES (1,'PROJ-1','PROJ','Stage environment','Need a stage','In Progress','indeterminate','2026-04-01T09:00:00.000+0100','2026-04-20T09:37:38.027+0100','2026-04-20T11:00:01Z')`)
	require.NoError(t, err)
}

func TestKB_SearchHappyPath(t *testing.T) {
	database := writeKBConfig(t)
	seedKBJiraIssue(t, database)

	_, err := kb.Run(context.Background(), database, kb.Options{})
	require.NoError(t, err)

	out, err := runKB(t, "search", "stage")
	require.NoError(t, err)
	assert.Contains(t, out, "PROJ-1", "search must find the seeded Jira issue's document ref")
	assert.Contains(t, out, "Stage environment")
	assert.Contains(t, out, "[jira]")
}

func TestKB_SearchNoMatches(t *testing.T) {
	writeKBConfig(t)

	out, err := runKB(t, "search", "nothingindexedyet")
	require.NoError(t, err)
	assert.Contains(t, out, "No matches.")
}

func TestKB_SearchJSONShape(t *testing.T) {
	database := writeKBConfig(t)
	seedKBJiraIssue(t, database)
	_, err := kb.Run(context.Background(), database, kb.Options{})
	require.NoError(t, err)

	out, err := runKB(t, "search", "stage", "--json")
	require.NoError(t, err)

	var res kb.Result
	require.NoError(t, json.Unmarshal([]byte(out), &res))
	require.Len(t, res.Hits, 1)
	assert.Equal(t, "jira", res.Hits[0].Source)
}

func TestKB_ReindexUnknownSourceErrors(t *testing.T) {
	writeKBConfig(t)

	_, err := runKB(t, "reindex", "--source", "nope")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "unknown source")
}

func TestKB_ReindexHappyPath(t *testing.T) {
	database := writeKBConfig(t)
	seedKBJiraIssue(t, database)

	out, err := runKB(t, "reindex")
	require.NoError(t, err)
	assert.Contains(t, out, "Rebuilding all sources")
	assert.Contains(t, out, "Done:")
	assert.Contains(t, out, "1 written")

	var n int
	require.NoError(t, database.QueryRow(`SELECT count(*) FROM kb_documents`).Scan(&n))
	assert.Equal(t, 1, n)
}

func TestKB_StatusJSONShape(t *testing.T) {
	database := writeKBConfig(t)
	seedKBJiraIssue(t, database)
	_, err := kb.Run(context.Background(), database, kb.Options{Now: time.Now()})
	require.NoError(t, err)

	out, err := runKB(t, "status", "--json")
	require.NoError(t, err)

	var statuses []kb.SourceStatus
	require.NoError(t, json.Unmarshal([]byte(out), &statuses))
	require.Equal(t, kb.SourceNames(), namesOf(statuses))

	var jira kb.SourceStatus
	for _, s := range statuses {
		if s.Source == "jira" {
			jira = s
		}
	}
	assert.Equal(t, 1, jira.Docs, "jira source must report the seeded document")
}

func TestKB_StatusTextShape(t *testing.T) {
	writeKBConfig(t)

	out, err := runKB(t, "status")
	require.NoError(t, err)
	assert.Contains(t, out, "SOURCE")
	assert.Contains(t, out, "DOCS")
	assert.Contains(t, out, "CHUNKS")
	assert.Contains(t, out, "PROGRESS")
}

func namesOf(statuses []kb.SourceStatus) []string {
	out := make([]string, len(statuses))
	for i, s := range statuses {
		out[i] = s.Source
	}
	return out
}

func TestKB_ReindexRefusesWhileDaemonRuns(t *testing.T) {
	database := writeKBConfig(t)
	seedKBJiraIssue(t, database)

	_, err := runKBWithDaemon(t, 4242, "reindex")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "PID 4242")
	assert.Contains(t, err.Error(), "--force")
	var n int
	require.NoError(t, database.QueryRow(`SELECT count(*) FROM kb_documents`).Scan(&n))
	assert.Equal(t, 0, n, "a refused reindex touches nothing")

	out, err := runKBWithDaemon(t, 4242, "reindex", "--force")
	require.NoError(t, err)
	assert.Contains(t, out, "1 written")
}

// The production daemon check reads the workspace's real pid file: a live
// PID there (this test process, legacy one-field format) refuses the rebuild.
func TestKB_ReindexDaemonCheckReadsPIDFile(t *testing.T) {
	writeKBConfig(t)
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	pidPath := pidFilePath(cfg)
	require.NoError(t, os.MkdirAll(filepath.Dir(pidPath), 0o755))
	require.NoError(t, os.WriteFile(pidPath, []byte(strconv.Itoa(os.Getpid())), 0o600))

	pid, err := kbDaemonPID()
	require.NoError(t, err)
	assert.Equal(t, os.Getpid(), pid)
	assert.Error(t, checkReindexAllowed(pid, false))
	assert.NoError(t, checkReindexAllowed(pid, true))
	assert.NoError(t, checkReindexAllowed(0, false))
}

// Flags are bound per command: --source given to reindex never leaks into a
// later search in the same process.
func TestKB_FlagsDoNotLeakBetweenCommands(t *testing.T) {
	database := writeKBConfig(t)
	seedKBJiraIssue(t, database)
	_, err := runKB(t, "reindex", "--source", "calendar")
	require.NoError(t, err)
	_, err = runKB(t, "reindex", "--source", "jira")
	require.NoError(t, err)
	out, err := runKB(t, "search", "stage")
	require.NoError(t, err)
	assert.Contains(t, out, "PROJ-1", "search is not restricted by an earlier reindex --source")
}

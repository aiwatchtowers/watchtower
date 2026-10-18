package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlog"
	"watchtower/internal/agentlogdb"
	"watchtower/internal/db"
)

func runAgentsCmd(t *testing.T, args ...string) string {
	t.Helper()
	t.Cleanup(func() {
		flagAgentsWorkbench, flagAgentsJSON = 0, false
		flagAgentsSince, flagAgentsDays, flagAgentsSession = "", 7, ""
		rootCmd.SetArgs(nil)
	})
	var out, errOut bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errOut)
	rootCmd.SetArgs(append([]string{"agents"}, args...))
	require.NoError(t, rootCmd.Execute(), errOut.String())
	return out.String()
}

func agentsFixture(t *testing.T) (wb int64) {
	t.Helper()
	database := writeActionsConfig(t)
	folder, _ := filepath.EvalSymlinks(t.TempDir())
	wb, err := database.CreateWorkbench("app", folder)
	require.NoError(t, err)
	claude := t.TempDir()
	prev := agentsClaudeDir
	agentsClaudeDir = func() string { return claude }
	t.Cleanup(func() { agentsClaudeDir = prev })
	dir := filepath.Join(claude, "projects", agentlog.Slug(folder))
	require.NoError(t, os.MkdirAll(dir, 0o755))
	rec := `{"type":"assistant","sessionId":"s1","uuid":"u1","timestamp":"2026-10-01T10:00:00Z","cwd":"` + folder +
		`","requestId":"r1","message":{"id":"m1","model":"claude-opus-5-5","role":"assistant","content":[],"usage":{"input_tokens":10,"output_tokens":5}}}` + "\n"
	require.NoError(t, os.WriteFile(filepath.Join(dir, "s1.jsonl"), []byte(rec), 0o600))
	return wb
}

func TestAgentsEnable_BackfillsAtOnce(t *testing.T) {
	wb := agentsFixture(t)
	out := runAgentsCmd(t, "enable", "--workbench", strconv.FormatInt(wb, 10), "--json")
	var r map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &r))
	assert.EqualValues(t, 1, r["sessions"])
}

func TestAgentsStatsJSON_PinnedKeys(t *testing.T) {
	wb := agentsFixture(t)
	runAgentsCmd(t, "enable", "--workbench", strconv.FormatInt(wb, 10))
	out := runAgentsCmd(t, "stats", "--workbench", strconv.FormatInt(wb, 10), "--json")
	var m map[string]json.RawMessage
	require.NoError(t, json.Unmarshal([]byte(out), &m))
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	assert.Equal(t, []string{"cost_estimated_calls", "cost_usd", "enabled", "outcomes", "owner_turns", "per_session",
		"reported_cost_usd", "sessions", "skills", "tokens", "tools", "workbench_id"}, keys)
}

func jsonKeys(t *testing.T, out string) []string {
	t.Helper()
	var m map[string]json.RawMessage
	require.NoError(t, json.Unmarshal([]byte(out), &m))
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func mapKeys(m map[string]json.RawMessage) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func TestAgentsReportJSON_PinnedKeys(t *testing.T) {
	wb := strconv.FormatInt(agentsFixture(t), 10)
	runAgentsCmd(t, "enable", "--workbench", wb)
	out := runAgentsCmd(t, "report", "--workbench", wb, "--days", "0", "--json")
	assert.Equal(t, []string{"commands", "enabled", "hints", "models", "old_format_sessions", "sessions", "since",
		"subagents", "tasks", "time", "totals", "until", "workbench_id"}, jsonKeys(t, out))
	var ov struct {
		Totals   map[string]json.RawMessage `json:"totals"`
		Sessions []map[string]json.RawMessage
	}
	require.NoError(t, json.Unmarshal([]byte(out), &ov))
	require.Len(t, ov.Sessions, 1)
	assert.Equal(t, []string{"active_ms", "away_ms", "cost_estimated_calls", "cost_usd", "sessions", "tokens"}, mapKeys(ov.Totals))
	assert.Equal(t, []string{"active_ms", "avg_parallel", "branch", "cost_usd", "ended_at", "model", "old_format", "prs",
		"session_uuid", "started_at"}, mapKeys(ov.Sessions[0]))

	out = runAgentsCmd(t, "report", "--workbench", wb, "--session", "s1", "--json")
	assert.Equal(t, []string{"commands", "hints", "lanes", "session", "subagents", "time"}, jsonKeys(t, out))
}

func TestAgentsReport_EmptyWorkbench(t *testing.T) {
	database := writeActionsConfig(t)
	wb, err := database.CreateWorkbench("app", t.TempDir())
	require.NoError(t, err)
	out := runAgentsCmd(t, "report", "--workbench", strconv.FormatInt(wb, 10), "--json")
	assert.Contains(t, out, `"enabled": false`)
	for _, k := range []string{"commands", "models", "hints", "tasks", "sessions"} {
		assert.Contains(t, out, `"`+k+`": []`)
	}
	assert.NotContains(t, out, "null")
	flagAgentsJSON = false // flags persist between Execute calls
	assert.Contains(t, runAgentsCmd(t, "report", "--workbench", strconv.FormatInt(wb, 10)), "0 sessions")
}

func TestAgentsReport_UnknownSessionFails(t *testing.T) {
	wb := agentsFixture(t)
	rootCmd.SetArgs([]string{"agents", "report", "--workbench", strconv.FormatInt(wb, 10), "--session", "nope"})
	t.Cleanup(func() { flagAgentsWorkbench, flagAgentsSession = 0, ""; rootCmd.SetArgs(nil) })
	assert.ErrorContains(t, rootCmd.Execute(), "not found")
}

func TestAgentsScan_RefusesWhenDisabled(t *testing.T) {
	wb := agentsFixture(t)
	rootCmd.SetArgs([]string{"agents", "scan", "--workbench", strconv.FormatInt(wb, 10)})
	t.Cleanup(func() { flagAgentsWorkbench = 0; rootCmd.SetArgs(nil) })
	assert.ErrorContains(t, rootCmd.Execute(), "analytics is off")
}

func TestAgentsDisable_KeepsRows(t *testing.T) {
	wb := agentsFixture(t)
	id := strconv.FormatInt(wb, 10)
	runAgentsCmd(t, "enable", "--workbench", id)
	runAgentsCmd(t, "disable", "--workbench", id)
	out := runAgentsCmd(t, "stats", "--workbench", id, "--json")
	assert.Contains(t, out, `"sessions": 1`)
	assert.Contains(t, out, `"enabled": false`)
}

// Spec "Error handling": an agentlog.db that cannot be opened is report's
// error; it never answers from watchtower.db.
func TestAgentsReport_AgentlogOpenFails(t *testing.T) {
	database := writeActionsConfig(t)
	wb, err := database.CreateWorkbench("app", t.TempDir())
	require.NoError(t, err)
	var mainPath string
	require.NoError(t, database.QueryRow(`SELECT file FROM pragma_database_list WHERE name = 'main'`).Scan(&mainPath))
	require.NoError(t, os.Mkdir(agentlogdb.PathFor(mainPath), 0o700)) // a directory cannot open as a database
	rootCmd.SetArgs([]string{"agents", "report", "--workbench", strconv.FormatInt(wb, 10), "--json"})
	t.Cleanup(func() { flagAgentsWorkbench, flagAgentsJSON = 0, false; rootCmd.SetArgs(nil) })
	assert.ErrorContains(t, rootCmd.Execute(), "agentlog.db")
}

// seedMainAgentLog writes one file, one session of workbench wb and one event
// into watchtower.db's agent_log_* tables, as a release before #849 did.
func seedMainAgentLog(t *testing.T, database *db.DB, wb int64) {
	t.Helper()
	_, err := database.Exec(`INSERT INTO agent_log_files (path, agent) VALUES ('/gone/old1.jsonl', 'claude')`)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO agent_log_sessions (session_uuid, agent, project_id, folder_path, home_cwd, source_path, started_at, ended_at)
		VALUES ('old1', 'claude', ?, '/x', '/x', '/gone/old1.jsonl', '2026-10-01T10:00:00Z', '2026-10-01T11:00:00Z')`, wb)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO agent_log_events (session_uuid, key, kind, ts, src_path, src_offset)
		VALUES ('old1', 'old1:k1', 'api_call', '2026-10-01T10:30:00Z', '/gone/old1.jsonl', 0)`)
	require.NoError(t, err)
}

func mainAgentLogCount(t *testing.T, database *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(`SELECT (SELECT COUNT(*) FROM agent_log_files) + (SELECT COUNT(*) FROM agent_log_sessions)
		+ (SELECT COUNT(*) FROM agent_log_events)`).Scan(&n))
	return n
}

// Spec D4: the Desktop polls report every 60 s, so report never starts the
// move: the seeded rows stay in watchtower.db, agentlog.db gets no marker,
// and the answer is an empty overview.
func TestAgentsReport_BeforeMoveNeitherCopiesNorWrites(t *testing.T) {
	database := writeActionsConfig(t)
	wb, err := database.CreateWorkbench("app", t.TempDir())
	require.NoError(t, err)
	require.NoError(t, database.SetWorkbenchAgentAnalytics(wb, true))
	seedMainAgentLog(t, database, wb)

	out := runAgentsCmd(t, "report", "--workbench", strconv.FormatInt(wb, 10), "--days", "0", "--json")
	var ov map[string]json.RawMessage
	require.NoError(t, json.Unmarshal([]byte(out), &ov))
	for _, k := range []string{"commands", "models", "hints", "tasks", "sessions"} {
		assert.JSONEq(t, `[]`, string(ov[k]), k)
	}
	runAgentsCmd(t, "stats", "--workbench", strconv.FormatInt(wb, 10), "--json")

	assert.Equal(t, 3, mainAgentLogCount(t, database), "watchtower.db keeps its rows")
	var mainPath string
	require.NoError(t, database.QueryRow(`SELECT file FROM pragma_database_list WHERE name = 'main'`).Scan(&mainPath))
	al, err := agentlogdb.Open(agentlogdb.PathFor(mainPath))
	require.NoError(t, err)
	t.Cleanup(func() { _ = al.Close() })
	moved, err := al.Moved()
	require.NoError(t, err)
	assert.False(t, moved)
	var n int
	require.NoError(t, al.QueryRow(`SELECT COUNT(*) FROM agent_log_sessions`).Scan(&n))
	assert.Zero(t, n)
}

// The writing commands run the move first, so a CLI-only install moves too.
func TestAgentsScan_MovesFirst(t *testing.T) {
	wb := agentsFixture(t)
	id := strconv.FormatInt(wb, 10)
	var mainPath string
	database := openAgentsTestMain(t, &mainPath)
	require.NoError(t, database.SetWorkbenchAgentAnalytics(wb, true))
	seedMainAgentLog(t, database, wb)

	runAgentsCmd(t, "scan", "--workbench", id)

	assert.Zero(t, mainAgentLogCount(t, database))
	out := runAgentsCmd(t, "stats", "--workbench", id, "--json")
	assert.Contains(t, out, `"sessions": 2`, "the moved session and the scanned one")
}

func openAgentsTestMain(t *testing.T, path *string) *db.DB {
	t.Helper()
	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	*path = cfg.DBPath()
	database, err := db.Open(*path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	return database
}

// TestSyncDaemon_MovesBeforeDaemonStarts pins the #849 upgrade step: the
// daemon opens agentlog.db and moves the rows out of watchtower.db before
// daemon.New (runSyncDaemon cannot run in a test, so its body is parsed, as
// in TestRunSyncDaemon_WiresAutomations), and openAgentLog does move them.
func TestSyncDaemon_MovesBeforeDaemonStarts(t *testing.T) {
	file, err := parser.ParseFile(token.NewFileSet(), "sync.go", nil, 0)
	require.NoError(t, err)
	var moved, movedFirst bool
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Recv != nil || fn.Name.Name != "runSyncDaemon" {
			continue
		}
		ast.Inspect(fn.Body, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			switch f := call.Fun.(type) {
			case *ast.Ident:
				if f.Name == "openAgentLog" {
					moved = true
				}
			case *ast.SelectorExpr:
				if x, ok := f.X.(*ast.Ident); ok && x.Name == "daemon" && f.Sel.Name == "New" {
					movedFirst = moved
				}
			}
			return true
		})
	}
	assert.True(t, moved, "runSyncDaemon must call openAgentLog")
	assert.True(t, movedFirst, "runSyncDaemon must call openAgentLog before daemon.New")

	database := writeActionsConfig(t)
	wb, err := database.CreateWorkbench("app", t.TempDir())
	require.NoError(t, err)
	seedMainAgentLog(t, database, wb)
	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	al := openAgentLog(context.Background(), cfg, database, log.New(io.Discard, "", 0))
	require.NotNil(t, al)
	t.Cleanup(func() { _ = al.Close() })
	ok, err := al.Moved()
	require.NoError(t, err)
	assert.True(t, ok)
	assert.Zero(t, mainAgentLogCount(t, database))
	var n int
	require.NoError(t, al.QueryRow(`SELECT COUNT(*) FROM agent_log_events`).Scan(&n))
	assert.Equal(t, 1, n)
}

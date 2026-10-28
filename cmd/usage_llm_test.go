package cmd

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/llmusage"
)

// usageLLMEnv is a workspace with a migrated database whose config is at the
// current schema format, so the root command's pre-run never writes to it.
func usageLLMEnv(t *testing.T) (*db.DB, string) {
	t.Helper()
	database := writeActionsConfig(t)
	require.NoError(t, os.WriteFile(flagConfig, []byte("active_workspace: test\ndb:\n  schema_format: "+
		strconv.Itoa(db.CurrentSchemaFormat)+"\n"), 0o600))
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	return database, cfg.WorkspaceDir()
}

func runUsageLLMCmd(t *testing.T, args ...string) string {
	t.Helper()
	flagUsageLLMSince, flagUsageLLMJSON = "7d", false // cobra keeps the previous run's values
	t.Cleanup(func() {
		flagUsageLLMSince, flagUsageLLMJSON = "7d", false
		rootCmd.SetArgs(nil)
	})
	var out, errOut bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errOut)
	rootCmd.SetArgs(append([]string{"usage", "llm"}, args...))
	require.NoError(t, rootCmd.Execute(), errOut.String())
	return out.String()
}

func usageLLMJSON(t *testing.T, args ...string) usageLLMReport {
	t.Helper()
	var rep usageLLMReport
	require.NoError(t, json.Unmarshal([]byte(runUsageLLMCmd(t, append([]string{"--json"}, args...)...)), &rep))
	return rep
}

// usageAt is a call time inside every period.
func usageAt() string { return time.Now().Add(-time.Minute).UTC().Format(time.RFC3339) }

func usageCall(id, surface, purpose, process, model string, est float64) llmusage.Call {
	c := llmusage.Call{CallID: id, At: usageAt(), Surface: surface, Purpose: purpose, Process: process,
		Model: model, Input: 100, CacheRead: 1000, CacheWrite5m: 10, CacheWrite1h: 5, Output: 50, OK: true}
	if est >= 0 {
		c.EstCostUSD = &est
	}
	return c
}

func seedUsageAutomation(t *testing.T, d *db.DB, slug, name, origin string) int64 {
	t.Helper()
	q := `INSERT INTO automations (slug, scope, path, name, origin) VALUES (?, 'personal', ?, ?, 'owner')`
	args := []any{slug, "/r/" + slug + ".md", name}
	if origin == "builtin" {
		q = `INSERT INTO automations (slug, scope, path, name, origin, builtin_id) VALUES (?, 'personal', ?, ?, 'builtin', ?)`
		args = append(args, slug)
	}
	res, err := d.Exec(q, args...)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func withAutomation(c llmusage.Call, aid, run int64) llmusage.Call {
	c.AutomationID, c.AutomationRunID = &aid, &run
	return c
}

func writeUsageSpool(t *testing.T, path string, calls ...llmusage.Call) {
	t.Helper()
	var buf bytes.Buffer
	for _, c := range calls {
		b, err := json.Marshal(c)
		require.NoError(t, err)
		buf.Write(append(b, '\n'))
	}
	require.NoError(t, os.WriteFile(path, buf.Bytes(), 0o600))
}

func usageKeys(t *testing.T, raw json.RawMessage) []string {
	t.Helper()
	var m map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(raw, &m), string(raw))
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func TestUsageLLM_JSONKeysPinned(t *testing.T) {
	database, _ := usageLLMEnv(t)
	aid := seedUsageAutomation(t, database, "mine", "Mine", "owner")
	require.NoError(t, database.InsertLLMCalls([]llmusage.Call{
		usageCall("w1", "watchtower", "digest.channel", "daemon", "haiku", 0.1),
		usageCall("w2", "watchtower", "", "cli:jira boards", "haiku", 0.1),
		withAutomation(usageCall("a1", "watchtower", "automation.llm", "daemon", "sonnet", 0.2), aid, 1),
		usageCall("c1", "chat", "chat.turn", "ai session", "opus", 1),
		usageCall("h1", "workbench", "review.overview", "cli:workbench", "opus", 1),
	}))
	out := runUsageLLMCmd(t, "--json")

	var top map[string]json.RawMessage
	require.NoError(t, json.Unmarshal([]byte(out), &top))
	assert.Equal(t, []string{"chats", "ledger_since", "own_automations", "page_total", "period", "watchtower", "workbenches"},
		usageKeys(t, json.RawMessage(out)))

	totalsKeys := []string{"cache_read", "cache_write", "calls", "cost_is_estimate", "cost_is_lower_bound", "cost_usd",
		"errors", "estimated_calls", "input", "no_price_calls", "output", "untagged_calls"}
	var wt, own, bench map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(top["watchtower"], &wt))
	require.NoError(t, json.Unmarshal(top["own_automations"], &own))
	require.NoError(t, json.Unmarshal(top["workbenches"], &bench))
	assert.Equal(t, []string{"rows", "totals"}, usageKeys(t, top["watchtower"]))
	assert.Equal(t, []string{"rows", "totals"}, usageKeys(t, top["own_automations"]))
	assert.Equal(t, []string{"analytics_off", "helpers", "sessions", "totals"}, usageKeys(t, top["workbenches"]))
	for name, raw := range map[string]json.RawMessage{"watchtower.totals": wt["totals"], "own_automations.totals": own["totals"],
		"chats": top["chats"], "workbenches.totals": bench["totals"], "workbenches.helpers": bench["helpers"],
		"page_total": top["page_total"]} {
		assert.Equal(t, totalsKeys, usageKeys(t, raw), name)
	}
	sessionsKeys := append(append([]string{}, totalsKeys...), "sessions")
	sort.Strings(sessionsKeys)
	assert.Equal(t, sessionsKeys, usageKeys(t, bench["sessions"]))
	assert.JSONEq(t, `[]`, string(bench["analytics_off"]))

	var rows []json.RawMessage
	require.NoError(t, json.Unmarshal(wt["rows"], &rows))
	require.Len(t, rows, 2)
	rowKeys := []string{"cache_read", "cache_write", "calls", "cost_is_estimate", "cost_is_lower_bound", "cost_usd",
		"input", "models", "output", "per_call_tokens", "purpose"}
	assert.Equal(t, rowKeys, usageKeys(t, rows[0]), "tagged row")
	untaggedKeys := append(append([]string{}, rowKeys...), "process")
	sort.Strings(untaggedKeys)
	assert.Equal(t, untaggedKeys, usageKeys(t, rows[1]), "untagged row is last and names its process")
	var untagged struct {
		Purpose string   `json:"purpose"`
		Process string   `json:"process"`
		Models  []string `json:"models"`
	}
	require.NoError(t, json.Unmarshal(rows[1], &untagged))
	assert.Equal(t, "", untagged.Purpose)
	assert.Equal(t, "cli:jira boards", untagged.Process)
	assert.Equal(t, []string{"haiku"}, untagged.Models)

	var autoRows []json.RawMessage
	require.NoError(t, json.Unmarshal(own["rows"], &autoRows))
	require.Len(t, autoRows, 1)
	assert.Equal(t, []string{"automation_id", "calls", "cost_is_estimate", "cost_usd", "input", "name", "output", "runs"},
		usageKeys(t, autoRows[0]))
	var ledgerSince string
	require.NoError(t, json.Unmarshal(top["ledger_since"], &ledgerSince))
	_, err := time.Parse(time.RFC3339, ledgerSince)
	require.NoError(t, err, "ledger_since is RFC 3339")
}

func TestUsageLLM_SplitsOwnAutomations(t *testing.T) {
	database, _ := usageLLMEnv(t)
	owner := seedUsageAutomation(t, database, "weekly", "Weekly to-do", "owner")
	builtin := seedUsageAutomation(t, database, "morning-brief", "Morning brief", "builtin")
	require.NoError(t, database.InsertLLMCalls([]llmusage.Call{
		withAutomation(usageCall("o1", "watchtower", "automation.llm", "daemon", "haiku", 0.1), owner, 1),
		withAutomation(usageCall("o2", "watchtower", "automation.agent", "daemon", "sonnet", 0.2), owner, 1),
		withAutomation(usageCall("o3", "watchtower", "automation.llm", "daemon", "haiku", 0.1), owner, 2),
		withAutomation(usageCall("b1", "watchtower", "briefing.daily", "daemon", "opus", 1), builtin, 7),
		withAutomation(usageCall("b2", "watchtower", "briefing.daily", "daemon", "sonnet", 1), builtin, 8),
		withAutomation(usageCall("gone", "watchtower", "automation.llm", "daemon", "haiku", 0.1), 999, 3),
	}))
	rep := usageLLMJSON(t)

	require.Len(t, rep.Watchtower.Rows, 1, "only the built-in's purpose")
	r := rep.Watchtower.Rows[0]
	assert.Equal(t, "briefing.daily", r.Purpose)
	assert.Equal(t, []string{"opus", "sonnet"}, r.Models)
	assert.Equal(t, int64(2), r.Calls)
	assert.Equal(t, int64(2), rep.Watchtower.Totals.Calls)

	require.Len(t, rep.OwnAutomations.Rows, 2)
	byID := map[int64]usageLLMAutomationRow{}
	for _, a := range rep.OwnAutomations.Rows {
		byID[a.AutomationID] = a
	}
	assert.Equal(t, "Weekly to-do", byID[owner].Name)
	assert.Equal(t, int64(3), byID[owner].Calls)
	assert.Equal(t, int64(2), byID[owner].Runs, "a run spanning two models counts once")
	assert.Equal(t, "#999", byID[999].Name, "a deleted automation is an owner one named by its id")
	assert.Equal(t, int64(4), rep.OwnAutomations.Totals.Calls)
}

func TestUsageLLM_LowerBoundWhenNoPrice(t *testing.T) {
	database, _ := usageLLMEnv(t)
	reported := 2.0
	priced := usageCall("p", "watchtower", "memory.extract_episodes", "daemon", "sonnet", 0.5)
	priced.ReportedCostUSD = &reported
	require.NoError(t, database.InsertLLMCalls([]llmusage.Call{
		priced,
		usageCall("n1", "watchtower", "memory.extract_episodes", "daemon", "llama3", -1),
		usageCall("n2", "watchtower", "ideas.consolidate", "daemon", "llama3", -1),
		usageCall("e", "watchtower", "digest.channel", "daemon", "haiku", 0.25),
	}))
	rep := usageLLMJSON(t)

	byPurpose := map[string]usageLLMPurposeRow{}
	for _, r := range rep.Watchtower.Rows {
		byPurpose[r.Purpose] = r
	}
	mem := byPurpose["memory.extract_episodes"]
	require.NotNil(t, mem.CostUSD)
	assert.Equal(t, 2.0, *mem.CostUSD, "the reported cost wins over the estimate")
	assert.True(t, mem.CostIsLowerBound)
	assert.False(t, mem.CostIsEstimate)
	ideas := byPurpose["ideas.consolidate"]
	assert.Nil(t, ideas.CostUSD, "no call had a cost")
	assert.True(t, ideas.CostIsLowerBound)
	dg := byPurpose["digest.channel"]
	assert.True(t, dg.CostIsEstimate)
	assert.False(t, dg.CostIsLowerBound)

	tot := rep.Watchtower.Totals
	require.NotNil(t, tot.CostUSD)
	assert.InDelta(t, 2.25, *tot.CostUSD, 1e-9)
	assert.Equal(t, int64(2), tot.NoPriceCalls)
	assert.True(t, tot.CostIsLowerBound)
	assert.True(t, tot.CostIsEstimate)
	assert.True(t, rep.PageTotal.CostIsLowerBound)

	text := runUsageLLMCmd(t)
	assert.Contains(t, text, "≥ $2.25")
	assert.Contains(t, text, "memory.extract_episodes")
}

func TestUsageLLM_EmptyLedger(t *testing.T) {
	usageLLMEnv(t)
	out := runUsageLLMCmd(t, "--json", "--since", "today")
	rep := usageLLMReport{}
	require.NoError(t, json.Unmarshal([]byte(out), &rep))
	assert.Equal(t, "", rep.LedgerSince)
	assert.Equal(t, "today", rep.Period)
	assert.Equal(t, usageLLMTotals{}, rep.PageTotal)
	assert.Equal(t, usageLLMTotals{}, rep.Watchtower.Totals)
	assert.Empty(t, rep.Watchtower.Rows)
	assert.Empty(t, rep.OwnAutomations.Rows)

	var top map[string]json.RawMessage
	require.NoError(t, json.Unmarshal([]byte(out), &top))
	var wt map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(top["watchtower"], &wt))
	assert.JSONEq(t, `[]`, string(wt["rows"]), "rows is an array, never null")
	assert.JSONEq(t, `""`, string(top["ledger_since"]))
}

func TestUsageLLM_NoTableNoFile(t *testing.T) {
	t.Run("no llm_calls table", func(t *testing.T) {
		database, _ := usageLLMEnv(t)
		_, err := database.Exec(`DROP TABLE llm_calls`)
		require.NoError(t, err)
		rep := usageLLMJSON(t)
		assert.Equal(t, "", rep.LedgerSince)
		assert.Equal(t, usageLLMTotals{}, rep.PageTotal)
		assert.Equal(t, []string{}, rep.Workbenches.AnalyticsOff)
	})
	t.Run("no database file", func(t *testing.T) {
		database, ws := usageLLMEnv(t)
		require.NoError(t, database.Close())
		for _, suffix := range []string{"", "-wal", "-shm"} {
			_ = os.Remove(filepath.Join(ws, "watchtower.db"+suffix))
		}
		rep := usageLLMJSON(t)
		assert.Equal(t, "", rep.LedgerSince)
		assert.Equal(t, usageLLMTotals{}, rep.PageTotal)
		_, err := os.Stat(filepath.Join(ws, "watchtower.db"))
		assert.ErrorIs(t, err, os.ErrNotExist, "the command never creates the database")
	})
}

func TestUsageLLM_PageTotal(t *testing.T) {
	database, _ := usageLLMEnv(t)
	aid := seedUsageAutomation(t, database, "mine", "Mine", "owner")
	require.NoError(t, database.InsertLLMCalls([]llmusage.Call{
		usageCall("w", "watchtower", "digest.channel", "daemon", "haiku", 0.5),
		withAutomation(usageCall("a", "watchtower", "automation.llm", "daemon", "haiku", 0.25), aid, 1),
		usageCall("c", "chat", "chat.turn", "ai session", "opus", 2),
		usageCall("h", "workbench", "review.overview", "cli:workbench", "opus", 8),
	}))
	rep := usageLLMJSON(t)
	assert.Equal(t, int64(3), rep.PageTotal.Calls, "workbench helpers are not in the page total")
	require.NotNil(t, rep.PageTotal.CostUSD)
	assert.InDelta(t, 2.75, *rep.PageTotal.CostUSD, 1e-9)
	assert.Equal(t, rep.Watchtower.Totals.Input+rep.OwnAutomations.Totals.Input+rep.Chats.Input, rep.PageTotal.Input)
	assert.Equal(t, int64(3*1000), rep.PageTotal.CacheRead)
	assert.Equal(t, int64(3*15), rep.PageTotal.CacheWrite)
	assert.True(t, rep.PageTotal.CostIsEstimate)
	assert.Equal(t, int64(1), rep.Workbenches.Helpers.Calls)
}

func TestUsageLLM_WorkbenchAnalyticsOff(t *testing.T) {
	database, ws := usageLLMEnv(t)
	insert := func(name string, on int) int64 {
		res, err := database.Exec(`INSERT INTO projects (name, folder_path, agent_analytics) VALUES (?, ?, ?)`,
			name, "/w/"+name, on)
		require.NoError(t, err)
		id, err := res.LastInsertId()
		require.NoError(t, err)
		return id
	}
	onID := insert("alpha", 1)
	offID := insert("demo-bench", 0)
	require.NoError(t, database.InsertLLMCalls([]llmusage.Call{
		usageCall("h", "workbench", "review.overview", "cli:workbench", "opus", 1),
	}))

	al, err := agentlogdb.Open(agentlogdb.PathFor(filepath.Join(ws, "watchtower.db")))
	require.NoError(t, err)
	ts := time.Now().Add(-time.Minute).UTC().Format("2006-01-02T15:04:05.000Z")
	session := func(uuid string, pid int64) agentlogdb.AgentLogSession {
		return agentlogdb.AgentLogSession{SessionUUID: uuid, Agent: "claude", ProjectID: &pid, FolderPath: "/w",
			HomeCWD: "/w", SourcePath: "/x/" + uuid + ".jsonl", StartedAt: ts, EndedAt: ts}
	}
	call := func(uuid, key string) agentlogdb.AgentLogEvent {
		return agentlogdb.AgentLogEvent{SessionUUID: uuid, Key: key, Kind: "api_call", TS: ts, Name: "claude-opus-5-5",
			InputTokens: 10, OutputTokens: 20, CacheReadTokens: 300, CostUSD: 1.5, SrcPath: "/x/a.jsonl"}
	}
	ok, err := al.ApplyAgentLogBatch(agentlogdb.AgentLogBatch{
		File: agentlogdb.AgentLogFile{Path: "/x/a.jsonl", Agent: "claude", ReadOffset: 1}, ExpectOffset: -1,
		Sessions: []agentlogdb.AgentLogSession{session("on1", onID), session("on2", onID), session("off1", offID)},
		Events:   []agentlogdb.AgentLogEvent{call("on1", "k1"), call("on1", "k2"), call("on2", "k3"), call("off1", "k4")},
	})
	require.NoError(t, err)
	require.True(t, ok)
	require.NoError(t, al.Close())

	rep := usageLLMJSON(t)
	wb := rep.Workbenches
	assert.Equal(t, []string{"demo-bench"}, wb.AnalyticsOff)
	assert.Equal(t, int64(2), wb.Sessions.Sessions, "the off workbench's session is not counted")
	assert.Equal(t, int64(3), wb.Sessions.Calls)
	assert.Equal(t, int64(900), wb.Sessions.CacheRead)
	require.NotNil(t, wb.Sessions.CostUSD)
	assert.InDelta(t, 4.5, *wb.Sessions.CostUSD, 1e-9)
	assert.Equal(t, int64(4), wb.Totals.Calls, "sessions + helpers")
	require.NotNil(t, wb.Totals.CostUSD)
	assert.InDelta(t, 5.5, *wb.Totals.CostUSD, 1e-9)
	assert.Equal(t, int64(0), rep.PageTotal.Calls, "workbenches stay out of the page total")
}

func TestUsageLLM_SpoolAutomationRowsInOwnSection(t *testing.T) {
	database, ws := usageLLMEnv(t)
	owner := seedUsageAutomation(t, database, "triage", "Triage", "owner")
	builtin := seedUsageAutomation(t, database, "ideas", "Idea finder", "builtin")
	writeUsageSpool(t, llmusage.SpoolPath(ws),
		withAutomation(usageCall("s1", "watchtower", "automation.llm", "cli:automations run", "haiku", 0.1), owner, 4),
		withAutomation(usageCall("s2", "watchtower", "ideas.consolidate", "daemon", "sonnet", 0.1), builtin, 5),
		withAutomation(usageCall("s3", "watchtower", "automation.llm", "cli:automations run", "haiku", 0.1), 4242, 6),
	)
	rep := usageLLMJSON(t)

	require.Len(t, rep.Watchtower.Rows, 1)
	assert.Equal(t, "ideas.consolidate", rep.Watchtower.Rows[0].Purpose, "a built-in's spooled call is Watchtower's")
	names := map[int64]string{}
	for _, a := range rep.OwnAutomations.Rows {
		names[a.AutomationID] = a.Name
		assert.Equal(t, int64(1), a.Runs)
	}
	assert.Equal(t, map[int64]string{owner: "Triage", 4242: "#4242"}, names)
	assert.NotEmpty(t, rep.LedgerSince, "a spooled call starts the recording")
}

func TestUsageLLM_ReadOnlyCountsSpoolOnce(t *testing.T) {
	database, ws := usageLLMEnv(t)
	inTable := usageCall("same", "watchtower", "digest.channel", "daemon", "haiku", 0.5)
	require.NoError(t, database.InsertLLMCalls([]llmusage.Call{inTable}))
	require.NoError(t, database.Close())

	spool := llmusage.SpoolPath(ws)
	fresh := usageCall("new", "watchtower", "digest.channel", "cli:digest", "haiku", 0.5)
	writeUsageSpool(t, spool+llmusage.ImportingSuffix, inTable, fresh) // an import under way
	writeUsageSpool(t, spool, fresh,                                   // the live file overlaps it
		usageCall("bad", "elsewhere", "digest.channel", "daemon", "haiku", 0.5))
	old := usageCall("old", "watchtower", "digest.channel", "daemon", "haiku", 0.5)
	old.At = time.Now().Add(-40 * 24 * time.Hour).UTC().Format(time.RFC3339)
	f, err := os.OpenFile(spool, os.O_APPEND|os.O_WRONLY, 0o600)
	require.NoError(t, err)
	b, err := json.Marshal(old)
	require.NoError(t, err)
	_, err = f.Write(append(b, '\n'))
	require.NoError(t, err)
	require.NoError(t, f.Close())

	dbPath := filepath.Join(ws, "watchtower.db")
	before, err := os.Stat(dbPath)
	require.NoError(t, err)
	readFile := func(p string) []byte {
		data, err := os.ReadFile(p)
		require.NoError(t, err)
		return data
	}
	importingBefore, liveBefore := readFile(spool+llmusage.ImportingSuffix), readFile(spool)

	rep := usageLLMJSON(t)
	assert.Equal(t, int64(2), rep.Watchtower.Totals.Calls, "the table's call once, the new one once, bad surface and old ones out")
	assert.Equal(t, old.At, rep.LedgerSince, "the earliest recorded call, spooled or not")

	after, err := os.Stat(dbPath)
	require.NoError(t, err)
	assert.Equal(t, before.ModTime(), after.ModTime(), "the database file is not written")
	assert.Equal(t, importingBefore, readFile(spool+llmusage.ImportingSuffix))
	assert.Equal(t, liveBefore, readFile(spool))

	check, err := db.OpenExisting(dbPath, time.Second)
	require.NoError(t, err)
	t.Cleanup(func() { _ = check.Close() })
	var n int
	require.NoError(t, check.QueryRow(`SELECT COUNT(*) FROM llm_calls`).Scan(&n))
	assert.Equal(t, 1, n, "nothing imported")
}

func TestUsageLLM_RejectsUnknownPeriod(t *testing.T) {
	usageLLMEnv(t)
	t.Cleanup(func() {
		flagUsageLLMSince, flagUsageLLMJSON = "7d", false
		rootCmd.SetArgs(nil)
	})
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetArgs([]string{"usage", "llm", "--since", "1y"})
	err := rootCmd.Execute()
	require.Error(t, err)
	assert.Contains(t, err.Error(), "today, 7d or 30d")
}

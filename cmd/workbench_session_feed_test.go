package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlog"
	"watchtower/internal/db"
)

type sessionFeedFx struct {
	database *db.DB
	wb       int64
	session  int64
	dir      string // the transcripts directory of the workbench folder
}

func jsonRec(v map[string]any) string {
	b, _ := json.Marshal(v)
	return string(b) + "\n"
}

func feedUser(uuid, text string) string {
	return jsonRec(map[string]any{"type": "user", "uuid": uuid, "timestamp": "2026-10-01T10:00:00Z",
		"message": map[string]any{"role": "user", "content": text}})
}

func feedAgent(uuid, msg, text string) string {
	return jsonRec(map[string]any{"type": "assistant", "uuid": uuid, "timestamp": "2026-10-01T10:00:05Z",
		"message": map[string]any{"id": msg, "role": "assistant", "content": []map[string]any{{"type": "text", "text": text}}}})
}

func newSessionFeedFx(t *testing.T, convs ...string) sessionFeedFx {
	t.Helper()
	var fx sessionFeedFx
	fx.database = writeActionsConfig(t)
	folder, _ := filepath.EvalSymlinks(t.TempDir())
	var err error
	fx.wb, err = fx.database.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	claude := t.TempDir()
	prev := agentsClaudeDir
	agentsClaudeDir = func() string { return claude }
	t.Cleanup(func() { agentsClaudeDir = prev })
	fx.dir = filepath.Join(claude, "projects", agentlog.Slug(folder))
	require.NoError(t, os.MkdirAll(fx.dir, 0o755))
	res, err := fx.database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 'T', ?, ?)`, fx.wb, folder, convs[0])
	require.NoError(t, err)
	fx.session, err = res.LastInsertId()
	require.NoError(t, err)
	for _, c := range convs[1:] {
		_, err := fx.database.SetTerminalClaudeSessionID(fx.session, fx.wb, c)
		require.NoError(t, err)
	}
	return fx
}

func (fx sessionFeedFx) transcript(t *testing.T, conv string, lines ...string) {
	t.Helper()
	require.NoError(t, os.WriteFile(filepath.Join(fx.dir, conv+".jsonl"), []byte(strings.Join(lines, "")), 0o600))
}

func (fx sessionFeedFx) run(t *testing.T, args ...string) (string, error) {
	t.Helper()
	full := append([]string{"session-feed", "--session", strconv.FormatInt(fx.session, 10)}, args...)
	out, _, err := runWorkbenchAs(t, "workbench", full...)
	return out, err
}

func (fx sessionFeedFx) feedJSON(t *testing.T, args ...string) map[string]any {
	t.Helper()
	out, err := fx.run(t, append(args, "--json")...)
	require.NoError(t, err)
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &m), out)
	return m
}

func feedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func TestSessionFeedJSON_PinnedKeys(t *testing.T) {
	fx := newSessionFeedFx(t, "conv-1")
	fx.transcript(t, "conv-1",
		feedUser("u1", "hello"),
		feedAgent("a1", "m1", "hi there"),
		jsonRec(map[string]any{"type": "assistant", "uuid": "a2", "timestamp": "2026-10-01T10:00:06Z",
			"message": map[string]any{"id": "m2", "role": "assistant", "content": []map[string]any{{
				"type": "tool_use", "id": "toolu_1", "name": "Agent",
				"input": map[string]any{"subagent_type": "Explore", "description": "look around"}}}}}),
		feedUser("u2", "Ask #9 answered (Q: A) — read it with get_ask 9 using the skill."),
	)
	got := fx.feedJSON(t)
	assert.Equal(t, []string{"cursor", "entries", "session_id", "skipped", "subagents", "unknown_records"}, feedKeys(got))
	entries := got["entries"].([]any)
	require.Len(t, entries, 4)
	assert.Equal(t, []string{"at", "conversation", "id", "kind", "text"}, feedKeys(entries[0].(map[string]any)))
	ask := entries[3].(map[string]any)
	assert.Equal(t, []string{"ask_id", "at", "conversation", "id", "kind", "text"}, feedKeys(ask))
	sub := entries[2].(map[string]any)
	assert.Equal(t, []string{"agent_id", "description", "status", "tool_use_id", "type"}, feedKeys(sub["subagent"].(map[string]any)))
	assert.Len(t, got["subagents"], 1)
	assert.NotEmpty(t, got["cursor"])
	assert.Equal(t, map[string]any{}, got["unknown_records"])
}

func TestSessionFeed_TabAcrossClear(t *testing.T) {
	fx := newSessionFeedFx(t, "conv-1", "conv-2")
	fx.transcript(t, "conv-1", feedUser("u1", "first"))
	fx.transcript(t, "conv-2", feedUser("u2", "second"))
	got := fx.feedJSON(t)
	var kinds []string
	for _, e := range got["entries"].([]any) {
		kinds = append(kinds, e.(map[string]any)["kind"].(string))
	}
	assert.Equal(t, []string{"owner", "separator", "owner"}, kinds)
	cur := got["cursor"].(string)
	assert.True(t, strings.HasPrefix(cur, "conv-2:"), cur)

	again := fx.feedJSON(t, "--after", cur)
	assert.Empty(t, again["entries"])
	assert.Equal(t, cur, again["cursor"])
}

func TestSessionFeed_AskFromOwnWorkbenchOnly(t *testing.T) {
	fx := newSessionFeedFx(t, "conv-1")
	insert := func(wb int64, title string) int64 {
		res, err := fx.database.Exec(`INSERT INTO owner_asks (project_id, kind, title, summary, payload, status, answer, level, origin, created_at)
			VALUES (?, 'question', ?, 's', ?, 'answered', ?, 'quick', 'agent', '2026-10-10T09:00:00Z')`, wb, title,
			`{"focus":[],"questions":[{"id":"q1","question":"Style?","options":[{"label":"snake"},{"label":"camel"}]}],"checklist":[]}`,
			`{"answers":[{"id":"q1","labels":["snake"],"other":""}],"checklist":[],"comments":[],"note":"","verdict":""}`)
		require.NoError(t, err)
		id, err := res.LastInsertId()
		require.NoError(t, err)
		return id
	}
	other, err := fx.database.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	mine, foreign := insert(fx.wb, "Key style?"), insert(other, "Foreign secret")
	fx.transcript(t, "conv-1",
		feedUser("u1", fmt.Sprintf("Ask #%d answered (Q: A) — read it with get_ask %d using the skill.", mine, mine)),
		feedUser("u2", fmt.Sprintf("Ask #%d answered (Q: A) — read it with get_ask %d using the skill.", foreign, foreign)),
	)
	entries := fx.feedJSON(t)["entries"].([]any)
	require.Len(t, entries, 2)
	own := entries[0].(map[string]any)
	assert.Equal(t, "Key style?", own["title"])
	assert.Contains(t, own["text"], "snake")
	alien := entries[1].(map[string]any)
	assert.NotContains(t, alien, "title")
	assert.NotContains(t, alien["text"], "Foreign")
	assert.NotContains(t, alien["text"], "snake")
}

func TestSessionFeed_Errors(t *testing.T) {
	fx := newSessionFeedFx(t, "conv-1")
	_, _, err := runWorkbenchAs(t, "workbench", "session-feed", "--session", "9999")
	assert.EqualError(t, err, "session 9999 not found")

	res, err := fx.database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path) VALUES (?, 'shell', 'sh', '/tmp/acme')`, fx.wb)
	require.NoError(t, err)
	shell, _ := res.LastInsertId()
	_, _, err = runWorkbenchAs(t, "workbench", "session-feed", "--session", strconv.FormatInt(shell, 10))
	assert.EqualError(t, err, fmt.Sprintf("session %d is not an agent session", shell))

	res, err = fx.database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path) VALUES (?, 'codex', 'cx', '/tmp/acme')`, fx.wb)
	require.NoError(t, err)
	codex, _ := res.LastInsertId()
	_, _, err = runWorkbenchAs(t, "workbench", "session-feed", "--session", strconv.FormatInt(codex, 10))
	assert.EqualError(t, err, fmt.Sprintf("session %d: codex sessions are not supported yet", codex))

	_, err = fx.run(t, "--subagent", "toolu_nope")
	assert.EqualError(t, err, "subagent toolu_nope not found")
}

func TestSessionFeed_SubagentDrillIn(t *testing.T) {
	fx := newSessionFeedFx(t, "conv-1")
	call := func(id string) string {
		return jsonRec(map[string]any{"type": "assistant", "uuid": "a-" + id, "timestamp": "2026-10-01T10:00:06Z",
			"message": map[string]any{"id": "m-" + id, "role": "assistant", "content": []map[string]any{{
				"type": "tool_use", "id": id, "name": "Agent",
				"input": map[string]any{"subagent_type": "Explore", "description": "look " + id}}}}})
	}
	fx.transcript(t, "conv-1", feedUser("u1", "go"), call("toolu_1"))
	subDir := filepath.Join(fx.dir, "conv-1", "subagents")
	require.NoError(t, os.MkdirAll(subDir, 0o755))
	side := func(line string) string {
		var m map[string]any
		require.NoError(t, json.Unmarshal([]byte(line), &m))
		m["isSidechain"] = true
		return jsonRec(m)
	}
	meta := func(id, tool string) {
		require.NoError(t, os.WriteFile(filepath.Join(subDir, "agent-"+id+".meta.json"),
			[]byte(`{"toolUseId":"`+tool+`","finished":true,"agentType":"Explore"}`), 0o600))
	}
	meta("aa", "toolu_1")
	meta("bb", "toolu_2")
	require.NoError(t, os.WriteFile(filepath.Join(subDir, "agent-aa.jsonl"),
		[]byte(side(feedUser("s1", "task one"))+side(call("toolu_2"))), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(subDir, "agent-bb.jsonl"),
		[]byte(side(feedUser("s2", "nested task"))+side(feedAgent("s3", "sm", "nested done"))), 0o600))

	top := fx.feedJSON(t, "--subagent", "toolu_1")
	assert.Equal(t, "", top["cursor"])
	assert.Equal(t, []string{"cursor", "entries", "session_id", "skipped", "subagents", "unknown_records"}, feedKeys(top))
	assert.Len(t, top["subagents"], 1)
	assert.Equal(t, "toolu_2", top["subagents"].([]any)[0].(map[string]any)["id"])

	nested := fx.feedJSON(t, "--subagent", "toolu_2")
	entries := nested["entries"].([]any)
	require.NotEmpty(t, entries)
	assert.Equal(t, "nested task", entries[0].(map[string]any)["text"])
	assert.Empty(t, nested["subagents"])
}

func TestSessionFeed_PlainOutput(t *testing.T) {
	fx := newSessionFeedFx(t, "conv-1", "conv-2")
	fx.transcript(t, "conv-1", feedUser("u1", "hello\nsecond line"), feedAgent("a1", "m1", "hi there"))
	fx.transcript(t, "conv-2", feedUser("u2", "again"))
	out, err := fx.run(t)
	require.NoError(t, err)
	assert.Regexp(t, `(?m)^\d\d:\d\d  You:\n    hello\n    second line\n\d\d:\d\d  Agent:\n    hi there\n── new conversation ──\n\d\d:\d\d  You:\n    again\n$`, out)
	t.Log("\n" + out)
}

func TestSessionFeed_AfterAndSubagentExclusive(t *testing.T) {
	fx := newSessionFeedFx(t, "conv-1")
	_, err := fx.run(t, "--after", "conv-1:0", "--subagent", "toolu_x")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "none of the others can be")
}

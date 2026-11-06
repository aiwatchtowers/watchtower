package agentlog

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/klauspost/compress/zstd"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlogdb"
)

// Every rollout line below is hand-made (no recorded codex output is copied):
// each carries "synthetic": true, and ids are zero UUIDs.

const (
	cxParent = "00000000-0000-0000-0000-00000000c0d1"
	cxFork   = "00000000-0000-0000-0000-00000000c0d2"
	cxOther  = "00000000-0000-0000-0000-00000000c0d3"
)

// cx is one synthetic rollout line.
func cx(t *testing.T, ts, typ string, payload map[string]any) string {
	t.Helper()
	b, err := json.Marshal(map[string]any{"timestamp": "2026-11-01T10:00:" + ts + "Z", "type": typ, "payload": payload, "synthetic": true})
	require.NoError(t, err)
	return string(b) + "\n"
}

func cxMeta(t *testing.T, ts, id, cwd string) string {
	return cx(t, ts, "session_meta", map[string]any{"id": id, "timestamp": "2026-11-01T10:00:" + ts + "Z", "cwd": cwd,
		"git": map[string]any{"branch": "main"}, "base_instructions": map[string]any{"text": "SENTINEL-INSTRUCTIONS"}})
}

func cxModel(t *testing.T, ts, model string) string {
	return cx(t, ts, "turn_context", map[string]any{"model": model, "cwd": "/work"})
}

func cxUser(t *testing.T, ts, id, text string) string {
	return cx(t, ts, "event_msg", map[string]any{"type": "item_completed",
		"item": map[string]any{"type": "UserMessage", "id": id, "content": []any{map[string]any{"type": "text", "text": text}}}})
}

func cxLegacyUser(t *testing.T, ts, text string) string {
	return cx(t, ts, "event_msg", map[string]any{"type": "user_message", "message": text})
}

func cxAgent(t *testing.T, ts, text string) string {
	return cx(t, ts, "event_msg", map[string]any{"type": "agent_message", "message": text}) +
		cx(t, ts, "response_item", map[string]any{"type": "message", "role": "assistant",
			"content": []any{map[string]any{"type": "output_text", "text": text}}})
}

func cxExec(t *testing.T, ts, callID, cmd string) string {
	args, err := json.Marshal(map[string]any{"cmd": cmd, "workdir": "/work"})
	require.NoError(t, err)
	return cx(t, ts, "response_item", map[string]any{"type": "function_call", "name": "exec_command", "arguments": string(args), "call_id": callID})
}

func cxOut(t *testing.T, ts, callID, text string) string {
	return cx(t, ts, "response_item", map[string]any{"type": "function_call_output", "call_id": callID, "output": text})
}

func cxTokens(t *testing.T, ts string, in, cached, out, reasoning, total int64) string {
	u := map[string]any{"input_tokens": in, "cached_input_tokens": cached, "output_tokens": out,
		"reasoning_output_tokens": reasoning, "total_tokens": in + out}
	tot := map[string]any{"input_tokens": 0, "cached_input_tokens": 0, "output_tokens": 0, "reasoning_output_tokens": 0, "total_tokens": total}
	return cx(t, ts, "event_msg", map[string]any{"type": "token_count", "info": map[string]any{"last_token_usage": u, "total_token_usage": tot}})
}

// session is a whole parent rollout: brief, owner prompt, a model step, a
// failing `go test`, a second step, an answer. Two token_count responses,
// one repeated (same totals) and one with no info.
func cxSession(t *testing.T, id, cwd string) string {
	return cxMeta(t, "00.000", id, cwd) +
		cxModel(t, "00.500", "gpt-test") +
		cxUser(t, "01.000", "u-brief-"+id, "Watchtower workbench #7 brief: SENTINEL-BRIEF") +
		cxUser(t, "02.000", "u-1-"+id, "SENTINEL-PROMPT please run the tests") +
		cx(t, "02.500", "response_item", map[string]any{"type": "reasoning", "encrypted_content": "SENTINEL-REASONING"}) +
		cxExec(t, "05.000", "call-1-"+id, "go test ./... SENTINEL-ARG") +
		cxTokens(t, "05.000", 1000, 600, 50, 20, 1050) +
		cxOut(t, "09.000", "call-1-"+id, "SENTINEL-OUTPUT\nProcess exited with code 1\n") +
		cxTokens(t, "12.000", 1200, 900, 80, 30, 2330) +
		cxTokens(t, "12.100", 1200, 900, 80, 30, 2330) + // repeated report of the same response
		cx(t, "12.200", "event_msg", map[string]any{"type": "token_count", "info": nil}) +
		cxAgent(t, "12.000", "SENTINEL-ANSWER tests fail")
}

// writeRollout writes content as the rollout of session id under the codex
// home and returns its path.
func (f *fixture) writeRollout(id, content string) string {
	f.t.Helper()
	dir := filepath.Join(f.codex, "sessions", "2026", "11", "01")
	require.NoError(f.t, os.MkdirAll(dir, 0o755))
	p := filepath.Join(dir, "rollout-2026-11-01T10-00-00-"+id+".jsonl")
	require.NoError(f.t, os.WriteFile(p, []byte(content), 0o600))
	return p
}

// codexRow inserts a codex terminal session of workbench wb running id;
// stored is its agent_transcript_path ("" = none).
func (f *fixture) codexRow(wb int64, id, folder, stored string) int64 {
	f.t.Helper()
	var path any
	if stored != "" {
		path = stored
	}
	res, err := f.d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, agent_transcript_path)
		VALUES (?, 'codex', 'c', ?, ?, ?)`, wb, folder, id, path)
	require.NoError(f.t, err)
	n, err := res.LastInsertId()
	require.NoError(f.t, err)
	return n
}

func (f *fixture) sessionUUIDs() []string {
	f.t.Helper()
	rows, err := f.al.Query(`SELECT session_uuid FROM agent_log_sessions ORDER BY session_uuid`)
	require.NoError(f.t, err)
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		require.NoError(f.t, rows.Scan(&s))
		out = append(out, s)
	}
	require.NoError(f.t, rows.Err())
	return out
}

func parseCodex(t *testing.T, s string, o ParseOptions) *ParseResult {
	t.Helper()
	pr, err := ParseCodex(strings.NewReader(s), 0, o)
	require.NoError(t, err)
	return pr
}

func TestParseCodex_TokenCountPerResponse(t *testing.T) {
	pr := parseCodex(t, cxSession(t, cxParent, "/work"), ParseOptions{Path: "/r.jsonl", Folder: "/work", SessionUUID: cxParent})
	var calls, owners, tools []agentlogdb.AgentLogEvent
	for _, e := range pr.Events {
		switch e.Kind {
		case "api_call":
			calls = append(calls, e)
		case "owner_turn":
			owners = append(owners, e)
		case "tool":
			tools = append(tools, e)
		}
	}
	require.Len(t, calls, 2, "one api_call per token_count response; the repeat and the empty one add nothing")
	assert.Equal(t, int64(400), calls[0].InputTokens, "input without the cached part")
	assert.Equal(t, int64(600), calls[0].CacheReadTokens)
	assert.Equal(t, int64(50), calls[0].OutputTokens)
	assert.Equal(t, int64(20), calls[0].ThinkingTokens)
	assert.Equal(t, "gpt-test", calls[0].Name)
	assert.True(t, calls[0].CostEstimated, "a model with no price stays unpriced")
	assert.Zero(t, calls[0].CostUSD)
	assert.Equal(t, int64(300), calls[1].InputTokens)
	assert.Equal(t, int64(80), calls[1].OutputTokens)

	require.Len(t, owners, 2)
	assert.Equal(t, "hook", owners[0].Trigger, "the Watchtower brief is not the owner's turn")
	assert.Equal(t, "owner", owners[1].Trigger)

	require.Len(t, tools, 1)
	assert.Equal(t, "Bash", tools[0].Name)
	assert.Equal(t, "go test", tools[0].Target)
	assert.Equal(t, "pending", tools[0].Outcome)
	require.Len(t, pr.ToolResults, 1)
	assert.Equal(t, "error", pr.ToolResults[0].Outcome)
	assert.Equal(t, "exit_code", pr.ToolResults[0].ErrorClass)

	s := pr.Sessions[cxParent]
	require.NotNil(t, s)
	assert.Equal(t, "codex", s.Agent)
	assert.Equal(t, "/work", s.HomeCWD)
	assert.Equal(t, "main", s.GitBranch)
	assert.Equal(t, "gpt-test", s.Model)
	assert.Equal(t, "2026-11-01T10:00:00.000Z", s.StartedAt)
	assert.Equal(t, "2026-11-01T10:00:12.200Z", s.EndedAt)
	for _, e := range pr.Events {
		assert.Equal(t, cxParent, e.SessionUUID)
	}
}

func TestParseCodex_LegacyOwnerLineInterruptAndIncrementalRead(t *testing.T) {
	full := cxMeta(t, "00.000", cxParent, "/work") + cxLegacyUser(t, "01.000", "SENTINEL-PROMPT") +
		cx(t, "01.500", "event_msg", map[string]any{"type": "turn_aborted", "reason": "interrupted"})
	pr := parseCodex(t, full, ParseOptions{Path: "/r.jsonl", SessionUUID: cxParent})
	require.Len(t, pr.Events, 2)
	assert.Equal(t, "owner_turn", pr.Events[0].Kind)
	assert.Equal(t, "owner", pr.Events[0].Trigger)
	assert.Equal(t, "owner_turn", pr.Events[1].Kind)
	assert.Equal(t, "interrupt", pr.Events[1].Trigger, "an interrupted turn is the owner's interrupt")
	// A read that starts past session_meta still knows the session.
	more := cxTokens(t, "02.000", 10, 0, 5, 0, 15)
	pr2, err := ParseCodex(strings.NewReader(more), int64(len(full)), ParseOptions{Path: "/r.jsonl", SessionUUID: cxParent})
	require.NoError(t, err)
	require.Len(t, pr2.Events, 1)
	assert.Equal(t, cxParent, pr2.Events[0].SessionUUID)
	assert.Equal(t, int64(len(more)), pr2.Consumed)
}

func TestParseCodex_CompressedRollout(t *testing.T) {
	f := newFixture(t)
	plain := cxSession(t, cxParent, f.folder)
	var buf bytes.Buffer
	enc, err := zstd.NewWriter(&buf)
	require.NoError(t, err)
	_, err = enc.Write([]byte(plain))
	require.NoError(t, err)
	require.NoError(t, enc.Close())
	f.writeRollout(cxParent, buf.String())
	f.codexRow(f.wb, cxParent, f.folder, "")
	r := f.scan()
	assert.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	calls, out := f.totals()
	assert.Equal(t, int64(2), calls)
	assert.Equal(t, int64(130), out)
	r = f.scan()
	assert.Equal(t, 1, r.FilesSkipped, "an unchanged compressed rollout is not read again")
}

func TestAgentlog04_CodexOnlyWorkbenchRolloutsRead(t *testing.T) {
	f := newFixture(t)
	elsewhere := t.TempDir()
	otherWB, err := f.d.CreateWorkbench("other", elsewhere)
	require.NoError(t, err)

	f.writeRollout(cxParent, cxSession(t, cxParent, f.folder))
	f.codexRow(f.wb, cxParent, f.folder, "")
	// A rollout with no terminal session row: unreadable, so opening it would fail the scan's file.
	stray := f.writeRollout(cxOther, cxSession(t, cxOther, f.folder))
	require.NoError(t, os.Chmod(stray, 0o000))
	// Another workbench's codex row.
	otherPath := f.writeRollout(cxFork, cxSession(t, cxFork, elsewhere))
	f.codexRow(otherWB, cxFork, elsewhere, otherPath)

	r := f.scan()
	assert.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	assert.Equal(t, []string{cxParent}, f.sessionUUIDs())
	for _, p := range []string{stray, otherPath} {
		fr, err := f.al.GetAgentLogFile(p)
		require.NoError(t, err)
		assert.Nil(t, fr, p)
	}
	var tsid int64
	require.NoError(t, f.al.QueryRow(`SELECT terminal_session_id FROM agent_log_sessions WHERE session_uuid = ?`, cxParent).Scan(&tsid))
	assert.NotZero(t, tsid, "the session is attached to its codex row")
}

func TestAgentlog04_CodexRowWithForeignCwdNotRead(t *testing.T) {
	f := newFixture(t)
	elsewhere := t.TempDir()
	stored := f.writeRollout(cxParent, cxSession(t, cxParent, elsewhere)) // the rollout ran outside the workbench
	f.codexRow(f.wb, cxParent, f.folder, stored)
	f.scan()
	assert.Empty(t, f.sessionUUIDs())
}

func TestAgentlog04_CodexSymlinkSkipped(t *testing.T) {
	f := newFixture(t)
	target := filepath.Join(t.TempDir(), "rollout-2026-11-01T10-00-00-"+cxParent+".jsonl")
	require.NoError(t, os.WriteFile(target, []byte(cxSession(t, cxParent, f.folder)), 0o600))
	// The file in the date folder is a symlink, and so is the stored path.
	dir := filepath.Join(f.codex, "sessions", "2026", "11", "01")
	require.NoError(t, os.MkdirAll(dir, 0o755))
	link := filepath.Join(dir, filepath.Base(target))
	require.NoError(t, os.Symlink(target, link))
	f.codexRow(f.wb, cxParent, f.folder, link)

	// A symlinked date folder holding a real file.
	realDir := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(realDir, "rollout-2026-11-02T10-00-00-"+cxFork+".jsonl"),
		[]byte(cxSession(t, cxFork, f.folder)), 0o600))
	require.NoError(t, os.Symlink(realDir, filepath.Join(f.codex, "sessions", "2026", "11", "02")))
	f.codexRow(f.wb, cxFork, f.folder, "")

	f.scan()
	assert.Empty(t, f.sessionUUIDs())
}

func TestAgentlog04_CodexLongestFolderWins(t *testing.T) {
	f := newFixture(t)
	inner := filepath.Join(f.folder, "inner")
	require.NoError(t, os.Mkdir(inner, 0o755))
	innerWB, err := f.d.CreateWorkbench("inner", inner)
	require.NoError(t, err)
	require.NoError(t, f.d.SetWorkbenchAgentAnalytics(innerWB, true))
	// The outer workbench's row ran in the inner workbench's folder: inner wins, outer reads nothing.
	f.writeRollout(cxParent, cxSession(t, cxParent, inner))
	f.codexRow(f.wb, cxParent, f.folder, "")
	f.scan()
	assert.Empty(t, f.sessionUUIDs())
	// The inner workbench's own row is read by the inner scan.
	f.writeRollout(cxFork, cxSession(t, cxFork, inner))
	f.codexRow(innerWB, cxFork, inner, "")
	_, err = Scan(t.Context(), f.d, f.al, innerWB, Options{ClaudeDir: f.claude, CodexHome: f.codex})
	require.NoError(t, err)
	assert.Equal(t, []string{cxFork}, f.sessionUUIDs())
}

func TestAgentlog01_CodexNoTranscriptText(t *testing.T) {
	f := newFixture(t)
	f.writeRollout(cxParent, cxSession(t, cxParent, f.folder)+
		cx(t, "13.000", "response_item", map[string]any{"type": "custom_tool_call", "name": "exec", "call_id": "call-2",
			"input": `const r = await tools.exec_command({cmd: "rg SENTINEL-PATTERN", workdir: "/work"});`})+
		cx(t, "14.000", "response_item", map[string]any{"type": "custom_tool_call_output", "call_id": "call-2",
			"output": []any{map[string]any{"type": "input_text", "text": "SENTINEL-HIT"}}}))
	f.codexRow(f.wb, cxParent, f.folder, "")
	r := f.scan()
	require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	calls, _ := f.totals()
	require.Equal(t, int64(2), calls)
	assertNoSentinel(t, f.al)
}

// assertNoSentinel dumps every text column of every agent_log table.
func assertNoSentinel(t *testing.T, al *agentlogdb.DB) {
	t.Helper()
	for _, n := range agentLogTables(t, al) {
		for col, v := range tableText(t, al, n) {
			assert.NotContains(t, v, "SENTINEL", "%s.%s", n, col)
		}
	}
}

func agentLogTables(t *testing.T, al *agentlogdb.DB) []string {
	t.Helper()
	rows, err := al.Query(`SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'agent_log%'`)
	require.NoError(t, err)
	defer rows.Close()
	var names []string
	for rows.Next() {
		var n string
		require.NoError(t, rows.Scan(&n))
		names = append(names, n)
	}
	require.NoError(t, rows.Err())
	return names
}

// tableText is every text value of table, as "<column>#<row>" → value.
func tableText(t *testing.T, al *agentlogdb.DB, table string) map[string]string {
	t.Helper()
	rows, err := al.Query(`SELECT * FROM ` + table)
	require.NoError(t, err)
	defer rows.Close()
	cols, err := rows.Columns()
	require.NoError(t, err)
	out := map[string]string{}
	for r := 0; rows.Next(); r++ {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		require.NoError(t, rows.Scan(ptrs...))
		for i, v := range vals {
			switch x := v.(type) {
			case string:
				out[fmt.Sprintf("%s#%d", cols[i], r)] = x
			case []byte:
				out[fmt.Sprintf("%s#%d", cols[i], r)] = string(x)
			}
		}
	}
	require.NoError(t, rows.Err())
	return out
}

func TestAgentlog02_CodexForkedRolloutCountsOnce(t *testing.T) {
	for _, order := range [][]string{{cxParent, cxFork}, {cxFork, cxParent}} {
		f := newFixture(t)
		parent := cxSession(t, cxParent, f.folder)
		// A fork starts with its own session_meta, replays the parent's
		// lines verbatim (its session_meta included), then goes on.
		fork := cxMeta(t, "30.000", cxFork, f.folder) + parent +
			cxUser(t, "31.000", "u-9", "SENTINEL-PROMPT go on") + cxTokens(t, "35.000", 100, 0, 7, 0, 2437)
		content := map[string]string{cxParent: parent, cxFork: fork}
		f.codexRow(f.wb, cxParent, f.folder, "")
		f.codexRow(f.wb, cxFork, f.folder, "")
		for _, id := range order {
			f.writeRollout(id, content[id])
			r := f.scan()
			require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
		}
		calls, out := f.totals()
		assert.Equal(t, int64(3), calls, "order %v", order)
		assert.Equal(t, int64(137), out, "order %v", order)
		var parentCalls int
		require.NoError(t, f.al.QueryRow(`SELECT COUNT(*) FROM agent_log_events WHERE kind = 'api_call' AND session_uuid = ?`, cxParent).Scan(&parentCalls))
		assert.Equal(t, 2, parentCalls, "replayed calls stay with the earlier session")
	}
}

func TestAgentlog05_CodexReadOnly(t *testing.T) {
	f := newFixture(t)
	f.writeRollout(cxParent, cxSession(t, cxParent, f.folder))
	var buf bytes.Buffer
	enc, err := zstd.NewWriter(&buf)
	require.NoError(t, err)
	_, err = enc.Write([]byte(cxSession(t, cxFork, f.folder)))
	require.NoError(t, err)
	require.NoError(t, enc.Close())
	f.writeRollout(cxFork, buf.String())
	f.codexRow(f.wb, cxParent, f.folder, "")
	f.codexRow(f.wb, cxFork, f.folder, "")
	before := treeSnapshot(t, f.codex)
	r := f.scan()
	require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	require.Len(t, f.sessionUUIDs(), 2)
	assert.Equal(t, before, treeSnapshot(t, f.codex), "no file under CODEX_HOME is written, moved, added or removed")
}

// treeSnapshot is every entry under root with its mode, mtime and, for a
// regular file, the hash of its bytes.
func treeSnapshot(t *testing.T, root string) map[string]string {
	t.Helper()
	out := map[string]string{}
	var files []string
	require.NoError(t, filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		fi, err := d.Info()
		if err != nil {
			return err
		}
		out[p] = fi.Mode().String() + " " + fi.ModTime().String()
		if fi.Mode().IsRegular() {
			files = append(files, p)
		}
		return nil
	}))
	for _, p := range files {
		b, err := os.ReadFile(p)
		require.NoError(t, err)
		sum := sha256.Sum256(b)
		out[p] += " " + hex.EncodeToString(sum[:])
	}
	return out
}

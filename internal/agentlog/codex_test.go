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
	"time"

	"github.com/klauspost/compress/zstd"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlogdb"
)

// Every rollout line below is hand-made (no recorded codex output is copied):
// each carries "synthetic": true, and ids are zero UUIDs.

const (
	cxParent = "00000000-0000-0000-0000-00000000c0d1"
	cxFork   = "00000000-0000-0000-0000-00000000c0d0" // sorts before cxParent: a start tie would hand the fork the replayed rows
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
	r := f.scan()
	assert.Empty(t, f.sessionUUIDs())
	assert.Equal(t, 1, r.CodexOutsideWorkbench, "a skipped rollout is counted, not silent")
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
		cx(t, "13.000", "response_item", map[string]any{"type": "custom_tool_call", "name": "functions.exec", "call_id": "call-2",
			"input": `const r = await tools.exec_command({cmd: "rg SENTINEL-PATTERN", workdir: "/work"});`})+
		cx(t, "14.000", "response_item", map[string]any{"type": "custom_tool_call_output", "call_id": "call-2",
			"output": []any{map[string]any{"type": "input_text", "text": "SENTINEL-HIT"}}}))
	f.codexRow(f.wb, cxParent, f.folder, "")
	r := f.scan()
	require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	calls, _ := f.totals()
	require.Equal(t, int64(2), calls)
	var name, target string
	require.NoError(t, f.al.QueryRow(`SELECT name, target FROM agent_log_events WHERE key = 'tool:codex:call-2'`).Scan(&name, &target))
	assert.Equal(t, "Bash", name, "the namespaced exec tool is a shell call")
	assert.Equal(t, "rg", target)
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
	// The parent spawns a child, which spawns a grandchild (ask #1132): the
	// sub-agent rollouts are read and left untouched too.
	f.writeRollout(cxParent, cxSession(t, cxParent, f.folder)+cxSpawn(t, "13.000", "call-spawn-1", cxChild))
	f.writeRollout(cxChild, cxChildMeta(t, "19.000", cxChild, cxParent, f.folder)+cxChildBody(t, cxChild, 9000)+
		cxSpawn(t, "23.000", "call-spawn-2", cxGrand))
	f.writeRollout(cxGrand, cxChildMeta(t, "24.000", cxGrand, cxChild, f.folder)+cxChildBody(t, cxGrand, 9100))
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
	require.NotEmpty(t, f.lane(cxChild), "the child was read")
	require.NotEmpty(t, f.lane(cxGrand), "the grandchild was read")
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

func TestAgentlog04_CodexStoredPathInSymlinkedFolderSkipped(t *testing.T) {
	f := newFixture(t)
	realDir := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(f.codex, "sessions", "2026", "11"), 0o755))
	linkDir := filepath.Join(f.codex, "sessions", "2026", "11", "03")
	require.NoError(t, os.Symlink(realDir, linkDir))
	name := "rollout-2026-11-03T10-00-00-" + cxParent + ".jsonl"
	require.NoError(t, os.WriteFile(filepath.Join(realDir, name), []byte(cxSession(t, cxParent, f.folder)), 0o600))
	f.codexRow(f.wb, cxParent, f.folder, filepath.Join(linkDir, name)) // the stored path runs through the symlinked folder
	r := f.scan()
	assert.Empty(t, f.sessionUUIDs())
	assert.Equal(t, 1, r.CodexRolloutsMissing)
}

func TestAgentlog04_CodexArchivedRolloutRead(t *testing.T) {
	f := newFixture(t)
	dir := filepath.Join(f.codex, "archived_sessions")
	require.NoError(t, os.MkdirAll(dir, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "rollout-2026-11-01T10-00-00-"+cxParent+".jsonl"),
		[]byte(cxSession(t, cxParent, f.folder)), 0o600))
	f.codexRow(f.wb, cxParent, f.folder, "")
	r := f.scan()
	assert.Zero(t, r.CodexRolloutsMissing)
	assert.Equal(t, []string{cxParent}, f.sessionUUIDs())
}

func TestScan_CodexUnreadableRolloutCountsAsFailed(t *testing.T) {
	f := newFixture(t)
	p := f.writeRollout(cxParent, cxSession(t, cxParent, f.folder))
	require.NoError(t, os.Chmod(p, 0o000))
	f.codexRow(f.wb, cxParent, f.folder, "")
	r := f.scan()
	assert.Equal(t, 1, r.FailedFiles, "an unreadable rollout of the workbench's own row is a failed file, not a foreign one")
	assert.Zero(t, r.CodexOutsideWorkbench)
	require.NoError(t, os.Chmod(p, 0o600))
	r = f.scan()
	assert.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	assert.Equal(t, []string{cxParent}, f.sessionUUIDs(), "the next scan asks again")
}

func TestScan_CodexIncrementalSeedsModelAndCwd(t *testing.T) {
	f := newFixture(t)
	sub := filepath.Join(f.folder, "sub")
	require.NoError(t, os.Mkdir(sub, 0o755))
	first := cxSession(t, cxParent, sub)
	p := f.writeRollout(cxParent, first)
	f.codexRow(f.wb, cxParent, sub, "")
	f.scan()
	// The next lines: a late repeat of the last response (a new line time,
	// the same figures), a new response with no turn_context, a relative patch.
	more := cxTokens(t, "20.000", 1200, 900, 80, 30, 2330) +
		cxTokens(t, "25.000", 1500, 1000, 40, 0, 3870) +
		cx(t, "26.000", "response_item", map[string]any{"type": "custom_tool_call", "name": "apply_patch", "call_id": "call-p",
			"input": "*** Begin Patch\n*** Update File: a.go\n@@\n-x\n+y\n*** End Patch"})
	fh, err := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0o600)
	require.NoError(t, err)
	_, err = fh.WriteString(more)
	require.NoError(t, err)
	require.NoError(t, fh.Close())
	r := f.scan()
	require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	calls, out := f.totals()
	assert.Equal(t, int64(3), calls, "the late repeat adds nothing")
	assert.Equal(t, int64(170), out)
	var name string
	require.NoError(t, f.al.QueryRow(`SELECT name FROM agent_log_events WHERE kind = 'api_call' ORDER BY src_offset DESC LIMIT 1`).Scan(&name))
	assert.Equal(t, "gpt-test", name, "the model of the earlier read")
	var target string
	require.NoError(t, f.al.QueryRow(`SELECT target FROM agent_log_events WHERE key = 'tool:codex:call-p'`).Scan(&target))
	assert.Equal(t, "sub/a.go", target, "relative to the session's cwd, then to the workbench folder")
}

// A compressed rollout that takes several scans resumes where the last one
// stopped instead of rereading its start every time.
func TestScan_CodexCompressedResumesAcrossScans(t *testing.T) {
	old := batchRows
	batchRows = 2
	t.Cleanup(func() { batchRows = old })
	f := newFixture(t)
	var b strings.Builder
	b.WriteString(cxMeta(t, "00.000", cxParent, f.folder) + cxModel(t, "00.500", "gpt-test"))
	for i := range 8 {
		b.WriteString(cxTokens(t, fmt.Sprintf("%02d.000", 10+i), 100, 0, int64(i+1), 0, int64(1000*(i+1))))
	}
	var buf bytes.Buffer
	enc, err := zstd.NewWriter(&buf)
	require.NoError(t, err)
	_, err = enc.Write([]byte(b.String()))
	require.NoError(t, err)
	require.NoError(t, enc.Close())
	f.writeRollout(cxParent, buf.String())
	f.codexRow(f.wb, cxParent, f.folder, "")

	// Each scan has time for one slice: the third clock read (after the
	// first slice) is past the deadline.
	oneSlice := func() Options {
		n, base := 0, time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
		return Options{ClaudeDir: f.claude, CodexHome: f.codex, Budget: time.Minute, Now: func() time.Time {
			n++
			if n > 2 {
				return base.Add(time.Hour)
			}
			return base
		}}
	}
	done := false
	for range 8 {
		r, err := Scan(t.Context(), f.d, f.al, f.wb, oneSlice())
		require.NoError(t, err)
		require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
		if !r.Incomplete {
			done = true
			break
		}
	}
	require.True(t, done, "the import finishes one slice per scan")
	calls, out := f.totals()
	assert.Equal(t, int64(8), calls)
	assert.Equal(t, int64(36), out)
}

// A /clear moves a codex tab to a new conversation; the old conversation is
// still the workbench's (the agent session ledger) and is read.
func TestScan_CodexEarlierConversationOfTabRead(t *testing.T) {
	f := newFixture(t)
	f.writeRollout(cxParent, cxSession(t, cxParent, f.folder))
	id := f.codexRow(f.wb, cxParent, f.folder, "")
	_, err := f.d.Exec(`UPDATE terminal_sessions SET claude_session_id = ? WHERE id = ?`, cxFork, id)
	require.NoError(t, err)
	r := f.scan()
	assert.Equal(t, []string{cxParent}, f.sessionUUIDs())
	assert.Equal(t, 1, r.CodexRolloutsMissing, "the new conversation has no rollout yet")
	var tsid int64
	require.NoError(t, f.al.QueryRow(`SELECT terminal_session_id FROM agent_log_sessions WHERE session_uuid = ?`, cxParent).Scan(&tsid))
	assert.Equal(t, id, tsid)
}

// A fork whose replayed lines were re-stamped when written (an hour later):
// tokens still count once, and the parent's tool call keeps its own timing
// in either scan order.
func TestAgentlog02_CodexRestampedForkCountsOnceAndKeepsTiming(t *testing.T) {
	for _, order := range [][]string{{cxParent, cxFork}, {cxFork, cxParent}} {
		f := newFixture(t)
		parent := cxSession(t, cxParent, f.folder)
		fork := strings.ReplaceAll(cxMeta(t, "00.000", cxFork, f.folder)+parent, "T10:00:", "T11:00:") +
			strings.ReplaceAll(cxTokens(t, "35.000", 100, 0, 7, 0, 2437), "T10:00:", "T11:00:")
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
		var owner string
		var ms int64
		require.NoError(t, f.al.QueryRow(`SELECT session_uuid, duration_ms FROM agent_log_events WHERE key = ?`,
			"tool:codex:call-1-"+cxParent).Scan(&owner, &ms))
		assert.Equal(t, cxParent, owner, "order %v", order)
		assert.Equal(t, int64(4000), ms, "the parent's own call-to-output time, order %v", order)
	}
}

// The parent's rollout ends with a call still open; the fork replays the call
// and carries its result. Either scan order fills the row.
func TestAgentlog02_CodexResultOnlyInForkFillsPendingRow(t *testing.T) {
	for _, order := range [][]string{{cxParent, cxFork}, {cxFork, cxParent}} {
		f := newFixture(t)
		parent := cxMeta(t, "00.000", cxParent, f.folder) + cxExec(t, "05.000", "call-open", "go test ./...")
		fork := cxMeta(t, "30.000", cxFork, f.folder) + parent + cxOut(t, "40.000", "call-open", "Process exited with code 2")
		content := map[string]string{cxParent: parent, cxFork: fork}
		f.codexRow(f.wb, cxParent, f.folder, "")
		f.codexRow(f.wb, cxFork, f.folder, "")
		for _, id := range order {
			f.writeRollout(id, content[id])
			r := f.scan()
			require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
		}
		var owner, outcome, class string
		require.NoError(t, f.al.QueryRow(`SELECT session_uuid, outcome, error_class FROM agent_log_events WHERE key = 'tool:codex:call-open'`).
			Scan(&owner, &outcome, &class))
		assert.Equal(t, cxParent, owner, "order %v", order)
		assert.Equal(t, "error", outcome, "order %v", order)
		assert.Equal(t, "exit_code", class, "order %v", order)
	}
}

// Two independent sessions whose responses carry identical usage figures
// each keep their calls: the api_call key carries the rollout's lineage (the
// last session_meta before the first content line), which a fork shares with
// its parent and an unrelated session does not.
func TestAgentlog02_CodexIdenticalFiguresAcrossSessions(t *testing.T) {
	f := newFixture(t)
	f.writeRollout(cxParent, cxSession(t, cxParent, f.folder))
	f.writeRollout(cxOther, cxSession(t, cxOther, f.folder))
	f.codexRow(f.wb, cxParent, f.folder, "")
	f.codexRow(f.wb, cxOther, f.folder, "")
	r := f.scan()
	require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	calls, out := f.totals()
	assert.Equal(t, int64(4), calls, "two calls per session, none collapsed")
	assert.Equal(t, int64(260), out)
}

// The parent's later calls are read from a stored offset (no session_meta in
// the read); the fork replays them from its offset 0. Both reads key them by
// the same lineage, so they still count once.
func TestAgentlog02_CodexForkReplayAfterResumedRead(t *testing.T) {
	f := newFixture(t)
	head := cxMeta(t, "00.000", cxParent, f.folder) + cxModel(t, "00.500", "gpt-test") +
		cxUser(t, "01.000", "u-1", "SENTINEL-PROMPT") + cxTokens(t, "05.000", 1000, 600, 50, 20, 1050)
	tail := cxTokens(t, "12.000", 1200, 900, 80, 30, 2330)
	f.codexRow(f.wb, cxParent, f.folder, "")
	f.codexRow(f.wb, cxFork, f.folder, "")
	p := f.writeRollout(cxParent, head)
	r := f.scan()
	require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	require.NoError(t, os.WriteFile(p, []byte(head+tail), 0o600))
	r = f.scan()
	require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)

	fork := cxMeta(t, "30.000", cxFork, f.folder) + head + tail + cxTokens(t, "35.000", 100, 0, 7, 0, 2437)
	f.writeRollout(cxFork, fork)
	r = f.scan()
	require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	calls, out := f.totals()
	assert.Equal(t, int64(3), calls)
	assert.Equal(t, int64(137), out)
}

// A codex call with no call id is format drift: counted in Unknown, never
// dropped silently.
func TestParseCodex_EmptyCallIDCounted(t *testing.T) {
	s := cxMeta(t, "00.000", cxParent, "/work") + cxExec(t, "01.000", "", "go test") + cxOut(t, "02.000", "", "ok")
	pr := parseCodex(t, s, ParseOptions{Path: "/r.jsonl", SessionUUID: cxParent})
	assert.Equal(t, 2, pr.Unknown["<codex-no-call-id>"])
	assert.Empty(t, pr.Events)
	assert.Empty(t, pr.ToolResults)
}

// FILES-01: a codex rollout's failure in the scan result names the session
// and the error class, never the rollout's path.
func TestAgentlog_CodexFailureNamesSessionNotPath(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a mode-000 file")
	}
	t.Run("ownership read", func(t *testing.T) {
		f := newFixture(t)
		p := f.writeRollout(cxParent, cxSession(t, cxParent, f.folder))
		require.NoError(t, os.Chmod(p, 0))
		f.codexRow(f.wb, cxParent, f.folder, "")
		r := f.scan()
		require.Equal(t, 1, r.FailedFiles)
		msg := r.FirstFailure.Error()
		assert.Contains(t, msg, cxParent)
		assert.Contains(t, msg, "permission denied")
		assert.NotContains(t, msg, f.codex)
		assert.NotContains(t, msg, "rollout-")
		assert.ErrorIs(t, r.FirstFailure, errRolloutUnreadable)
		assert.ErrorIs(t, r.FirstFailure, fs.ErrPermission)
	})
	t.Run("incremental open", func(t *testing.T) {
		f := newFixture(t)
		s := cxSession(t, cxParent, f.folder)
		p := f.writeRollout(cxParent, s)
		f.codexRow(f.wb, cxParent, f.folder, "")
		r := f.scan()
		require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
		require.NoError(t, os.WriteFile(p, []byte(s+cxTokens(t, "40.000", 10, 0, 1, 0, 2341)), 0o600))
		require.NoError(t, os.Chmod(p, 0))
		r = f.scan()
		require.Equal(t, 1, r.FailedFiles)
		msg := r.FirstFailure.Error()
		assert.Contains(t, msg, cxParent)
		assert.NotContains(t, msg, f.codex)
		assert.NotContains(t, msg, "rollout-")
		assert.ErrorIs(t, r.FirstFailure, fs.ErrPermission)
	})
}

// A repeated report that straddles two slices of one scan from offset 0 is
// still one row: every slice keys by the lineage the first one found.
func TestAgentlog02_CodexRepeatedReportAcrossSlices(t *testing.T) {
	old := batchRows
	batchRows = 2
	t.Cleanup(func() { batchRows = old })
	f := newFixture(t)
	s := cxMeta(t, "00.000", cxParent, f.folder) + cxModel(t, "00.500", "gpt-test") +
		cxTokens(t, "01.000", 100, 0, 1, 0, 101) + cxTokens(t, "02.000", 100, 0, 2, 0, 203) +
		cxTokens(t, "02.100", 100, 0, 2, 0, 203) // the repeat opens the second slice
	f.writeRollout(cxParent, s)
	f.codexRow(f.wb, cxParent, f.folder, "")
	r := f.scan()
	require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	calls, out := f.totals()
	assert.Equal(t, int64(2), calls)
	assert.Equal(t, int64(3), out)
}

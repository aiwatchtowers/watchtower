package agentlog

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentkind"
	"watchtower/internal/pricing"
	"watchtower/internal/sessionagent"
)

// Codex sub-agents (spec 2026-11-03 §4.7, D50; AGENTLOG-04 as amended in
// ask #1132). Every rollout is hand-made; ids are zero UUIDs.
const (
	cxChild    = "00000000-0000-0000-0000-00000000c0e1"
	cxGrand    = "00000000-0000-0000-0000-00000000c0e2"
	cxUnnamed  = "00000000-0000-0000-0000-00000000c0e3"
	cxStranger = "00000000-0000-0000-0000-00000000c0e4"
)

// cxChildMeta is a sub-agent's first line: its session_meta naming parent
// through its source, as Codex writes a spawned thread.
func cxChildMeta(t *testing.T, ts, id, parent, cwd string) string {
	return cx(t, ts, "session_meta", map[string]any{"id": id, "timestamp": "2026-11-01T10:00:" + ts + "Z", "cwd": cwd,
		"source": map[string]any{"subagent": map[string]any{"thread_spawn": map[string]any{"parent_thread_id": parent, "depth": 1}}}})
}

// cxSpawn is a spawn_agent call and its collab_agent_spawn_end naming child.
func cxSpawn(t *testing.T, ts, callID, child string) string {
	return cx(t, ts, "response_item", map[string]any{"type": "function_call", "name": "spawn_agent",
		"arguments": `{"message":"SENTINEL-SPAWN-PROMPT"}`, "call_id": callID}) +
		cxSpawnEnd(t, ts, callID, child)
}

func cxSpawnEnd(t *testing.T, ts, callID, child string) string {
	return cx(t, ts, "event_msg", map[string]any{"type": "collab_agent_spawn_end", "call_id": callID,
		"new_thread_id": child, "prompt": "SENTINEL-SPAWN-PROMPT", "status": "running"})
}

// cxChildBody is a sub-agent's work: its parent agent's message (never an
// owner turn), a model step, a tool call and an abort.
func cxChildBody(t *testing.T, id string, total int64) string {
	return cxModel(t, "20.000", "gpt-test") +
		cxLegacyUser(t, "20.100", "SENTINEL-PARENT-PROMPT") +
		cxUser(t, "20.200", "u-"+id, "SENTINEL-PARENT-PROMPT") +
		cxExec(t, "21.000", "call-"+id, "go vet ./...") +
		cxTokens(t, "21.000", 500, 100, 40, 10, total) +
		cxOut(t, "22.000", "call-"+id, "Process exited with code 0\n") +
		cx(t, "22.500", "event_msg", map[string]any{"type": "turn_aborted", "reason": "interrupted"})
}

// rootWithSpawn is an owned root rollout whose agent spawns child.
func rootWithSpawn(t *testing.T, cwd, child string) string {
	return cxSession(t, cxParent, cwd) + cxSpawn(t, "13.000", "call-spawn-1", child)
}

type laneRow struct {
	session, agentID, kind string
	sidechain              bool
}

func (f *fixture) lane(agentID string) []laneRow {
	f.t.Helper()
	rows, err := f.al.Query(`SELECT session_uuid, agent_id, kind, is_sidechain FROM agent_log_events WHERE agent_id = ? ORDER BY id`, agentID)
	require.NoError(f.t, err)
	defer rows.Close()
	var out []laneRow
	for rows.Next() {
		var r laneRow
		require.NoError(f.t, rows.Scan(&r.session, &r.agentID, &r.kind, &r.sidechain))
		out = append(out, r)
	}
	require.NoError(f.t, rows.Err())
	return out
}

func (f *fixture) links() map[string]int {
	f.t.Helper()
	rows, err := f.al.Query(`SELECT session_uuid, agent_id, depth FROM agent_log_subagents`)
	require.NoError(f.t, err)
	defer rows.Close()
	out := map[string]int{}
	for rows.Next() {
		var s, a string
		var d int
		require.NoError(f.t, rows.Scan(&s, &a, &d))
		out[s+"/"+a] = d
	}
	require.NoError(f.t, rows.Err())
	return out
}

func (f *fixture) count(q string, args ...any) int {
	f.t.Helper()
	var n int
	require.NoError(f.t, f.al.QueryRow(q, args...).Scan(&n))
	return n
}

func TestAgentlog_CodexChildImportsUnderRoot(t *testing.T) {
	f := newFixture(t)
	f.writeRollout(cxParent, rootWithSpawn(t, f.folder, cxChild))
	f.writeRollout(cxChild, cxChildMeta(t, "19.000", cxChild, cxParent, f.folder)+cxChildBody(t, cxChild, 9000))
	f.codexRow(f.wb, cxParent, f.folder, "")

	r := f.scan()
	require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	assert.Zero(t, r.CodexRolloutsMissing)
	assert.Equal(t, []string{cxParent}, f.sessionUUIDs(), "the child writes no session row")
	rows := f.lane(cxChild)
	kinds := map[string]int{}
	for _, row := range rows {
		assert.Equal(t, cxParent, row.session)
		assert.True(t, row.sidechain)
		kinds[row.kind]++
	}
	assert.Equal(t, map[string]int{"api_call": 1, "tool": 1}, kinds, "no owner_turn from the child")
	assert.Equal(t, map[string]int{cxParent + "/" + cxChild: 1}, f.links())
	var spawned string
	require.NoError(t, f.al.QueryRow(`SELECT spawned_agent_id FROM agent_log_events WHERE key = 'tool:codex:call-spawn-1'`).Scan(&spawned))
	assert.Equal(t, cxChild, spawned)
	assert.Equal(t, 2, f.count(`SELECT COUNT(*) FROM agent_log_events WHERE kind = 'owner_turn'`), "the root's brief and prompt only")
	assertNoSentinel(t, f.al)

	r = f.scan()
	assert.Zero(t, r.FilesScanned, "nothing changed")
	assert.Equal(t, 2, r.FilesSkipped)
}

func TestAgentlog_CodexChildInOtherFolderCountsForRoot(t *testing.T) {
	f := newFixture(t)
	f.writeRollout(cxParent, rootWithSpawn(t, f.folder, cxChild))
	f.writeRollout(cxChild, cxChildMeta(t, "19.000", cxChild, cxParent, "/tmp/elsewhere")+cxChildBody(t, cxChild, 9000))
	f.codexRow(f.wb, cxParent, f.folder, "")
	r := f.scan()
	require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	assert.Zero(t, r.CodexOutsideWorkbench, "a child belongs to its root, whatever its cwd")
	assert.Len(t, f.lane(cxChild), 2)
}

func TestAgentlog_CodexGrandchildDepthTwo(t *testing.T) {
	f := newFixture(t)
	f.writeRollout(cxParent, rootWithSpawn(t, f.folder, cxChild))
	f.writeRollout(cxChild, cxChildMeta(t, "19.000", cxChild, cxParent, f.folder)+cxChildBody(t, cxChild, 9000)+
		cxSpawn(t, "23.000", "call-spawn-2", cxGrand))
	f.writeRollout(cxGrand, cxChildMeta(t, "24.000", cxGrand, cxChild, f.folder)+cxChildBody(t, cxGrand, 9100))
	f.codexRow(f.wb, cxParent, f.folder, "")
	r := f.scan()
	require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	assert.Equal(t, map[string]int{cxParent + "/" + cxChild: 1, cxParent + "/" + cxGrand: 2}, f.links())
	for _, row := range f.lane(cxGrand) {
		assert.Equal(t, cxParent, row.session)
	}
	assert.Len(t, f.lane(cxGrand), 2)
}

func TestAgentlog_CodexChildFoundOnLaterScan(t *testing.T) {
	f := newFixture(t)
	f.writeRollout(cxParent, rootWithSpawn(t, f.folder, cxChild))
	f.codexRow(f.wb, cxParent, f.folder, "")
	r := f.scan()
	assert.Equal(t, 1, r.CodexRolloutsMissing, "the linked child has no rollout yet")
	assert.Empty(t, f.lane(cxChild))
	assert.Len(t, f.links(), 1, "the link stays")

	f.writeRollout(cxChild, cxChildMeta(t, "19.000", cxChild, cxParent, f.folder)+cxChildBody(t, cxChild, 9000))
	r = f.scan()
	require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	assert.Zero(t, r.CodexRolloutsMissing)
	assert.Len(t, f.lane(cxChild), 2)
}

func TestAgentlog_CodexChildNamingOtherParentNotRead(t *testing.T) {
	f := newFixture(t)
	f.writeRollout(cxParent, rootWithSpawn(t, f.folder, cxChild))
	f.writeRollout(cxChild, cxChildMeta(t, "19.000", cxChild, cxStranger, f.folder)+cxChildBody(t, cxChild, 9000))
	f.codexRow(f.wb, cxParent, f.folder, "")
	r := f.scan()
	require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	assert.Equal(t, 1, r.CodexRolloutsMissing)
	assert.Empty(t, f.lane(cxChild))
	assert.Zero(t, f.count(`SELECT COUNT(*) FROM agent_log_files WHERE path LIKE ?`, "%"+cxChild+"%"))
}

func TestAgentlog_CodexSpawnRowLinkedAcrossSlices(t *testing.T) {
	old := batchRows
	batchRows = 3
	t.Cleanup(func() { batchRows = old })
	f := newFixture(t)
	f.writeRollout(cxParent, cxMeta(t, "00.000", cxParent, f.folder)+cxModel(t, "00.500", "gpt-test")+
		cx(t, "01.000", "response_item", map[string]any{"type": "function_call", "name": "spawn_agent", "arguments": "{}", "call_id": "call-spawn-1"})+
		cxTokens(t, "02.000", 100, 0, 1, 0, 101)+
		cxTokens(t, "03.000", 100, 0, 2, 0, 203)+ // the slice ends here: the call is stored, the link is not yet read
		cxSpawnEnd(t, "04.000", "call-spawn-1", cxChild)+
		cxOut(t, "05.000", "call-spawn-1", `{"agent_id":"x"}`))
	f.codexRow(f.wb, cxParent, f.folder, "")
	r := f.scan()
	require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	var spawned, name, outcome string
	require.NoError(t, f.al.QueryRow(`SELECT spawned_agent_id, name, outcome FROM agent_log_events WHERE key = 'tool:codex:call-spawn-1'`).
		Scan(&spawned, &name, &outcome))
	assert.Equal(t, cxChild, spawned)
	assert.Equal(t, "spawn_agent", name)
	assert.Equal(t, "ok", outcome)
	assert.Equal(t, 1, f.count(`SELECT COUNT(*) FROM agent_log_events WHERE kind = 'tool'`))
}

func TestAgentlog_CodexKilledBetweenParentAndChild(t *testing.T) {
	f := newFixture(t)
	f.writeRollout(cxParent, rootWithSpawn(t, f.folder, cxChild))
	f.writeRollout(cxChild, cxChildMeta(t, "19.000", cxChild, cxParent, f.folder)+cxChildBody(t, cxChild, 9000))
	f.codexRow(f.wb, cxParent, f.folder, "")

	// Out of time once the parent's slice (and its link) is committed.
	start := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	now := func() time.Time {
		if len(f.links()) > 0 {
			return start.Add(time.Hour)
		}
		return start
	}
	r, err := Scan(t.Context(), f.d, f.al, f.wb, Options{ClaudeDir: f.claude, CodexHome: f.codex, Budget: time.Minute, Now: now})
	require.NoError(t, err)
	assert.True(t, r.Incomplete)
	assert.Len(t, f.links(), 1, "the link is committed with the parent's slice")
	assert.Empty(t, f.lane(cxChild))
	before := f.count(`SELECT COUNT(*) FROM agent_log_events`)

	r = f.scan()
	require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	assert.False(t, r.Incomplete)
	assert.Len(t, f.lane(cxChild), 2)
	assert.Equal(t, before+2, f.count(`SELECT COUNT(*) FROM agent_log_events`), "no duplicates")
	r = f.scan()
	assert.Zero(t, r.EventsWritten)
}

// AGENTLOG-04 (ask #1132): a rollout no read rollout names in a spawn event
// and no terminal row lists is never opened, even when its session_meta
// names the owned root as its parent. It is unreadable on disk, so any open
// would fail the scan.
func TestAgentlog04_CodexUnnamedRolloutNeverOpened(t *testing.T) {
	setup := func(t *testing.T) (*fixture, string) {
		f := newFixture(t)
		f.writeRollout(cxParent, cxSession(t, cxParent, f.folder)) // no spawn event
		unnamed := f.writeRollout(cxUnnamed, cxChildMeta(t, "19.000", cxUnnamed, cxParent, f.folder)+cxChildBody(t, cxUnnamed, 9000))
		require.NoError(t, os.Chmod(unnamed, 0o000))
		t.Cleanup(func() { _ = os.Chmod(unnamed, 0o600) })
		f.codexRow(f.wb, cxParent, f.folder, "")
		return f, unnamed
	}
	check := func(t *testing.T, f *fixture, unnamed string, r *Result) {
		require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
		assert.Zero(t, f.count(`SELECT COUNT(*) FROM agent_log_files WHERE path = ?`, unnamed))
		assert.Empty(t, f.lane(cxUnnamed))
		assert.Empty(t, f.links())
	}

	t.Run("real adapter", func(t *testing.T) {
		f, unnamed := setup(t)
		check(t, f, unnamed, f.scan())
	})
	t.Run("recording adapter", func(t *testing.T) {
		f, unnamed := setup(t)
		codex, ok := sessionagent.For(agentkind.Codex)
		require.True(t, ok)
		fake := &fakeCodexAdapter{Adapter: codex, path: filepath.Join(f.codex, "sessions", "2026", "11", "01",
			"rollout-2026-11-01T10-00-00-"+cxParent+".jsonl")}
		r, err := Scan(t.Context(), f.d, f.al, f.wb, Options{ClaudeDir: f.claude, CodexHome: f.codex,
			Sessions: func(k sessionagent.Kind) (sessionagent.Adapter, bool) {
				if k == agentkind.Codex {
					return fake, true
				}
				return sessionagent.For(k)
			}})
		require.NoError(t, err)
		check(t, f, unnamed, r)
		assert.NotContains(t, fake.children, cxUnnamed)
		assert.Empty(t, fake.children, "no link, no lookup")
		assert.NotContains(t, fake.opens, unnamed)
	})
}

// D59: a stored api_call takes its tokens from last_token_usage, the usage
// of one response of the thread that wrote it, so a parent whose cumulative
// total includes its child's tokens never adds them; a forked child that
// replays its parent's token_count line counts it once (lineage keys).
func TestAgentlog_CodexParentTotalsExcludeChildren(t *testing.T) {
	const model = "gpt-5.6-sol"
	cost := func(in, cached, out int64) float64 {
		usd, ok := pricing.CodexCost(model, in-cached, out, cached, 0)
		require.True(t, ok)
		return usd
	}
	sum := func(f *fixture) (n int, usd float64) {
		require.NoError(t, f.al.QueryRow(`SELECT COUNT(*), COALESCE(SUM(cost_usd),0) FROM agent_log_events
			WHERE kind = 'api_call' AND session_uuid = ?`, cxParent).Scan(&n, &usd))
		return
	}
	parentA := cxTokens(t, "05.000", 1000, 600, 50, 0, 1050)

	t.Run("separate thread", func(t *testing.T) {
		f := newFixture(t)
		f.writeRollout(cxParent, cxMeta(t, "00.000", cxParent, f.folder)+cxModel(t, "00.500", model)+
			cxSpawn(t, "01.000", "call-spawn-1", cxChild)+
			cxTokens(t, "06.000", 2000, 1000, 70, 0, 99999)) // A, whose running total already holds the child's
		f.writeRollout(cxChild, cxChildMeta(t, "02.000", cxChild, cxParent, f.folder)+cxModel(t, "02.500", model)+
			cxTokens(t, "03.000", 400, 100, 30, 0, 430)) // B
		f.codexRow(f.wb, cxParent, f.folder, "")
		require.Zero(t, f.scan().FailedFiles)
		n, usd := sum(f)
		assert.Equal(t, 2, n)
		assert.InDelta(t, cost(2000, 1000, 70)+cost(400, 100, 30), usd, 1e-12)
	})
	t.Run("forked child replays the parent's call", func(t *testing.T) {
		f := newFixture(t)
		parent := cxMeta(t, "00.000", cxParent, f.folder) + cxModel(t, "00.500", model) + parentA
		f.writeRollout(cxParent, parent+cxSpawn(t, "07.000", "call-spawn-1", cxChild))
		f.writeRollout(cxChild, cxChildMeta(t, "08.000", cxChild, cxParent, f.folder)+parent+
			cxSpawn(t, "07.000", "call-spawn-1", cxChild)+ // the replayed spawn of itself is not a link
			cxTokens(t, "09.000", 400, 100, 30, 0, 1480))
		f.codexRow(f.wb, cxParent, f.folder, "")
		require.Zero(t, f.scan().FailedFiles)
		n, usd := sum(f)
		assert.Equal(t, 2, n, "the replayed line keeps the parent's key")
		assert.InDelta(t, cost(1000, 600, 50)+cost(400, 100, 30), usd, 1e-12)
		assert.Equal(t, map[string]int{cxParent + "/" + cxChild: 1}, f.links())
		var agentID string
		require.NoError(t, f.al.QueryRow(`SELECT agent_id FROM agent_log_events WHERE kind = 'api_call' AND output_tokens = 50`).Scan(&agentID))
		assert.Empty(t, agentID, "the replayed call stays the parent's")
	})
}

// A sub-agent read that resumes past its turn_context still prices the
// next call with that model: the root's model comes from its session row, a
// sub-agent's from the last turn_context before the offset.
func TestAgentlog_CodexChildResumeKeepsModel(t *testing.T) {
	f := newFixture(t)
	f.writeRollout(cxParent, rootWithSpawn(t, f.folder, cxChild))
	head := cxChildMeta(t, "19.000", cxChild, cxParent, f.folder) + cxModel(t, "19.500", "gpt-5.6-sol")
	p := f.writeRollout(cxChild, head)
	f.codexRow(f.wb, cxParent, f.folder, "")
	require.Zero(t, f.scan().FailedFiles)

	require.NoError(t, os.WriteFile(p, []byte(head+cxTokens(t, "21.000", 500, 100, 40, 10, 540)), 0o600))
	r := f.scan()
	require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	var name string
	var usd float64
	require.NoError(t, f.al.QueryRow(`SELECT name, cost_usd FROM agent_log_events WHERE kind = 'api_call' AND agent_id = ?`, cxChild).
		Scan(&name, &usd))
	assert.Equal(t, "gpt-5.6-sol", name)
	assert.Positive(t, usd)
}

// A forked child that replays its parent's tool call and result, re-stamped
// later, never re-times or re-settles the parent's call (AGENTLOG-02/06).
func TestAgentlog_CodexForkedChildKeepsParentToolTiming(t *testing.T) {
	f := newFixture(t)
	parent := cxMeta(t, "00.000", cxParent, f.folder) + cxModel(t, "00.500", "gpt-test") +
		cxExec(t, "01.000", "call-p", "go test ./...") + cxOut(t, "02.000", "call-p", "Process exited with code 0\n")
	f.writeRollout(cxParent, parent+cxSpawn(t, "03.000", "call-spawn-1", cxChild))
	f.writeRollout(cxChild, cxChildMeta(t, "04.000", cxChild, cxParent, f.folder)+parent+
		cxOut(t, "40.000", "call-p", "Process exited with code 1\n")) // a re-stamped, different copy
	f.codexRow(f.wb, cxParent, f.folder, "")
	r := f.scan()
	require.Zero(t, r.FailedFiles, "%v", r.FirstFailure)
	var outcome string
	var dur int64
	require.NoError(t, f.al.QueryRow(`SELECT outcome, duration_ms FROM agent_log_events WHERE key = 'tool:codex:call-p'`).Scan(&outcome, &dur))
	assert.Equal(t, "ok", outcome)
	assert.Equal(t, int64(1000), dur)
}

// Spawn events never dropped silently: no thread id, or past the depth cap,
// count in Unknown; a spawn whose call is absent writes no tool row.
func TestParseCodex_SpawnEdgesCounted(t *testing.T) {
	pr := parseCodex(t, cxSpawnEnd(t, "01.000", "call-x", "not-a-thread")+cxSpawnEnd(t, "02.000", "", cxGrand),
		ParseOptions{Path: "/r.jsonl", SessionUUID: cxParent})
	assert.Equal(t, 1, pr.Unknown["<codex-spawn-no-thread>"])
	require.Len(t, pr.Subagents, 1)
	assert.Empty(t, pr.CodexSpawns, "no call id, no tool row to link")
	for _, e := range pr.Events {
		assert.NotEqual(t, "tool", e.Kind, "a spawn never adds a tool row of its own")
	}

	pr = parseCodex(t, cxSpawnEnd(t, "01.000", "call-y", cxGrand),
		ParseOptions{Path: "/r.jsonl", SessionUUID: cxParent, AgentID: cxChild, Depth: 8})
	assert.Empty(t, pr.Subagents, "depth 9 is past the cap")
	assert.Equal(t, 1, pr.Unknown["<codex-spawn-too-deep>"])
}

func TestAgentlog_CodexSpawnWithoutCallWritesNoRow(t *testing.T) {
	f := newFixture(t)
	f.writeRollout(cxParent, cxSession(t, cxParent, f.folder)+cxSpawnEnd(t, "13.000", "call-gone", cxChild))
	f.codexRow(f.wb, cxParent, f.folder, "")
	require.Zero(t, f.scan().FailedFiles)
	assert.Zero(t, f.count(`SELECT COUNT(*) FROM agent_log_events WHERE key = 'tool:codex:call-gone'`))
	assert.Len(t, f.links(), 1)
}

// A named child that cannot be opened is a failed file (by its thread id,
// never its path), not a missing one.
func TestAgentlog_CodexUnreadableChildFailed(t *testing.T) {
	f := newFixture(t)
	f.writeRollout(cxParent, rootWithSpawn(t, f.folder, cxChild))
	p := f.writeRollout(cxChild, cxChildMeta(t, "19.000", cxChild, cxParent, f.folder)+cxChildBody(t, cxChild, 9000))
	require.NoError(t, os.Chmod(p, 0o000))
	t.Cleanup(func() { _ = os.Chmod(p, 0o600) })
	f.codexRow(f.wb, cxParent, f.folder, "")
	r := f.scan()
	assert.Equal(t, 1, r.FailedFiles)
	assert.Zero(t, r.CodexRolloutsMissing)
	require.Error(t, r.FirstFailure)
	assert.Contains(t, r.FirstFailure.Error(), cxChild)
	assert.NotContains(t, r.FirstFailure.Error(), p)
}

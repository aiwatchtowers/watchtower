package cmd

import (
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

const (
	probePID       = 4242
	probeProcStart = "Sat Oct 10 09:00:00 2026"
)

// fakeProbeProcs is a process table: pid → lstart.
type fakeProbeProcs map[int]string

func (f fakeProbeProcs) Exists(pid int) bool { _, ok := f[pid]; return ok }

func (f fakeProbeProcs) Start(pid int) (string, bool) { s, ok := f[pid]; return s, ok }

func useProbeProcs(t *testing.T, p fakeProbeProcs) {
	t.Helper()
	orig := probeProcs
	probeProcs = p
	t.Cleanup(func() { probeProcs = orig })
}

// registrySetup prepares a Claude config dir and process table for the
// probe of briefLaunchID.
type registrySetup struct {
	name  string
	entry string // registry entry JSON for probePID; "" = none
	procs fakeProbeProcs
}

func registryEntry(status string) string {
	s := `{"pid":` + strconv.Itoa(probePID) + `,"sessionId":"` + briefLaunchID + `","procStart":"` + probeProcStart + `"`
	if status != "" {
		s += `,"status":"` + status + `","statusUpdatedAt":1760000000000`
	}
	return s + `}`
}

func (r registrySetup) apply(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", dir)
	if r.entry != "" {
		require.NoError(t, os.MkdirAll(filepath.Join(dir, "sessions"), 0o700))
		require.NoError(t, os.WriteFile(filepath.Join(dir, "sessions", strconv.Itoa(probePID)+".json"), []byte(r.entry), 0o600))
	}
	useProbeProcs(t, r.procs)
}

var liveProbeProcs = fakeProbeProcs{probePID: probeProcStart}

// probeRegistries is every registry reading the probe distinguishes.
var probeRegistries = []registrySetup{
	{"no entry", "", liveProbeProcs},
	{"dead pid", registryEntry("idle"), fakeProbeProcs{}},
	{"reused pid", registryEntry("busy"), fakeProbeProcs{probePID: "Sat Oct 10 11:00:00 2026"}},
	{"busy", registryEntry("busy"), liveProbeProcs},
	{"waiting", registryEntry("waiting"), liveProbeProcs},
	{"idle", registryEntry("idle"), liveProbeProcs},
	{"shell", registryEntry("shell"), liveProbeProcs},
	{"no status", registryEntry(""), liveProbeProcs},
	{"unknown status", registryEntry("thinking"), liveProbeProcs},
}

// countedRow stores the Stop's `waiting` with count n, reported at time at, on the
// fixture row, plus a turn end and finished_at for the never-touch checks.
func countedRow(t *testing.T, database *db.DB, pid, row int64, n int64, at time.Time) {
	t.Helper()
	_, err := database.SetTerminalTurnEnd(row, pid, briefLaunchID, 100)
	require.NoError(t, err)
	_, err = database.Exec(`UPDATE terminal_sessions SET finished_at = '2026-01-01T00:00:00Z' WHERE id = ?`, row)
	require.NoError(t, err)
	order := db.AgentOrder{Stop: true}
	if n > 0 {
		order.Background = sql.NullInt64{Int64: n, Valid: true}
	}
	ok, err := database.SetTerminalAgentState(row, pid, briefLaunchID, "waiting", at, "", nil, false, order)
	require.NoError(t, err)
	require.True(t, ok)
}

// runSessionProbe runs `workbench session-probe` and decodes its one JSON
// object; the command always exits 0.
func runSessionProbe(t *testing.T, pid, row int64) map[string]any {
	t.Helper()
	out, errOut, err := runWorkbench(t, "session-probe",
		"--workbench", strconv.FormatInt(pid, 10), "--session", strconv.FormatInt(row, 10))
	require.NoError(t, err, "stderr: %s", errOut)
	var got map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &got), "stdout: %s", out)
	for k, v := range got {
		require.NotNil(t, v, "key %q is null in %s", k, out)
	}
	return got
}

func TestSessionProbeStageOneTable(t *testing.T) {
	stale := time.Now().Add(-31 * time.Minute)
	wantOutcome := map[string]string{
		"no entry": "gone", "dead pid": "gone", "reused pid": "gone",
		"busy": "busy", "waiting": "waiting", "idle": "idle", "shell": "shell",
		"no status": "unknown", "unknown status": "unknown",
	}
	for _, reg := range probeRegistries {
		t.Run(reg.name, func(t *testing.T) {
			database, pid, row := briefSessionFixture(t)
			countedRow(t, database, pid, row, 2, stale)
			reg.apply(t)
			before := rowSnapshot(t, database, row)
			stamp := db.AgentStateStamp(stale)
			require.Equal(t, stamp, before["agent_background_at"])

			got := runSessionProbe(t, pid, row)
			outcome := wantOutcome[reg.name]
			ends := outcome != "busy" && outcome != "waiting"
			assert.Equal(t, map[string]any{
				"ok": true, "outcome": outcome, "ended": ends, "agent_background_at": stamp,
			}, got)

			after := rowSnapshot(t, database, row)
			if ends {
				assert.Nil(t, after["agent_background"], "the count ended")
				assert.Nil(t, after["agent_background_at"], "the stamp ended with it")
				delete(before, "agent_background")
				delete(before, "agent_background_at")
				delete(after, "agent_background")
				delete(after, "agent_background_at")
			}
			assert.Equal(t, before, after)
		})
	}

	t.Run("not stale", func(t *testing.T) {
		database, pid, row := briefSessionFixture(t)
		recent := time.Now().Add(-29 * time.Minute)
		countedRow(t, database, pid, row, 2, recent)
		probeRegistries[0].apply(t) // no entry: would end a stale count
		before := rowSnapshot(t, database, row)
		got := runSessionProbe(t, pid, row)
		assert.Equal(t, map[string]any{
			"ok": true, "outcome": "not_stale", "ended": false, "agent_background_at": db.AgentStateStamp(recent),
		}, got)
		assert.Equal(t, before, rowSnapshot(t, database, row))
	})

	// F18: an agent_background_at that does not parse reads as no report;
	// the probe never ends a count it cannot compare-and-clear.
	t.Run("unparsable stamp", func(t *testing.T) {
		database, pid, row := briefSessionFixture(t)
		countedRow(t, database, pid, row, 2, stale)
		_, err := database.Exec(`UPDATE terminal_sessions SET agent_background_at = 'garbled' WHERE id = ?`, row)
		require.NoError(t, err)
		probeRegistries[0].apply(t)
		before := rowSnapshot(t, database, row)
		got := runSessionProbe(t, pid, row)
		assert.Equal(t, map[string]any{
			"ok": true, "outcome": "not_stale", "ended": false, "agent_background_at": "",
		}, got)
		assert.Equal(t, before, rowSnapshot(t, database, row))
	})

	t.Run("not counted", func(t *testing.T) {
		database, pid, row := briefSessionFixture(t)
		countedRow(t, database, pid, row, 2, stale)
		_, err := database.SetTerminalAgentState(row, pid, briefLaunchID, "working", time.Now(), "", nil, false, db.AgentOrder{})
		require.NoError(t, err)
		probeRegistries[0].apply(t)
		before := rowSnapshot(t, database, row)
		got := runSessionProbe(t, pid, row)
		assert.Equal(t, "not_stale", got["outcome"])
		assert.Equal(t, before, rowSnapshot(t, database, row))
	})
}

// Board #411 (PROJ-11): only the Stop starts a count. Over a `waiting` with
// no count the probe writes nothing whatever the registry reads.
func TestProj11_ProbeNeverStartsBackground(t *testing.T) {
	for _, reg := range probeRegistries {
		t.Run(reg.name, func(t *testing.T) {
			database, pid, row := briefSessionFixture(t)
			countedRow(t, database, pid, row, 0, time.Now().Add(-time.Hour))
			reg.apply(t)
			before := rowSnapshot(t, database, row)
			require.Nil(t, before["agent_background"])
			got := runSessionProbe(t, pid, row)
			assert.Equal(t, "not_stale", got["outcome"])
			assert.Equal(t, before, rowSnapshot(t, database, row), "the row changed")
		})
	}
}

// Board #411: whatever the outcome, the probe never changes the row's state,
// its time, finished_at or the turn order.
func TestSessionProbeNeverTouchesStateOrFinished(t *testing.T) {
	cols := []string{"agent_state", "agent_state_at", "finished_at", "agent_turn_end", "agent_tool_run",
		"agent_failed_at", "agent_error"}
	for _, reg := range probeRegistries {
		t.Run(reg.name, func(t *testing.T) {
			database, pid, row := briefSessionFixture(t)
			countedRow(t, database, pid, row, 3, time.Now().Add(-time.Hour))
			reg.apply(t)
			before := rowSnapshot(t, database, row)
			require.NotNil(t, before["finished_at"])
			require.NotNil(t, before["agent_turn_end"])
			runSessionProbe(t, pid, row)
			after := rowSnapshot(t, database, row)
			for _, c := range cols {
				assert.Equal(t, before[c], after[c], "column %s", c)
			}
		})
	}
}

func TestSessionProbeEnvelopeShape(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	countedRow(t, database, pid, row, 2, time.Now().Add(-time.Hour))
	probeRegistries[0].apply(t)

	got := runSessionProbe(t, pid, row)
	assert.ElementsMatch(t, []string{"ok", "outcome", "ended", "agent_background_at"}, keysOf(got))

	other, err := database.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	for _, tc := range []struct {
		name     string
		pid, row int64
	}{
		{"missing row", pid, row + 100},
		{"another workbench", other, row},
		{"no ids", 0, 0},
	} {
		got := runSessionProbe(t, tc.pid, tc.row)
		assert.ElementsMatch(t, []string{"ok", "error"}, keysOf(got), tc.name)
		assert.Equal(t, false, got["ok"], tc.name)
		assert.NotEmpty(t, got["error"], tc.name)
	}

	t.Run("broken config", func(t *testing.T) {
		brokenConfig(t)
		got := runSessionProbe(t, pid, row)
		assert.Equal(t, false, got["ok"])
		assert.Contains(t, got["error"], "loading config")
	})
}

// Spec §10 / ask #142: the probe reads the registry only; no ping flag.
func TestSessionProbeHasNoPingFlag(t *testing.T) {
	_, pid, row := briefSessionFixture(t)
	_, _, err := runWorkbench(t, "session-probe", "--workbench", strconv.FormatInt(pid, 10),
		"--session", strconv.FormatInt(row, 10), "--ping")
	assert.ErrorContains(t, err, "unknown flag: --ping")
}

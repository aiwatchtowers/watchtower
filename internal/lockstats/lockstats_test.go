package lockstats

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db/lockmetrics"
)

// Synthetic fixture: two processes (pids 100 and 200) plus an MCP server
// (pid 300) on one made-up day. No live data.
var fixtureNow = time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)

const (
	siteSave   = "internal/sync.(*Syncer).saveMessages"
	siteUpsert = "internal/db.(*DB).UpsertUser"
	siteHook   = "internal/workbench.(*Store).SetState"
	siteOwnTx  = "internal/workbench.(*Store).Touch"
)

const fixtureLog = `{"ts":"2026-10-14T11:00:00.000Z","pid":100,"proc":"daemon","kind":"tx","hold_ms":9000,"site":"internal/sync.(*Syncer).saveMessages"}
{"ts":"2026-10-15T11:00:01.000Z","pid":100,"proc":"daemon","kind":"tx","wait_ms":10,"hold_ms":1200,"site":"internal/sync.(*Syncer).saveMessages"}
not json at all
{"ts":"2026-10-15T11:00:05.000Z","pid":200,"proc":"hook:session-state","kind":"tx","hold_ms":400,"site":"internal/workbench.(*Store).Touch"}
{"ts":"2026-10-15T11:00:05.500Z","pid":200,"proc":"hook:session-state","kind":"busy","site":"internal/workbench.(*Store).SetState","err":"SQLITE_BUSY","busy_timeout_ms":1000}

{"ts":"2026-10-15T11:00:10.000Z","pid":100,"proc":"daemon","kind":"tx","wait_ms":30,"hold_ms":6000,"site":"internal/sync.(*Syncer).saveMessages"}
{"kind":"tx","pid":1}
{"ts":"2026-10-15T11:30:00.000Z","pid":100,"proc":"daemon","kind":"exec","wait_ms":250,"hold_ms":300,"site":"internal/db.(*DB).UpsertUser"}
{"ts":"2026-10-15T11:40:00.000Z","pid":201,"proc":"hook:session-state","kind":"busy","site":"internal/workbench.(*Store).SetState","err":"SQLITE_BUSY","busy_timeout_ms":5000}
{"ts":"2026-10-15T11:41:00.000Z","pid":300,"proc":"mcp","kind":"pool_wait","wait_ms":250}
{"ts":"2026-10-15T11:42:00.000Z","pid":300,"proc":"mcp","kind":"pool_wait","wait_ms":50}
{"ts":"2026-10-15T11:43:00.000Z","pid":100,"proc":"daemon","kind":"pool_wait","wait_ms":900}
{"ts":"2026-10-15T11:50:00.000Z","pid":100,"proc":"daemon","kind":"wal","wal_bytes":1000,"checkpoint":"busy=0 log=12 ckpt=12"}
{"ts":"2026-10-15T11:51:00.000Z","pid":100,"proc":"daemon","kind":"wal","wal_bytes":5000,"checkpoint":"busy=1 log=40 ckpt=10"}
{"ts":"2026-10-15T11:52:00.000Z","pid":100,"proc":"daemon","kind":"wal","wal_bytes":3000,"checkpoint":"busy=0 log=8 ckpt=8"}
{"ts":"2026-10-15T11:53:00.000Z","pid":100,"proc":"daemon","kind":"compaction"}
`

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
}

func fixtureReport(t *testing.T) Report {
	t.Helper()
	path := filepath.Join(t.TempDir(), lockmetrics.FileName)
	writeFile(t, path, fixtureLog)
	parsed, err := ReadFiles([]string{path})
	require.NoError(t, err)
	return Build(parsed, fixtureNow, 24*time.Hour)
}

func TestReadFiles_SkipsMissingAndCountsMalformed(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, lockmetrics.FileName)
	writeFile(t, path, fixtureLog)

	parsed, err := ReadFiles([]string{path + ".1", path})
	require.NoError(t, err)
	assert.Equal(t, []string{path}, parsed.Files, "a missing generation is skipped, not an error")
	// "not json at all", the line without ts and the unknown kind; the blank
	// line is not counted.
	assert.Equal(t, 3, parsed.Malformed)
	assert.Len(t, parsed.Events, 13)
}

func TestReadFiles_ReadsRotatedGenerationAndUnterminatedLastLine(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, lockmetrics.FileName)
	writeFile(t, path+".1", `{"ts":"2026-10-15T10:00:00.000Z","pid":100,"proc":"daemon","kind":"tx","hold_ms":700,"site":"a"}`+"\n")
	// The last line has no newline: a writer may be mid-append, or it was
	// the last line before a crash. A whole object still counts.
	writeFile(t, path, `{"ts":"2026-10-15T10:00:01.000Z","pid":100,"proc":"daemon","kind":"tx","hold_ms":800,"site":"b"}`+"\n"+
		`{"ts":"2026-10-15T10:00:02.000Z","pid":100,"proc":"daemon","kind":"tx","hold_ms":900,"site":"c"}`)

	parsed, err := ReadFiles([]string{path + ".1", path})
	require.NoError(t, err)
	assert.Equal(t, []string{path + ".1", path}, parsed.Files)
	assert.Zero(t, parsed.Malformed)
	require.Len(t, parsed.Events, 3)
	assert.Equal(t, "c", parsed.Events[2].Site)
}

func TestReadFiles_NoFiles(t *testing.T) {
	path := filepath.Join(t.TempDir(), lockmetrics.FileName)
	parsed, err := ReadFiles([]string{path + ".1", path})
	require.NoError(t, err)
	assert.Empty(t, parsed.Files)
	assert.Empty(t, parsed.Events)
}

func TestReadFiles_UnreadableFileIsAnError(t *testing.T) {
	dir := t.TempDir() // a directory in place of the file: open succeeds, read fails
	_, err := ReadFiles([]string{dir})
	require.Error(t, err)
	assert.Contains(t, err.Error(), dir)
}

func TestBuild_Window(t *testing.T) {
	r := fixtureReport(t)
	assert.Equal(t, fixtureNow.Add(-24*time.Hour), r.Window.From)
	assert.Equal(t, fixtureNow, r.Window.To)
	assert.Equal(t, int64(24*60*60), r.Window.SinceSeconds)
	assert.Equal(t, 12, r.Window.Events, "the event older than --since is dropped")
	assert.Equal(t, 3, r.Malformed)
}

func TestBuild_SitesRankedByTotalHold(t *testing.T) {
	r := fixtureReport(t)
	require.Len(t, r.Sites, 2, "only tx events: an exec's duration is not a pure hold")

	assert.Equal(t, Site{
		Site: siteSave, Count: 2, TotalHoldMS: 7200, MaxHoldMS: 6000,
		MaxWaitMS: 30, Over1s: 2, Over5s: 1,
	}, r.Sites[0], "the 9000 ms hold from the day before is outside the window")
	assert.Equal(t, siteOwnTx, r.Sites[1].Site)
}

// An exec's hold_ms is wait+hold combined: it gets its own section and is
// never summed into total_hold_ms or counted in over_1s/over_5s.
func TestBuild_ExecSitesKeptApartFromHolds(t *testing.T) {
	r := fixtureReport(t)
	assert.Equal(t, []ExecSite{{Site: siteUpsert, Count: 1, TotalMS: 300, MaxMS: 300}}, r.ExecSites)

	events := []lockmetrics.Event{
		{TS: fixtureNow, Kind: lockmetrics.KindExec, HoldMS: 6000, Site: "s"},
		{TS: fixtureNow, Kind: lockmetrics.KindTx, HoldMS: 100, Site: "s"},
	}
	r = Build(Parsed{Events: events}, fixtureNow, time.Hour)
	assert.Equal(t, []Site{{Site: "s", Count: 1, TotalHoldMS: 100, MaxHoldMS: 100}}, r.Sites)
	assert.Equal(t, []ExecSite{{Site: "s", Count: 1, TotalMS: 6000, MaxMS: 6000}}, r.ExecSites)
}

func TestBuild_SitesTieOnTotalBreaksOnMaxThenName(t *testing.T) {
	events := []lockmetrics.Event{
		{TS: fixtureNow, Kind: lockmetrics.KindTx, HoldMS: 500, Site: "b"},
		{TS: fixtureNow, Kind: lockmetrics.KindTx, HoldMS: 500, Site: "b"},
		{TS: fixtureNow, Kind: lockmetrics.KindTx, HoldMS: 1000, Site: "c"},
		{TS: fixtureNow, Kind: lockmetrics.KindTx, HoldMS: 1000, Site: "a"},
		{TS: fixtureNow, Kind: lockmetrics.KindTx, HoldMS: 10},
		{TS: fixtureNow, Kind: lockmetrics.KindExec, HoldMS: 500, Site: "y"},
		{TS: fixtureNow, Kind: lockmetrics.KindExec, HoldMS: 500, Site: "y"},
		{TS: fixtureNow, Kind: lockmetrics.KindExec, HoldMS: 1000, Site: "x"},
	}
	r := Build(Parsed{Events: events}, fixtureNow, time.Hour)
	var names []string
	for _, s := range r.Sites {
		names = append(names, s.Site)
	}
	assert.Equal(t, []string{"a", "c", "b", unknownSite}, names)
	names = nil
	for _, s := range r.ExecSites {
		names = append(names, s.Site)
	}
	assert.Equal(t, []string{"x", "y"}, names)
}

func TestBuild_BusyGroupedByProcAndSite(t *testing.T) {
	r := fixtureReport(t)
	require.Len(t, r.Busy, 1)
	assert.Equal(t, BusyGroup{
		Proc: "hook:session-state", Site: siteHook, Count: 2,
		BusyTimeoutsMS: []int64{1000, 5000}, Errs: []string{"SQLITE_BUSY"},
	}, r.Busy[0])
}

func TestBuild_BusyHoldersAreOtherPidsOverlappingTheWait(t *testing.T) {
	r := fixtureReport(t)
	require.Len(t, r.BusyHolders, 2)

	first := r.BusyHolders[0]
	assert.Equal(t, 200, first.PID)
	assert.Equal(t, int64(1000), first.BusyTimeoutMS)
	// Wait window [11:00:04.5, 11:00:05.5]. The 6000 ms daemon tx ending at
	// 11:00:10 ran [11:00:04, 11:00:10] and overlaps; the 1200 ms one ending
	// at 11:00:01 does not; pid 200's own tx is not a holder of its lock.
	require.Len(t, first.Holders, 1)
	assert.Equal(t, Holder{
		TS:  time.Date(2026, 10, 15, 11, 0, 10, 0, time.UTC),
		PID: 100, Proc: "daemon", Kind: lockmetrics.KindTx, Site: siteSave, HoldMS: 6000,
	}, first.Holders[0])

	assert.Empty(t, first.Execs)

	// Wait window [11:39:55, 11:40:00]: nothing slow ran then.
	assert.Equal(t, 201, r.BusyHolders[1].PID)
	assert.Empty(t, r.BusyHolders[1].Holders)
	assert.NotNil(t, r.BusyHolders[1].Holders, "an empty holder list encodes as [] in --json")
	assert.NotNil(t, r.BusyHolders[1].Execs, "an empty exec list encodes as [] in --json")
}

// An exec overlapping a busy wait is listed apart from the holders: its
// duration may be its own wait behind the same holder.
func TestBuild_BusyExecOverlapIsNotAHolder(t *testing.T) {
	busyAt := fixtureNow.Add(-time.Minute)
	events := []lockmetrics.Event{
		{TS: busyAt.Add(time.Second), PID: 2, Proc: "daemon", Kind: lockmetrics.KindTx, HoldMS: 3000, Site: "holder"},
		{TS: busyAt.Add(-100 * time.Millisecond), PID: 3, Proc: "hook:brief", Kind: lockmetrics.KindExec, HoldMS: 900, Site: "queued"},
		{TS: busyAt, PID: 1, Proc: "cli", Kind: lockmetrics.KindBusy, BusyTimeoutMS: 1000, WaitMS: 1000},
	}
	r := Build(Parsed{Events: events}, fixtureNow, time.Hour)
	require.Len(t, r.BusyHolders, 1)
	b := r.BusyHolders[0]
	require.Len(t, b.Holders, 1)
	assert.Equal(t, "holder", b.Holders[0].Site)
	assert.Equal(t, []ExecOverlap{{
		TS: busyAt.Add(-100 * time.Millisecond), PID: 3, Proc: "hook:brief", Site: "queued", MS: 900,
	}}, b.Execs)
	assert.Equal(t, int64(1000), b.WaitMS)

	var out strings.Builder
	require.NoError(t, WriteText(&out, r))
	assert.Contains(t, out.String(), "held by daemon pid 2 tx holder hold 3000ms")
	assert.Contains(t, out.String(), "exec by hook:brief pid 3 queued 900ms wait+hold (may be a waiter)")
	assert.NotContains(t, out.String(), "held by hook:brief")
}

// A busy's window is its measured wait when it has one; busy_timeout_ms is
// only the fallback. A busy that failed fast (SQLITE_BUSY_SNAPSHOT) does not
// name holds from its full timeout back.
func TestBuild_BusyWindowUsesMeasuredWait(t *testing.T) {
	busyAt := fixtureNow.Add(-time.Minute)
	events := []lockmetrics.Event{
		{TS: busyAt.Add(-2 * time.Second), PID: 2, Kind: lockmetrics.KindTx, HoldMS: 500, Site: "ended-before-the-wait"},
		{TS: busyAt.Add(-50 * time.Millisecond), PID: 2, Kind: lockmetrics.KindTx, HoldMS: 500, Site: "in-the-wait"},
		{TS: busyAt, PID: 1, Kind: lockmetrics.KindBusy, BusyTimeoutMS: 5000, WaitMS: 100, Err: "SQLITE_BUSY_SNAPSHOT"},
		{TS: busyAt.Add(time.Millisecond), PID: 1, Kind: lockmetrics.KindBusy, BusyTimeoutMS: 5000},
	}
	r := Build(Parsed{Events: events}, fixtureNow, time.Hour)
	require.Len(t, r.BusyHolders, 2)
	sitesOf := func(hs []Holder) []string {
		var out []string
		for _, h := range hs {
			out = append(out, h.Site)
		}
		return out
	}
	assert.Equal(t, []string{"in-the-wait"}, sitesOf(r.BusyHolders[0].Holders), "wait_ms 100 bounds the window")
	assert.Equal(t, []string{"ended-before-the-wait", "in-the-wait"}, sitesOf(r.BusyHolders[1].Holders),
		"no wait_ms: busy_timeout_ms bounds it")
}

// procs names each role's newest event across the files read, older than
// the window included, so a role that stopped writing shows its last line.
func TestBuild_ProcsNewestEventPerRole(t *testing.T) {
	r := fixtureReport(t)
	assert.Equal(t, []ProcLast{
		{Proc: "daemon", LastTS: time.Date(2026, 10, 15, 11, 52, 0, 0, time.UTC), Events: 7},
		{Proc: "hook:session-state", LastTS: time.Date(2026, 10, 15, 11, 40, 0, 0, time.UTC), Events: 3},
		{Proc: "mcp", LastTS: time.Date(2026, 10, 15, 11, 42, 0, 0, time.UTC), Events: 2},
	}, r.Procs)

	old := []lockmetrics.Event{{TS: fixtureNow.Add(-48 * time.Hour), Proc: "desktop", Kind: lockmetrics.KindTx}}
	r = Build(Parsed{Events: old}, fixtureNow, time.Hour)
	assert.Equal(t, []ProcLast{{Proc: "desktop", LastTS: fixtureNow.Add(-48 * time.Hour)}}, r.Procs)
	assert.Empty(t, r.Sites)
}

func TestBuild_BusyHoldersOverlapEdges(t *testing.T) {
	busyAt := fixtureNow.Add(-time.Minute)
	busy := lockmetrics.Event{TS: busyAt, PID: 1, Proc: "cli", Kind: lockmetrics.KindBusy, BusyTimeoutMS: 1000}
	tx := func(pid int, end time.Time, holdMS int64, site string) lockmetrics.Event {
		return lockmetrics.Event{TS: end, PID: pid, Proc: "daemon", Kind: lockmetrics.KindTx, HoldMS: holdMS, Site: site}
	}
	events := []lockmetrics.Event{
		tx(2, busyAt.Add(-time.Second), 100, "ends-exactly-at-wait-start"),
		tx(2, busyAt.Add(-time.Second-time.Millisecond), 100, "ends-just-before"),
		tx(2, busyAt.Add(time.Hour), int64(time.Hour/time.Millisecond), "starts-exactly-at-busy"),
		tx(2, busyAt.Add(time.Hour+time.Millisecond), int64(time.Hour/time.Millisecond), "starts-just-after"),
		tx(3, busyAt.Add(2*time.Minute), int64(10*time.Minute/time.Millisecond), "long-spanning"),
		{TS: busyAt, PID: 2, Kind: lockmetrics.KindPoolWait, WaitMS: 5000},
		busy,
	}
	r := Build(Parsed{Events: events}, fixtureNow.Add(2*time.Hour), 24*time.Hour)
	require.Len(t, r.BusyHolders, 1)
	var sites []string
	for _, h := range r.BusyHolders[0].Holders {
		sites = append(sites, h.Site)
	}
	sort.Strings(sites)
	assert.Equal(t, []string{"ends-exactly-at-wait-start", "long-spanning", "starts-exactly-at-busy"}, sites)
}

func TestBuild_BusyWithoutTimeoutMatchesOnlyTheInstant(t *testing.T) {
	busyAt := fixtureNow.Add(-time.Minute)
	events := []lockmetrics.Event{
		{TS: busyAt.Add(time.Second), PID: 2, Kind: lockmetrics.KindTx, HoldMS: 2000, Site: "spans"},
		{TS: busyAt.Add(-time.Millisecond), PID: 2, Kind: lockmetrics.KindTx, HoldMS: 2000, Site: "ended"},
		{TS: busyAt, PID: 1, Kind: lockmetrics.KindBusy},
	}
	r := Build(Parsed{Events: events}, fixtureNow, time.Hour)
	require.Len(t, r.BusyHolders, 1)
	require.Len(t, r.BusyHolders[0].Holders, 1)
	assert.Equal(t, "spans", r.BusyHolders[0].Holders[0].Site)
}

func TestBuild_WAL(t *testing.T) {
	r := fixtureReport(t)
	assert.Equal(t, WAL{
		Samples: 3, MinBytes: 1000, MedianBytes: 3000, MaxBytes: 5000,
		Checkpoints: 3, CheckpointBusy: 1, CheckpointIncomplete: 1,
		LastCheckpoint: "busy=0 log=8 ckpt=8",
	}, r.WAL)
}

func TestBuild_WALEvenMedianAndUnparsedCheckpoint(t *testing.T) {
	events := []lockmetrics.Event{
		{TS: fixtureNow, Kind: lockmetrics.KindWAL, WALBytes: 4000},
		{TS: fixtureNow, Kind: lockmetrics.KindWAL, WALBytes: 1000, Checkpoint: "garbage"},
		{TS: fixtureNow, Kind: lockmetrics.KindWAL, WALBytes: 2000, Checkpoint: "busy=0 log=-1 ckpt=-1"},
		{TS: fixtureNow, Kind: lockmetrics.KindWAL}, // wal_bytes omitted = 0
	}
	r := Build(Parsed{Events: events}, fixtureNow, time.Hour)
	assert.Equal(t, 4, r.WAL.Samples)
	assert.Equal(t, int64(0), r.WAL.MinBytes)
	assert.Equal(t, int64(1500), r.WAL.MedianBytes)
	assert.Equal(t, int64(4000), r.WAL.MaxBytes)
	assert.Equal(t, 1, r.WAL.Checkpoints, "log=-1 parses; garbage does not")
	assert.Equal(t, 1, r.WAL.CheckpointUnparsed)
	assert.Zero(t, r.WAL.CheckpointBusy)
	assert.Zero(t, r.WAL.CheckpointIncomplete)
}

func TestBuild_PoolWaitPerProcess(t *testing.T) {
	r := fixtureReport(t)
	assert.Equal(t, []PoolWait{
		{Proc: "daemon", Count: 1, TotalWaitMS: 900, MaxWaitMS: 900},
		{Proc: "mcp", Count: 2, TotalWaitMS: 300, MaxWaitMS: 250},
	}, r.PoolWait)
}

func TestBuild_EmptyInputEncodesEmptyArrays(t *testing.T) {
	r := Build(Parsed{}, fixtureNow, time.Hour)
	out, err := json.Marshal(r)
	require.NoError(t, err)
	s := string(out)
	for _, key := range []string{`"sites":[]`, `"exec_sites":[]`, `"busy":[]`, `"busy_holders":[]`, `"pool_wait":[]`, `"procs":[]`} {
		assert.Contains(t, s, key)
	}
}

// TestReport_JSONKeysPinned pins the --json keys, top-level and nested;
// scripts and the #529 live-run notes read them. Add keys, never rename.
func TestReport_JSONKeysPinned(t *testing.T) {
	// Every list non-empty and every omitempty field set, so each element's
	// key set is present.
	events := []lockmetrics.Event{
		{TS: fixtureNow, PID: 2, Proc: "daemon", Kind: lockmetrics.KindTx, HoldMS: 900, Site: "tx"},
		{TS: fixtureNow, PID: 3, Proc: "mcp", Kind: lockmetrics.KindExec, HoldMS: 900, Site: "exec"},
		{TS: fixtureNow, PID: 1, Proc: "cli", Kind: lockmetrics.KindBusy, BusyTimeoutMS: 1000, Site: "b", Err: "SQLITE_BUSY"},
		{TS: fixtureNow, PID: 2, Proc: "daemon", Kind: lockmetrics.KindWAL, WALBytes: 1, Checkpoint: "busy=0 log=1 ckpt=1"},
		{TS: fixtureNow, PID: 2, Proc: "daemon", Kind: lockmetrics.KindPoolWait, WaitMS: 5},
	}
	out, err := json.Marshal(Build(Parsed{Events: events, Files: []string{"f"}}, fixtureNow, time.Hour))
	require.NoError(t, err)
	var top map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(out, &top))
	assert.Equal(t, []string{"busy", "busy_holders", "exec_sites", "malformed", "pool_wait", "procs", "sites", "wal", "window"}, keysOf(t, top))

	object := func(key string) map[string]json.RawMessage {
		var m map[string]json.RawMessage
		require.NoError(t, json.Unmarshal(top[key], &m), key)
		return m
	}
	first := func(raw json.RawMessage, key string) map[string]json.RawMessage {
		var list []map[string]json.RawMessage
		require.NoError(t, json.Unmarshal(raw, &list), key)
		require.NotEmpty(t, list, key)
		return list[0]
	}
	assert.Equal(t, []string{"events", "files", "from", "since_seconds", "to"}, keysOf(t, object("window")))
	assert.Equal(t, []string{"count", "max_hold_ms", "max_wait_ms", "over_1s", "over_5s", "site", "total_hold_ms"},
		keysOf(t, first(top["sites"], "sites")))
	assert.Equal(t, []string{"count", "max_ms", "site", "total_ms"}, keysOf(t, first(top["exec_sites"], "exec_sites")))
	assert.Equal(t, []string{"busy_timeouts_ms", "count", "errs", "proc", "site"}, keysOf(t, first(top["busy"], "busy")))
	busy := first(top["busy_holders"], "busy_holders")
	assert.Equal(t, []string{"busy_timeout_ms", "err", "execs", "holders", "pid", "proc", "site", "ts", "wait_ms"}, keysOf(t, busy))
	assert.Equal(t, []string{"hold_ms", "kind", "pid", "proc", "site", "ts"}, keysOf(t, first(busy["holders"], "holders")))
	assert.Equal(t, []string{"ms", "pid", "proc", "site", "ts"}, keysOf(t, first(busy["execs"], "execs")))
	assert.Equal(t, []string{
		"checkpoint_busy", "checkpoint_incomplete", "checkpoint_unparsed", "checkpoints",
		"last_checkpoint", "max_bytes", "median_bytes", "min_bytes", "samples",
	}, keysOf(t, object("wal")))
	assert.Equal(t, []string{"count", "max_wait_ms", "proc", "total_wait_ms"}, keysOf(t, first(top["pool_wait"], "pool_wait")))
	assert.Equal(t, []string{"events", "last_ts", "proc"}, keysOf(t, first(top["procs"], "procs")))
}

func keysOf(t *testing.T, m map[string]json.RawMessage) []string {
	t.Helper()
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func TestWriteText(t *testing.T) {
	var b strings.Builder
	require.NoError(t, WriteText(&b, fixtureReport(t)))
	out := b.String()

	for _, want := range []string{
		"3 malformed lines skipped",
		siteSave,
		"hook:session-state",
		"1000,5000",
		"held by daemon pid 100 tx " + siteSave + " hold 6000ms",
		"no recorded holder",
		"min 1000  median 3000  max 5000",
		"3 checkpoints, 1 busy, 1 incomplete",
		"mcp",
		"Slow autocommit writes by site (wait+hold combined",
		siteUpsert + "  1      300       300",
		"Last event per process",
		"hook:session-state  2026-10-15 11:40:00.000  3",
	} {
		assert.Contains(t, out, want)
	}
}

func TestWriteText_Empty(t *testing.T) {
	var b strings.Builder
	require.NoError(t, WriteText(&b, Build(Parsed{}, fixtureNow, time.Hour)))
	out := b.String()
	assert.NotContains(t, out, "malformed")
	assert.Contains(t, out, "0 events")
	assert.Equal(t, 7, strings.Count(out, "  none"), "each of the seven sections says none")
}

func TestWriteText_CapsBusyHolderList(t *testing.T) {
	var events []lockmetrics.Event
	for i := range maxTextBusy + 5 {
		events = append(events, lockmetrics.Event{
			TS: fixtureNow.Add(-time.Duration(i+1) * time.Second), PID: 1, Proc: "cli",
			Kind: lockmetrics.KindBusy, Site: "s",
		})
	}
	var b strings.Builder
	require.NoError(t, WriteText(&b, Build(Parsed{Events: events}, fixtureNow, time.Hour)))
	assert.Contains(t, b.String(), "latest 20 of 25")
}

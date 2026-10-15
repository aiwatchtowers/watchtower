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
	require.Len(t, r.Sites, 3)

	assert.Equal(t, Site{
		Site: siteSave, Count: 2, TotalHoldMS: 7200, MaxHoldMS: 6000,
		MaxWaitMS: 30, Over1s: 2, Over5s: 1,
	}, r.Sites[0], "the 9000 ms hold from the day before is outside the window")
	assert.Equal(t, siteOwnTx, r.Sites[1].Site)
	assert.Equal(t, Site{
		Site: siteUpsert, Count: 1, TotalHoldMS: 300, MaxHoldMS: 300, MaxWaitMS: 250,
	}, r.Sites[2])
}

func TestBuild_SitesTieOnTotalBreaksOnMaxThenName(t *testing.T) {
	events := []lockmetrics.Event{
		{TS: fixtureNow, Kind: lockmetrics.KindTx, HoldMS: 500, Site: "b"},
		{TS: fixtureNow, Kind: lockmetrics.KindTx, HoldMS: 500, Site: "b"},
		{TS: fixtureNow, Kind: lockmetrics.KindTx, HoldMS: 1000, Site: "c"},
		{TS: fixtureNow, Kind: lockmetrics.KindExec, HoldMS: 1000, Site: "a"},
		{TS: fixtureNow, Kind: lockmetrics.KindExec, HoldMS: 10},
	}
	r := Build(Parsed{Events: events}, fixtureNow, time.Hour)
	var names []string
	for _, s := range r.Sites {
		names = append(names, s.Site)
	}
	assert.Equal(t, []string{"a", "c", "b", unknownSite}, names)
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

	assert.Equal(t, 201, r.BusyHolders[1].PID)
	assert.Empty(t, r.BusyHolders[1].Holders)
	assert.NotNil(t, r.BusyHolders[1].Holders, "an empty holder list encodes as [] in --json")
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
	for _, key := range []string{`"sites":[]`, `"busy":[]`, `"busy_holders":[]`, `"pool_wait":[]`} {
		assert.Contains(t, s, key)
	}
}

// TestReport_JSONKeysPinned pins the --json top-level keys; scripts and the
// #529 live-run notes read them.
func TestReport_JSONKeysPinned(t *testing.T) {
	out, err := json.Marshal(fixtureReport(t))
	require.NoError(t, err)
	var top map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(out, &top))
	var keys []string
	for k := range top {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	assert.Equal(t, []string{"busy", "busy_holders", "malformed", "pool_wait", "sites", "wal", "window"}, keys)
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
	assert.Equal(t, 5, strings.Count(out, "  none"), "each of the five sections says none")
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

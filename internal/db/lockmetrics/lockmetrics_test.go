package lockmetrics

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// helperEnv makes the re-executed test binary act as a second writer process
// (see TestHelperProcessRecord).
const (
	helperEnv      = "LOCKMETRICS_HELPER_DB"
	helperCountEnv = "LOCKMETRICS_HELPER_COUNT"
	helperRoleEnv  = "LOCKMETRICS_HELPER_ROLE"
)

// setup gives each test a fresh process state, a temp workspace and the
// sink configured next to a fake DB file in it. It returns the sink path.
func setup(t *testing.T) string {
	t.Helper()
	resetForTest()
	t.Cleanup(resetForTest)
	dir := t.TempDir()
	Configure(filepath.Join(dir, "watchtower.db"))
	return filepath.Join(dir, FileName)
}

// captureWarnings swaps the default slog logger for one writing into a
// buffer and returns a counter of WARN records.
func captureWarnings(t *testing.T) func() int {
	t.Helper()
	var mu sync.Mutex
	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&lockedWriter{mu: &mu, w: &buf}, nil)))
	t.Cleanup(func() { slog.SetDefault(prev) })
	return func() int {
		mu.Lock()
		defer mu.Unlock()
		return strings.Count(buf.String(), "level=WARN")
	}
}

type lockedWriter struct {
	mu *sync.Mutex
	w  *bytes.Buffer
}

func (l *lockedWriter) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.w.Write(p)
}

func readLines(t *testing.T, path string) []string {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open %s: %v", path, err)
	}
	defer f.Close()
	var lines []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		lines = append(lines, sc.Text())
	}
	if err := sc.Err(); err != nil {
		t.Fatalf("scan %s: %v", path, err)
	}
	return lines
}

func TestRecordWritesLineWithFilledFieldsAndBindingKeys(t *testing.T) {
	path := setup(t)
	SetProcessRole("hook:session-state")

	before := time.Now().UTC()
	Record(Event{
		Kind:          KindBusy,
		WaitMS:        12,
		HoldMS:        1840,
		Site:          "internal/sync.(*Syncer).saveMessages",
		Err:           "SQLITE_BUSY",
		BusyTimeoutMS: 1000,
		WALBytes:      4096,
		Checkpoint:    "busy=0 log=12 ckpt=12",
	})

	lines := readLines(t, path)
	if len(lines) != 1 {
		t.Fatalf("want 1 line, got %d: %q", len(lines), lines)
	}
	var raw map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &raw); err != nil {
		t.Fatalf("line is not JSON: %v: %s", err, lines[0])
	}
	var keys []string
	for k := range raw {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	want := []string{"busy_timeout_ms", "checkpoint", "err", "hold_ms", "kind", "pid", "proc", "site", "ts", "wait_ms", "wal_bytes"}
	if strings.Join(keys, ",") != strings.Join(want, ",") {
		t.Fatalf("keys = %v, want %v", keys, want)
	}
	if raw["proc"] != "hook:session-state" || raw["kind"] != "busy" || raw["err"] != "SQLITE_BUSY" {
		t.Fatalf("unexpected values: %s", lines[0])
	}
	if int(raw["pid"].(float64)) != os.Getpid() {
		t.Fatalf("pid = %v, want %d", raw["pid"], os.Getpid())
	}
	tsStr := raw["ts"].(string)
	if !tsPattern.MatchString(tsStr) {
		t.Fatalf("ts %q is not fixed-width UTC with milliseconds", tsStr)
	}
	ts, err := time.Parse(time.RFC3339Nano, tsStr)
	if err != nil {
		t.Fatalf("ts not RFC3339Nano: %v", err)
	}
	if ts.Before(before.Add(-time.Second)) || ts.After(time.Now().Add(time.Second)) {
		t.Fatalf("ts %v not around now", ts)
	}
}

func TestRecordOmitsEmptyOptionalFieldsAndDefaultsRoleToCLI(t *testing.T) {
	path := setup(t)
	Record(Event{Kind: KindTx, HoldMS: 250})

	lines := readLines(t, path)
	if len(lines) != 1 {
		t.Fatalf("want 1 line, got %d", len(lines))
	}
	var raw map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &raw); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"wait_ms", "site", "err", "busy_timeout_ms", "wal_bytes", "checkpoint"} {
		if _, ok := raw[k]; ok {
			t.Errorf("empty %s should be omitted: %s", k, lines[0])
		}
	}
	if raw["proc"] != "cli" {
		t.Errorf("default proc = %v, want cli", raw["proc"])
	}
}

func TestRecordKeepsCallerTimestampInUTC(t *testing.T) {
	path := setup(t)
	loc := time.FixedZone("plus3", 3*3600)
	ts := time.Now().In(loc).Truncate(time.Millisecond)
	Record(Event{TS: ts, Kind: KindWAL, WALBytes: 1})

	var e Event
	if err := json.Unmarshal([]byte(readLines(t, path)[0]), &e); err != nil {
		t.Fatal(err)
	}
	if !e.TS.Equal(ts) || e.TS.Location() != time.UTC {
		t.Fatalf("ts = %v, want %v in UTC", e.TS, ts)
	}
}

func TestConcurrentRecordsNeverInterleave(t *testing.T) {
	path := setup(t)
	const goroutines, perG = 16, 200
	site := strings.Repeat("x", 300) // long lines make a torn write visible
	var wg sync.WaitGroup
	for g := 0; g < goroutines; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := 0; i < perG; i++ {
				Record(Event{Kind: KindExec, WaitMS: int64(g), HoldMS: int64(i), Site: site})
			}
		}(g)
	}
	wg.Wait()

	lines := readLines(t, path)
	if len(lines) != goroutines*perG {
		t.Fatalf("lines = %d, want %d", len(lines), goroutines*perG)
	}
	for i, l := range lines {
		var e Event
		if err := json.Unmarshal([]byte(l), &e); err != nil {
			t.Fatalf("line %d does not parse: %v", i, err)
		}
	}
}

// TestHelperProcessRecord is not a test on its own: the cross-process test
// re-executes the test binary with helperEnv set, and this body then acts as
// a second writer process.
func TestHelperProcessRecord(t *testing.T) {
	dbPath := os.Getenv(helperEnv)
	if dbPath == "" {
		t.Skip("helper process only")
	}
	n, _ := strconv.Atoi(os.Getenv(helperCountEnv))
	resetForTest()
	SetProcessRole(os.Getenv(helperRoleEnv))
	Configure(dbPath)
	site := strings.Repeat("y", 300)
	for i := 0; i < n; i++ {
		Record(Event{Kind: KindTx, HoldMS: int64(i), Site: site})
	}
}

func TestTwoProcessesNeverInterleave(t *testing.T) {
	path := setup(t)
	dbPath := filepath.Join(filepath.Dir(path), "watchtower.db")
	const perProc = 500

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	var cmds []*exec.Cmd
	for i := 0; i < 2; i++ {
		cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestHelperProcessRecord$")
		cmd.Env = append(os.Environ(),
			helperEnv+"="+dbPath,
			helperCountEnv+"="+strconv.Itoa(perProc),
			helperRoleEnv+"=cli:helper"+strconv.Itoa(i),
		)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
		if err := cmd.Start(); err != nil {
			t.Fatalf("start helper: %v", err)
		}
		t.Cleanup(func() {
			if cmd.ProcessState != nil {
				return // already reaped: its pgid may belong to someone else now
			}
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			_ = cmd.Wait()
		})
		cmds = append(cmds, cmd)
	}
	for _, cmd := range cmds {
		if err := cmd.Wait(); err != nil {
			t.Fatalf("helper failed: %v", err)
		}
	}

	lines := readLines(t, path)
	if len(lines) != 2*perProc {
		t.Fatalf("lines = %d, want %d", len(lines), 2*perProc)
	}
	perRole := map[string]int{}
	for i, l := range lines {
		var e Event
		if err := json.Unmarshal([]byte(l), &e); err != nil {
			t.Fatalf("line %d does not parse: %v", i, err)
		}
		perRole[e.Proc]++
	}
	if perRole["cli:helper0"] != perProc || perRole["cli:helper1"] != perProc {
		t.Fatalf("per-process counts = %v", perRole)
	}
}

// The sink's names and cap are a Go↔Swift dual path: DBLockMetricsTests
// asserts the same literals, so a rename on one side fails a suite instead of
// passing both through each side's own constant.
func TestSinkNamesAndCapAreTheSharedLiterals(t *testing.T) {
	path := setup(t)
	setMaxFileBytesForTest(1024)
	for i := 0; i < 40; i++ {
		Record(Event{Kind: KindTx, HoldMS: int64(i), Site: strings.Repeat("s", 60)})
	}
	dir := filepath.Dir(path)
	for _, name := range []string{"dblock.jsonl", "dblock.jsonl.1", "dblock.jsonl.lock"} {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			t.Errorf("%s after a rotation: %v", name, err)
		}
	}
	if MaxFileBytes != 10485760 {
		t.Errorf("MaxFileBytes = %d, want 10485760 (10 MiB, as the Swift writer)", MaxFileBytes)
	}
}

func TestRotationMovesFullFileToDotOneAndContinues(t *testing.T) {
	path := setup(t)
	setMaxFileBytesForTest(1024)

	for i := 0; i < 40; i++ {
		Record(Event{Kind: KindTx, HoldMS: int64(i), Site: strings.Repeat("s", 60)})
	}

	rotated := readLines(t, path+".1")
	current := readLines(t, path)
	if len(rotated) == 0 || len(current) == 0 {
		t.Fatalf("rotated=%d current=%d, want both non-empty", len(rotated), len(current))
	}
	if fi, err := os.Stat(path); err != nil || fi.Size() > 1024+200 {
		t.Fatalf("current file not reset after rotation: %v, %v", fi, err)
	}
	// The newest event is in the current file; nothing is torn.
	var last Event
	if err := json.Unmarshal([]byte(current[len(current)-1]), &last); err != nil {
		t.Fatal(err)
	}
	if last.HoldMS != 39 {
		t.Fatalf("last event hold_ms = %d, want 39", last.HoldMS)
	}
	for _, l := range append(rotated, current...) {
		var e Event
		if err := json.Unmarshal([]byte(l), &e); err != nil {
			t.Fatalf("torn line %q: %v", l, err)
		}
	}
	if _, err := os.Stat(path + ".2"); !os.IsNotExist(err) {
		t.Fatalf("only one generation expected, .2 stat err = %v", err)
	}
}

func TestRotatedOrDeletedElsewhereReopensPath(t *testing.T) {
	path := setup(t)
	Record(Event{Kind: KindTx, HoldMS: 1})

	// Another process rotates the file away and already starts the fresh
	// one: the next line goes to the file now at the path, never to the
	// held (now .1) inode.
	if err := os.Rename(path, path+".1"); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	Record(Event{Kind: KindTx, HoldMS: 2})
	if got := readLines(t, path+".1"); len(got) != 1 {
		t.Fatalf(".1 lines = %d, want 1 (stale inode kept receiving writes)", len(got))
	}
	if got := readLines(t, path); len(got) != 1 {
		t.Fatalf("path lines after external rotation = %d, want 1", len(got))
	}

	// Someone deletes it: the next record recreates it.
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	Record(Event{Kind: KindTx, HoldMS: 3})
	got := readLines(t, path)
	if len(got) != 1 {
		t.Fatalf("path lines after delete = %d, want 1", len(got))
	}
	var e Event
	if err := json.Unmarshal([]byte(got[0]), &e); err != nil || e.HoldMS != 3 {
		t.Fatalf("recreated file holds %q (err=%v)", got[0], err)
	}
}

var tsPattern = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$`)

func TestTimestampKeepsZeroFraction(t *testing.T) {
	path := setup(t)
	ts := time.Date(2026, 10, 15, 10, 0, 0, 0, time.FixedZone("plus3", 3*3600))
	Record(Event{TS: ts, Kind: KindBusy})
	line := readLines(t, path)[0]
	if !strings.HasPrefix(line, `{"ts":"2026-10-15T07:00:00.000Z",`) {
		t.Fatalf("line = %s, want ts 2026-10-15T07:00:00.000Z first", line)
	}
}

// writeFull puts n bytes at path so it is over a test-sized cap.
func writeFull(t *testing.T, path string, n int) os.FileInfo {
	t.Helper()
	if err := os.WriteFile(path, []byte(strings.Repeat("x", n-1)+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return fi
}

func fileSize(t *testing.T, path string) int64 {
	t.Helper()
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return fi.Size()
}

// Two writers both saw the full file over the cap. The first rotates it and
// a fresh file appears at the path; the second, acting on its stale stat,
// must not move the fresh file over the full generation in .1.
func TestRotationRaceKeepsFullGeneration(t *testing.T) {
	path := setup(t)
	setMaxFileBytesForTest(1024)
	seen := writeFull(t, path, 4096)

	rotate(path, seen) // writer A
	if got := fileSize(t, path+".1"); got != 4096 {
		t.Fatalf(".1 after first rotation = %d bytes, want 4096", got)
	}
	if err := os.WriteFile(path, []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	rotate(path, seen) // writer B, stale view
	if got := fileSize(t, path+".1"); got != 4096 {
		t.Fatalf(".1 after the losing rotation = %d bytes, want the full 4096", got)
	}
	if got := fileSize(t, path); got != 3 {
		t.Fatalf("fresh file = %d bytes, want 3 (left in place)", got)
	}

	// Even a new file already over the cap is not B's to rotate: it is not
	// the inode B saw.
	writeFull(t, path, 2048)
	rotate(path, seen)
	if got := fileSize(t, path+".1"); got != 4096 {
		t.Fatalf(".1 = %d bytes after a stale rotation of another full file, want 4096", got)
	}
}

// The same inode truncated below the cap (someone emptied the log in place)
// is no longer full: nothing to rotate.
func TestRotationSkipsSameFileNoLongerOverCap(t *testing.T) {
	path := setup(t)
	setMaxFileBytesForTest(1024)
	seen := writeFull(t, path, 4096)
	if err := os.Truncate(path, 10); err != nil {
		t.Fatal(err)
	}
	rotate(path, seen)
	if _, err := os.Stat(path + ".1"); !os.IsNotExist(err) {
		t.Fatalf("rotated a file under the cap (err=%v)", err)
	}
}

func TestRotationSkippedWhileAnotherWriterHoldsTheLock(t *testing.T) {
	path := setup(t)
	setMaxFileBytesForTest(1024)
	writeFull(t, path, 4096)

	lockPath := filepath.Join(filepath.Dir(path), LockFileName)
	lf, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer lf.Close()
	if err := syscall.Flock(int(lf.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatal(err)
	}

	Record(Event{Kind: KindTx, HoldMS: 1}) // must not block, must not rotate
	if _, err := os.Stat(path + ".1"); !os.IsNotExist(err) {
		t.Fatalf("rotated while the lock was held (err=%v)", err)
	}
	if got := fileSize(t, path); got <= 4096 {
		t.Fatalf("line not appended while rotation was skipped: size %d", got)
	}

	if err := syscall.Flock(int(lf.Fd()), syscall.LOCK_UN); err != nil {
		t.Fatal(err)
	}
	Record(Event{Kind: KindTx, HoldMS: 2})
	if got := fileSize(t, path+".1"); got <= 4096 {
		t.Fatalf(".1 = %d bytes, want the full generation once the lock is free", got)
	}
	if fi, err := os.Stat(lockPath); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("lock file must stay, mode 0600: %v, %v", fi, err)
	}
}

func TestFileModeIs0600(t *testing.T) {
	path := setup(t)
	Record(Event{Kind: KindBusy})
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v, want 0600", fi.Mode().Perm())
	}
}

func TestThresholdEnv(t *testing.T) {
	cases := []struct {
		val       string
		set       bool
		enabled   bool
		threshold time.Duration
		warns     int
	}{
		{set: false, enabled: true, threshold: DefaultThreshold},
		{val: "0", set: true, enabled: true, threshold: 0},
		{val: "750", set: true, enabled: true, threshold: 750 * time.Millisecond},
		{val: "off", set: true, enabled: false, threshold: DefaultThreshold},
		{val: "OFF", set: true, enabled: false, threshold: DefaultThreshold},
		{val: "garbage", set: true, enabled: true, threshold: DefaultThreshold, warns: 1},
		{val: "-5", set: true, enabled: true, threshold: DefaultThreshold, warns: 1},
		{val: "", set: true, enabled: true, threshold: DefaultThreshold},
		{val: " 300 ", set: true, enabled: true, threshold: 300 * time.Millisecond},
	}
	for _, tc := range cases {
		t.Run(fmt.Sprintf("%q/set=%v", tc.val, tc.set), func(t *testing.T) {
			if tc.set {
				t.Setenv(thresholdEnv, tc.val)
			} else {
				t.Setenv(thresholdEnv, "") // restore on cleanup
				if err := os.Unsetenv(thresholdEnv); err != nil {
					t.Fatal(err)
				}
			}
			warns := captureWarnings(t)
			path := setup(t)

			if got := Enabled(); got != tc.enabled {
				t.Errorf("Enabled() = %v, want %v", got, tc.enabled)
			}
			if got := Threshold(); got != tc.threshold {
				t.Errorf("Threshold() = %v, want %v", got, tc.threshold)
			}
			_ = Threshold() // read once: a second call must not warn again
			if got := warns(); got != tc.warns {
				t.Errorf("warnings = %d, want %d", got, tc.warns)
			}

			Record(Event{Kind: KindBusy})
			_, err := os.Stat(path)
			if tc.enabled && err != nil {
				t.Errorf("enabled but nothing written: %v", err)
			}
			if !tc.enabled && !os.IsNotExist(err) {
				t.Errorf("off but file exists (err=%v)", err)
			}
		})
	}
}

func TestSlow(t *testing.T) {
	t.Setenv(thresholdEnv, "200")
	setup(t)
	cases := []struct {
		wait, hold time.Duration
		want       bool
	}{
		{0, 0, false},
		{199 * time.Millisecond, 199 * time.Millisecond, false},
		{200 * time.Millisecond, 0, true},
		{0, 200 * time.Millisecond, true},
		{time.Second, time.Second, true},
	}
	for _, tc := range cases {
		if got := Slow(tc.wait, tc.hold); got != tc.want {
			t.Errorf("Slow(%v, %v) = %v, want %v", tc.wait, tc.hold, got, tc.want)
		}
	}
}

func TestSlowZeroThresholdLogsEverything(t *testing.T) {
	t.Setenv(thresholdEnv, "0")
	setup(t)
	if !Slow(0, 0) {
		t.Fatal("threshold 0: Slow(0, 0) should be true")
	}
}

func TestSlowFalseWhenDisabled(t *testing.T) {
	t.Setenv(thresholdEnv, "off")
	setup(t)
	if Slow(time.Hour, time.Hour) {
		t.Fatal("off: Slow must be false")
	}
}

func TestConfigureMemoryOrEmptyDisables(t *testing.T) {
	for _, p := range []string{":memory:", ""} {
		t.Run(fmt.Sprintf("%q", p), func(t *testing.T) {
			path := setup(t)
			if !Enabled() {
				t.Fatal("precondition: enabled after Configure(file)")
			}
			Configure(p)
			if Enabled() {
				t.Fatal("Configure should disable the sink")
			}
			Record(Event{Kind: KindBusy})
			if _, err := os.Stat(path); !os.IsNotExist(err) {
				t.Fatalf("file written while disabled (err=%v)", err)
			}
		})
	}
}

func TestNotConfiguredIsDisabled(t *testing.T) {
	resetForTest()
	t.Cleanup(resetForTest)
	if Enabled() {
		t.Fatal("Enabled() without Configure should be false")
	}
	Record(Event{Kind: KindBusy}) // must not panic
}

func TestConfigureLastCallWins(t *testing.T) {
	first := setup(t)
	dir2 := t.TempDir()
	Configure(filepath.Join(dir2, "watchtower.db"))
	Configure(filepath.Join(dir2, "watchtower.db")) // idempotent
	Record(Event{Kind: KindBusy})
	if _, err := os.Stat(first); !os.IsNotExist(err) {
		t.Fatalf("first sink written after reconfigure (err=%v)", err)
	}
	if got := len(readLines(t, filepath.Join(dir2, FileName))); got != 1 {
		t.Fatalf("second sink lines = %d, want 1", got)
	}
}

func TestUnwritableDirWarnsOnceAndNeverPanics(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root ignores the 0500 directory mode")
	}
	warns := captureWarnings(t)
	resetForTest()
	t.Cleanup(resetForTest)
	dir := t.TempDir()
	ro := filepath.Join(dir, "ro")
	if err := os.Mkdir(ro, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(ro, 0o700) })
	Configure(filepath.Join(ro, "watchtower.db"))

	for i := 0; i < 5; i++ {
		Record(Event{Kind: KindBusy})
	}
	if got := warns(); got != 1 {
		t.Fatalf("warnings = %d, want exactly 1", got)
	}
	if _, err := os.Stat(filepath.Join(ro, FileName)); !os.IsNotExist(err) {
		t.Fatalf("file unexpectedly exists (err=%v)", err)
	}
}

func TestRecordZeroEventStillWrites(t *testing.T) {
	path := setup(t)
	Record(Event{})
	if got := len(readLines(t, path)); got != 1 {
		t.Fatalf("zero event lines = %d, want 1", got)
	}
}

func BenchmarkRecord(b *testing.B) {
	resetForTest()
	b.Cleanup(resetForTest)
	Configure(filepath.Join(b.TempDir(), "watchtower.db"))
	e := Event{Kind: KindTx, WaitMS: 3, HoldMS: 250, Site: "internal/sync.(*Syncer).saveMessages"}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		Record(e)
	}
}

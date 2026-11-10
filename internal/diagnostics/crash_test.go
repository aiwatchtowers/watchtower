package diagnostics

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// crashFiles writes the three log files (watchtower.log, watchtower.log.1,
// daemon.log) into a temp dir; an empty content leaves that file missing.
func crashFiles(t *testing.T, current, rotated, daemon string) []string {
	t.Helper()
	dir := t.TempDir()
	names := []string{"watchtower.log", "watchtower.log.1", "daemon.log"}
	contents := []string{current, rotated, daemon}
	files := make([]string, len(names))
	for i, n := range names {
		files[i] = filepath.Join(dir, n)
		if contents[i] == "" {
			continue
		}
		if err := os.WriteFile(files[i], []byte(contents[i]), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return files
}

func scanUTC(files []string) CrashScan {
	return ScanCrashes(files, time.Now().Add(time.Minute), time.Now, time.UTC)
}

const goTrace = "panic: something broke\n" +
	"\n" +
	"goroutine 7 [running]:\n" +
	"runtime.throw({0x1, 0x2})\n" +
	"\t/usr/local/go/src/runtime/panic.go:1 +0x1\n" +
	"watchtower/internal/sync.(*Syncer).run(0xc000123456, {0x1, 0x2})\n" +
	"\t/src/internal/sync/sync.go:10 +0x2\n" +
	"created by watchtower/cmd.runSync in goroutine 1\n" +
	"\t/src/cmd/sync.go:5 +0x3\n"

func TestDiagnostics_CrashRuntimeHeaders(t *testing.T) {
	got := scanUTC(crashFiles(t, goTrace, "", ""))
	if got.Count != 1 || got.Place != "watchtower/internal/sync.(*Syncer).run" {
		t.Fatalf("panic trace: got %+v", got)
	}

	fatal := "fatal error: concurrent map writes\n" +
		"\n" +
		"goroutine 1 [running]:\n" +
		"watchtower/internal/db.(*DB).Put(...)\n" +
		"\t/src/internal/db/db.go:3\n"
	got = scanUTC(crashFiles(t, fatal, "", ""))
	if got.Count != 1 || got.Place != "watchtower/internal/db.(*DB).Put" {
		t.Fatalf("fatal error trace: got %+v", got)
	}
}

func TestDiagnostics_IgnoresLoggedPanicText(t *testing.T) {
	logged := "2026/11/04 09:00:00 recovered panic: x\n" +
		"goroutine 3 [running]:\n"
	if got := scanUTC(crashFiles(t, logged, "", "")); got.Count != 0 {
		t.Fatalf("timestamped panic text counted: %+v", got)
	}

	noHeader := "panic: x\n1\n2\n3\n4\n5\ngoroutine 1 [running]:\n"
	if got := scanUTC(crashFiles(t, noHeader, "", "")); got.Count != 0 {
		t.Fatalf("panic without a header within 5 lines counted: %+v", got)
	}

	withinFive := "panic: x\n1\n2\n3\n4\ngoroutine 1 [running]:\n"
	if got := scanUTC(crashFiles(t, withinFive, "", "")); got.Count != 1 {
		t.Fatalf("header on the 5th line not counted: %+v", got)
	}
}

func TestDiagnostics_CrashTimeAndPlace(t *testing.T) {
	log := "2026/11/04 09:10:00 sync: started\n" +
		"2026/11/04 09:12:30 sync: channel page\n" +
		goTrace
	got := scanUTC(crashFiles(t, log, "", ""))
	want := time.Date(2026, 11, 4, 9, 12, 30, 0, time.UTC)
	if got.Count != 1 || !got.TimeKnown || !got.Time.Equal(want) ||
		got.Place != "watchtower/internal/sync.(*Syncer).run" {
		t.Fatalf("got %+v, want time %v and a place", got, want)
	}
}

func TestDiagnostics_CrashTimeUnknownWithPlace(t *testing.T) {
	got := scanUTC(crashFiles(t, goTrace, "", ""))
	if got.Count != 1 || got.TimeKnown || got.Place == "" {
		t.Fatalf("got %+v, want time unknown with a place", got)
	}
}

const runtimeOnlyTrace = "fatal error: out of memory\n" +
	"\n" +
	"goroutine 1 [running]:\n" +
	"runtime.throw({0x1, 0x2})\n" +
	"\t/usr/local/go/src/runtime/panic.go:1 +0x1\n" +
	"main.main()\n" +
	"\t/src/main.go:3 +0x1\n" +
	"\n" +
	"goroutine 9 [select]:\n" +
	"watchtower/internal/daemon.(*Daemon).loop(...)\n" +
	"\t/src/internal/daemon/daemon.go:9\n"

func TestDiagnostics_CrashLocationUnknown(t *testing.T) {
	log := "2026/11/04 08:00:00 daemon: cycle\n" + runtimeOnlyTrace
	got := scanUTC(crashFiles(t, log, "", ""))
	if got.Count != 1 || !got.TimeKnown || got.Place != "" {
		t.Fatalf("got %+v, want time known and location unknown (frames of another goroutine never count)", got)
	}
}

func TestDiagnostics_CrashTimeAndLocationUnknown(t *testing.T) {
	got := scanUTC(crashFiles(t, runtimeOnlyTrace, "", ""))
	if got.Count != 1 || got.TimeKnown || got.Place != "" {
		t.Fatalf("got %+v, want time and location unknown", got)
	}
}

func TestDiagnostics_NoCrash(t *testing.T) {
	got := scanUTC(crashFiles(t, "2026/11/04 08:00:00 daemon: cycle\n", "", "nothing\n"))
	if got.Count != 0 || got.NoLogs || got.Stopped {
		t.Fatalf("got %+v, want no crash", got)
	}
}

func TestDiagnostics_CrashNoLogs(t *testing.T) {
	files := crashFiles(t, "", "", "")
	if got := scanUTC(files); !got.NoLogs || got.Count != 0 {
		t.Fatalf("got %+v, want NoLogs", got)
	}
	// A directory in a log's place is unreadable and skipped too.
	if err := os.Mkdir(files[0], 0o700); err != nil {
		t.Fatal(err)
	}
	if got := scanUTC(files); !got.NoLogs {
		t.Fatalf("directory as a log: got %+v, want NoLogs", got)
	}
}

func TestDiagnostics_CrashTimeLocalToUTC(t *testing.T) {
	plus3 := time.FixedZone("UTC+3", 3*60*60)
	log := "2026/11/04 12:12:00 sync: page\n" + goTrace
	got := ScanCrashes(crashFiles(t, log, "", ""), time.Now().Add(time.Minute), time.Now, plus3)
	want := time.Date(2026, 11, 4, 9, 12, 0, 0, time.UTC)
	if !got.TimeKnown || !got.Time.Equal(want) || got.Time.Location() != time.UTC {
		t.Fatalf("got %v (%v), want %v in UTC", got.Time, got.Time.Location(), want)
	}

	berlin, err := time.LoadLocation("Europe/Berlin")
	if err != nil {
		t.Skipf("no zoneinfo: %v", err)
	}
	// 02:30 happens twice on 2026-10-25 in Berlin; ParseInLocation decides.
	const overlap = "2026/10/25 02:30:00"
	log = overlap + " sync: page\n" + goTrace
	got = ScanCrashes(crashFiles(t, log, "", ""), time.Now().Add(time.Minute), time.Now, berlin)
	expected, err := time.ParseInLocation("2006/01/02 15:04:05", overlap, berlin)
	if err != nil {
		t.Fatal(err)
	}
	if !got.TimeKnown || !got.Time.Equal(expected.UTC()) {
		t.Fatalf("DST overlap: got %v, want %v", got.Time, expected.UTC())
	}
}

func TestDiagnostics_CrashOrderAcrossFiles(t *testing.T) {
	early := "2026/11/04 08:00:00 x\n" + strings.Replace(goTrace, "(*Syncer).run", "early", 1)
	late := "2026/11/04 10:00:00 x\n" + strings.Replace(goTrace, "(*Syncer).run", "late", 1)
	got := scanUTC(crashFiles(t, early, late, ""))
	if got.Count != 2 || got.Place != "watchtower/internal/sync.late" {
		t.Fatalf("newest by time: got %+v", got)
	}

	// Unknown times: watchtower.log over .1 over daemon.log.
	a := strings.Replace(goTrace, "(*Syncer).run", "current", 1)
	b := strings.Replace(goTrace, "(*Syncer).run", "rotated", 1)
	c := strings.Replace(goTrace, "(*Syncer).run", "daemon", 1)
	got = scanUTC(crashFiles(t, a, b, c))
	if got.Count != 3 || got.Place != "watchtower/internal/sync.current" {
		t.Fatalf("unknown times: got %+v", got)
	}
	got = scanUTC(crashFiles(t, "", b, c))
	if got.Place != "watchtower/internal/sync.rotated" {
		t.Fatalf("unknown times without watchtower.log: got %+v", got)
	}

	// Equal times: file order again.
	same := "2026/11/04 09:00:00 x\n"
	got = scanUTC(crashFiles(t, "", same+b, same+c))
	if got.Place != "watchtower/internal/sync.rotated" {
		t.Fatalf("equal times: got %+v", got)
	}

	// Two crashes in one file: the later one.
	got = scanUTC(crashFiles(t, early+late, "", ""))
	if got.Count != 2 || got.Place != "watchtower/internal/sync.late" {
		t.Fatalf("two in one file: got %+v", got)
	}
}

func TestDiagnostics_PanicDeeperThan256KB(t *testing.T) {
	var sb strings.Builder
	sb.WriteString("2026/11/04 07:00:00 start\n")
	sb.WriteString(goTrace)
	line := "2026/11/04 07:00:01 " + strings.Repeat("x", 100) + "\n"
	for sb.Len() < 5<<20 {
		sb.WriteString(line)
	}
	got := scanUTC(crashFiles(t, "", "", sb.String()))
	if got.Count != 1 || got.Stopped || got.Place != "watchtower/internal/sync.(*Syncer).run" {
		t.Fatalf("got %+v, want the crash at the start of a 5 MB file", got)
	}
}

func TestDiagnostics_CrashLongLineDoesNotStopTheFile(t *testing.T) {
	log := strings.Repeat("y", 3<<20) + "\n" + goTrace
	if got := scanUTC(crashFiles(t, log, "", "")); got.Count != 1 {
		t.Fatalf("got %+v, want the crash after a 3 MB line", got)
	}
}

func TestDiagnostics_ScanBudget(t *testing.T) {
	line := strings.Repeat("z", 999) + "\n" // 1000 bytes
	big := goTrace + strings.Repeat(line, 6000)
	start := time.Date(2026, 11, 4, 9, 0, 0, 0, time.UTC)
	clock := start
	now := func() time.Time {
		clock = clock.Add(time.Second)
		return clock
	}
	files := crashFiles(t, big, big, big)
	got := ScanCrashes(files, start.Add(2*time.Second), now, time.UTC)
	if !got.Stopped || got.ScannedMB < 1 {
		t.Fatalf("1 s per read against a 2 s budget: got %+v, want Stopped with ScannedMB", got)
	}

	// A slower clock: about 2 000 lines read before the deadline.
	clock = start
	now = func() time.Time {
		clock = clock.Add(time.Millisecond)
		return clock
	}
	got = ScanCrashes(files, start.Add(2*time.Second), now, time.UTC)
	if !got.Stopped || got.ScannedMB < 1 || got.ScannedMB > 3 || got.Count != 1 {
		t.Fatalf("got %+v, want Stopped after about 2 MB with the first crash kept", got)
	}
}

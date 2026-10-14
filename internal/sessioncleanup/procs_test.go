package sessioncleanup

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"
)

const psFixture = `  501     1   501 S    Mon Oct 12 10:00:00 2026     /bin/sleep
  502   501   501 Ss+  Fri Oct  2 09:05:01 2026     /Applications/Foo Bar.app/Contents/MacOS/Foo Bar
    1     0     0 Ss   Thu Oct  1 08:00:00 2026     /sbin/launchd

`

const lsofFixture = "p501\nfcwd\nn/private/tmp/wt one\nftxt\nn/bin/sleep\nftxt\nn/usr/lib/dyld\n" +
	"p502\nfcwd\nn/Users/example\n" +
	"p999\nftxt\nn/usr/bin/true\n"

func TestPsParse_FixtureLines(t *testing.T) {
	procs, err := parsePs([]byte(psFixture))
	if err != nil {
		t.Fatal(err)
	}
	want := []Proc{
		{PID: 501, PPID: 1, UID: 501, Start: "Mon Oct 12 10:00:00 2026", Name: "/bin/sleep"},
		{PID: 502, PPID: 501, UID: 501, Start: "Fri Oct 2 09:05:01 2026", Name: "/Applications/Foo Bar.app/Contents/MacOS/Foo Bar"},
		{PID: 1, PPID: 0, UID: 0, Start: "Thu Oct 1 08:00:00 2026", Name: "/sbin/launchd"},
	}
	got := make([]Proc, len(procs))
	for i, r := range procs {
		got[i] = r.Proc
		if r.zombie {
			t.Errorf("pid %d parsed as a zombie", r.PID)
		}
	}
	if !slices.Equal(got, want) {
		t.Fatalf("parsePs = %+v, want %+v", got, want)
	}
	if rows, err := parsePs([]byte("503 1 501 Z+ Mon Oct 12 10:00:00 2026 (clang)\n")); err != nil || len(rows) != 1 || !rows[0].zombie {
		t.Fatalf("zombie line = %+v, %v; want one zombie row", rows, err)
	}
	for _, bad := range []string{
		"501 1 501 S Mon Oct 12 10:00:00",              // short
		"x 1 501 S Mon Oct 12 10:00:00 2026 /bin/ls",   // pid not a number
		"501 1 501 S 12 Oct Mon 10:00:00 2026 /bin/ls", // locale-shaped start time
		"501 1 501 Mon Oct 12 10:00:00 2026 /bin/ls",   // no stat column
	} {
		if _, err := parsePs([]byte(bad + "\n")); err == nil {
			t.Errorf("parsePs(%q) = nil error, want a failure (fail closed)", bad)
		}
	}
}

func TestLsofParse_FixtureLines(t *testing.T) {
	files, err := parseLsof([]byte(lsofFixture))
	if err != nil {
		t.Fatal(err)
	}
	want := map[int]procFiles{
		501: {cwd: "/private/tmp/wt one", exe: "/bin/sleep"},
		502: {cwd: "/Users/example"},
		999: {exe: "/usr/bin/true"},
	}
	if len(files) != len(want) {
		t.Fatalf("parseLsof = %+v, want %+v", files, want)
	}
	for pid, f := range want {
		if files[pid] != f {
			t.Errorf("pid %d = %+v, want %+v", pid, files[pid], f)
		}
	}
	for _, bad := range []string{
		"pabc\nfcwd\nn/tmp\n", // pid not a number
		"p0\nfcwd\nn/tmp\n",   // no such pid
		"fcwd\nn/tmp\n",       // a file before any process
		"p501\nk12\n",         // a field lsof was not asked for
	} {
		if files, err := parseLsof([]byte(bad)); err == nil {
			t.Errorf("parseLsof(%q) = %+v, nil error; want a failure (fail closed)", bad, files)
		}
	}
}

func TestLsofParse_DecodesEscapedNames(t *testing.T) {
	for raw, want := range map[string]string{
		`/tmp/acme/\xd0\xbf\xd1\x80\xd0\xbe\xd0\xb5\xd0\xba\xd1\x82/wt`: "/tmp/acme/проект/wt",
		"/tmp/acme/проект/wt":                                           "/tmp/acme/проект/wt", // a UTF-8 locale prints it as is
		`/tmp/a\tb`:                                                     "/tmp/a\tb",
		`/tmp/a^Ib`:                                                     "", // caret notation is ambiguous: unknown
		`/tmp/a\qb`:                                                     "", // unknown escape: unknown
		`/tmp/a\x4`:                                                     "", // truncated escape: unknown
	} {
		files, err := parseLsof([]byte("p501\nfcwd\nn" + raw + "\n"))
		if err != nil {
			t.Fatal(err)
		}
		if got := files[501].cwd; got != want {
			t.Errorf("cwd of %q = %q, want %q", raw, got, want)
		}
	}
	root := "/tmp/acme/проект"
	procs := []Proc{{PID: 501, PPID: 1, UID: os.Getuid(), Start: "x", Exe: root + "/wt/.build/stub",
		Cwd: decodeLsofName(`/tmp/acme/\xd0\xbf\xd1\x80\xd0\xbe\xd0\xb5\xd0\xba\xd1\x82/wt`)}}
	if orphans, _ := OrphansIn(procs, []string{root + "/wt"}, 0); len(orphans) != 1 {
		t.Fatalf("a decoded non-ASCII cwd did not match its worktree: %+v", orphans)
	}
}

// fakeCmds answers ps/lsof runs from canned output and records them.
type fakeCmds struct {
	out   map[string]string // binary -> stdout
	fail  map[string]error  // binary -> error
	calls [][]string
}

func (f *fakeCmds) run(_ context.Context, bin string, args ...string) ([]byte, error) {
	f.calls = append(f.calls, append([]string{bin}, args...))
	if err := f.fail[bin]; err != nil {
		return nil, err
	}
	return []byte(f.out[bin]), nil
}

func TestScan_MergesPsAndLsof(t *testing.T) {
	cmds := &fakeCmds{out: map[string]string{psBinary: psFixture, lsofBinary: lsofFixture}}
	procs, err := SystemProcs{run: cmds.run}.Scan(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(procs) != 3 || procs[0].Cwd != "/private/tmp/wt one" || procs[0].Exe != "/bin/sleep" {
		t.Fatalf("Scan = %+v", procs)
	}
	if procs[1].Exe != "" || procs[2].Cwd != "" || procs[2].Exe != "" {
		t.Fatalf("unreported files must stay unknown: %+v", procs)
	}
	lsof := cmds.calls[1]
	wantTail := []string{"-u", fmt.Sprint(os.Getuid())}
	if lsof[0] != "/usr/sbin/lsof" || !slices.Equal(lsof[len(lsof)-2:], wantTail) || !slices.Contains(lsof, "cwd,txt") {
		t.Fatalf("lsof run = %q", lsof)
	}
	if cmds.calls[0][0] != "/bin/ps" {
		t.Fatalf("ps run = %q, want the fixed path", cmds.calls[0])
	}
}

func TestScan_AnyToolFailureIsAnError(t *testing.T) {
	for _, bin := range []string{psBinary, lsofBinary} {
		cmds := &fakeCmds{out: map[string]string{psBinary: psFixture, lsofBinary: lsofFixture},
			fail: map[string]error{bin: errors.New("exit status 1")}}
		if procs, err := (SystemProcs{run: cmds.run}).Scan(context.Background()); err == nil {
			t.Errorf("%s failing: Scan = %+v, nil error; want an error so the plan keeps everything", bin, procs)
		}
	}
}

// unknownCmds answers the full ps with all, lsof with lsof, and the
// re-check ps (`-o ... -p <pids>`) with recheck (or recheckErr).
type unknownCmds struct {
	all, lsof, recheck string
	recheckErr         error
	rechecked          []string // the -p lists the re-check asked for
}

func (u *unknownCmds) run(_ context.Context, bin string, args ...string) ([]byte, error) {
	switch {
	case bin == lsofBinary:
		return []byte(u.lsof), nil
	case bin == psBinary && args[0] == "-axo":
		return []byte(u.all), nil
	case bin == psBinary && args[len(args)-2] == "-p":
		u.rechecked = append(u.rechecked, args[len(args)-1])
		return []byte(u.recheck), u.recheckErr
	}
	return nil, fmt.Errorf("unexpected run %s %q", bin, args)
}

// TestScan_UnknownCwdIsRechecked: a current-user process lsof did not
// report blocks every worktree only while it is still the same live,
// non-zombie process; one that exited or was replaced in between is
// dropped, and any doubt keeps it.
func TestScan_UnknownCwdIsRechecked(t *testing.T) {
	uid := os.Getuid()
	line := func(pid int, stat, start string) string {
		return fmt.Sprintf("%d 1 %d %s %s /bin/x\n", pid, uid, stat, start)
	}
	t0, t1 := "Mon Oct 12 10:00:00 2026", "Mon Oct 12 10:00:05 2026"
	all := line(601, "S", t0) + line(602, "S", t0) + line(603, "S", t0) + line(604, "S", t0) + line(605, "Z", t0)
	esrch := func(pid int, sig syscall.Signal) error {
		if sig != 0 {
			t.Errorf("signal %d sent to %d during a scan", sig, pid)
		}
		if pid == 602 {
			return syscall.ESRCH
		}
		return nil
	}
	// 601 alive and the same; 602 gone per kill; 603 gone per ps; 604 pid
	// reused (new start); 605 a zombie in the first scan.
	cmds := &unknownCmds{all: all, recheck: line(601, "S", t0) + line(604, "S", t1)}
	procs, err := SystemProcs{run: cmds.run, kill: esrch}.Scan(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if got := pids(procs); !slices.Equal(got, []int{601}) {
		t.Fatalf("Scan kept %v, want only the live unknown 601", got)
	}
	if !slices.Equal(cmds.rechecked, []string{"601,603,604"}) {
		t.Fatalf("re-check asked for %q, want the unknowns kill did not rule out", cmds.rechecked)
	}
	if _, blockers := OrphansIn(procs, []string{"/private/tmp/acme/wt"}, 0); len(blockers) != 1 {
		t.Fatalf("a live unknown process must still block every worktree: %+v", blockers)
	}

	// A zombie in the re-check is gone too.
	cmds = &unknownCmds{all: line(601, "S", t0), recheck: line(601, "Z", t0)}
	if procs, err = (SystemProcs{run: cmds.run, kill: esrch}).Scan(context.Background()); err != nil || len(procs) != 0 {
		t.Fatalf("a process that became a zombie: Scan = %+v, %v; want it dropped", procs, err)
	}
}

func TestScan_UnknownRecheckDoubtKeepsTheProcess(t *testing.T) {
	uid := os.Getuid()
	all := fmt.Sprintf("601 1 %d S Mon Oct 12 10:00:00 2026 /bin/x\n", uid)
	alive := func(int, syscall.Signal) error { return nil }
	for name, s := range map[string]SystemProcs{
		"ps fails":     {run: (&unknownCmds{all: all, recheckErr: errors.New("exit status 1")}).run, kill: alive},
		"ps malformed": {run: (&unknownCmds{all: all, recheck: "garbage\n"}).run, kill: alive},
		"kill EPERM": {run: (&unknownCmds{all: all, recheckErr: errors.New("exit status 1")}).run,
			kill: func(int, syscall.Signal) error { return syscall.EPERM }},
	} {
		procs, err := s.Scan(context.Background())
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if got := pids(procs); !slices.Equal(got, []int{601}) {
			t.Errorf("%s: Scan kept %v, want 601 kept as unknown (fail closed)", name, got)
		}
	}
}

func TestProj18_OnlyOrphansAreSignalled(t *testing.T) {
	root := "/private/tmp/acme/wt"
	uid := os.Getuid()
	start := "Mon Oct 12 10:00:00 2026"
	orphan := Proc{PID: 501, PPID: 1, UID: uid, Start: start, Exe: root + "/.build/debug/stub", Cwd: root + "/sub"}
	builtExe := Proc{PID: 502, PPID: 1, UID: uid, Start: start, Exe: root + "/.build/debug/server", Cwd: "/"}
	never := []Proc{
		{PID: 601, PPID: 77, UID: uid, Start: start, Exe: "/bin/sleep", Cwd: root},               // has a parent
		{PID: 602, PPID: 1, UID: uid + 1, Start: start, Exe: "/bin/sleep", Cwd: root},            // another user
		{PID: 603, PPID: 1, UID: uid, Start: start, Exe: "/usr/local/bin/watchtower", Cwd: root}, // Watchtower CLI
		{PID: 604, PPID: 1, UID: uid, Start: start, Exe: "/Applications/Watchtower.app/Contents/MacOS/W", Cwd: root},
		{PID: 605, PPID: 1, UID: uid, Start: start, Exe: "/opt/bin/claude", Cwd: root},
		{PID: 606, PPID: 1, UID: uid, Start: start, Exe: "/home/x/.local/share/claude/versions/2.1.296", Cwd: root},
		{PID: 607, PPID: 1, UID: uid, Start: start, Exe: "/opt/bin/codex", Cwd: root},
		{PID: 608, PPID: 1, UID: uid, Start: start, Exe: "", Cwd: root},                               // executable unknown
		{PID: 609, PPID: 1, UID: uid, Start: start, Exe: "/bin/sleep", Cwd: "/private/tmp/acme/wt2"},  // outside
		{PID: 610, PPID: 1, UID: uid, Start: start, Exe: "/bin/sleep", Cwd: ""},                       // cwd unknown: may be inside
		{PID: 611, PPID: 1, UID: uid + 1, Start: start, Exe: "/bin/sleep", Cwd: ""},                   // another user's, unknown
		{PID: 612, PPID: 1, UID: uid, Start: start, Exe: "/usr/local/bin/node", Cwd: root},            // npm-installed codex
		{PID: 613, PPID: 1, UID: uid, Start: start, Exe: "/opt/homebrew/bin/tmux", Cwd: root},         // tmux server
		{PID: 614, PPID: 1, UID: uid, Start: start, Exe: "/bin/zsh", Cwd: root + "/sub"},              // a shell
		{PID: 615, PPID: 1, UID: uid, Start: start, Exe: "/bin/sleep", Cwd: root},                     // a system tool
		{PID: 616, PPID: 1, UID: uid, Start: start, Exe: root + "/.build/debug/stub", Cwd: ""},        // built inside, cwd unknown
		{PID: os.Getpid(), PPID: 1, UID: uid, Start: start, Exe: root + "/.build/debug/x", Cwd: root}, // self
	}
	all := append([]Proc{orphan, builtExe}, never...)
	orphans, blockers := OrphansIn(all, []string{root}, os.Getpid())
	if got := pids(orphans); !slices.Equal(got, []int{501, 502}) {
		t.Fatalf("orphans = %v, want [501 502]", got)
	}
	if got := pids(blockers); !slices.Equal(got, []int{601, 602, 603, 604, 605, 606, 607, 608, 610, 612, 613, 614, 615, 616, os.Getpid()}) {
		t.Fatalf("blockers = %v", got)
	}
	// An unknown cwd blocks every worktree, wherever it is.
	if _, b := OrphansIn(all, []string{"/elsewhere/wt"}, os.Getpid()); !slices.Equal(pids(b), []int{610, 616}) {
		t.Fatalf("blockers of an unrelated worktree = %v, want the unknown-cwd processes [610 616]", pids(b))
	}

	var killed []int
	ps := map[int]Proc{}
	for _, p := range all {
		ps[p.PID] = p
	}
	s := SystemProcs{run: psFor(ps), kill: func(pid int, sig syscall.Signal) error {
		if sig != syscall.SIGTERM {
			t.Errorf("signal %v, want SIGTERM only", sig)
		}
		killed = append(killed, pid)
		return nil
	}}
	for _, p := range orphans {
		if err := s.Terminate(p); err != nil {
			t.Fatalf("Terminate(%d): %v", p.PID, err)
		}
	}
	if !slices.Equal(killed, []int{501, 502}) {
		t.Fatalf("signalled %v, want only the orphans", killed)
	}
}

func TestTerminate_ReusedPidIsNotSignalled(t *testing.T) {
	p := Proc{PID: 501, PPID: 1, UID: os.Getuid(), Start: "Mon Oct 12 10:00:00 2026", Exe: "/bin/sleep"}
	for name, now := range map[string]Proc{
		"start differs": {PID: 501, PPID: 1, UID: p.UID, Start: "Mon Oct 12 10:00:01 2026"},
		"uid differs":   {PID: 501, PPID: 1, UID: p.UID + 1, Start: p.Start},
	} {
		killed := false
		s := SystemProcs{run: psFor(map[int]Proc{501: now}), kill: func(int, syscall.Signal) error {
			killed = true
			return nil
		}}
		if err := s.Terminate(p); !errors.Is(err, errPidReused) {
			t.Errorf("%s: Terminate = %v, want errPidReused", name, err)
		}
		if killed {
			t.Errorf("%s: a reused pid was signalled", name)
		}
	}
	gone := SystemProcs{run: psFor(nil), kill: func(int, syscall.Signal) error {
		t.Error("a gone pid was signalled")
		return nil
	}}
	if err := gone.Terminate(p); err == nil {
		t.Error("Terminate of a gone pid = nil, want an error")
	}
}

// psFor answers `ps ... -p <pid>` from procs; an unknown pid exits 1 as ps
// does.
func psFor(procs map[int]Proc) cmdRunner {
	return func(_ context.Context, bin string, args ...string) ([]byte, error) {
		var pid int
		if bin != psBinary || len(args) < 2 || args[len(args)-2] != "-p" {
			return nil, fmt.Errorf("unexpected run %s %q", bin, args)
		}
		fmt.Sscan(args[len(args)-1], &pid) //nolint:errcheck // a bad pid simply matches nothing
		p, ok := procs[pid]
		if !ok {
			return nil, errors.New("exit status 1")
		}
		return []byte(fmt.Sprintf("%d %d %d S %s /bin/sleep\n", p.PID, p.PPID, p.UID, p.Start)), nil
	}
}

func pids(procs []Proc) []int {
	out := make([]int, len(procs))
	for i, p := range procs {
		out[i] = p.PID
	}
	return out
}

// TestSystemProcs_SmokeOnARealChild is the one real run: a short sleep in a
// temp dir (never a protected folder), lsof scoped to its pid, then SIGTERM.
func TestSystemProcs_SmokeOnARealChild(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("ps/lsof flags and paths are macOS's")
	}
	dir := t.TempDir()
	cmd := exec.Command("/bin/sleep", "30")
	cmd.Dir = dir
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	waited := make(chan error, 1)
	go func() { waited <- cmd.Wait() }()
	t.Cleanup(func() {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		<-waited
	})

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	procs, err := SystemProcs{pids: []int{cmd.Process.Pid}}.Scan(ctx)
	if err != nil {
		t.Fatal(err)
	}
	i := slices.IndexFunc(procs, func(p Proc) bool { return p.PID == cmd.Process.Pid })
	if i < 0 {
		t.Fatalf("pid %d not in the scan", cmd.Process.Pid)
	}
	child := procs[i]
	wantCwd, _ := filepath.EvalSymlinks(dir)
	if child.Cwd != wantCwd || child.Exe != "/bin/sleep" || child.PPID != os.Getpid() || child.UID != os.Getuid() {
		t.Fatalf("child = %+v, want cwd %s, exe /bin/sleep", child, wantCwd)
	}
	if err := (SystemProcs{}).Terminate(child); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-waited:
		waited <- err // for the cleanup
		if !strings.Contains(fmt.Sprint(err), "terminated") {
			t.Fatalf("child ended with %v, want SIGTERM", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the child survived SIGTERM")
	}
}

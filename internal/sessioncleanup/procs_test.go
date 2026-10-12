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

const psFixture = `  501     1   501 Mon Oct 12 10:00:00 2026     /bin/sleep
  502   501   501 Fri Oct  2 09:05:01 2026     /Applications/Foo Bar.app/Contents/MacOS/Foo Bar
    1     0     0 Thu Oct  1 08:00:00 2026     /sbin/launchd

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
		{PID: 501, PPID: 1, UID: 501, Start: "Mon Oct 12 10:00:00 2026"},
		{PID: 502, PPID: 501, UID: 501, Start: "Fri Oct 2 09:05:01 2026"},
		{PID: 1, PPID: 0, UID: 0, Start: "Thu Oct 1 08:00:00 2026"},
	}
	if !slices.Equal(procs, want) {
		t.Fatalf("parsePs = %+v, want %+v", procs, want)
	}
	for _, bad := range []string{
		"501 1 501 Mon Oct 12 10:00:00",              // short
		"x 1 501 Mon Oct 12 10:00:00 2026 /bin/ls",   // pid not a number
		"501 1 501 12 Oct Mon 10:00:00 2026 /bin/ls", // locale-shaped start time
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

func TestProj16_OnlyOrphansAreSignalled(t *testing.T) {
	root := "/private/tmp/acme/wt"
	uid := os.Getuid()
	start := "Mon Oct 12 10:00:00 2026"
	orphan := Proc{PID: 501, PPID: 1, UID: uid, Start: start, Exe: "/bin/sleep", Cwd: root + "/sub"}
	builtExe := Proc{PID: 502, PPID: 1, UID: uid, Start: start, Exe: root + "/.build/debug/server", Cwd: "/"}
	never := []Proc{
		{PID: 601, PPID: 77, UID: uid, Start: start, Exe: "/bin/sleep", Cwd: root},               // has a parent
		{PID: 602, PPID: 1, UID: uid + 1, Start: start, Exe: "/bin/sleep", Cwd: root},            // another user
		{PID: 603, PPID: 1, UID: uid, Start: start, Exe: "/usr/local/bin/watchtower", Cwd: root}, // Watchtower CLI
		{PID: 604, PPID: 1, UID: uid, Start: start, Exe: "/Applications/Watchtower.app/Contents/MacOS/W", Cwd: root},
		{PID: 605, PPID: 1, UID: uid, Start: start, Exe: "/opt/bin/claude", Cwd: root},
		{PID: 606, PPID: 1, UID: uid, Start: start, Exe: "/home/x/.local/share/claude/versions/2.1.296", Cwd: root},
		{PID: 607, PPID: 1, UID: uid, Start: start, Exe: "/opt/bin/codex", Cwd: root},
		{PID: 608, PPID: 1, UID: uid, Start: start, Exe: "", Cwd: root},                              // executable unknown
		{PID: 609, PPID: 1, UID: uid, Start: start, Exe: "/bin/sleep", Cwd: "/private/tmp/acme/wt2"}, // outside
		{PID: 610, PPID: 1, UID: uid, Start: start, Exe: "/bin/sleep", Cwd: ""},                      // cwd unknown, outside
		{PID: os.Getpid(), PPID: 1, UID: uid, Start: start, Exe: "/bin/sleep", Cwd: root},            // self
	}
	all := append([]Proc{orphan, builtExe}, never...)
	orphans, blockers := OrphansIn(all, []string{root}, os.Getpid())
	if got := pids(orphans); !slices.Equal(got, []int{501, 502}) {
		t.Fatalf("orphans = %v, want [501 502]", got)
	}
	if got := pids(blockers); !slices.Equal(got, []int{601, 602, 603, 604, 605, 606, 607, 608, os.Getpid()}) {
		t.Fatalf("blockers = %v", got)
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
		return []byte(fmt.Sprintf("%d %d %d %s /bin/sleep\n", p.PID, p.PPID, p.UID, p.Start)), nil
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

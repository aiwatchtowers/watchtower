package sessioncleanup

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// psBinary and lsofBinary run at their fixed system paths, never via PATH.
const (
	psBinary   = "/bin/ps"
	lsofBinary = "/usr/sbin/lsof"
)

// errPidReused means the pid now belongs to another process (or another
// user) than the one the plan saw; nothing was signalled.
var errPidReused = errors.New("the pid now belongs to another process")

// cmdRunner runs bin with args and returns its stdout; a non-zero exit is an
// error carrying stderr.
type cmdRunner func(ctx context.Context, bin string, args ...string) ([]byte, error)

// runCommand is the real cmdRunner. ps runs in the C locale so it prints
// lstart in one fixed format; lsof keeps the caller's locale (in the C
// locale it would escape every non-ASCII byte; decodeLsofName undoes the
// escapes either way).
func runCommand(ctx context.Context, bin string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, bin, args...)
	if bin == psBinary {
		cmd.Env = append(os.Environ(), "LC_ALL=C")
	}
	cmd.WaitDelay = 2 * time.Second
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return out, fmt.Errorf("%s %s: %w: %s", bin, strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return out, nil
}

// SystemProcs is the real ProcessScanner: one `ps` for every process and one
// `lsof` for the current user's cwds and executables. The executable comes
// from lsof's first txt entry (the vnode path), never from `ps comm`, which
// is argv-based. A process lsof did not report has Exe and Cwd "" (unknown):
// an unknown executable is never an orphan and a current-user process of
// unknown cwd blocks every worktree (OrphansIn).
type SystemProcs struct {
	run  cmdRunner                               // nil = runCommand
	kill func(pid int, sig syscall.Signal) error // nil = syscall.Kill
	pids []int                                   // tests: limit lsof to these pids instead of the user
}

// Scan lists every process; any failure of ps or lsof is an error, so the
// plan keeps everything rather than missing a process.
func (s SystemProcs) Scan(ctx context.Context) ([]Proc, error) {
	run := s.runner()
	out, err := run(ctx, psBinary, "-axo", "pid=,ppid=,uid=,lstart=,comm=")
	if err != nil {
		return nil, err
	}
	procs, err := parsePs(out)
	if err != nil {
		return nil, err
	}
	out, err = run(ctx, lsofBinary, s.lsofArgs()...)
	if err != nil {
		return nil, err
	}
	files, err := parseLsof(out)
	if err != nil {
		return nil, err
	}
	for i := range procs {
		if f, ok := files[procs[i].PID]; ok {
			procs[i].Cwd, procs[i].Exe = f.cwd, f.exe
		}
	}
	return procs, nil
}

func (s SystemProcs) lsofArgs() []string {
	args := []string{"-a", "-d", "cwd,txt", "-n", "-P", "-w", "-F", "pfn"}
	if len(s.pids) == 0 {
		return append(args, "-u", strconv.Itoa(os.Getuid()))
	}
	list := make([]string, len(s.pids))
	for i, pid := range s.pids {
		list[i] = strconv.Itoa(pid)
	}
	return append(args, "-p", strings.Join(list, ","))
}

// Terminate sends SIGTERM to p after re-reading its start time and uid: a
// pid reused by another process (or gone) is never signalled.
func (s SystemProcs) Terminate(p Proc) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, err := s.runner()(ctx, psBinary, "-o", "pid=,ppid=,uid=,lstart=,comm=", "-p", strconv.Itoa(p.PID))
	if err != nil {
		return fmt.Errorf("re-reading pid %d: %w", p.PID, err)
	}
	now, err := parsePs(out)
	if err != nil {
		return err
	}
	if len(now) != 1 || now[0].PID != p.PID || now[0].Start != p.Start || now[0].UID != p.UID {
		return fmt.Errorf("pid %d: %w", p.PID, errPidReused)
	}
	kill := s.kill
	if kill == nil {
		kill = syscall.Kill
	}
	return kill(p.PID, syscall.SIGTERM)
}

func (s SystemProcs) runner() cmdRunner {
	if s.run != nil {
		return s.run
	}
	return runCommand
}

// parsePs reads `ps -o pid=,ppid=,uid=,lstart=,comm=` lines. lstart is five
// fields in the C locale ("Mon Oct 12 10:00:00 2026"); comm, the rest of the
// line, is ignored. A malformed line fails the whole parse (fail closed).
func parsePs(out []byte) ([]Proc, error) {
	var procs []Proc
	sc := bufio.NewScanner(bytes.NewReader(out))
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		p, err := parsePsLine(line)
		if err != nil {
			return nil, err
		}
		procs = append(procs, p)
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("reading ps output: %w", err)
	}
	return procs, nil
}

func parsePsLine(line string) (Proc, error) {
	f := strings.Fields(line)
	if len(f) < 8 {
		return Proc{}, fmt.Errorf("unexpected ps line %q", line)
	}
	var nums [3]int
	for i := range nums {
		n, err := strconv.Atoi(f[i])
		if err != nil {
			return Proc{}, fmt.Errorf("unexpected ps line %q", line)
		}
		nums[i] = n
	}
	start := strings.Join(f[3:8], " ")
	if _, err := time.Parse("Mon Jan 2 15:04:05 2006", start); err != nil {
		return Proc{}, fmt.Errorf("unexpected ps start time %q", start)
	}
	return Proc{PID: nums[0], PPID: nums[1], UID: nums[2], Start: start, Name: strings.Join(f[8:], " ")}, nil
}

type procFiles struct{ cwd, exe string }

// parseLsof reads `lsof -F pfn` output: a p line per process, then f/n
// pairs. The cwd entry is the cwd; the first txt entry is the executable.
// Anything unexpected — a non-numeric pid, an f or n line before any p
// line, an unknown field — fails the whole parse (fail closed).
func parseLsof(out []byte) (map[int]procFiles, error) {
	files := map[int]procFiles{}
	pid, fd := 0, ""
	sc := bufio.NewScanner(bytes.NewReader(out))
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if line == "" {
			continue
		}
		var err error
		if pid, fd, err = lsofLine(files, line, pid, fd); err != nil {
			return nil, err
		}
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("reading lsof output: %w", err)
	}
	return files, nil
}

// lsofLine applies one line to files and returns the new pid and fd.
func lsofLine(files map[int]procFiles, line string, pid int, fd string) (int, string, error) {
	val := line[1:]
	switch {
	case line[0] == 'p':
		n, err := strconv.Atoi(val)
		if err != nil || n <= 0 {
			return 0, "", fmt.Errorf("unexpected lsof line %q", line)
		}
		if _, seen := files[n]; !seen {
			files[n] = procFiles{} // listed, even with no cwd or txt entry
		}
		return n, "", nil
	case pid == 0:
		return 0, "", fmt.Errorf("unexpected lsof line %q before a process", line)
	case line[0] == 'f':
		return pid, val, nil
	case line[0] == 'n':
		recordLsofName(files, pid, fd, decodeLsofName(val))
		return pid, fd, nil
	}
	return 0, "", fmt.Errorf("unexpected lsof line %q", line)
}

func recordLsofName(files map[int]procFiles, pid int, fd, name string) {
	f := files[pid]
	switch {
	case fd == "cwd":
		f.cwd = name
	case fd == "txt" && f.exe == "":
		f.exe = name
	}
	files[pid] = f
}

// decodeLsofName undoes lsof's escaping of a name: \xNN is the byte NN and
// \b \f \n \r \t are those controls. A name with a caret (lsof's ^X
// control notation, ambiguous with a literal caret) or an unknown escape is
// "" — unknown, so the process blocks rather than being matched wrongly.
func decodeLsofName(s string) string {
	if strings.Contains(s, "^") {
		return ""
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] != '\\' {
			b.WriteByte(s[i])
			continue
		}
		c, n, ok := lsofEscape(s[i+1:])
		if !ok {
			return ""
		}
		b.WriteByte(c)
		i += n
	}
	return b.String()
}

// lsofEscape decodes the escape at the start of rest (after the backslash):
// the byte and how many characters of rest it used.
func lsofEscape(rest string) (byte, int, bool) {
	if rest == "" {
		return 0, 0, false
	}
	if c, ok := map[byte]byte{'b': '\b', 'f': '\f', 'n': '\n', 'r': '\r', 't': '\t'}[rest[0]]; ok {
		return c, 1, true
	}
	if rest[0] != 'x' || len(rest) < 3 {
		return 0, 0, false
	}
	n, err := strconv.ParseUint(rest[1:3], 16, 8)
	if err != nil {
		return 0, 0, false
	}
	return byte(n), 3, true
}

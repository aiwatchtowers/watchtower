// Command fakecli is the one fake CLI of the transport contract suite
// (internal/transporttest). The suite builds it once and installs it under
// the names `claude` and `codex`; a fixture file named by the environment
// tells it what to do.
//
// Environment:
//
//	WT_FAKECLI_FIXTURE  the fixture script (required unless --version)
//	WT_FAKECLI_LOG      one JSON line per invocation, grandchild and failure
//	                    is appended here: {"pid","pgid","argv"} /
//	                    {"grandchild"} / {"fake_error"}
//	WT_FAKECLI_VERSION  what `--version` prints (default "fakecli 0.0.0")
//	WT_FAKECLI_HANG     set: a FIFO the fake writes "hang" to when it
//	                    reaches a hang directive (the suite's deadline
//	                    passes on it, not on a clock)
//
// A fixture is a script read top to bottom. A line starting with "#!" is a
// directive, any other line starting with "#" a comment, an empty line is
// skipped, and every other line is emitted on stdout as it stands. Sections
// separated by "#! next-invocation" serve successive invocations (the n-th
// non-version invocation logged runs section n; past the last section the
// last one repeats). Directives:
//
//	emit <line>          write <line> on stdout; {{pad:N}} becomes N "x"s
//	sleep <duration>     time.ParseDuration
//	stderr <text>        write <text> and a newline on stderr
//	exit <code>          exit now with <code>
//	hang                 block until a signal ends the process
//	ignore-sigint        ignore SIGINT from here on
//	spawn-grandchild     start a child that ignores SIGINT and holds stdout
//	argv-has <text>      exit 97 unless the space-joined argv contains <text>
//	argv-lacks <text>    exit 97 if the space-joined argv contains <text>
//	stdin-has <text>     read stdin lines until one contains <text>; exit 98 at EOF
//	rollout <line>       append <line> to the run's codex rollout under
//	                     $CODEX_HOME/sessions (a codex run in its own home)
//
// Reaching the end of the section exits 0.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	envFixture    = "WT_FAKECLI_FIXTURE"
	envLog        = "WT_FAKECLI_LOG"
	envVersion    = "WT_FAKECLI_VERSION"
	envGrandchild = "WT_FAKECLI_GRANDCHILD"
	envHang       = "WT_FAKECLI_HANG"

	exitArgv    = 97
	exitStdin   = 98
	exitFixture = 96
)

var padRE = regexp.MustCompile(`\{\{pad:(\d+)\}\}`)

func main() {
	if os.Getenv(envGrandchild) != "" {
		signal.Ignore(syscall.SIGINT)
		sleepForever()
	}
	args := os.Args[1:]
	if len(args) == 1 && args[0] == "--version" {
		v := os.Getenv(envVersion)
		if v == "" {
			v = "fakecli 0.0.0"
		}
		fmt.Println(v)
		return
	}
	n := invocationIndex()
	if err := logLine(map[string]any{"pid": os.Getpid(), "pgid": pgid(), "argv": args}); err != nil {
		fail(exitFixture, "fakecli: logging the launch: %v", err)
	}
	section, err := loadSection(os.Getenv(envFixture), n)
	if err != nil {
		fail(exitFixture, "fakecli: %v", err)
	}
	run(section, args)
}

// invocationIndex counts the invocations logged before this one.
func invocationIndex() int {
	f, err := os.Open(os.Getenv(envLog))
	if err != nil {
		return 0
	}
	defer f.Close()
	n := 0
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 16<<20)
	for sc.Scan() {
		if strings.Contains(sc.Text(), `"argv"`) {
			n++
		}
	}
	return n
}

func pgid() int {
	g, err := syscall.Getpgid(os.Getpid())
	if err != nil {
		return 0
	}
	return g
}

func logLine(v map[string]any) error {
	path := os.Getenv(envLog)
	if path == "" {
		return nil
	}
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(append(b, '\n')); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

// loadSection returns the lines of the fixture's n-th section.
func loadSection(path string, n int) ([]string, error) {
	if path == "" {
		return nil, fmt.Errorf("%s is not set", envFixture)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	sections := [][]string{nil}
	for _, line := range strings.Split(string(raw), "\n") {
		if strings.TrimSpace(line) == "#! next-invocation" {
			sections = append(sections, nil)
			continue
		}
		sections[len(sections)-1] = append(sections[len(sections)-1], line)
	}
	return sections[min(n, len(sections)-1)], nil
}

func run(lines []string, argv []string) {
	joined := strings.Join(argv, " ")
	var stdin *bufio.Reader
	for _, line := range lines {
		if strings.TrimSpace(line) == "" {
			continue
		}
		if !strings.HasPrefix(line, "#") {
			emit(line)
			continue
		}
		rest, ok := strings.CutPrefix(line, "#!")
		if !ok {
			continue // a comment
		}
		name, arg, _ := strings.Cut(strings.TrimSpace(rest), " ")
		switch name {
		case "emit":
			emit(arg)
		case "sleep":
			d, err := time.ParseDuration(arg)
			if err != nil {
				fail(exitFixture, "fakecli: sleep %q: %v", arg, err)
			}
			time.Sleep(d)
		case "stderr":
			fmt.Fprintln(os.Stderr, arg)
		case "exit":
			code, err := strconv.Atoi(arg)
			if err != nil {
				fail(exitFixture, "fakecli: exit %q: %v", arg, err)
			}
			os.Exit(code)
		case "hang":
			if p := os.Getenv(envHang); p != "" {
				if err := os.WriteFile(p, []byte("hang\n"), 0o600); err != nil {
					fail(exitFixture, "fakecli: announcing the hang: %v", err)
				}
			}
			sleepForever()
		case "ignore-sigint":
			signal.Ignore(syscall.SIGINT)
		case "spawn-grandchild":
			spawnGrandchild()
		case "argv-has":
			if !strings.Contains(joined, arg) {
				fail(exitArgv, "fakecli: argv lacks %q", arg)
			}
		case "argv-lacks":
			if strings.Contains(joined, arg) {
				fail(exitArgv, "fakecli: argv has %q", arg)
			}
		case "rollout":
			appendRollout(arg)
		case "stdin-has":
			if stdin == nil {
				stdin = bufio.NewReaderSize(os.Stdin, 1<<20)
			}
			waitStdin(stdin, arg)
		default:
			fail(exitFixture, "fakecli: unknown directive %q", name)
		}
	}
}

func emit(line string) {
	line = padRE.ReplaceAllStringFunc(line, func(m string) string {
		n, _ := strconv.Atoi(padRE.FindStringSubmatch(m)[1])
		return strings.Repeat("x", n)
	})
	_, _ = os.Stdout.WriteString(line + "\n")
}

// appendRollout appends line to the one rollout file of the run's
// CODEX_HOME, as codex writes it while a non-ephemeral run goes on.
func appendRollout(line string) {
	home := os.Getenv("CODEX_HOME")
	if home == "" {
		fail(exitFixture, "fakecli: rollout: CODEX_HOME is not set")
	}
	dir := filepath.Join(home, "sessions", "2026", "01", "01")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		fail(exitFixture, "fakecli: rollout: %v", err)
	}
	f, err := os.OpenFile(filepath.Join(dir, "rollout-2026-01-01T00-00-00-fake.jsonl"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		fail(exitFixture, "fakecli: rollout: %v", err)
	}
	if _, err := f.WriteString(line + "\n"); err != nil {
		fail(exitFixture, "fakecli: rollout: %v", err)
	}
	if err := f.Close(); err != nil {
		fail(exitFixture, "fakecli: rollout: %v", err)
	}
}

func waitStdin(r *bufio.Reader, want string) {
	for {
		line, err := r.ReadString('\n')
		if strings.Contains(line, want) {
			return
		}
		if err != nil {
			fail(exitStdin, "fakecli: stdin ended without %q", want)
		}
	}
}

func spawnGrandchild() {
	self, err := os.Executable()
	if err != nil {
		fail(exitFixture, "fakecli: %v", err)
	}
	c := exec.Command(self)
	c.Env = append(os.Environ(), envGrandchild+"=1")
	c.Stdout = os.Stdout // holds the parent's stdout open
	c.Stderr = os.Stderr
	if err := c.Start(); err != nil {
		fail(exitFixture, "fakecli: grandchild: %v", err)
	}
	if err := logLine(map[string]any{"grandchild": c.Process.Pid}); err != nil {
		fail(exitFixture, "fakecli: logging the grandchild: %v", err)
	}
}

func sleepForever() {
	for {
		time.Sleep(time.Hour)
	}
}

// fail reports what the fake rejected on stderr and in the log (the suite
// reads it back, so a rejected input is never mistaken for the
// transport's own failure), then exits with code.
func fail(code int, format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	fmt.Fprintln(os.Stderr, msg)
	_ = logLine(map[string]any{"fake_error": msg}) // already failing: stderr has it
	os.Exit(code)
}

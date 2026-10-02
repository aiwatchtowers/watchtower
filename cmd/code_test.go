package cmd

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// runCLIEnv makes the test binary run as the real CLI (see TestMain).
const runCLIEnv = "WATCHTOWER_TEST_RUN_CLI"

func writeCodeFile(t *testing.T, root, rel, data string) {
	t.Helper()
	p := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
}

// decodeLines decodes a JSON-lines stream.
func decodeLines(t *testing.T, out string) []map[string]any {
	t.Helper()
	var lines []map[string]any
	for line := range strings.SplitSeq(strings.TrimSuffix(out, "\n"), "\n") {
		if line == "" {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			t.Fatalf("line %q: %v", line, err)
		}
		lines = append(lines, m)
	}
	return lines
}

func TestCodeIndex_JSONStreamsEveryFileThenDone(t *testing.T) {
	root := t.TempDir()
	writeCodeFile(t, root, "main.go", "package main\n\n// Run runs.\nfunc Run() {}\n")
	writeCodeFile(t, root, "notes.txt", "plain\n")
	var out bytes.Buffer
	if err := codeIndex(context.Background(), codeIndexOptions{folder: root}, nil, &out); err != nil {
		t.Fatalf("codeIndex: %v", err)
	}
	lines := decodeLines(t, out.String())
	if len(lines) != 3 {
		t.Fatalf("%d lines, want 2 files + done:\n%s", len(lines), out.String())
	}
	files := map[any]map[string]any{}
	for _, l := range lines[:2] {
		files[l["file"]] = l
	}
	if l := files["notes.txt"]; l["lang"] != "" || len(l["symbols"].([]any)) != 0 {
		t.Errorf("notes.txt = %v, want lang \"\" and no symbols", l)
	}
	if done := lines[2]; done["done"] != true || done["files"] != 2.0 || done["symbols"] != float64(len(files["main.go"]["symbols"].([]any))) {
		t.Errorf("done = %v", done)
	}
	if _, ok := lines[2]["ms"]; !ok {
		t.Error("done line has no ms")
	}
}

func TestCodeIndex_FilesDeletedAndUnsupported(t *testing.T) {
	root := t.TempDir()
	writeCodeFile(t, root, "notes.txt", "plain\n")
	var out bytes.Buffer
	o := codeIndexOptions{folder: root, paths: []string{"gone.go", "notes.txt"}}
	if err := codeIndex(context.Background(), o, nil, &out); err != nil {
		t.Fatalf("codeIndex: %v", err)
	}
	got := map[string]string{}
	for line := range strings.SplitSeq(strings.TrimSpace(out.String()), "\n") {
		var m map[string]any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			t.Fatal(err)
		}
		if f, ok := m["file"].(string); ok {
			got[f] = line
		}
	}
	if got["gone.go"] != `{"file":"gone.go","deleted":true}` {
		t.Errorf("gone.go line = %s", got["gone.go"])
	}
	if got["notes.txt"] != `{"file":"notes.txt","lang":"","symbols":[]}` {
		t.Errorf("notes.txt line = %s", got["notes.txt"])
	}
}

// cliProcess is the test binary running `watchtower args…` in its own
// process group, which t.Cleanup kills and reaps whatever the test did.
type cliProcess struct {
	cmd   *exec.Cmd
	stdin io.WriteCloser
	lines chan string
	wait  func() error
}

func startCLI(t *testing.T, args ...string) *cliProcess {
	t.Helper()
	c := exec.Command(os.Args[0], args...)
	c.Env = append(os.Environ(), runCLIEnv+"=1")
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	c.Stderr = os.Stderr
	stdin, err := c.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := c.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	p := &cliProcess{cmd: c, stdin: stdin, lines: make(chan string, 1<<14)}
	scanned := make(chan struct{})
	go func() {
		defer close(scanned)
		defer close(p.lines)
		sc := bufio.NewScanner(stdout)
		sc.Buffer(make([]byte, 0, 64<<10), 16<<20)
		for sc.Scan() {
			p.lines <- sc.Text()
		}
	}()
	// Wait only after stdout is drained (exec.Cmd's rule for StdoutPipe).
	p.wait = sync.OnceValue(func() error {
		<-scanned
		return c.Wait()
	})
	t.Cleanup(func() {
		_ = syscall.Kill(-c.Process.Pid, syscall.SIGKILL) // the whole group; ESRCH once it exited
		_ = stdin.Close()
		_ = p.wait()
	})
	return p
}

// next is the process's next stdout line, failing after timeout.
func (p *cliProcess) next(t *testing.T, timeout time.Duration) (string, bool) {
	t.Helper()
	select {
	case line, ok := <-p.lines:
		return line, ok
	case <-time.After(timeout):
		t.Fatalf("no output line within %v", timeout)
		return "", false
	}
}

// untilDone reads one run's lines up to and including its done line.
func (p *cliProcess) untilDone(t *testing.T) []string {
	t.Helper()
	var run []string
	for {
		line, ok := p.next(t, 10*time.Second)
		if !ok {
			t.Fatalf("stdout closed before a done line; got %v", run)
		}
		run = append(run, line)
		if strings.HasPrefix(line, `{"done":true`) {
			return run
		}
	}
}

func exitCode(err error) int {
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode()
	}
	if err != nil {
		return -1
	}
	return 0
}

func TestCodeIndex_ServeOneRunPerLineAndEOFExitsZero(t *testing.T) {
	root := t.TempDir()
	writeCodeFile(t, root, "a.go", "package a\n\nfunc A() {}\n")
	writeCodeFile(t, root, "b.md", "# B\n")
	p := startCLI(t, "code", "index", "--folder", root, "--serve")

	if _, err := io.WriteString(p.stdin, "a.go\n\n"); err != nil {
		t.Fatal(err)
	}
	first := p.untilDone(t)
	if _, err := io.WriteString(p.stdin, "b.md\tgone.go\n"); err != nil {
		t.Fatal(err)
	}
	second := p.untilDone(t)
	if len(first) != 2 || !strings.Contains(first[0], `"file":"a.go"`) || !strings.Contains(first[0], `"name":"A"`) {
		t.Errorf("run 1 = %v", first)
	}
	if len(second) != 3 || !strings.Contains(strings.Join(second, "\n"), `{"file":"gone.go","deleted":true}`) {
		t.Errorf("run 2 = %v", second)
	}

	if err := p.stdin.Close(); err != nil {
		t.Fatal(err)
	}
	if code := exitCode(p.wait()); code != 0 {
		t.Fatalf("exit code after EOF = %d, want 0", code)
	}
}

func TestCodeIndex_SIGTERMDuringARunExitsAtOnceWithNoDone(t *testing.T) {
	root := t.TempDir()
	var paths []string
	for i := range 3000 {
		rel := fmt.Sprintf("pkg%d/f%d.go", i%30, i)
		writeCodeFile(t, root, rel, fmt.Sprintf("package p\n\n// F%d is one.\nfunc F%d() int { return %d }\n", i, i, i))
		paths = append(paths, rel)
	}
	p := startCLI(t, "code", "index", "--folder", root, "--serve")
	if _, err := io.WriteString(p.stdin, strings.Join(paths, "\t")+"\n"); err != nil {
		t.Fatal(err)
	}
	if line, _ := p.next(t, 10*time.Second); !strings.HasPrefix(line, `{"file":`) {
		t.Fatalf("first line = %q, want a file line", line)
	}

	sent := time.Now()
	if err := p.cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	err := p.wait()
	elapsed := time.Since(sent)
	if code := exitCode(err); code != 0 {
		t.Fatalf("exit code after SIGTERM = %d (%v), want 0", code, err)
	}
	if elapsed > 50*time.Millisecond {
		t.Errorf("exited %v after SIGTERM, want ≤ 50ms", elapsed)
	}
	n := 1
	for line := range p.lines {
		n++
		if strings.Contains(line, `"done"`) {
			t.Fatalf("a done line after SIGTERM: %s", line)
		}
	}
	if n >= len(paths) {
		t.Errorf("all %d files were emitted: SIGTERM did not stop the run", n)
	}
}

func TestCodeIndex_UsageErrorsExitTwo(t *testing.T) {
	root := t.TempDir()
	notDir := filepath.Join(root, "file.txt")
	writeCodeFile(t, root, "file.txt", "x\n")
	for name, args := range map[string][]string{
		"no folder":          {"code", "index", "--json"},
		"missing folder":     {"code", "index", "--folder", filepath.Join(root, "missing"), "--json"},
		"folder is a file":   {"code", "index", "--folder", notDir, "--json"},
		"no output format":   {"code", "index", "--folder", root},
		"files without one":  {"code", "index", "--folder", root, "--json", "--files"},
		"args without files": {"code", "index", "--folder", root, "--json", "a.go"},
		"serve with files":   {"code", "index", "--folder", root, "--serve", "--files", "a.go"},
		"unknown flag":       {"code", "index", "--folder", root, "--json", "--nope"},
	} {
		t.Run(name, func(t *testing.T) {
			p := startCLI(t, args...)
			_ = p.stdin.Close()
			if code := exitCode(p.wait()); code != 2 {
				t.Fatalf("exit code = %d, want 2", code)
			}
		})
	}
}

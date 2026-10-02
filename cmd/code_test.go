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
	"slices"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"watchtower/internal/codesearch"
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
	// stderr is a copy of the process's stderr; read it only after wait.
	stderr bytes.Buffer
}

func startCLI(t *testing.T, args ...string) *cliProcess {
	t.Helper()
	c := exec.Command(os.Args[0], args...)
	// GORACE: a -race binary otherwise sleeps 1 s at exit, which the
	// SIGTERM timing tests would measure.
	c.Env = append(os.Environ(), runCLIEnv+"=1", "GORACE=atexit_sleep_ms=0")
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	p := &cliProcess{cmd: c, lines: make(chan string, 1<<14)}
	c.Stderr = io.MultiWriter(os.Stderr, &p.stderr)
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
	p.stdin = stdin
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

// A server idle on stdin between runs also stops at once on SIGTERM.
func TestCodeIndex_SIGTERMWhileIdleExitsAtOnce(t *testing.T) {
	root := t.TempDir()
	writeCodeFile(t, root, "a.md", "# A\n")
	p := startCLI(t, "code", "index", "--folder", root, "--serve")
	if _, err := io.WriteString(p.stdin, "a.md\n"); err != nil {
		t.Fatal(err)
	}
	p.untilDone(t)

	sent := time.Now()
	if err := p.cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- p.wait() }()
	select {
	case err := <-done:
		if code := exitCode(err); code != 0 {
			t.Fatalf("exit code = %d, want 0", code)
		}
		if elapsed := time.Since(sent); elapsed > 50*time.Millisecond {
			t.Errorf("exited %v after SIGTERM, want ≤ 50ms", elapsed)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("still running 5s after SIGTERM (blocked on stdin)")
	}
}

func TestCodeSearch_StreamsMatchesThenDone(t *testing.T) {
	root := t.TempDir()
	writeCodeFile(t, root, "a.go", "package a\n\nfunc saveNow() {}\n")
	writeCodeFile(t, root, "b.txt", "nothing here\n")
	var out bytes.Buffer
	opt := codesearch.Options{Query: "savenow", Max: 2000, Context: 2}
	if err := codeSearch(context.Background(), root, opt, &out); err != nil {
		t.Fatalf("codeSearch: %v", err)
	}
	lines := strings.Split(strings.TrimSuffix(out.String(), "\n"), "\n")
	want := []string{
		`{"path":"a.go","line":3,"col":6,"text":"func saveNow() {}","before":["package a",""],"after":[]}`,
		`{"done":true,"files":1,"matches":1,"truncated":false}`,
	}
	if !slices.Equal(lines, want) {
		t.Fatalf("output:\n%s\nwant:\n%s", out.String(), strings.Join(want, "\n"))
	}

	out.Reset()
	if err := codeSearch(context.Background(), root, codesearch.Options{Query: "absent", Max: 10}, &out); err != nil {
		t.Fatalf("codeSearch(no match): %v", err)
	}
	if got := out.String(); got != `{"done":true,"files":0,"matches":0,"truncated":false}`+"\n" {
		t.Fatalf("no-match output = %q", got)
	}
}

func TestCodeSearch_MaxTruncates(t *testing.T) {
	root := t.TempDir()
	writeCodeFile(t, root, "a.txt", strings.Repeat("hit\n", 20))
	p := startCLI(t, "code", "search", "--folder", root, "--query", "hit", "--max", "5", "--json")
	_ = p.stdin.Close()
	run := p.untilDone(t)
	if len(run) != 6 || run[5] != `{"done":true,"files":1,"matches":5,"truncated":true}` {
		t.Fatalf("run = %v", run)
	}
	if code := exitCode(p.wait()); code != 0 {
		t.Fatalf("exit code = %d, want 0", code)
	}
}

func TestCodeSearch_InvalidRegexExitsTwoWithAMessage(t *testing.T) {
	root := t.TempDir()
	p := startCLI(t, "code", "search", "--folder", root, "--query", "(", "--regex")
	_ = p.stdin.Close()
	if code := exitCode(p.wait()); code != 2 {
		t.Fatalf("exit code = %d, want 2", code)
	}
	if msg := p.stderr.String(); !strings.Contains(msg, "invalid query") || !strings.Contains(msg, "missing closing )") {
		t.Fatalf("stderr = %q, want the regexp error", msg)
	}
}

func TestCodeSearch_UsageErrorsExitTwo(t *testing.T) {
	root := t.TempDir()
	writeCodeFile(t, root, "file.txt", "x\n")
	for name, args := range map[string][]string{
		"no folder":        {"--query", "x"},
		"missing folder":   {"--folder", filepath.Join(root, "missing"), "--query", "x"},
		"folder is a file": {"--folder", filepath.Join(root, "file.txt"), "--query", "x"},
		"no query":         {"--folder", root},
		"zero max":         {"--folder", root, "--query", "x", "--max", "0"},
		"negative context": {"--folder", root, "--query", "x", "--context", "-1"},
		"stray argument":   {"--folder", root, "--query", "x", "extra"},
		"unknown flag":     {"--folder", root, "--query", "x", "--nope"},
	} {
		t.Run(name, func(t *testing.T) {
			p := startCLI(t, append([]string{"code", "search"}, args...)...)
			_ = p.stdin.Close()
			if code := exitCode(p.wait()); code != 2 {
				t.Fatalf("exit code = %d, want 2", code)
			}
		})
	}
}

func TestCodeSearch_SIGTERMMidRunExitsAtOnceWithNoDone(t *testing.T) {
	root := t.TempDir()
	body := strings.Repeat("hit1 hit2 hit3 hit4\n", 200)
	const files = 1500
	for i := range files {
		writeCodeFile(t, root, fmt.Sprintf("d%d/f%d.txt", i%30, i), body)
	}
	p := startCLI(t, "code", "search", "--folder", root, "--query", "hit", "--max", "100000000", "--context", "0")
	_ = p.stdin.Close()
	if line, _ := p.next(t, 10*time.Second); !strings.HasPrefix(line, `{"path":`) {
		t.Fatalf("first line = %q, want a match line", line)
	}
	// Drain stdout while the process exits, so a full pipe cannot block it.
	type drained struct {
		n    int
		done bool
	}
	rest := make(chan drained, 1)
	go func() {
		var d drained
		for line := range p.lines {
			d.n++
			d.done = d.done || strings.Contains(line, `"done"`)
		}
		rest <- d
	}()

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
	d := <-rest
	if d.done {
		t.Fatal("a done line after SIGTERM")
	}
	if total := files * 800; d.n+1 >= total {
		t.Errorf("all %d matches were emitted: SIGTERM did not stop the run", total)
	}
}

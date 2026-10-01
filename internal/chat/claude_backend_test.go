package chat

import (
	"context"
	"encoding/base64"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

type fakeFiles struct{ argv, stdin, pid, childPID, mark, cwd, workDir string }

// fakeClaude installs testdata/fake_claude.sh as an executable `claude` and
// returns backend options pointing at it. It also registers a t.Cleanup
// (assertNoProcessSurvives) so every test built on it is checked, after its
// own teardown has run, for a leaked stub process — the class of bug where a
// test bails out (assertion failure, t.Fatal) before it reaches its manual
// Close() call and the stub, parked in its own process group, is reparented
// to PID 1 and never reaped.
func fakeClaude(t *testing.T, mode string) (ClaudeOptions, fakeFiles) {
	t.Helper()
	dir := t.TempDir()
	assertNoProcessSurvives(t, dir)
	script, err := os.ReadFile(filepath.Join("testdata", "fake_claude.sh"))
	require.NoError(t, err)
	bin := filepath.Join(dir, "claude")
	require.NoError(t, os.WriteFile(bin, script, 0o755))
	f := fakeFiles{
		argv: filepath.Join(dir, "argv"), stdin: filepath.Join(dir, "stdin"),
		pid: filepath.Join(dir, "pid"), childPID: filepath.Join(dir, "child"), mark: filepath.Join(dir, "mark"),
		cwd: filepath.Join(dir, "cwd"), workDir: filepath.Join(dir, "workdir"),
	}
	return ClaudeOptions{
		Binary: bin, Model: "fake-model", SystemPrompt: "SYSTEM-PROMPT-SECRET",
		MCPConfig: `{"mcpServers":{}}`, AllowedTools: "mcp__watchtower", DisallowedTools: "Bash",
		WorkDir: f.workDir,
		Env: []string{"FAKE_MODE=" + mode, "FAKE_ARGV=" + f.argv, "FAKE_STDIN=" + f.stdin,
			"FAKE_PID=" + f.pid, "FAKE_CHILD_PID=" + f.childPID, "FAKE_MARK=" + f.mark, "FAKE_CWD=" + f.cwd},
		InterruptGrace: 300 * time.Millisecond,
		CloseGrace:     200 * time.Millisecond,
	}, f
}

// assertNoProcessSurvives registers a t.Cleanup — it runs last (fakeClaude
// calls it before anything else in the test registers its own cleanup, and
// t.Cleanup runs last-registered-first) — that fails the test if any process
// whose argv mentions dir (the fake claude's own temp dir, so its path is
// unique per test) is still alive. This is the proof that a test's backend
// Close()/session teardown actually reaped the stub and its whole process
// group, not just asked it to go away.
func assertNoProcessSurvives(t *testing.T, dir string) {
	t.Helper()
	t.Cleanup(func() {
		deadline := time.Now().Add(2 * time.Second)
		var out []byte
		for {
			out, _ = exec.Command("pgrep", "-f", dir).Output()
			if len(strings.TrimSpace(string(out))) == 0 || time.Now().After(deadline) {
				break
			}
			time.Sleep(20 * time.Millisecond)
		}
		if s := strings.TrimSpace(string(out)); s != "" {
			// A regression here must not also leave the process running: kill
			// it (best-effort) so the failure is visible without leaking.
			_ = exec.Command("pkill", "-9", "-f", dir).Run()
			t.Errorf("process(es) from %s survived test cleanup (pid(s): %s)", dir, strings.Join(strings.Fields(s), ", "))
		}
	})
}

// argvRuns splits the fake's argv log into one slice per process run.
func argvRuns(t *testing.T, path string) [][]string {
	t.Helper()
	data, err := os.ReadFile(path)
	require.NoError(t, err)
	var runs [][]string
	var cur []string
	for _, l := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
		if l == "--" {
			runs = append(runs, cur)
			cur = nil
			continue
		}
		cur = append(cur, l)
	}
	return runs
}

// waitRuns polls until the fake has logged at least n process runs.
func waitRuns(t *testing.T, path string, n int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if data, err := os.ReadFile(path); err == nil && strings.Count(string(data), "\n--\n") >= n {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("the fake claude never logged %d run(s)", n)
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func readPIDFile(t *testing.T, path string) int {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if b, err := os.ReadFile(path); err == nil {
			if pid, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil && pid > 0 {
				return pid
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("pid file %s never appeared", path)
	return 0
}

// waitGone polls until pid no longer exists (reaped), failing after 5 s.
func waitGone(t *testing.T, pid int, what string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if err := syscall.Kill(pid, 0); errors.Is(err, syscall.ESRCH) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("%s (pid %d) is still alive", what, pid)
}

func TestClaudeBackend_MultiTurnInOneWarmProcess(t *testing.T) {
	opts, f := fakeClaude(t, "normal")
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "hello"})
	assert.Equal(t, "turn 1", h.next(EventTextDelta).Text)
	u := h.next(EventUsage)
	assert.Equal(t, 3, u.TokensIn)
	done := h.next(EventTurnDone)
	assert.Equal(t, StatusComplete, done.Status)
	assert.Equal(t, "sess-fake", done.SessionID)

	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "again"})
	assert.Equal(t, "turn 2", h.next(EventTextDelta).Text, "the second turn reaches the same process")
	h.next(EventTurnDone)
	require.NoError(t, h.finish())

	assert.Len(t, argvRuns(t, f.argv), 1, "one claude process for the whole conversation")
}

func TestClaudeBackend_CancelInterruptsAndProcessStaysWarm(t *testing.T) {
	opts, f := fakeClaude(t, "slow")
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "long answer please"})
	assert.Equal(t, "partial", h.next(EventTextDelta).Text)
	h.send(Command{Type: CommandCancel})
	done := h.next(EventTurnDone)
	assert.Equal(t, "t1", done.TurnID)
	assert.Equal(t, StatusInterrupted, done.Status)

	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "next"})
	assert.Equal(t, "turn 2", h.next(EventTextDelta).Text)
	assert.Equal(t, StatusComplete, h.next(EventTurnDone).Status)
	require.NoError(t, h.finish())

	stdin, err := os.ReadFile(f.stdin)
	require.NoError(t, err)
	assert.Contains(t, string(stdin), `"subtype":"interrupt"`, "cancel sends the interrupt control request")
	assert.Len(t, argvRuns(t, f.argv), 1)
}

func TestClaudeBackend_CancelKillsAfterGraceAndNextTurnResumes(t *testing.T) {
	opts, f := fakeClaude(t, "ignore_interrupt")
	opts.ResumeSessionID = "sess-0"
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "long"})
	h.next(EventTextDelta)
	h.send(Command{Type: CommandCancel})
	done := h.next(EventTurnDone)
	assert.Equal(t, StatusInterrupted, done.Status, "no result within the grace → killed, still reported as interrupted")

	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "next"})
	assert.Equal(t, "turn 1", h.next(EventTextDelta).Text, "a fresh process answers")
	h.next(EventTurnDone)
	require.NoError(t, h.finish())

	runs := argvRuns(t, f.argv)
	require.Len(t, runs, 2)
	assert.True(t, contains(runs[1], "--resume"), "the respawn resumes the session")
}

// A fresh (replayed) session killed after a cancel must not lose the
// conversation: the next turn — sent without replay, since the app counts
// the stopped turn as seen — resumes the session the killed child reported
// on its init line, and the interrupted turn_done carries that id.
func TestClaudeBackend_CancelKillOnFreshSessionResumesItsOwnSession(t *testing.T) {
	opts, f := fakeClaude(t, "ignore_interrupt")
	opts.Env = append(opts.Env, "FAKE_INIT_SID=sess-new")
	opts.Replay = func(string) (string, error) { return "=== CONVERSATION SO FAR ===\n=== END ===\n\n", nil }
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "long", Replay: true})
	h.next(EventTextDelta)
	h.send(Command{Type: CommandCancel})
	done := h.next(EventTurnDone)
	assert.Equal(t, StatusInterrupted, done.Status)
	assert.Equal(t, "sess-new", done.SessionID, "the app records the fresh session it can resume")

	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "next"})
	h.next(EventTurnDone)
	require.NoError(t, h.finish())

	runs := argvRuns(t, f.argv)
	last := runs[len(runs)-1]
	idx := indexOf(last, "--resume")
	require.GreaterOrEqual(t, idx, 0, "the respawn after the kill resumes, never a blank session")
	assert.Equal(t, "sess-new", last[idx+1])
}

func TestClaudeBackend_CrashThenNextTurnRespawnsWithResume(t *testing.T) {
	opts, f := fakeClaude(t, "crash_once")
	opts.ResumeSessionID = "sess-0"
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "x"})
	e := h.next(EventError)
	assert.Equal(t, "t1", e.TurnID)
	assert.Equal(t, CodeInternal, e.Code)
	assert.True(t, e.Retryable)

	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "retry"})
	assert.Equal(t, "turn 1", h.next(EventTextDelta).Text)
	assert.Equal(t, StatusComplete, h.next(EventTurnDone).Status)
	require.NoError(t, h.finish())

	runs := argvRuns(t, f.argv)
	require.Len(t, runs, 2)
	idx := indexOf(runs[1], "--resume")
	require.GreaterOrEqual(t, idx, 0)
	assert.Equal(t, "sess-0", runs[1][idx+1])
}

func indexOf(list []string, s string) int {
	for i, x := range list {
		if x == s {
			return i
		}
	}
	return -1
}

// TestClaudeBackend_SessionLostRetriesWithReplay: a rejected --resume is
// retried once as a fresh session carrying the replayed history — the owner
// sees an answer, not an error (spec §5, Review Focus 5).
func TestClaudeBackend_SessionLostRetriesWithReplay(t *testing.T) {
	opts, f := fakeClaude(t, "lost")
	opts.ResumeSessionID = "gone"
	opts.Replay = func(turnID string) (string, error) {
		assert.Equal(t, "t1", turnID)
		return "=== CONVERSATION SO FAR ===\nOwner: earlier question\n=== END ===\n\n", nil
	}
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "hello"})
	assert.Equal(t, "turn 1", h.next(EventTextDelta).Text)
	assert.Equal(t, StatusComplete, h.next(EventTurnDone).Status)
	require.NoError(t, h.finish())
	for e := range h.events {
		assert.NotEqual(t, EventError, e.Type, "session_lost is recovered silently")
	}

	runs := argvRuns(t, f.argv)
	last := runs[len(runs)-1]
	assert.False(t, contains(last, "--resume"), "the retry starts a fresh session")
	assert.True(t, contains(last, "--system-prompt-file"), "a fresh session gets the system prompt")
	stdin, err := os.ReadFile(f.stdin)
	require.NoError(t, err)
	assert.Contains(t, string(stdin), "CONVERSATION SO FAR")
	assert.Contains(t, string(stdin), "hello")
}

func TestClaudeBackend_ReplayCommandStartsFreshSession(t *testing.T) {
	opts, f := fakeClaude(t, "normal")
	opts.ResumeSessionID = "sess-0"
	opts.Replay = func(string) (string, error) { return "=== CONVERSATION SO FAR ===\n=== END ===\n\n", nil }
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)
	// Let the warm process actually start (a fresh script can take longer
	// than CloseGrace to exec) so its replacement is observable in argv.
	waitRuns(t, f.argv, 1)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "edited question", Replay: true})
	h.next(EventTurnDone)
	require.NoError(t, h.finish())

	runs := argvRuns(t, f.argv)
	require.Len(t, runs, 2, "the warm process is replaced by a fresh one")
	assert.True(t, contains(runs[0], "--resume"))
	assert.False(t, contains(runs[1], "--resume"))
}

// BEHAVIOR CHAT-04 — see docs/inventory/chat.md
// TestChat04_ClaudeArgvCarriesNoContent: CHAT-04 — the system prompt, the
// owner's text and attachment paths never appear on any process's argv; the
// prompt travels in a 0600 file, the text on stdin.
func TestChat04_ClaudeArgvCarriesNoContent(t *testing.T) {
	opts, f := fakeClaude(t, "normal")
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)

	h.send(Command{Type: CommandTurn, TurnID: "t0", Text: "see attached",
		Attachments: []Attachment{{Path: "/private/ATTACHMENT-PATH-SECRET.png", Mime: "image/png", Name: "x.png"}}})
	assert.Equal(t, CodeAttachmentUnsupported, h.next(EventError).Code)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "USER-TEXT-SECRET"})
	h.next(EventTurnDone)

	runs := argvRuns(t, f.argv)
	require.Len(t, runs, 1)
	argv := strings.Join(runs[0], "\n")
	for _, secret := range []string{"SYSTEM-PROMPT-SECRET", "USER-TEXT-SECRET", "ATTACHMENT-PATH-SECRET"} {
		assert.NotContains(t, argv, secret)
	}
	i := indexOf(runs[0], "--system-prompt-file")
	require.GreaterOrEqual(t, i, 0)
	promptFile := runs[0][i+1]
	data, err := os.ReadFile(promptFile)
	require.NoError(t, err)
	assert.Equal(t, "SYSTEM-PROMPT-SECRET", string(data))
	info, err := os.Stat(promptFile)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())

	j := indexOf(runs[0], "--mcp-config")
	require.GreaterOrEqual(t, j, 0)
	mcpFile := runs[0][j+1]
	info, err = os.Stat(mcpFile)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm(), "the mcp config can hold connection secrets")

	stdin, err := os.ReadFile(f.stdin)
	require.NoError(t, err)
	assert.Contains(t, string(stdin), "USER-TEXT-SECRET", "the owner's text travels on stdin")
	require.NoError(t, h.finish())

	_, err = os.Stat(promptFile)
	assert.True(t, os.IsNotExist(err), "the prompt file is deleted when the session exits")
	_, err = os.Stat(mcpFile)
	assert.True(t, os.IsNotExist(err), "the mcp config file (secrets) is deleted when the session exits")
}

// BEHAVIOR CHAT-04 — see docs/inventory/chat.md
// TestChat04_ClaudeSendsRealAttachmentAsContentBlock: the companion to
// TestChat04_ClaudeArgvCarriesNoContent's rejection case (task-20-review.md
// Important I1) — a real, accepted attachment must still complete the turn,
// with its base64 content on stdin and its path on neither argv nor stdin.
func TestChat04_ClaudeSendsRealAttachmentAsContentBlock(t *testing.T) {
	opts, f := fakeClaude(t, "normal")
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)

	// The attachment's directory name carries the CHAT-04 sentinel: if the
	// path ever reached argv or stdin (instead of just the file's base64
	// content), this would catch it the same way the rejection test does.
	dir := filepath.Join(t.TempDir(), "ATTACHMENT-PATH-SECRET")
	require.NoError(t, os.MkdirAll(dir, 0o700))
	imgPath := filepath.Join(dir, "shot.png")
	require.NoError(t, os.WriteFile(imgPath, fixturePNG, 0o600))

	h.send(Command{Type: CommandTurn, TurnID: "t0", Text: "what is in this image?",
		Attachments: []Attachment{{Path: imgPath, Mime: "image/png", Name: "shot.png"}}})
	done := h.next(EventTurnDone)
	assert.Equal(t, StatusComplete, done.Status)
	require.NoError(t, h.finish())

	runs := argvRuns(t, f.argv)
	require.Len(t, runs, 1)
	assert.NotContains(t, strings.Join(runs[0], "\n"), "ATTACHMENT-PATH-SECRET")

	stdin, err := os.ReadFile(f.stdin)
	require.NoError(t, err)
	stdinStr := string(stdin)
	assert.NotContains(t, stdinStr, "ATTACHMENT-PATH-SECRET", "the attachment path never travels on stdin")
	assert.Contains(t, stdinStr, `"type":"image"`)
	assert.Contains(t, stdinStr, `"media_type":"image/png"`)
	assert.Contains(t, stdinStr, base64.StdEncoding.EncodeToString(fixturePNG), "the file's content, base64-encoded, does travel on stdin")
}

// BEHAVIOR CHAT-04 — see docs/inventory/chat.md
func TestChat04_ClaudeArgsOnResume(t *testing.T) {
	args := claudeArgs(ClaudeOptions{Model: "sonnet", AllowedTools: "mcp__watchtower", DisallowedTools: "Bash"},
		"/tmp/p", "/tmp/m", "sess-9")
	assert.True(t, contains(args, "--resume"))
	assert.False(t, contains(args, "--system-prompt-file"), "a resumed session reuses its recorded prompt")
	assert.True(t, contains(args, "--input-format"))
	assert.True(t, contains(args, "--include-partial-messages"))
	assert.True(t, contains(args, "/tmp/m"), "mcp config travels as a file path")
	assert.True(t, contains(args, "--strict-mcp-config"), "a resumed session also sees only Watchtower's MCP servers")
}

// The claude child only ever sees the MCP servers Watchtower hands it
// (--strict-mcp-config: watchtower + Quick Connections, never the owner's
// claude.ai connectors) and runs in a dedicated, empty, stable directory, so
// no project CLAUDE.md from an inherited cwd leaks into the session and
// --resume finds the session again on the next spawn.
func TestClaudeBackend_StrictMCPAndNeutralWorkDir(t *testing.T) {
	opts, f := fakeClaude(t, "normal")
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "hi"})
	h.next(EventTurnDone)
	require.NoError(t, h.finish())

	runs := argvRuns(t, f.argv)
	require.Len(t, runs, 1)
	assert.True(t, contains(runs[0], "--strict-mcp-config"))
	assert.True(t, contains(runs[0], "--mcp-config"), "Watchtower's own servers still come through --mcp-config")

	cwd, err := os.ReadFile(f.cwd)
	require.NoError(t, err)
	want, err := filepath.EvalSymlinks(f.workDir)
	require.NoError(t, err)
	assert.Equal(t, want, strings.TrimSpace(string(cwd)), "the child runs in WorkDir, created on demand")
	entries, err := os.ReadDir(f.workDir)
	require.NoError(t, err)
	assert.Empty(t, entries, "the work dir holds nothing claude could load as project instructions")
}

func TestNeutralWorkDir_IsStableUnderTheTempDir(t *testing.T) {
	assert.Equal(t, filepath.Join(os.TempDir(), "watchtower-chat-cwd"), NeutralWorkDir())
	assert.Equal(t, NeutralWorkDir(), NeutralWorkDir(), "one path for every spawn, so --resume works")
	b, ok := NewClaudeBackend(ClaudeOptions{Binary: "/nonexistent"}).(*claudeBackend)
	require.True(t, ok)
	assert.Equal(t, NeutralWorkDir(), b.opts.WorkDir, "an unset WorkDir defaults to the neutral dir")
}

// BEHAVIOR CHAT-03 — see docs/inventory/chat.md
// TestChat03_CloseReapsStubbornChild: CHAT-03 / Review Focus 2 — a child that
// ignores stdin EOF and SIGTERM, and its own child, are both gone after Close.
func TestChat03_CloseReapsStubbornChild(t *testing.T) {
	opts, f := fakeClaude(t, "stubborn")
	b := NewClaudeBackend(opts)
	_, err := b.Start(context.Background())
	require.NoError(t, err)
	leader := readPIDFile(t, f.pid)
	child := readPIDFile(t, f.childPID)

	start := time.Now()
	require.NoError(t, b.Close())
	assert.Less(t, time.Since(start), 3*time.Second, "EOF, TERM, then KILL — bounded")
	waitGone(t, leader, "claude")
	waitGone(t, child, "claude's child")
}

func TestClaudeBackend_StdinEOFEndsSessionAndSweepsGroup(t *testing.T) {
	opts, f := fakeClaude(t, "grandchild")
	inR, inW := io.Pipe()
	s := NewSession(NewClaudeBackend(opts), NewEventWriter(io.Discard))
	done := make(chan error, 1)
	go func() { done <- s.Run(context.Background(), inR) }()

	// Wait for the grandchild first: a freshly written script can take longer
	// than CloseGrace to exec on macOS, and a fake killed before it spawned
	// its child proves nothing about the sweep.
	child := readPIDFile(t, f.childPID)
	require.NoError(t, inW.Close())
	select {
	case err := <-done:
		assert.NoError(t, err)
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not return after stdin EOF")
	}
	waitGone(t, child, "the MCP-server stand-in left behind by claude")
}

func TestClaudeBackend_ContextCancelEndsSession(t *testing.T) {
	opts, f := fakeClaude(t, "grandchild")
	inR, inW := io.Pipe()
	defer func() { _ = inW.Close() }()
	ctx, cancel := context.WithCancel(context.Background())
	s := NewSession(NewClaudeBackend(opts), NewEventWriter(io.Discard))
	done := make(chan error, 1)
	go func() { done <- s.Run(ctx, inR) }()

	child := readPIDFile(t, f.childPID)
	cancel()
	select {
	case err := <-done:
		assert.NoError(t, err)
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not return after ctx cancel")
	}
	waitGone(t, child, "claude's child")
}

func TestClaudeBackend_MissingBinaryIsProviderUnavailable(t *testing.T) {
	opts, _ := fakeClaude(t, "normal")
	opts.Binary = filepath.Join(t.TempDir(), "no-such-claude")
	h := startSession(t, NewClaudeBackend(opts), nil)
	e := h.next(EventError)
	assert.Equal(t, CodeProviderUnavailable, e.Code)
	assert.True(t, e.Retryable)
}

// A --resume rejected only through the result's "errors" array on stdout (the
// real CLI's shape, no stderr needed) is recovered with a replay too.
func TestClaudeBackend_SessionLostFromResultErrorsRetriesWithReplay(t *testing.T) {
	opts, f := fakeClaude(t, "lost_result")
	opts.ResumeSessionID = "gone"
	opts.Replay = func(string) (string, error) { return "=== CONVERSATION SO FAR ===\n=== END ===\n\n", nil }
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "hello"})
	assert.Equal(t, "turn 1", h.next(EventTextDelta).Text)
	assert.Equal(t, StatusComplete, h.next(EventTurnDone).Status)
	require.NoError(t, h.finish())
	for e := range h.events {
		assert.NotEqual(t, EventError, e.Type, "session_lost is recovered silently")
	}
	runs := argvRuns(t, f.argv)
	assert.False(t, contains(runs[len(runs)-1], "--resume"))
}

// ToolSearch never surfaces as a step through the whole backend either, and
// is not hidden from the model (it must stay usable to load MCP tools).
func TestClaudeBackend_InternalToolsAreNotSteps(t *testing.T) {
	opts, f := fakeClaude(t, "internal_tool")
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "targets?"})
	start := h.next(EventToolStart)
	assert.Equal(t, "list_targets", start.Name)
	h.next(EventTurnDone)
	require.NoError(t, h.finish())
	for e := range h.events {
		assert.NotEqual(t, EventToolStart, e.Type)
	}
	runs := argvRuns(t, f.argv)
	i := indexOf(runs[0], "--disallowedTools")
	require.GreaterOrEqual(t, i, 0)
	assert.NotContains(t, runs[0][i+1], "ToolSearch")
}

// blockingReplay returns a Replay func that signals entry and then blocks
// until release is closed — a turn parked between restartFresh and send.
func blockingReplay() (replay func(string) (string, error), entered chan struct{}, release chan struct{}) {
	entered, release = make(chan struct{}), make(chan struct{})
	var once sync.Once
	return func(string) (string, error) {
		once.Do(func() { close(entered) })
		<-release
		return "=== CONVERSATION SO FAR ===\n=== END ===\n\n", nil
	}, entered, release
}

// BEHAVIOR CHAT-03 — see docs/inventory/chat.md
// TestChat03_CloseDuringReplayNeverRespawns: stdin EOF while a replay turn
// sits between restartFresh and the respawn must not spawn a claude after
// Close — it would run the turn unreaped (review Important #1).
func TestChat03_CloseDuringReplayNeverRespawns(t *testing.T) {
	opts, f := fakeClaude(t, "normal")
	opts.ResumeSessionID = "sess-0"
	var entered, release chan struct{}
	opts.Replay, entered, release = blockingReplay()
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)
	waitRuns(t, f.argv, 1)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "edited", Replay: true})
	<-entered
	require.NoError(t, h.in.Close()) // the app went away mid-turn
	time.Sleep(300 * time.Millisecond)
	close(release)
	select {
	case err := <-h.done:
		require.NoError(t, err)
	case <-time.After(10 * time.Second):
		t.Fatal("session did not stop")
	}
	time.Sleep(300 * time.Millisecond) // a late spawn would log its argv by now
	assert.Len(t, argvRuns(t, f.argv), 1, "no claude is spawned after Close")
}

// A closed backend refuses to spawn even when the turn's ctx is still live.
// BEHAVIOR CHAT-03 — see docs/inventory/chat.md
func TestChat03_ClosedBackendRefusesToSpawn(t *testing.T) {
	opts, f := fakeClaude(t, "normal")
	b := NewClaudeBackend(opts)
	_, err := b.Start(context.Background())
	require.NoError(t, err)
	waitRuns(t, f.argv, 1)
	require.NoError(t, b.Close())

	var got []Event
	err = b.Turn(context.Background(), Command{Type: CommandTurn, TurnID: "t1", Text: "x"}, func(e Event) { got = append(got, e) })
	require.ErrorIs(t, err, errBackendClosed)
	assert.Empty(t, got)
	time.Sleep(300 * time.Millisecond)
	assert.Len(t, argvRuns(t, f.argv), 1)
}

// A cancel that lands before the owner's message reaches claude ends the turn
// as interrupted — not lost, not an internal error — sends nothing, and does
// not leak into the next turn.
func TestClaudeBackend_CancelBeforeMessageIsSentIsInterrupted(t *testing.T) {
	opts, f := fakeClaude(t, "normal")
	var entered, release chan struct{}
	opts.Replay, entered, release = blockingReplay()
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "NEVER-SENT", Replay: true})
	<-entered
	h.send(Command{Type: CommandCancel})
	time.Sleep(100 * time.Millisecond) // let the cancel reach the backend
	close(release)
	done := h.next(EventTurnDone)
	assert.Equal(t, "t1", done.TurnID)
	assert.Equal(t, StatusInterrupted, done.Status)

	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "next"})
	next := h.next(EventTurnDone)
	assert.Equal(t, "t2", next.TurnID)
	assert.Equal(t, StatusComplete, next.Status, "the cancel does not leak into the next turn")
	require.NoError(t, h.finish())

	stdin, _ := os.ReadFile(f.stdin)
	assert.NotContains(t, string(stdin), "NEVER-SENT")
	assert.NotContains(t, string(stdin), `"subtype":"interrupt"`, "nothing was in flight to interrupt")
}

// BEHAVIOR CHAT-03 — see docs/inventory/chat.md
// TestChat03_CloseUnblocksAStuckWrite: a child that stopped reading stdin
// leaves the turn's write blocked on a full pipe. Close must still get
// through (its SIGTERM/SIGKILL escalation exists for exactly this child) and
// the blocked write must fail instead of hanging the turn.
func TestChat03_CloseUnblocksAStuckWrite(t *testing.T) {
	opts, f := fakeClaude(t, "noread")
	b := NewClaudeBackend(opts)
	// Close is idempotent (closeOnce), so this is a no-op once the test's own
	// Close() call below runs; it's the guarantee that the stub still gets
	// reaped if an assertion fails first and skips the rest of the test body.
	t.Cleanup(func() { _ = b.Close() })
	_, err := b.Start(context.Background())
	require.NoError(t, err)
	waitRuns(t, f.argv, 1)

	turnErr := make(chan error, 1)
	go func() {
		turnErr <- b.Turn(context.Background(), Command{Type: CommandTurn, TurnID: "t1",
			Text: strings.Repeat("x", 8<<20)}, func(Event) {})
	}()
	time.Sleep(300 * time.Millisecond)
	select {
	case err := <-turnErr:
		t.Fatalf("the write was expected to block on the full pipe, the turn returned %v", err)
	default:
	}

	closed := make(chan struct{})
	start := time.Now()
	go func() { _ = b.Close(); close(closed) }()
	select {
	case <-closed:
		assert.Less(t, time.Since(start), 2*opts.CloseGrace+time.Second, "Close stays within its escalation budget")
	case <-time.After(5 * time.Second):
		t.Fatal("Close blocked behind the stuck write")
	}
	select {
	case err := <-turnErr:
		require.ErrorIs(t, err, errBackendClosed, "the blocked write fails once Close closes stdin")
	case <-time.After(5 * time.Second):
		t.Fatal("the blocked write never returned")
	}
}

// A cancel while the message write is stuck returns at once (the session
// loop keeps serving commands), and the grace kill ends the turn interrupted.
func TestClaudeBackend_CancelDuringStuckWriteEndsInterrupted(t *testing.T) {
	opts, _ := fakeClaude(t, "noread")
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: strings.Repeat("x", 4<<20)})
	h.next(EventTurnStart)
	time.Sleep(300 * time.Millisecond)
	h.send(Command{Type: CommandCancel})
	done := h.next(EventTurnDone)
	assert.Equal(t, "t1", done.TurnID)
	assert.Equal(t, StatusInterrupted, done.Status)
	require.NoError(t, h.finish())
}

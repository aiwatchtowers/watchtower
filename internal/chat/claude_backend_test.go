package chat

import (
	"bytes"
	"context"
	"encoding/base64"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/providers"
)

type fakeFiles struct {
	argv, stdin, pid, childPID, mark, cwd, workDir string
	// cli is the in-process fake the options run (fakeCLI); a test of the
	// process wiring itself switches to the script with useRealProcess.
	cli *fakeCLI
}

// fakeClaude installs testdata/fake_claude.sh as an executable `claude` and
// returns backend options pointing at it, run in process by a fakeCLI (the
// script's protocol in Go, over channel pipes), so the test can run inside
// testing/synctest. It also registers a t.Cleanup — it runs last — that
// fails the test when a fake child is still running after the test's own
// teardown: the in-process twin of a leaked stub process.
func fakeClaude(t *testing.T, mode string) (ClaudeOptions, fakeFiles) {
	t.Helper()
	dir := t.TempDir()
	cli := &fakeCLI{}
	t.Cleanup(func() {
		for i, k := range cli.children() {
			assert.False(t, k.alive(), "fake claude child %d still runs after the test", i)
		}
	})
	script, err := os.ReadFile(filepath.Join("testdata", "fake_claude.sh"))
	require.NoError(t, err)
	bin := filepath.Join(dir, "claude")
	require.NoError(t, os.WriteFile(bin, script, 0o755))
	f := fakeFiles{
		argv: filepath.Join(dir, "argv"), stdin: filepath.Join(dir, "stdin"),
		pid: filepath.Join(dir, "pid"), childPID: filepath.Join(dir, "child"), mark: filepath.Join(dir, "mark"),
		cwd: filepath.Join(dir, "cwd"), workDir: filepath.Join(dir, "workdir"), cli: cli,
	}
	return ClaudeOptions{
		Binary: bin, Model: "fake-model", SystemPrompt: "SYSTEM-PROMPT-SECRET",
		MCPConfig: `{"mcpServers":{}}`, AllowedTools: "mcp__watchtower", DisallowedTools: "Bash",
		WorkDir: f.workDir,
		Env: []string{"FAKE_MODE=" + mode, "FAKE_ARGV=" + f.argv, "FAKE_STDIN=" + f.stdin,
			"FAKE_PID=" + f.pid, "FAKE_CHILD_PID=" + f.childPID, "FAKE_MARK=" + f.mark, "FAKE_CWD=" + f.cwd},
		InterruptGrace: 300 * time.Millisecond,
		CloseGrace:     200 * time.Millisecond,
		start:          cli.start,
	}, f
}

// useRealProcess makes opts start testdata/fake_claude.sh as a real child
// process: only for the tests of the process wiring itself (spawn, the
// payload pipes, process-group kill), which wait on process events only.
func useRealProcess(opts *ClaudeOptions) { opts.start = nil }

// argvRuns splits the fake's argv log into one slice per process run.
func argvRuns(t *testing.T, path string) [][]string {
	t.Helper()
	data, err := os.ReadFile(path)
	require.NoError(t, err)
	var runs [][]string
	var cur []string
	for l := range strings.SplitSeq(strings.TrimRight(string(data), "\n"), "\n") {
		if l == "--" {
			runs = append(runs, cur)
			cur = nil
			continue
		}
		cur = append(cur, l)
	}
	return runs
}

func contains(list []string, s string) bool {
	return slices.Contains(list, s)
}

// childFIFO makes the FIFO a real fake's grandchild (stubborn and grandchild
// modes) holds open for writing, set in opts. Its open returns once the
// grandchild started; reading it ends at EOF once the grandchild is gone,
// whoever reaped it: process events, never a poll.
func childFIFO(t *testing.T, opts *ClaudeOptions) (open func() *os.File) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "child.fifo")
	require.NoError(t, syscall.Mkfifo(path, 0o600))
	opts.Env = append(opts.Env, "FAKE_CHILD_FIFO="+path)
	return func() *os.File {
		f, err := os.Open(path) // blocks until the grandchild opens it
		require.NoError(t, err)
		t.Cleanup(func() { _ = f.Close() })
		return f
	}
}

// requireGone reads the grandchild's FIFO to EOF: it returns once the
// grandchild is dead.
func requireGone(t *testing.T, fifo *os.File) {
	t.Helper()
	_, err := io.Copy(io.Discard, fifo)
	require.NoError(t, err)
}

func TestClaudeBackend_MultiTurnInOneWarmProcess(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
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
	})
}

func TestClaudeBackend_CancelInterruptsAndProcessStaysWarm(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
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
	})
}

func TestClaudeBackend_CancelKillsAfterGraceAndNextTurnReplays(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		opts, f := fakeClaude(t, "ignore_interrupt")
		opts.Replay = func(string, []Attachment) (string, error) {
			return replayHeader + "\nOwner: long\n" + replayFooter + "\n\n", nil
		}
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
		assert.False(t, contains(runs[1], "--resume"), "nothing to resume: no session is stored")
		assert.True(t, contains(runs[1], "--no-session-persistence"))
		lines := stdinLines(t, f.stdin)
		last := lines[len(lines)-1]
		assert.Contains(t, last, "CONVERSATION SO FAR", "the new child gets the history replayed")
		assert.Contains(t, last, "next")
	})
}

// A replaced child's late line must not change the session id the turn
// events report: only the live child's id counts.
func TestClaudeBackend_NoteSessionIDIgnoresAReplacedChild(t *testing.T) {
	b := &claudeBackend{}
	old, live := &claudeProc{}, &claudeProc{}
	b.proc = live
	b.noteSessionID(old, "sess-old")
	assert.Empty(t, b.currentSession())
	b.noteSessionID(live, "sess-live")
	assert.Equal(t, "sess-live", b.currentSession())
	b.noteSessionID(old, "sess-old")
	assert.Equal(t, "sess-live", b.currentSession())
}

// The claude backend hands the turn's attachments to the Replay hook, so a
// file sent again with the turn is left out of the replay.
func TestClaudeBackend_ReplayGetsTheTurnsAttachments(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		opts, _ := fakeClaude(t, "normal")
		p := writeAttachmentFixture(t, "a.csv", []byte("a,b"))
		var got []Attachment
		opts.Replay = func(_ string, current []Attachment) (string, error) {
			got = current
			return "", nil
		}
		h := startSession(t, NewClaudeBackend(opts), nil)
		h.next(EventSessionReady)
		att := Attachment{Path: p, Mime: "text/csv", Name: "a.csv"}
		h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "x", Attachments: []Attachment{att}})
		h.next(EventTurnDone)
		require.NoError(t, h.finish())
		assert.Equal(t, []Attachment{att}, got)
	})
}

// TestClaudeBackend_RespawnReplays (#604 Review Focus 2): the child dies
// mid-conversation; the next turn goes to a new child carrying the replayed
// history, never to a blank session.
func TestClaudeBackend_RespawnReplays(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		opts, f := fakeClaude(t, "crash_once")
		var replayed []string
		opts.Replay = func(turnID string, _ []Attachment) (string, error) {
			replayed = append(replayed, turnID)
			return replayHeader + "\nOwner: x\n" + replayFooter + "\n\n", nil
		}
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
		assert.False(t, contains(runs[1], "--resume"))
		lines := stdinLines(t, f.stdin)
		last := lines[len(lines)-1]
		assert.Contains(t, last, replayHeader, "the new child's first message starts with the replayed history")
		assert.Contains(t, last, "Owner: x", "it carries the earlier turn")
		assert.Contains(t, last, "retry")
		assert.Equal(t, []string{"t1", "t2"}, replayed, "every new child's first turn replays")
	})
}

// Every spawn gets fresh pipes: the child that replaces a crashed one reads
// the system prompt and the MCP config again (#604 G7).
func TestClaudeBackend_RespawnReadsPromptPipesAgain(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		opts, f := fakeClaude(t, "crash_once")
		read := filepath.Join(t.TempDir(), "read")
		opts.Env = append(opts.Env, "FAKE_PROMPT="+read+".prompt", "FAKE_MCP="+read+".mcp")
		h := startSession(t, NewClaudeBackend(opts), nil)
		h.next(EventSessionReady)

		h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "x"})
		h.next(EventError)
		h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "retry"})
		assert.Equal(t, StatusComplete, h.next(EventTurnDone).Status)
		require.NoError(t, h.finish())

		require.Len(t, argvRuns(t, f.argv), 2)
		prompt, err := os.ReadFile(read + ".prompt")
		require.NoError(t, err)
		assert.Equal(t, strings.Repeat("SYSTEM-PROMPT-SECRET\n--\n", 2), string(prompt))
		mcp, err := os.ReadFile(read + ".mcp")
		require.NoError(t, err)
		assert.Equal(t, strings.Repeat(opts.MCPConfig+"\n--\n", 2), string(mcp))
	})
}

func indexOf(list []string, s string) int {
	for i, x := range list {
		if x == s {
			return i
		}
	}
	return -1
}

func TestClaudeBackend_ReplayCommandStartsFreshSession(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		opts, f := fakeClaude(t, "normal")
		opts.Replay = func(string, []Attachment) (string, error) { return "=== CONVERSATION SO FAR ===\n=== END ===\n\n", nil }
		h := startSession(t, NewClaudeBackend(opts), nil)
		h.next(EventSessionReady)
		// Let the warm process actually start (a fresh script can take longer
		// than CloseGrace to exec) so its replacement is observable in argv.
		h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "edited question", Replay: true})
		h.next(EventTurnDone)
		require.NoError(t, h.finish())

		runs := argvRuns(t, f.argv)
		require.Len(t, runs, 2, "the warm process is replaced by a fresh one")
		for _, run := range runs {
			assert.False(t, contains(run, "--resume"))
		}
	})
}

// BEHAVIOR CHAT-04 — see docs/inventory/chat.md
// TestChat04_ClaudeArgvCarriesNoContent: CHAT-04 — the system prompt, the
// owner's text and attachment paths never appear on any process's argv; the
// prompt and the MCP config travel over inherited pipes (/dev/fd/N; #604 G7/G8
// — no temp file holds them, not even while the child runs), the text on
// stdin — in claude.ai mode too.
func TestChat04_ClaudeArgvCarriesNoContent(t *testing.T) {
	// The real fake process: the prompt and the config are read from the
	// inherited pipes the spawn hands over, end to end.
	forEachClaudeAIModeReal(t, func(t *testing.T, mode ClaudeAIMode) {
		opts, f := fakeClaude(t, "normal")
		useRealProcess(&opts)
		opts.ClaudeAI = mode
		tmp := t.TempDir()
		t.Setenv("TMPDIR", tmp)
		// The temp-file checks below watch the directory a prompt file
		// would land in (os.CreateTemp("") = os.TempDir()), not a vacuous one.
		require.Equal(t, tmp, os.TempDir())
		read := filepath.Join(t.TempDir(), "read")
		opts.Env = append(opts.Env, "FAKE_PROMPT="+read+".prompt", "FAKE_MCP="+read+".mcp")
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
		assert.Regexp(t, `^/dev/fd/\d+$`, runs[0][i+1], "the prompt rides an inherited pipe")
		data, err := os.ReadFile(read + ".prompt")
		require.NoError(t, err)
		assert.Equal(t, "SYSTEM-PROMPT-SECRET\n--\n", string(data), "the child read the prompt from it")

		j := indexOf(runs[0], "--mcp-config")
		require.GreaterOrEqual(t, j, 0)
		assert.Regexp(t, `^/dev/fd/\d+$`, runs[0][j+1], "the mcp config (connection secrets) rides an inherited pipe")
		data, err = os.ReadFile(read + ".mcp")
		require.NoError(t, err)
		assert.Equal(t, opts.MCPConfig+"\n--\n", string(data))

		// While the child runs, no temp file holds the prompt or the config.
		assertNoWTTemp(t, tmp)

		stdin, err := os.ReadFile(f.stdin)
		require.NoError(t, err)
		assert.Contains(t, string(stdin), "USER-TEXT-SECRET", "the owner's text travels on stdin")
		require.NoError(t, h.finish())
		assertNoWTTemp(t, tmp)
	})
}

// assertNoWTTemp fails when dir holds a wt-* file (a prompt or config temp).
func assertNoWTTemp(t *testing.T, dir string) {
	t.Helper()
	entries, err := os.ReadDir(dir)
	require.NoError(t, err)
	for _, e := range entries {
		assert.False(t, strings.HasPrefix(e.Name(), "wt-"), "temp file %s exists", e.Name())
	}
}

// BEHAVIOR CHAT-04 — see docs/inventory/chat.md
// TestChat04_ClaudeSendsRealAttachmentAsContentBlock: the companion to
// TestChat04_ClaudeArgvCarriesNoContent's rejection case (task-20-review.md
// Important I1) — a real, accepted attachment must still complete the turn,
// with its base64 content on stdin and its path on neither argv nor stdin.
func TestChat04_ClaudeSendsRealAttachmentAsContentBlock(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
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
	})
}

// BEHAVIOR CHAT-04 — see docs/inventory/chat.md
// TestChat04_ClaudeArgsNeverResume (#604 G11, ask #571; replaces
// TestChat04_ClaudeArgsOnResume): every spawn — the first, and every one
// after a child exit — passes --no-session-persistence and never --resume,
// so the prompt is always handed over; nothing on argv but paths.
func TestChat04_ClaudeArgsNeverResume(t *testing.T) {
	forEachClaudeAIMode(t, func(t *testing.T, mode ClaudeAIMode) {
		args := claudeArgs(ClaudeOptions{Model: "sonnet", AllowedTools: "mcp__watchtower", DisallowedTools: "Bash",
			ClaudeAI: mode}, "/dev/fd/4", "/dev/fd/3")
		assert.True(t, contains(args, "--no-session-persistence"))
		assert.False(t, contains(args, "--resume"))
		assert.True(t, contains(args, "--system-prompt-file"), "every child gets the prompt")
		assert.True(t, contains(args, "--input-format"))
		assert.True(t, contains(args, "--include-partial-messages"))
		assert.True(t, contains(args, "/dev/fd/3"), "mcp config travels as a path")
		if mode.On {
			assert.True(t, contains(args, "--permission-prompt-tool"), "a claude.ai session keeps its gate")
		} else {
			assert.True(t, contains(args, "--strict-mcp-config"), "a session sees only Watchtower's MCP servers")
		}

		// End to end: a child that crashed is replaced by one with the same
		// shape.
		opts, f := fakeClaude(t, "crash_once")
		opts.ClaudeAI = mode
		h := startSession(t, NewClaudeBackend(opts), nil)
		h.next(EventSessionReady)
		h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "x"})
		h.next(EventError)
		h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "again"})
		h.next(EventTurnDone)
		require.NoError(t, h.finish())
		runs := argvRuns(t, f.argv)
		require.Len(t, runs, 2)
		for _, run := range runs {
			assert.True(t, contains(run, "--no-session-persistence"))
			assert.False(t, contains(run, "--resume"))
			assert.True(t, contains(run, "--system-prompt-file"))
		}
	})
}

// forEachClaudeAIMode runs f as a subtest with claude.ai mode off and on,
// each inside a testing/synctest bubble.
func forEachClaudeAIMode(t *testing.T, f func(t *testing.T, mode ClaudeAIMode)) {
	t.Helper()
	forEachClaudeAIModeReal(t, func(t *testing.T, mode ClaudeAIMode) {
		synctest.Test(t, func(t *testing.T) { f(t, mode) })
	})
}

// forEachClaudeAIModeReal is forEachClaudeAIMode outside a bubble, for a
// test that runs the real fake process (useRealProcess).
func forEachClaudeAIModeReal(t *testing.T, f func(t *testing.T, mode ClaudeAIMode)) {
	t.Helper()
	for _, c := range []struct {
		name string
		mode ClaudeAIMode
	}{{"off", ClaudeAIMode{}}, {"claude.ai", ClaudeAIMode{On: true, Connectors: true, Sandbox: testSandbox(t)}}} {
		t.Run(c.name, func(t *testing.T) { f(t, c.mode) })
	}
}

// The warm child always carries the --tools built-in allowlist: the value it
// is given, and "" (no built-in at all) when none is set, so a built-in a
// later CLI release adds is never visible by default.
func TestClaudeArgs_ToolsAllowlistAlwaysPassed(t *testing.T) {
	for _, tools := range []string{"ToolSearch,WebSearch", ""} {
		args := claudeArgs(ClaudeOptions{Tools: tools, AllowedTools: "mcp__watchtower", DisallowedTools: "Bash"},
			"/tmp/p", "/tmp/m")
		i := indexOf(args, "--tools")
		require.GreaterOrEqual(t, i, 0, "tools=%q", tools)
		require.Less(t, i+1, len(args))
		assert.Equal(t, tools, args[i+1])
		assert.Equal(t, i, lastIndexOf(args, "--tools"), "--tools passed once")
	}
}

func lastIndexOf(args []string, s string) int {
	for i := len(args) - 1; i >= 0; i-- {
		if args[i] == s {
			return i
		}
	}
	return -1
}

// The claude child only ever sees the MCP servers Watchtower hands it
// (--strict-mcp-config: watchtower + Quick Connections, never the owner's
// claude.ai connectors) and runs in a dedicated, empty, stable directory, so
// no project CLAUDE.md from an inherited cwd leaks into the session and
// --resume finds the session again on the next spawn.
func TestClaudeBackend_StrictMCPAndNeutralWorkDir(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
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
	})
}

func TestNeutralWorkDir_IsStableUnderTheTempDir(t *testing.T) {
	assert.Equal(t, filepath.Join(os.TempDir(), "watchtower-chat-cwd"), NeutralWorkDir())
	assert.Equal(t, NeutralWorkDir(), NeutralWorkDir(), "one path for every spawn, so --resume works")
	b, ok := NewClaudeBackend(ClaudeOptions{Binary: "/nonexistent"}).(*claudeBackend)
	require.True(t, ok)
	assert.Equal(t, NeutralWorkDir(), b.opts.WorkDir, "an unset WorkDir defaults to the neutral dir")
}

// The child loads its cwd's .claude settings, so a work dir another user
// could have planted (a symlink, a file) is refused with a *WorkDirError
// naming the folder: no child is spawned there.
func TestClaudeBackend_RefusesAWorkDirThatIsNotPrivate(t *testing.T) {
	planted := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(planted, ".claude"), 0o755))
	for name, setup := range map[string]func(string) error{
		"symlink": func(p string) error { return os.Symlink(planted, p) },
		"file":    func(p string) error { return os.WriteFile(p, nil, 0o600) },
	} {
		t.Run(name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				opts, f := fakeClaude(t, "normal")
				require.NoError(t, setup(f.workDir))
				b, ok := NewClaudeBackend(opts).(*claudeBackend)
				require.True(t, ok)
				b.mu.Lock()
				p, err := b.spawnLocked()
				b.mu.Unlock()
				require.Error(t, err)
				assert.Nil(t, p)
				var we *WorkDirError
				require.ErrorAs(t, err, &we)
				assert.Contains(t, err.Error(), "Watchtower's chat folder "+f.workDir+" isn't private")
				assert.Contains(t, err.Error(), "delete it and try again")
				assert.NoFileExists(t, f.argv, "the claude child must never start in that directory")
			})
		})
	}
}

// A work dir of our own that is only group/other-writable (an old umask) is
// narrowed to 0700 and used, with one warning line — not a dead chat.
func TestClaudeBackend_NarrowsItsOwnGroupWritableWorkDir(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		opts, f := fakeClaude(t, "normal")
		require.NoError(t, os.Mkdir(f.workDir, 0o700))
		require.NoError(t, os.Chmod(f.workDir, 0o777))
		var warn bytes.Buffer
		opts.Warn = &warn
		h := startSession(t, NewClaudeBackend(opts), nil)
		h.next(EventSessionReady)
		require.NoError(t, h.finish())

		info, err := os.Stat(f.workDir)
		require.NoError(t, err)
		assert.Equal(t, os.FileMode(0o700), info.Mode().Perm())
		assert.Equal(t, 1, strings.Count(warn.String(), "narrowed it to 0700"), warn.String())
	})
}

// A group-writable work dir may already hold what another user planted while
// it was open (hooks in .claude/settings.json, a CLAUDE.md): it is narrowed,
// but refused when anything in it is open to others or a symlink.
func TestClaudeBackend_RefusesAGroupWritableWorkDirWithOpenContents(t *testing.T) {
	for name, plant := range map[string]func(dir string) error{
		"group-writable settings": func(dir string) error {
			if err := os.MkdirAll(filepath.Join(dir, ".claude"), 0o700); err != nil {
				return err
			}
			p := filepath.Join(dir, ".claude", "settings.json")
			if err := os.WriteFile(p, []byte(`{"hooks":{}}`), 0o600); err != nil {
				return err
			}
			return os.Chmod(p, 0o666)
		},
		"group-writable .claude dir": func(dir string) error {
			p := filepath.Join(dir, ".claude")
			if err := os.Mkdir(p, 0o700); err != nil {
				return err
			}
			return os.Chmod(p, 0o777)
		},
		"symlinked CLAUDE.md": func(dir string) error {
			return os.Symlink(filepath.Join(t.TempDir(), "CLAUDE.md"), filepath.Join(dir, "CLAUDE.md"))
		},
	} {
		t.Run(name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				opts, f := fakeClaude(t, "normal")
				require.NoError(t, os.Mkdir(f.workDir, 0o700))
				require.NoError(t, plant(f.workDir))
				require.NoError(t, os.Chmod(f.workDir, 0o777))
				b, ok := NewClaudeBackend(opts).(*claudeBackend)
				require.True(t, ok)
				b.mu.Lock()
				p, err := b.spawnLocked()
				b.mu.Unlock()
				assert.Nil(t, p)
				var we *WorkDirError
				require.ErrorAs(t, err, &we)
				assert.NoFileExists(t, f.argv, "the claude child must never start in that directory")
				info, err := os.Stat(f.workDir)
				require.NoError(t, err)
				assert.Equal(t, os.FileMode(0o700), info.Mode().Perm(), "narrowed before the contents were judged")
			})
		})
	}
}

// A respawn at turn time (the child died) re-checks the work dir: a folder
// swapped for a symlink meanwhile fails that turn as workdir_unsafe, with no
// Retry.
func TestClaudeBackend_RespawnIntoAnUnsafeWorkDirFailsTheTurn(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		opts, f := fakeClaude(t, "crash_once")
		h := startSession(t, NewClaudeBackend(opts), nil)
		h.next(EventSessionReady)
		h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "x"})
		h.next(EventError)

		require.NoError(t, os.RemoveAll(f.workDir))
		require.NoError(t, os.Symlink(t.TempDir(), f.workDir))
		h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "again"})
		e := h.next(EventError)
		assert.Equal(t, "t2", e.TurnID)
		assert.Equal(t, CodeWorkDirUnsafe, e.Code)
		assert.False(t, e.Retryable)
		assert.Contains(t, e.Message, f.workDir)
		require.NoError(t, h.finish())
		assert.Len(t, argvRuns(t, f.argv), 1, "no child started in the swapped folder")
	})
}

// A refused work dir reaches the Desktop as its own non-retryable code with
// the folder in the message — not provider_unavailable with a Retry that can
// never succeed.
func TestClaudeBackend_UnsafeWorkDirIsItsOwnNonRetryableCode(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		opts, f := fakeClaude(t, "normal")
		require.NoError(t, os.Symlink(t.TempDir(), f.workDir))
		h := startSession(t, NewClaudeBackend(opts), nil)
		e := h.next(EventError)
		assert.Equal(t, CodeWorkDirUnsafe, e.Code)
		assert.False(t, e.Retryable)
		assert.Contains(t, e.Message, f.workDir)
		assert.NoFileExists(t, f.argv)
	})
}

// BEHAVIOR CHAT-03 — see docs/inventory/chat.md
// TestChat03_CloseReapsStubbornChild: CHAT-03 / Review Focus 2 — a child that
// ignores stdin EOF and SIGTERM, and its own child, are both gone after Close.
// The escalation is bounded by construction, checked step by step instead of
// by wall clock: exactly two CloseGrace waits (after EOF, after TERM), which
// the test runs out itself, then KILL — the only signal that ends this child.
//
// A real process (the script): the signals, the process group and the
// reaping are what is under test. It waits on process events only — the
// grandchild's FIFO opening and reaching EOF.
func TestChat03_CloseReapsStubbornChild(t *testing.T) {
	opts, f := fakeClaude(t, "stubborn")
	useRealProcess(&opts)
	grandchild := childFIFO(t, &opts)
	b := NewClaudeBackend(opts)
	t.Cleanup(func() { _ = b.Close() })
	steps := controlGrace(b, 2)
	_, err := b.Start(context.Background())
	require.NoError(t, err)
	fifo := grandchild() // the stubborn child trapped TERM and started its own
	pidText, err := os.ReadFile(f.pid)
	require.NoError(t, err)
	leader, err := strconv.Atoi(strings.TrimSpace(string(pidText)))
	require.NoError(t, err)

	require.NoError(t, b.Close())
	assert.Equal(t, []time.Duration{opts.CloseGrace, opts.CloseGrace}, steps(),
		"EOF, TERM, then KILL — two grace steps, nothing else waited on")
	// Close returns only once the leader was reaped.
	assert.ErrorIs(t, syscall.Kill(leader, 0), syscall.ESRCH, "the stubborn child is gone")
	requireGone(t, fifo)
}

// controlGrace takes over b's CloseGrace timer: the first fired steps run
// out at once, a later one never does (only the child's exit ends it). The
// returned func lists the durations stopProc asked for, in order.
func controlGrace(b Backend, fired int) func() []time.Duration {
	var mu sync.Mutex
	var steps []time.Duration
	b.(*claudeBackend).graceAfter = func(d time.Duration) <-chan time.Time {
		mu.Lock()
		steps = append(steps, d)
		n := len(steps)
		mu.Unlock()
		if n > fired {
			return nil
		}
		out := make(chan time.Time, 1)
		out <- time.Time{}
		return out
	}
	return func() []time.Duration {
		mu.Lock()
		defer mu.Unlock()
		return slices.Clone(steps)
	}
}

// A real process (the script): the sweep of the child's process group is
// what is under test, seen through the grandchild's FIFO.
func TestClaudeBackend_StdinEOFEndsSessionAndSweepsGroup(t *testing.T) {
	opts, _ := fakeClaude(t, "grandchild")
	useRealProcess(&opts)
	grandchild := childFIFO(t, &opts)
	inR, inW := io.Pipe()
	s := NewSession(NewClaudeBackend(opts), NewEventWriter(io.Discard))
	done := make(chan error, 1)
	go func() { done <- s.Run(context.Background(), inR) }()

	// The grandchild first: a fake ended before it spawned its child proves
	// nothing about the sweep.
	fifo := grandchild()
	require.NoError(t, inW.Close())
	err := <-done
	assert.NoError(t, err)
	requireGone(t, fifo)
}

func TestClaudeBackend_ContextCancelEndsSession(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		opts, f := fakeClaude(t, "normal")
		inR, inW := io.Pipe()
		defer func() { _ = inW.Close() }()
		ctx, cancel := context.WithCancel(context.Background())
		s := NewSession(NewClaudeBackend(opts), NewEventWriter(io.Discard))
		done := make(chan error, 1)
		go func() { done <- s.Run(ctx, inR) }()

		synctest.Wait()
		child := f.cli.last()
		require.NotNil(t, child, "the session started its child")
		cancel()
		err := <-done
		assert.NoError(t, err)
		assert.False(t, child.alive(), "the session's end reaped the child")
	})
}

func TestClaudeBackend_MissingBinaryIsProviderUnavailable(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		opts, _ := fakeClaude(t, "normal")
		opts.Binary = filepath.Join(t.TempDir(), "no-such-claude")
		h := startSession(t, NewClaudeBackend(opts), nil)
		e := h.next(EventError)
		assert.Equal(t, CodeProviderUnavailable, e.Code)
		assert.True(t, e.Retryable)
	})
}

// ToolSearch never surfaces as a step through the whole backend either, and
// is not hidden from the model (it must stay usable to load MCP tools).
func TestClaudeBackend_InternalToolsAreNotSteps(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
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
	})
}

// blockingReplay returns a Replay func that signals entry and then blocks
// until release is closed — a turn parked between restartFresh and send.
func blockingReplay() (replay func(string, []Attachment) (string, error), entered chan struct{}, release chan struct{}) {
	entered, release = make(chan struct{}), make(chan struct{})
	var once sync.Once
	return func(string, []Attachment) (string, error) {
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
	synctest.Test(t, func(t *testing.T) {
		opts, f := fakeClaude(t, "normal")
		var entered, release chan struct{}
		opts.Replay, entered, release = blockingReplay()
		h := startSession(t, NewClaudeBackend(opts), nil)
		h.next(EventSessionReady)

		h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "edited", Replay: true})
		<-entered
		require.NoError(t, h.in.Close()) // the app went away mid-turn
		synctest.Wait()                  // the Close lands while the turn is parked
		close(release)
		err := <-h.done
		require.NoError(t, err)
		synctest.Wait() // a late spawn would have logged its argv by now
		assert.Len(t, argvRuns(t, f.argv), 1, "no claude is spawned after Close")
	})
}

// A closed backend refuses to spawn even when the turn's ctx is still live.
// BEHAVIOR CHAT-03 — see docs/inventory/chat.md
func TestChat03_ClosedBackendRefusesToSpawn(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		opts, f := fakeClaude(t, "normal")
		b := NewClaudeBackend(opts)
		_, err := b.Start(context.Background())
		require.NoError(t, err)
		require.NoError(t, b.Close())

		var got []Event
		err = b.Turn(context.Background(), Command{Type: CommandTurn, TurnID: "t1", Text: "x"}, func(e Event) { got = append(got, e) })
		require.ErrorIs(t, err, errBackendClosed)
		assert.Empty(t, got)
		synctest.Wait()
		assert.Len(t, argvRuns(t, f.argv), 1)
	})
}

// A cancel that lands before the owner's message reaches claude ends the turn
// as interrupted — not lost, not an internal error — sends nothing, and does
// not leak into the next turn.
func TestClaudeBackend_CancelBeforeMessageIsSentIsInterrupted(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		opts, f := fakeClaude(t, "normal")
		var entered, release chan struct{}
		opts.Replay, entered, release = blockingReplay()
		h := startSession(t, NewClaudeBackend(opts), nil)
		h.next(EventSessionReady)

		h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "NEVER-SENT", Replay: true})
		<-entered
		h.send(Command{Type: CommandCancel})
		synctest.Wait() // let the cancel reach the backend
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
	})
}

// BEHAVIOR CHAT-03 — see docs/inventory/chat.md
// TestChat03_CloseUnblocksAStuckWrite: a child that stopped reading stdin
// leaves the turn's write blocked on a full pipe. Close must still get
// through (its SIGTERM/SIGKILL escalation exists for exactly this child) and
// the blocked write must fail instead of hanging the turn.
//
// A real process (the script): a write blocked on a real, full pipe is what
// is under test; the in-process fakes cannot show the kernel failing it.
func TestChat03_CloseUnblocksAStuckWrite(t *testing.T) {
	opts, _ := fakeClaude(t, "noread")
	useRealProcess(&opts)
	b := NewClaudeBackend(opts)
	// Close is idempotent (closeOnce), so this is a no-op once the test's own
	// Close() call below runs; it's the guarantee that the stub still gets
	// reaped if an assertion fails first and skips the rest of the test body.
	t.Cleanup(func() { _ = b.Close() })
	// The escalation budget is checked by step, not by wall clock: the EOF
	// step runs out at once, and the TERM step never runs out — only the
	// child's exit on SIGTERM may end it.
	steps := controlGrace(b, 1)
	_, err := b.Start(context.Background())
	require.NoError(t, err)

	// The turn's message write is seen entering the child's stdin; nothing
	// reads that pipe, so an 8 MB write cannot complete.
	cb := b.(*claudeBackend)
	cb.mu.Lock()
	entered := make(chan struct{})
	cb.proc.stdin = &enteredWriter{WriteCloser: cb.proc.stdin, min: 1 << 20, entered: entered}
	cb.mu.Unlock()
	turnErr := make(chan error, 1)
	go func() {
		turnErr <- b.Turn(context.Background(), Command{Type: CommandTurn, TurnID: "t1",
			Text: strings.Repeat("x", 8<<20)}, func(Event) {})
	}()
	<-entered
	select {
	case err := <-turnErr:
		t.Fatalf("the write was expected to block on the full pipe, the turn returned %v", err)
	default:
	}

	require.NoError(t, b.Close()) // a Close blocked behind the stuck write never returns
	assert.Equal(t, []time.Duration{opts.CloseGrace, opts.CloseGrace}, steps(),
		"Close stays within its escalation budget: EOF and TERM steps, no other wait")
	require.ErrorIs(t, <-turnErr, errBackendClosed, "the blocked write fails once Close closes stdin")
}

// enteredWriter closes entered when a write of at least min bytes begins,
// then hands it on: a test's event for "the big write is under way".
type enteredWriter struct {
	io.WriteCloser
	min     int
	entered chan struct{}
	once    sync.Once
}

func (w *enteredWriter) Write(p []byte) (int, error) {
	if len(p) >= w.min {
		w.once.Do(func() { close(w.entered) })
	}
	return w.WriteCloser.Write(p)
}

// A cancel while the message write is stuck returns at once (the session
// loop keeps serving commands), and the grace kill ends the turn interrupted.
func TestClaudeBackend_CancelDuringStuckWriteEndsInterrupted(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		opts, _ := fakeClaude(t, "noread")
		h := startSession(t, NewClaudeBackend(opts), nil)
		h.next(EventSessionReady)
		h.send(Command{Type: CommandTurn, TurnID: "t1", Text: strings.Repeat("x", 4<<20)})
		h.next(EventTurnStart)
		synctest.Wait() // the write is stuck on the full pipe
		h.send(Command{Type: CommandCancel})
		done := h.next(EventTurnDone)
		assert.Equal(t, "t1", done.TurnID)
		assert.Equal(t, StatusInterrupted, done.Status)
		require.NoError(t, h.finish())
	})
}

// runOneTurn starts b, runs turn t1 and returns its events.
func runOneTurn(t *testing.T, b Backend) []Event {
	t.Helper()
	t.Cleanup(func() { _ = b.Close() })
	ctx := context.Background()
	_, err := b.Start(ctx)
	require.NoError(t, err)
	var events []Event
	require.NoError(t, b.Turn(ctx, Command{Type: CommandTurn, TurnID: "t1", Text: "hello"}, func(e Event) { events = append(events, e) }))
	require.NotEmpty(t, events)
	return events
}

// requireTypedTurnError checks the turn's text and that it ended with a
// turn-scoped error typed want, coded through ClassifyFailure.
func requireTypedTurnError(t *testing.T, events []Event, want providers.ErrorCategory) Event {
	t.Helper()
	var text strings.Builder
	for _, e := range events {
		if e.Type == EventTextDelta {
			text.WriteString(e.Text)
		}
	}
	assert.Equal(t, "partial", text.String(), "the partial text is delivered")
	last := events[len(events)-1]
	require.Equal(t, EventError, last.Type)
	assert.Equal(t, "t1", last.TurnID)
	var failure *providers.Failure
	require.ErrorAs(t, last.Cause, &failure, "the error carries a typed cause")
	assert.Equal(t, want, failure.Category)
	code, reason, retryable := ClassifyFailure(failure)
	assert.Equal(t, code, last.Code)
	assert.Equal(t, reason, last.Reason)
	assert.Equal(t, retryable, last.Retryable)
	return last
}

// L12: a warm child that exits 0 mid-turn without its result line ends the
// turn with a typed failure, through ClassifyFailure, after the partial
// text; never a blank success or an untyped internal error. Its stderr is in
// the message and decides the category when it is one of the CLI's own auth
// or rate-limit diagnostics; else the failure is invalid_output.
func TestClaudeBackend_CleanExitWithoutResultIsInvalidOutput(t *testing.T) {
	for _, tc := range []struct {
		stderr, wantMsg string
		want            providers.ErrorCategory
	}{
		{"", "claude ended the turn without a result", providers.InvalidOutput},
		{"mcp server failed to start", "claude ended the turn without a result: mcp server failed to start", providers.InvalidOutput},
		{"Invalid API key · Please run /login", "claude ended the turn without a result: Invalid API key · Please run /login", providers.Auth},
		{"API Error: 429 slow down", "claude ended the turn without a result: API Error: 429 slow down", providers.RateLimit},
	} {
		t.Run(tc.wantMsg, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				opts, _ := fakeClaude(t, "exit_clean")
				opts.Env = append(opts.Env, "FAKE_STDERR="+tc.stderr)
				last := requireTypedTurnError(t, runOneTurn(t, NewClaudeBackend(opts)), tc.want)
				assert.Equal(t, tc.wantMsg, last.Message)
			})
		})
	}
}

// A skipped line that may carry the turn's control flow (here its result)
// would leave the turn waiting for good: it fails the turn as invalid
// output and ends the child, so the next turn gets a fresh one, which
// replays.
func TestClaudeBackend_OverlongProtocolLineFailsTheTurn(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		old := maxWarmLine
		maxWarmLine = 64 << 10
		t.Cleanup(func() { maxWarmLine = old })
		opts, f := fakeClaude(t, "long_line")
		opts.Env = append(opts.Env, "FAKE_LONG_BYTES="+strconv.Itoa(256<<10), "FAKE_LONG_TYPE=result")
		b := NewClaudeBackend(opts)
		events := runOneTurn(t, b)
		last := events[len(events)-1]
		require.Equal(t, EventError, last.Type)
		var failure *providers.Failure
		require.ErrorAs(t, last.Cause, &failure)
		assert.Equal(t, providers.InvalidOutput, failure.Category)
		assert.Contains(t, last.Message, "reading claude output")
		assert.False(t, f.cli.last().alive(), "the child whose result line could not be read is gone")
	})
}

// A stdout line over maxWarmLine (a huge tool result) is skipped and
// counted, as every other CLI reader does (streamline, spec §3.1/§3.4): the
// turn goes on, completes, and the child stays up for the next turn.
func TestClaudeBackend_OverlongLineIsSkipped(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		old := maxWarmLine
		maxWarmLine = 64 << 10
		t.Cleanup(func() { maxWarmLine = old })
		opts, f := fakeClaude(t, "long_line")
		opts.Env = append(opts.Env, "FAKE_LONG_BYTES="+strconv.Itoa(256<<10))
		var warn bytes.Buffer
		opts.Warn = &warn
		b := NewClaudeBackend(opts)
		events := runOneTurn(t, b)
		var text strings.Builder
		for _, e := range events {
			require.NotEqual(t, EventError, e.Type, "the turn must not fail: %+v", e)
			if e.Type == EventTextDelta {
				text.WriteString(e.Text)
			}
		}
		assert.Equal(t, "before after", text.String())
		assert.Equal(t, EventTurnDone, events[len(events)-1].Type)
		assert.Contains(t, warn.String(), "chat: skipped 1 claude output line(s) over 65536 bytes")
		assert.NotContains(t, warn.String(), "xxxx", "the skipped line's content never reaches the log")
		assert.True(t, f.cli.last().alive(), "the child is still up for the next turn")
	})
}

package codex

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/providers"
)

// streamTurns runs the stream rule over JSONL lines.
func streamTurns(t *testing.T, lines []string) int {
	t.Helper()
	var tc turnCounter
	for _, l := range lines {
		if strings.TrimSpace(l) == "" {
			continue
		}
		var ev CodexEvent
		require.NoError(t, json.Unmarshal([]byte(l), &ev), l)
		tc.event(&ev)
	}
	return tc.turns
}

func fixtureLines(t *testing.T, name string) []string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", name))
	require.NoError(t, err)
	return strings.Split(strings.TrimSpace(string(data)), "\n")
}

func toolStart(id string) string {
	return `{"type":"item.started","item":{"id":"` + id + `","type":"mcp_tool_call","server":"watchtower","tool":"list_targets","arguments":{},"status":"in_progress"}}`
}

func toolDone(id string) string {
	return `{"type":"item.completed","item":{"id":"` + id + `","type":"mcp_tool_call","server":"watchtower","tool":"list_targets","arguments":{},"result":{"content":[{"type":"text","text":"[]"}]},"status":"completed"}}`
}

func message(id, text string) string {
	return `{"type":"item.completed","item":{"id":"` + id + `","type":"agent_message","text":"` + text + `"}}`
}

const (
	turnStarted   = `{"type":"turn.started"}`
	turnCompleted = `{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}`
	// One model response as the rollout records it: the record after the
	// response, the token_count after its tool results.
	rolloutRecord     = `{"type":"token_usage_record","payload":{},"synthetic":true}`
	rolloutTokenCount = `{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1}}},"synthetic":true}`
)

func TestTurnCounter_ParallelCallsAreOneTurn(t *testing.T) {
	// Live recording: three shell calls started before any returned.
	assert.Equal(t, 2, streamTurns(t, fixtureLines(t, "turns_parallel.jsonl")), "one tool response, then the answer")
	lines := []string{turnStarted, toolStart("a"), toolStart("b"), toolDone("a"), toolDone("b"), message("m", "done")}
	assert.Equal(t, 2, streamTurns(t, lines))
}

func TestTurnCounter_ConsecutiveResponsesCount(t *testing.T) {
	lines := []string{turnStarted, toolStart("a"), toolDone("a"), toolStart("b"), toolDone("b"), toolStart("c"), toolDone("c")}
	assert.Equal(t, 3, streamTurns(t, lines))
	// Live recording: a preamble and three responses of one call each, then
	// the answer.
	assert.Equal(t, 4, streamTurns(t, fixtureLines(t, "turns_sequential.jsonl")))
}

func TestTurnCounter_TextOnlyIsOneTurn(t *testing.T) {
	assert.Equal(t, 1, streamTurns(t, fixtureLines(t, "turns_text.jsonl")))
	// Two messages of one response (no tool between them) stay one turn.
	assert.Equal(t, 1, streamTurns(t, []string{turnStarted, message("m1", "a"), message("m2", "b")}))
}

func TestTurnCounter_ItemCompletedWithoutStart(t *testing.T) {
	// A tool seen only at item.completed opens and closes at once.
	lines := []string{turnStarted, toolDone("a"), toolDone("b"), message("m", "done")}
	assert.Equal(t, 3, streamTurns(t, lines))
	lines = []string{turnStarted, toolStart("a"), toolDone("b"), toolDone("a"), message("m", "done")}
	assert.Equal(t, 2, streamTurns(t, lines), "b came back while a was open: one response")
}

// Id-less tool items pair up in order, as queryStream.anonTool pairs them.
func TestTurnCounter_IdLessToolsPairInOrder(t *testing.T) {
	lines := []string{turnStarted, toolStart(""), toolDone(""), toolStart(""), toolDone(""), toolStart(""), toolDone("")}
	assert.Equal(t, 3, streamTurns(t, lines), "three responses of one id-less call each")
	lines = []string{turnStarted, toolStart(""), toolStart(""), toolDone(""), toolDone(""), message("", "done")}
	assert.Equal(t, 2, streamTurns(t, lines))
	lines = []string{turnStarted, toolDone(""), toolDone(""), message("", "done")}
	assert.Equal(t, 3, streamTurns(t, lines), "a tool seen only at its completion")
}

// A rollout that records no response while the stream shows tool rounds
// (its markers changed shape) is not trusted: the stream rule keeps the cap.
func TestTurnCounter_RolloutWithoutRecordsFallsBackToStream(t *testing.T) {
	var logs bytes.Buffer
	log.SetOutput(&logs)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })
	steps := []string{"R:" + `{"type":"session_meta","payload":{},"synthetic":true}`, turnStarted,
		toolStart("a"), toolDone("a"), toolStart("b"), toolDone("b"), toolStart("c"), "HOLD"}
	c, pid := cappedClient(t, steps, 2, t.TempDir())
	_, _, err := c.QuerySync(context.Background(), "sys", "hi", "")
	assertBudget(t, err, 2)
	assertGroupGone(t, pid())
	assert.Equal(t, 1, strings.Count(logs.String(), "without response records"), logs.String())
}

// A run that failed on its own keeps its failure; only a stop by the cap,
// or a clean run over the cap, is a budget failure.
func TestCodexClient_OwnFailureIsNotRelabelledBudget(t *testing.T) {
	steps := []string{turnStarted, message("m", "done"),
		`{"type":"turn.failed","error":{"message":"usage limit reached"}}`,
		"R:" + rolloutRecord, "R:" + rolloutTokenCount, "R:" + rolloutRecord, "R:" + rolloutTokenCount}
	c, _ := cappedClient(t, steps, 1, t.TempDir())
	_, err := runQuery(t, c)
	require.Error(t, err)
	var f *providers.Failure
	require.True(t, errors.As(err, &f), "a typed failure: %v", err)
	assert.NotEqual(t, providers.Budget, f.Category, err.Error())
}

func TestTurnCounter_ReasoningOpensTheNextTurn(t *testing.T) {
	reasoning := `{"type":"item.completed","item":{"id":"r1","type":"reasoning","text":"thinking"}}`
	lines := []string{turnStarted, toolStart("a"), toolDone("a"), reasoning, toolStart("b"), toolDone("b")}
	assert.Equal(t, 2, streamTurns(t, lines), "the reasoning opens turn 2, its tool belongs to it")
}

// The rollout records one token_count with usage per model response (and,
// newer, one token_usage_record); a token_count without info only carries
// rate limits. Read incrementally, a half-written line waits for its end.
func TestRolloutTurns_CountsResponses(t *testing.T) {
	for name, want := range map[string]int{"turns_rollout_parallel.jsonl": 2, "turns_rollout_sequential.jsonl": 4, "turns_rollout_text.jsonl": 1} {
		home := t.TempDir()
		data, err := os.ReadFile(filepath.Join("testdata", name))
		require.NoError(t, err)
		writeRollout(t, home, string(data))
		n, ok := (&rolloutTurns{home: home}).read()
		require.True(t, ok, name)
		assert.Equal(t, want, n, name)
	}

	home := t.TempDir()
	r := &rolloutTurns{home: home}
	_, ok := r.read()
	assert.False(t, ok, "no rollout yet")
	assert.NoError(t, r.err, "a rollout not written yet is not unreadable")
	rateOnly := `{"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{}},"synthetic":true}`
	path := writeRollout(t, home, rateOnly+"\n"+rolloutTokenCount+"\n"+rolloutTokenCount[:20])
	n, ok := r.read()
	require.True(t, ok)
	assert.Equal(t, 1, n, "a rate-limit token_count and a half line do not count")
	appendFile(t, path, rolloutTokenCount[20:]+"\n"+rolloutRecord+"\n")
	n, _ = r.read()
	assert.Equal(t, 2, n, "the finished line counts; the record count trails")
}

// N5 (ask #522): codex 0.159 runs one response's MCP calls one after
// another, which the stream rule counts as one turn per call. A run in its
// own home counts the rollout instead: the recorded run of three serial
// calls in one response is 2 turns, so a cap of 2 lets it finish.
func TestTurnCounter_RolloutTokenCountIsOneTurnPerResponse(t *testing.T) {
	serial := fixtureLines(t, "turns_serial_mcp.jsonl")
	require.Equal(t, 4, streamTurns(t, serial), "the stream rule over-counts the serial calls")

	home := t.TempDir()
	steps := []string{"R:" + rolloutRecord}
	steps = append(steps, serial[:3]...) // thread, turn, preamble
	steps = append(steps, serial[3:9]...)
	steps = append(steps, "R:"+rolloutTokenCount, "R:"+rolloutRecord, serial[9], "R:"+rolloutTokenCount, serial[10])
	c, _ := cappedClient(t, steps, 2, home)
	text, err := runQuery(t, c)
	require.NoError(t, err)
	assert.Contains(t, text, "0, 0, and 0")
}

func TestCodexClient_StopsWhenTurnNPlus1Starts(t *testing.T) {
	steps := []string{turnStarted, toolStart("a"), toolDone("a"), message("m1", "TURN TWO"), toolStart("b"), toolDone("b"),
		message("m2", "THIRD RESPONSE"), turnCompleted}
	past := append(steps[:6:6], toolStart("c"), "HOLD")
	c, pid := cappedClient(t, past, 2, "")
	text, err := runQuery(t, c)
	assertBudget(t, err, 2)
	assert.Contains(t, text, "TURN TWO", "the text of the turns inside the cap was delivered")
	assert.NotContains(t, text, "THIRD", "the turn past the cap never shows")
	assertGroupGone(t, pid())

	// QuerySync stops the same way.
	c, pid = cappedClient(t, past, 2, "")
	_, _, err = c.QuerySync(context.Background(), "sys", "hi", "")
	assertBudget(t, err, 2)
	assertGroupGone(t, pid())

	// The cap is a ceiling, not a target: a run inside it completes.
	c, _ = cappedClient(t, steps, 3, "")
	text, err = runQuery(t, c)
	require.NoError(t, err)
	assert.Contains(t, text, "THIRD RESPONSE")
}

// In its own home the rollout decides: the record of response 3 stops the
// run when its first item arrives, and a run whose last, text-only response
// passes the cap fails when codex ends, as claude's error_max_turns does.
func TestCodexClient_RolloutStopsWhenTurnNPlus1Starts(t *testing.T) {
	steps := []string{"R:" + rolloutRecord, turnStarted, toolStart("a"), toolDone("a"), "R:" + rolloutTokenCount,
		"R:" + rolloutRecord, toolStart("b"), toolDone("b"), "R:" + rolloutTokenCount,
		"R:" + rolloutRecord, toolStart("c"), "HOLD"}
	c, pid := cappedClient(t, steps, 2, t.TempDir())
	_, _, err := c.QuerySync(context.Background(), "sys", "hi", "")
	assertBudget(t, err, 2)
	assertGroupGone(t, pid())

	// The rollout's last lines land after the last stdout line.
	steps = []string{turnStarted, message("m", "done"), turnCompleted,
		"R:" + rolloutRecord, "R:" + rolloutTokenCount, "R:" + rolloutRecord, "R:" + rolloutTokenCount}
	c, _ = cappedClient(t, steps, 1, t.TempDir())
	_, _, err = c.QuerySync(context.Background(), "sys", "hi", "")
	assertBudget(t, err, 1)
}

// An unreadable rollout leaves the stream rule in charge, logged once.
func TestTurnCounter_UnreadableRolloutFallsBackToStream(t *testing.T) {
	var logs bytes.Buffer
	log.SetOutput(&logs)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })
	home := t.TempDir()
	path := writeRollout(t, home, rolloutRecord+"\n")
	require.NoError(t, os.Chmod(path, 0))
	steps := []string{turnStarted, toolStart("a"), toolDone("a"), toolStart("b"), toolDone("b"), toolStart("c"), "HOLD"}
	c, pid := cappedClient(t, steps, 2, home)
	_, _, err := c.QuerySync(context.Background(), "sys", "hi", "")
	assertBudget(t, err, 2)
	assertGroupGone(t, pid())
	assert.Equal(t, 1, strings.Count(logs.String(), "turn cap counts the stream"), logs.String())
	assert.Contains(t, logs.String(), "unreadable")
	assert.NotContains(t, logs.String(), home, "a class, never a path")
}

// A run home makes the run non-ephemeral in that home; without one the run
// stays --ephemeral in the inherited CODEX_HOME.
func TestCodexClient_RunHomeDropsEphemeral(t *testing.T) {
	c := NewClient("m", "", "/usr/bin/false")
	assert.Contains(t, c.ArgsForTest("", "hi"), "--ephemeral")
	home := t.TempDir()
	c.SetChildEnv([]string{"HOME=/tmp/acme-home", "CODEX_HOME=/tmp/owner-home"})
	c.SetRunHome(home)
	assert.NotContains(t, c.ArgsForTest("", "hi"), "--ephemeral")
	env := c.childEnviron(nil)
	assert.Contains(t, env, "CODEX_HOME="+home)
	assert.NotContains(t, env, "CODEX_HOME=/tmp/owner-home")
}

// cappedClient is a client capped at maxTurns over a stub codex that plays
// steps: "R:<line>" appends <line> to the rollout under $CODEX_HOME,
// "HOLD" blocks until the process group is killed, any other step is a
// stdout line. runHome "" = no run home. pid reads the stub's pid.
func cappedClient(t *testing.T, steps []string, maxTurns int, runHome string) (*Client, func() int) {
	t.Helper()
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "pid")
	var b strings.Builder
	b.WriteString(`if [ "$1" = "--version" ]; then echo "codex-cli 0.159.2"; exit 0; fi` + "\n")
	b.WriteString("echo $$ > " + pidFile + ".tmp; mv " + pidFile + ".tmp " + pidFile + "\n")
	b.WriteString(`R="$CODEX_HOME/sessions/2026/01/01/rollout-2026-01-01T00-00-00-x.jsonl"` + "\n")
	for _, s := range steps {
		switch {
		case s == "HOLD":
			b.WriteString("sleep 60 &\nwait\n")
		case strings.HasPrefix(s, "R:"):
			b.WriteString(`mkdir -p "$(dirname "$R")"; printf '%s\n' '` + s[2:] + `' >> "$R"` + "\n")
		default:
			b.WriteString(`printf '%s\n' '` + s + `'` + "\n")
		}
	}
	pid := func() int {
		data, err := os.ReadFile(pidFile)
		if err != nil {
			return 0
		}
		n, _ := strconv.Atoi(strings.TrimSpace(string(data)))
		return n
	}
	t.Cleanup(func() {
		if p := pid(); p > 0 {
			_ = syscall.Kill(-p, syscall.SIGKILL)
		}
	})
	c := NewClient("m", "", "")
	c.codexCmd = writeStubCodex(t, b.String())
	c.SetProcessGroup(true)
	c.SetMaxTurns(maxTurns)
	if runHome != "" {
		c.SetRunHome(runHome)
	}
	return c, pid
}

// runQuery drains a streaming Query: its text and its error.
func runQuery(t *testing.T, c *Client) (string, error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	textCh, errCh, sidCh := c.Query(ctx, "sys", "hi", "")
	var text strings.Builder
	for ch := range textCh {
		text.WriteString(ch.Text)
	}
	for range sidCh {
	}
	var err error
	for e := range errCh {
		if err == nil {
			err = e
		}
	}
	return text.String(), err
}

func assertBudget(t *testing.T, err error, n int) {
	t.Helper()
	require.Error(t, err)
	var f *providers.Failure
	require.True(t, errors.As(err, &f), "a typed failure: %v", err)
	assert.Equal(t, providers.Budget, f.Category, err.Error())
	assert.Contains(t, err.Error(), "stopped after "+strconv.Itoa(n)+" model turns")
}

func assertGroupGone(t *testing.T, pid int) {
	t.Helper()
	require.Positive(t, pid, "the stub ran")
	assert.Eventually(t, func() bool { return errors.Is(syscall.Kill(-pid, 0), syscall.ESRCH) },
		10*time.Second, 20*time.Millisecond, "the stub's process group is gone")
}

func writeRollout(t *testing.T, home, content string) string {
	t.Helper()
	dir := filepath.Join(home, "sessions", "2026", "01", "01")
	require.NoError(t, os.MkdirAll(dir, 0o700))
	path := filepath.Join(dir, "rollout-2026-01-01T00-00-00-x.jsonl")
	require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
	return path
}

func appendFile(t *testing.T, path, content string) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	require.NoError(t, err)
	w := bufio.NewWriter(f)
	_, err = w.WriteString(content)
	require.NoError(t, err)
	require.NoError(t, w.Flush())
	require.NoError(t, f.Close())
}

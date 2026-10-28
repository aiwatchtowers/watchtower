package llmusage

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// reset puts the package state back to "nothing set" for one test and
// restores it afterwards.
func reset(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	mu.Lock()
	saved := state
	state = config{}
	mu.Unlock()
	savedErr := stderr
	stderr = &buf
	t.Cleanup(func() {
		mu.Lock()
		state = saved
		mu.Unlock()
		stderr = savedErr
	})
	return &buf
}

type memSink struct{ calls []Call }

func (m *memSink) Write(c Call) error { m.calls = append(m.calls, c); return nil }

func TestRecordFillsDefaults(t *testing.T) {
	reset(t)
	SetProcess("cli:jira boards", "workbench")
	sink := &memSink{}
	SetSink(sink)

	ctx := WithPurpose(context.Background(), "digest.channel")
	Record(ctx, Call{Provider: "claude", Model: "claude-haiku-5-5", Input: 1000, Output: 100, OK: true})

	ctx2 := WithAutomation(WithSurface(context.Background(), "chat"), 7, 42)
	Record(ctx2, Call{Provider: "codex", Model: "gpt-5.6-sol", Input: 10})

	require.Len(t, sink.calls, 2)
	a, b := sink.calls[0], sink.calls[1]
	assert.Regexp(t, regexp.MustCompile(`^[0-9a-f]{16}$`), a.CallID)
	assert.NotEqual(t, a.CallID, b.CallID)
	at, err := time.Parse(time.RFC3339, a.At)
	require.NoError(t, err)
	assert.Equal(t, time.UTC, at.Location())
	assert.WithinDuration(t, time.Now(), at, time.Minute)
	assert.Equal(t, "digest.channel", a.Purpose)
	assert.Equal(t, "workbench", a.Surface, "process default surface")
	assert.Equal(t, "cli:jira boards", a.Process)
	assert.Nil(t, a.AutomationID)
	require.NotNil(t, a.EstCostUSD)
	assert.InDelta(t, (1000*0.10+100*0.50)/1e6, *a.EstCostUSD, 1e-12)

	assert.Empty(t, b.Purpose, "untagged")
	assert.Equal(t, "chat", b.Surface, "ctx surface wins")
	assert.Nil(t, b.EstCostUSD, "no price for the model")
	require.NotNil(t, b.AutomationID)
	require.NotNil(t, b.AutomationRunID)
	assert.Equal(t, int64(7), *b.AutomationID)
	assert.Equal(t, int64(42), *b.AutomationRunID)

	// a short model name is priced through pricing.Resolve
	Record(context.Background(), Call{Model: "haiku", Input: 1})
	require.Len(t, sink.calls, 3)
	assert.NotNil(t, sink.calls[2].EstCostUSD)
}

func TestRecordDefaultSurfaceIsWatchtower(t *testing.T) {
	reset(t)
	sink := &memSink{}
	SetSink(sink)
	Record(context.Background(), Call{})
	require.Len(t, sink.calls, 1)
	assert.Equal(t, "watchtower", sink.calls[0].Surface)
}

func TestRecordSpoolsWithoutSink(t *testing.T) {
	reset(t)
	dir := t.TempDir()
	path := SpoolPath(dir)
	assert.Equal(t, filepath.Join(dir, "llm_calls.spool.jsonl"), path)
	SetProcess("mcp:workbench", "")
	SetSpoolPath(path)

	ctx := WithPurpose(context.Background(), "media.describe")
	Record(ctx, Call{Provider: "claude", Model: "claude-opus-5-5", Input: 5, Output: 6, OK: true})
	Record(ctx, Call{Provider: "ollama", Model: "llama", Estimated: true})

	info, err := os.Stat(path)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())

	allowed := map[string]bool{}
	ct := reflect.TypeFor[Call]()
	for i := range ct.NumField() {
		allowed[strings.Split(ct.Field(i).Tag.Get("json"), ",")[0]] = true
	}

	f, err := os.Open(path)
	require.NoError(t, err)
	defer f.Close()
	var lines []Call
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var m map[string]any
		require.NoError(t, json.Unmarshal(sc.Bytes(), &m))
		for k := range m {
			assert.True(t, allowed[k], "unexpected field %q", k)
		}
		var c Call
		require.NoError(t, json.Unmarshal(sc.Bytes(), &c))
		lines = append(lines, c)
	}
	require.NoError(t, sc.Err())
	require.Len(t, lines, 2)
	assert.Equal(t, "media.describe", lines[0].Purpose)
	assert.Equal(t, "mcp:workbench", lines[0].Process)
	assert.Equal(t, int64(5), lines[0].Input)
	assert.True(t, lines[1].Estimated)
}

func TestUnwritableSpoolFallsBack(t *testing.T) {
	errBuf := reset(t)
	dir := t.TempDir()
	// the spool's directory is a regular file, so neither the directory,
	// the lock nor the spool can be created
	require.NoError(t, os.WriteFile(filepath.Join(dir, "blocked"), nil, 0o600))
	SetSpoolPath(filepath.Join(dir, "blocked", "llm_calls.spool.jsonl"))
	SetProcess("hook:stop", "")
	var got []Call
	SetFallback(func(c Call) error { got = append(got, c); return nil })

	ctx := WithPurpose(context.Background(), "automation.llm")
	Record(ctx, Call{Model: "claude-opus-5-5", Input: 3})
	require.Len(t, got, 1)
	assert.Equal(t, "automation.llm", got[0].Purpose)
	assert.Equal(t, int64(3), got[0].Input)
	assert.NotEmpty(t, got[0].CallID)
	assert.Empty(t, errBuf.String())

	logPath := filepath.Join(dir, "watchtower.log")
	SetLogPath(logPath)
	SetFallback(func(Call) error { return errors.New("database is locked: /secret/path") })
	Record(ctx, Call{Model: "claude-opus-5-5"})

	logData, err := os.ReadFile(logPath)
	require.NoError(t, err)
	for name, out := range map[string]string{"log": string(logData), "stderr": errBuf.String()} {
		assert.Equal(t, 1, strings.Count(out, "\n"), name)
		assert.Contains(t, out, "llmusage: call not recorded (automation.llm, hook:stop): ", name)
		assert.NotContains(t, out, "/secret/path", name+": error class only")
	}
}

func TestSpoolCreatesItsDirectory(t *testing.T) {
	reset(t)
	dir := filepath.Join(t.TempDir(), "fresh", "data-root")
	SetSpoolPath(SpoolPath(dir))

	Record(context.Background(), Call{Model: "m", OK: true})

	info, err := os.Stat(dir)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o700), info.Mode().Perm())
	calls, err := ReadSpool(SpoolPath(dir))
	require.NoError(t, err)
	assert.Len(t, calls, 1)
}

func TestLossLineCreatesTheLogDirectory(t *testing.T) {
	errBuf := reset(t)
	logPath := filepath.Join(t.TempDir(), "fresh", "watchtower.log")
	SetLogPath(logPath)

	Record(context.Background(), Call{Purpose: "probe"})

	data, err := os.ReadFile(logPath)
	require.NoError(t, err)
	assert.Contains(t, string(data), "llmusage: call not recorded (probe, ): ")
	assert.Contains(t, errBuf.String(), "llmusage: call not recorded (probe, ): ")
}

func TestRecordWithNothingSetWritesStderrOnly(t *testing.T) {
	errBuf := reset(t)
	assert.NotPanics(t, func() { Record(context.Background(), Call{}) })
	assert.Contains(t, errBuf.String(), "llmusage: call not recorded (, ): ")
	assert.Equal(t, 1, strings.Count(errBuf.String(), "\n"))
}

func TestEstimateTokens(t *testing.T) {
	assert.Equal(t, int64(0), EstimateTokens(""))
	assert.Equal(t, int64(1), EstimateTokens("abc"))
	assert.Equal(t, int64(2), EstimateTokens("abcdefgh"))
}

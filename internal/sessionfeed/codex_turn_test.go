package sessionfeed

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	turnStartedLine = `{"timestamp":"2026-11-05T12:19:00.699Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}`
	turnFailedLine  = `{"timestamp":"2026-11-05T12:19:00.918Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1",` +
		`"last_agent_message":null,"error":{"message":"You have hit your usage limit.","codex_error_info":"usage_limit_exceeded"}}}`
	turnOKLine      = `{"timestamp":"2026-11-05T12:20:36.437Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"hi"}}`
	turnAbortedLine = `{"timestamp":"2026-11-05T12:18:00.348Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t1","reason":"interrupted"}}`
	agentItemLine   = `{"timestamp":"2026-11-05T12:19:00.800Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}`
)

func writeRollout(t *testing.T, lines ...string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "rollout-x.jsonl")
	require.NoError(t, os.WriteFile(p, []byte(strings.Join(lines, "\n")+"\n"), 0o600))
	return p
}

func TestCodexLastTurn_FailedTurn(t *testing.T) {
	p := writeRollout(t, turnStartedLine, agentItemLine, turnFailedLine)

	got, err := CodexLastTurn(p)

	require.NoError(t, err)
	assert.True(t, got.Failed)
	assert.Equal(t, "usage_limit_exceeded", got.Error)
	assert.Equal(t, time.Date(2026, 11, 5, 12, 19, 0, 918e6, time.UTC), got.At)
}

func TestCodexLastTurn_Table(t *testing.T) {
	for name, lines := range map[string][]string{
		"ended fine":           {turnStartedLine, turnOKLine},
		"aborted":              {turnStartedLine, turnAbortedLine},
		"still running":        {turnStartedLine, agentItemLine},
		"new turn after error": {turnStartedLine, turnFailedLine, turnStartedLine},
		"no turn yet":          {agentItemLine},
		"partial last line":    {turnStartedLine, turnFailedLine[:40]},
	} {
		t.Run(name, func(t *testing.T) {
			got, err := CodexLastTurn(writeRollout(t, lines...))
			require.NoError(t, err)
			assert.False(t, got.Failed)
		})
	}
}

// codex_error_info is an object in some codex versions ({"http_connection_failed": {...}}):
// its key is the error type; anything else unreadable is "".
func TestCodexLastTurn_ErrorInfoShapes(t *testing.T) {
	for info, want := range map[string]string{
		`{"http_connection_failed":{"http_status_code":502}}`: "http_connection_failed",
		`null`: "",
		`42`:   "",
	} {
		line := strings.Replace(turnFailedLine, `"usage_limit_exceeded"`, info, 1)
		got, err := CodexLastTurn(writeRollout(t, turnStartedLine, line))
		require.NoError(t, err)
		assert.True(t, got.Failed, info)
		assert.Equal(t, want, got.Error, info)
	}
}

// Only the file's tail is read: a failure at the end of a long rollout is
// found, and the head before it is never parsed.
func TestCodexLastTurn_ReadsTheTailOnly(t *testing.T) {
	big := `{"type":"response_item","payload":{"text":"` + strings.Repeat("x", 4096) + `"}}`
	lines := []string{`{not json`}
	for range 200 {
		lines = append(lines, big)
	}
	lines = append(lines, turnStartedLine, turnFailedLine)

	got, err := CodexLastTurn(writeRollout(t, lines...))

	require.NoError(t, err)
	assert.True(t, got.Failed)
}

func TestCodexLastTurn_ZstdAndMissing(t *testing.T) {
	// A compressed rollout is read through its decompressed text, so its
	// failed turn shows like a plain one's — also past the tail window.
	p := filepath.Join(t.TempDir(), "rollout-z.jsonl")
	long := strings.Repeat(turnStartedLine+"\n", codexTurnTailBytes/len(turnStartedLine)+1) + turnFailedLine + "\n"
	require.NoError(t, os.WriteFile(p, []byte(long), 0o600))
	compressInPlace(t, p)
	got, err := CodexLastTurn(p)
	require.NoError(t, err)
	assert.True(t, got.Failed, "a compressed rollout's failed turn is read")

	// A corrupt frame is a read failure, never a silent not-failed.
	require.NoError(t, os.WriteFile(p, append([]byte{0x28, 0xb5, 0x2f, 0xfd}, []byte(turnFailedLine)...), 0o600))
	_, err = CodexLastTurn(p)
	require.Error(t, err)

	_, err = CodexLastTurn(filepath.Join(t.TempDir(), "gone.jsonl"))
	require.Error(t, err)
}

// A read failure names its class (spec §3.5): the watch gives up at once on
// permission and compressed, after 30 s on missing, after three ticks on
// unreadable.
func TestCodexLastTurn_ReadFailuresAreTypedWatchIssues(t *testing.T) {
	issueOf := func(err error) string {
		t.Helper()
		var wi *WatchIssueError
		require.ErrorAs(t, err, &wi)
		return wi.Issue
	}
	_, err := CodexLastTurn(filepath.Join(t.TempDir(), "gone.jsonl"))
	assert.Equal(t, "missing", issueOf(err))

	p := writeRollout(t, turnStartedLine)
	require.NoError(t, os.Chmod(p, 0o000))
	t.Cleanup(func() { _ = os.Chmod(p, 0o600) })
	if _, rerr := os.ReadFile(p); rerr == nil {
		t.Skip("running as a user that reads mode 000 files")
	}
	_, err = CodexLastTurn(p)
	assert.Equal(t, "permission", issueOf(err))

	z := filepath.Join(t.TempDir(), "rollout-z.jsonl")
	require.NoError(t, os.WriteFile(z, append([]byte{0x28, 0xb5, 0x2f, 0xfd}, []byte(turnFailedLine)...), 0o600))
	_, err = CodexLastTurn(z)
	assert.Equal(t, "compressed", issueOf(err))
}

// An interrupted turn (turn_aborted) is the pull's Interrupt: reported with
// its time so the watch ends the turn as waiting.
func TestCodexLastTurn_AbortedTurnCarriesItsTime(t *testing.T) {
	got, err := CodexLastTurn(writeRollout(t, turnStartedLine, turnAbortedLine))
	require.NoError(t, err)
	assert.False(t, got.Failed)
	assert.True(t, got.Aborted)
	assert.Equal(t, time.Date(2026, 11, 5, 12, 18, 0, 348e6, time.UTC), got.At)

	got, err = CodexLastTurn(writeRollout(t, turnAbortedLine, turnStartedLine))
	require.NoError(t, err)
	assert.False(t, got.Aborted, "a new turn after the abort runs")
}

// A committed last line that is not JSON is an undecodable tail; an
// unterminated last line is not: it is left for the next read.
func TestCodexLastTurn_UndecodableTail(t *testing.T) {
	got, err := CodexLastTurn(writeRollout(t, turnStartedLine, `{not json`))
	require.NoError(t, err)
	assert.True(t, got.TailUndecodable)

	p := filepath.Join(t.TempDir(), "rollout-p.jsonl")
	require.NoError(t, os.WriteFile(p, []byte(turnStartedLine+"\n"+turnFailedLine[:40]), 0o600))
	got, err = CodexLastTurn(p)
	require.NoError(t, err)
	assert.False(t, got.TailUndecodable, "an unterminated last line waits for the next tick")
}

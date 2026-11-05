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
	p := filepath.Join(t.TempDir(), "rollout-z.jsonl")
	require.NoError(t, os.WriteFile(p, append([]byte{0x28, 0xb5, 0x2f, 0xfd}, []byte(turnFailedLine)...), 0o600))
	got, err := CodexLastTurn(p)
	require.NoError(t, err)
	assert.False(t, got.Failed, "a compressed rollout is not read")

	// A compressed rollout longer than the tail window: the magic is read at
	// the start, not in the tail.
	long := append([]byte{0x28, 0xb5, 0x2f, 0xfd, '\n'}, []byte(strings.Repeat("x", codexTurnTailBytes)+"\n")...)
	long = append(long, []byte(turnStartedLine+"\n"+turnFailedLine+"\n")...)
	require.NoError(t, os.WriteFile(p, long, 0o600))
	got, err = CodexLastTurn(p)
	require.NoError(t, err)
	assert.False(t, got.Failed, "a long compressed rollout is not read")

	_, err = CodexLastTurn(filepath.Join(t.TempDir(), "gone.jsonl"))
	require.Error(t, err)
}

package cmd

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat"
	"watchtower/internal/db"
	"watchtower/internal/slacklive"
)

func liveRow(provider, status, connector string, at time.Time) db.SlackLiveStatus {
	return db.SlackLiveStatus{Provider: provider, Status: status, ConnectorID: connector, CheckedAt: at}
}

func codexHomeWith(t *testing.T, mode string) string {
	t.Helper()
	dir := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(dir, "auth.json"), []byte(`{"auth_mode":"`+mode+`"}`), 0o600))
	return dir
}

func TestCodexChatApps_OnlyForChatGPTLogin(t *testing.T) {
	now := time.Now()
	rows := []db.SlackLiveStatus{liveRow("codex", "ok", "conn_x", now)}
	assert.Equal(t, "conn_x", codexSlackConnector(rows, codexHomeWith(t, "chatgpt")))
	assert.Empty(t, codexSlackConnector(rows, codexHomeWith(t, "apikey")), "an API-key login has no connectors")
}

func TestBuildSystemPrompt_CodexSlackLiveNeedsOkRow(t *testing.T) {
	home := codexHomeWith(t, "chatgpt")
	now := time.Now()
	assert.Empty(t, codexSlackConnector(nil, home), "no row: no apps, no promise")
	assert.Empty(t, codexSlackConnector([]db.SlackLiveStatus{liveRow("codex", "ok", "", now)}, home), "an ok row without a connector id")
	assert.Empty(t, codexSlackConnector([]db.SlackLiveStatus{liveRow("codex", "needs_admin", "conn_x", now)}, home))
	assert.Equal(t, "conn_x", codexSlackConnector([]db.SlackLiveStatus{liveRow("codex", "ok", "conn_x", now)}, home))
}

func TestBuildSystemPrompt_SlackLiveOffAfterKnownFailure(t *testing.T) {
	now := time.Now()
	assert.True(t, claudeSlackLive(nil, true, false), "no row yet: the first call writes the status")
	assert.True(t, claudeSlackLive([]db.SlackLiveStatus{liveRow("claude", "ok", "", now)}, true, false))
	for _, s := range []string{"not_connected", "needs_admin", "no_plan"} {
		assert.False(t, claudeSlackLive([]db.SlackLiveStatus{liveRow("claude", s, "", now)}, true, false), s)
	}
	assert.False(t, claudeSlackLive(nil, false, false), "connectors off")
	assert.False(t, claudeSlackLive(nil, true, true), "Slack switched off in Settings")
	// A Codex failure does not turn off Claude.
	assert.True(t, claudeSlackLive([]db.SlackLiveStatus{liveRow("codex", "no_plan", "", now)}, true, false))
}

func slackWatcher(t *testing.T, database *db.DB, now time.Time) (*slackLiveWatcher, *[]string) {
	t.Helper()
	var probes []string
	w := newSlackLiveWatcher(database, "claude")
	w.now = func() time.Time { return now }
	w.classify = func(text string, _, readOK bool) (string, string) {
		if readOK {
			return "ok", ""
		}
		if text == "Unknown tool" {
			return "not_connected", "not_authorized"
		}
		return "unavailable", "read_failed"
	}
	w.startProbe = func(p string) { probes = append(probes, p) }
	return w, &probes
}

func toolCall(w *slackLiveWatcher, id, name string, ok bool, summary string) {
	w.Observe(chat.Event{Type: chat.EventToolStart, ID: id, Name: name})
	w.wg.Wait()
	w.Observe(chat.Event{Type: chat.EventToolEnd, ID: id, OK: &ok, Summary: summary})
	w.wg.Wait()
}

func TestAISession_ProbeOnFirstSlackToolOnly(t *testing.T) {
	now := time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC)
	d := db.OpenTestDB(t)
	w, probes := slackWatcher(t, d, now)

	toolCall(w, "1", "search_knowledge", true, "")
	assert.Empty(t, *probes, "a chat that never touches Slack never probes")

	toolCall(w, "2", "list_messages", true, "")
	assert.Equal(t, []string{"claude"}, *probes, "first Slack tool, no row: one probe")
	toolCall(w, "3", "list_slack_channels", true, "")
	toolCall(w, "3b", "watchtower-app:list_messages", true, "")
	assert.Len(t, *probes, 1, "at most once per session")

	// A fresh row suppresses the probe.
	w2, probes2 := slackWatcher(t, d, now)
	require.NoError(t, d.UpsertSlackLiveStatus(liveRow("claude", "ok", "", now.Add(-time.Hour))))
	toolCall(w2, "1", "list_messages", true, "")
	assert.Empty(t, *probes2)

	// A stale one does not.
	w3, probes3 := slackWatcher(t, d, now.Add(48*time.Hour))
	toolCall(w3, "1", "list_messages", true, "")
	assert.Len(t, *probes3, 1)
}

func TestAISession_ProbeMatchesRenamedServer(t *testing.T) {
	d := db.OpenTestDB(t)
	w, probes := slackWatcher(t, d, time.Now())
	toolCall(w, "1", "watchtower-app:list_messages", true, "")
	assert.Len(t, *probes, 1)
}

func TestSlackLiveWatcher_NoWorkAfterWait(t *testing.T) {
	d := db.OpenTestDB(t)
	w, probes := slackWatcher(t, d, time.Now())
	w.Wait()
	ok := true
	w.Observe(chat.Event{Type: chat.EventToolStart, ID: "1", Name: "list_messages"})
	w.Observe(chat.Event{Type: chat.EventToolEnd, ID: "1", OK: &ok})
	w.Observe(chat.Event{Type: chat.EventToolStart, ID: "2", Name: "claude_ai_Slack:slack_read_channel"})
	w.Observe(chat.Event{Type: chat.EventToolEnd, ID: "2", OK: &ok})
	w.Wait()
	assert.Empty(t, *probes)
	rows, err := d.ListSlackLiveStatus()
	require.NoError(t, err)
	assert.Empty(t, rows)
}

func TestSlackLiveWatcher_StatusTimeIsEventTime(t *testing.T) {
	d := db.OpenTestDB(t)
	t1 := time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC)
	t2 := t1.Add(time.Hour)
	w, _ := slackWatcher(t, d, t1)

	// The failure's write is held until the newer ok has been written.
	release := make(chan struct{})
	okDone := make(chan struct{})
	w.beforeWrite = func(e chat.Event) {
		if !*e.OK {
			<-release
		}
	}
	w.afterWrite = func(e chat.Event) {
		if *e.OK {
			close(okDone)
		}
	}
	bad, good := false, true
	w.Observe(chat.Event{Type: chat.EventToolStart, ID: "1", Name: "claude_ai_Slack:slack_read_channel"})
	w.Observe(chat.Event{Type: chat.EventToolEnd, ID: "1", OK: &bad, Summary: "Unknown tool"}) // event time t1
	w.now = func() time.Time { return t2 }
	w.Observe(chat.Event{Type: chat.EventToolStart, ID: "2", Name: "claude_ai_Slack:slack_read_channel"})
	w.Observe(chat.Event{Type: chat.EventToolEnd, ID: "2", OK: &good}) // event time t2
	<-okDone
	w.now = func() time.Time { return t2.Add(time.Hour) } // the clock has moved on when the failure is written
	close(release)
	w.Wait()

	rows, err := d.ListSlackLiveStatus()
	require.NoError(t, err)
	require.Len(t, rows, 1)
	assert.Equal(t, "ok", rows[0].Status, "the older failure, written last, cannot overwrite the newer ok")
	assert.True(t, t2.Equal(rows[0].CheckedAt))
}

func TestChatLive_StatusWrittenOnUse(t *testing.T) {
	now := time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC)
	d := db.OpenTestDB(t)
	w, _ := slackWatcher(t, d, now)

	toolCall(w, "1", "claude_ai_Slack:slack_read_channel", true, "12 messages")
	rows, err := d.ListSlackLiveStatus()
	require.NoError(t, err)
	require.Len(t, rows, 1)
	assert.Equal(t, "ok", rows[0].Status)

	w.now = func() time.Time { return now.Add(time.Minute) }
	toolCall(w, "2", "claude_ai_Slack:slack_search_public", false, "Unknown tool")
	rows, err = d.ListSlackLiveStatus()
	require.NoError(t, err)
	require.Len(t, rows, 1)
	assert.Equal(t, "not_connected", rows[0].Status)

	// A Codex app call: server codex_apps, tool slack.<name>.
	w.now = func() time.Time { return now.Add(2 * time.Minute) }
	toolCall(w, "5", "codex_apps:slack.slack_list_workspaces", true, "ok")
	rows, _ = d.ListSlackLiveStatus()
	assert.Equal(t, "ok", rows[0].Status)
	w.now = func() time.Time { return now.Add(3 * time.Minute) }
	toolCall(w, "6", "claude_ai_Slack:slack_send_message", false, "boom") // a write: not a read-status signal
	rows, _ = d.ListSlackLiveStatus()
	assert.Equal(t, "ok", rows[0].Status)

	// A local Slack tool or another connector never writes a status.
	toolCall(w, "3", "list_messages", true, "")
	toolCall(w, "4", "claude_ai_Gmail:search", true, "")
	rows, _ = d.ListSlackLiveStatus()
	assert.Len(t, rows, 1)
	assert.Equal(t, "ok", rows[0].Status)
}

// An ordinary tool error (a missing channel, bad arguments: read_failed)
// says nothing about the connection and leaves the status as it was; a
// connection-class failure is written (M1). The real classifier decides.
func TestChatLive_OrdinaryToolErrorKeepsLive(t *testing.T) {
	now := time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC)
	d := db.OpenTestDB(t)
	w, _ := slackWatcher(t, d, now)
	w.classify = slacklive.Classify
	toolCall(w, "1", "claude_ai_Slack:slack_read_channel", true, "12 messages")
	w.now = func() time.Time { return now.Add(time.Minute) }
	toolCall(w, "2", "claude_ai_Slack:slack_read_channel", false, "channel_not_found")
	toolCall(w, "2b", "claude_ai_Slack:slack_read_channel", false, "request timed out")
	rows, err := d.ListSlackLiveStatus()
	require.NoError(t, err)
	require.Len(t, rows, 1)
	assert.Equal(t, "ok", rows[0].Status, "one failed read does not turn Live off")
	assert.True(t, now.Equal(rows[0].CheckedAt), "nothing was written: a failed read or one call's timeout is an ordinary tool error")
	assert.True(t, claudeSlackLive(rows, true, false))

	for _, c := range []struct{ text, status string }{
		{"Too many requests (429)", "unavailable"},
		{"Your workspace admin must approve this app", "needs_admin"},
		{"This tool is not available on your plan", "no_plan"},
		{"Unknown tool: slack_read_channel", "not_connected"},
	} {
		w.now = func() time.Time { return now.Add(time.Hour) }
		toolCall(w, "3", "claude_ai_Slack:slack_read_channel", false, c.text)
		rows, err = d.ListSlackLiveStatus()
		require.NoError(t, err)
		assert.Equal(t, c.status, rows[0].Status, c.text)
		now = now.Add(2 * time.Hour)
	}
}

func TestChatLive_ConnectorErrorShown(t *testing.T) {
	// CHAT-02: a failed connector call reaches the owner as a tool_end with
	// ok=false and its text; the watcher only observes it.
	d := db.OpenTestDB(t)
	w, _ := slackWatcher(t, d, time.Now())
	var out []chat.Event
	ew := chat.NewEventWriter(discard{})
	ew.Observe = func(e chat.Event) { out = append(out, e); w.Observe(e) }
	defer w.Wait()
	f := false
	require.NoError(t, ew.Emit(chat.Event{Type: chat.EventToolStart, ID: "1", Name: "claude_ai_Slack:slack_read_channel"}))
	require.NoError(t, ew.Emit(chat.Event{Type: chat.EventToolEnd, ID: "1", OK: &f, Summary: "Unknown tool"}))
	require.Len(t, out, 2)
	require.NotNil(t, out[1].OK)
	assert.False(t, *out[1].OK)
	assert.Equal(t, "Unknown tool", out[1].Summary)
}

type discard struct{}

func (discard) Write(p []byte) (int, error) { return len(p), nil }

// Every main-surface chat gets the watcher, whatever the configured provider:
// a conversation pinned to Claude on an Ollama default still writes the
// status from its session_ready provider. Other surfaces get none.
func TestAISession_SlackLiveWatcherForEveryMainChat(t *testing.T) {
	d := db.OpenTestDB(t)
	ew := chat.NewEventWriter(discard{})
	wait := attachSessionSlackLive(t.Context(), ew, d, "main", "ollama")
	require.NotNil(t, ew.Observe, "attached on main with an unwired configured provider")
	ok := true
	require.NoError(t, ew.Emit(chat.Event{Type: chat.EventSessionReady, Provider: "claude"}))
	require.NoError(t, ew.Emit(chat.Event{Type: chat.EventToolStart, ID: "1", Name: "claude_ai_Slack:slack_read_channel"}))
	require.NoError(t, ew.Emit(chat.Event{Type: chat.EventToolEnd, ID: "1", OK: &ok, Summary: "3 messages"}))
	wait()
	rows, err := d.ListSlackLiveStatus()
	require.NoError(t, err)
	r, found := newestSlackLive(rows, "claude")
	require.True(t, found, "the connector call wrote the session's actual provider's status")
	assert.Equal(t, "ok", r.Status)

	other := chat.NewEventWriter(discard{})
	attachSessionSlackLive(t.Context(), other, d, "target", "claude")()
	assert.Nil(t, other.Observe, "no watcher off the main surface")
}

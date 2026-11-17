package chatengine

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/rivo/uniseg"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// feedActionOf reads conv's feed with one assistant message of turn "t1" and
// one agent action of that turn, inserted with the given columns.
func feedActionOf(t *testing.T, external int, errText, resultJSON, argsJSON string) FeedAction {
	t.Helper()
	d := openDB(t)
	conv := newConversation(t, d)
	res, err := d.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at, turn_id)
		VALUES (?, 'assistant', 'I propose an issue.', 1, 't1')`, conv)
	require.NoError(t, err)
	msg, _ := res.LastInsertId()
	_, err = d.Exec(`UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?`, msg, conv)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO agent_actions (tool, external, args_json, surface, conversation_id, turn_id, status, result_json, error)
		VALUES ('create_jira_issue', ?, ?, 'main', ?, 't1', 'applied', ?, ?)`, external, argsJSON, conv, resultJSON, errText)
	require.NoError(t, err)
	return onlyAction(t, d, conv)
}

func onlyAction(t *testing.T, d *db.DB, conv int64) FeedAction {
	t.Helper()
	f, err := ReadFeed(context.Background(), d, conv, 0, time.Unix(10, 0), nil)
	require.NoError(t, err)
	require.Len(t, f.Actions, 1)
	return f.Actions[0]
}

// TestChatengine_FeedActionCarriesCardFields: the feed action carries what
// the approval card reads beyond the args (ask #1409): external, the row's
// error, the result's card keys and the turn.
func TestChatengine_FeedActionCarriesCardFields(t *testing.T) {
	a := feedActionOf(t, 1, "boom",
		`{"url":"https://example.com/acme-1","label":"ACME-1","warning":"mirror failed"}`, `{"summary":"x"}`)
	assert.True(t, a.External)
	assert.Equal(t, "boom", a.Error)
	assert.Equal(t, "https://example.com/acme-1", a.Result["url"])
	assert.Equal(t, "ACME-1", a.Result["label"])
	assert.Equal(t, "mirror failed", a.Result["warning"])
	assert.Equal(t, "t1", a.TurnID)
	assert.True(t, a.ArgsComplete)

	var payload map[string]any
	require.NoError(t, json.Unmarshal(approvalPart(a).Payload, &payload))
	assert.Equal(t, true, payload["external"])
	assert.Equal(t, "boom", payload["error"])
	assert.Equal(t, "t1", payload["turn_id"])
	assert.Equal(t, true, payload["args_complete"])
	assert.Equal(t, map[string]any{"url": "https://example.com/acme-1", "label": "ACME-1", "warning": "mirror failed"},
		payload["result"])
}

// TestChatengine_FeedActionResultKeepsOnlyCardKeys: a result key the card
// does not show never leaves the Mac, and each value is clipped to 512 bytes.
func TestChatengine_FeedActionResultKeepsOnlyCardKeys(t *testing.T) {
	long := strings.Repeat("é", 2048) // 4 KB
	a := feedActionOf(t, 0, "", `{"label":"`+long+`","token":"secret","target_id":7,"version":3}`, `{}`)
	assert.NotContains(t, a.Result, "token")
	assert.LessOrEqual(t, len(a.Result["label"]), 512)
	assert.True(t, strings.HasPrefix(long, a.Result["label"]), "clipped on a rune boundary")
	assert.Equal(t, "7", a.Result["target_id"])
	assert.Equal(t, "3", a.Result["version"])
	assert.False(t, a.External)
	assert.Empty(t, a.Error)

	none := feedActionOf(t, 0, "", "", `{}`)
	assert.Nil(t, none.Result, "no result: no key on the wire")
}

// TestChatengine_FeedActionArgsCompleteFalseWhenClipped: args past the
// display cap reach the phone clipped, so the card offers no editor.
func TestChatengine_FeedActionArgsCompleteFalseWhenClipped(t *testing.T) {
	big := feedActionOf(t, 1, "", "", `{"text":"`+strings.Repeat("a", maxActionArgsBytes)+`"}`)
	assert.False(t, big.ArgsComplete)
	small := feedActionOf(t, 1, "", "", `{"text":"hi"}`)
	assert.True(t, small.ArgsComplete)
}

// TestChatengine_FeedActionErrorClippedToLabel: a tool failure's error (a
// whole API body) leaves the Mac clipped to maxLabel, in the flat action and
// the approval part alike.
func TestChatengine_FeedActionErrorClippedToLabel(t *testing.T) {
	long := "jira said no: " + strings.Repeat("x", 5000)
	a := feedActionOf(t, 1, long, "", `{}`)
	assert.LessOrEqual(t, uniseg.GraphemeClusterCount(a.Error), maxLabel)
	assert.True(t, strings.HasPrefix(a.Error, "jira said no: "))
	var payload map[string]any
	require.NoError(t, json.Unmarshal(approvalPart(a).Payload, &payload))
	assert.Equal(t, a.Error, payload["error"])
}

// TestChatengine_FeedActionResultEdges: a url past the value cap is dropped
// (a cut link would open somewhere else); a result that is not a JSON object
// yields none; args that are not JSON are shown as stored and whole.
func TestChatengine_FeedActionResultEdges(t *testing.T) {
	longURL := "https://example.com/acme-1?q=" + strings.Repeat("a", 600)
	a := feedActionOf(t, 0, "", `{"url":"`+longURL+`","label":"ACME-1"}`, `{}`)
	assert.NotContains(t, a.Result, "url")
	assert.Equal(t, "ACME-1", a.Result["label"])
	for _, bad := range []string{"not json", `[1,2]`, `"x"`} {
		assert.Nil(t, feedActionOf(t, 0, "", bad, `{}`).Result, bad)
	}
	raw := feedActionOf(t, 0, "", "", "not json")
	assert.Equal(t, "not json", raw.ArgsDisplay)
	assert.True(t, raw.ArgsComplete)
}

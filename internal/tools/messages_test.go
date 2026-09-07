package tools

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func messagesRegistry(t *testing.T, d *db.DB) *Registry {
	t.Helper()
	reg := New(d)
	require.NoError(t, reg.Register(NewListMessages()))
	return reg
}

func seedMessagesDB(t *testing.T) *db.DB {
	t.Helper()
	d := openDB(t)
	require.NoError(t, d.UpsertUser(db.User{ID: "U001", Name: "esaenko", DisplayName: "Женя Саенко"}))
	require.NoError(t, d.UpsertUser(db.User{ID: "U002", Name: "bogdan", DisplayName: "Богдан"}))
	require.NoError(t, d.UpsertMessage(db.Message{ChannelID: "C1", TS: "1700000001.0001", UserID: "U001", Text: "open questions for Cloudflare: latency and billing", Permalink: "https://slack/1", RawJSON: "{}"}))
	require.NoError(t, d.UpsertMessage(db.Message{ChannelID: "C1", TS: "1700000002.0001", UserID: "U002", Text: "unrelated chatter", RawJSON: "{}"}))
	require.NoError(t, d.UpsertMessage(db.Message{ChannelID: "C1", TS: "1700000003.0001", UserID: "U001", Text: "Cloudflare follow-up still open", Permalink: "https://slack/3", RawJSON: "{}"}))
	return d
}

// list_messages by person name resolves the name, returns that person's
// messages (rendered with a display name, not a raw id), and excludes others.
func TestListMessages_ByPersonName(t *testing.T) {
	d := seedMessagesDB(t)
	got := callReadString(t, messagesRegistry(t, d), "list_messages", `{"person":"Саенко"}`)
	assert.Contains(t, got, "open questions for Cloudflare")
	assert.Contains(t, got, "Cloudflare follow-up")
	assert.NotContains(t, got, "unrelated chatter")
	assert.Contains(t, got, "Женя Саенко")
	assert.NotContains(t, got, "U001", "sender must render as a name, not a raw id")
}

func TestListMessages_PersonPlusKeyword(t *testing.T) {
	d := seedMessagesDB(t)
	got := callReadString(t, messagesRegistry(t, d), "list_messages", `{"person":"Саенко","query":"billing"}`)
	assert.Contains(t, got, "latency and billing")
	assert.NotContains(t, got, "follow-up still open")
}

func TestListMessages_NoFilterErrors(t *testing.T) {
	_, err := messagesRegistry(t, seedMessagesDB(t)).CallRead(context.Background(), "list_messages", json.RawMessage(`{}`))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "at least one filter")
}

// A lowercase name starting with U (e.g. "Ulyana") is not mistaken for a Slack
// id — it goes down the name-resolution path and errors as unknown.
func TestListMessages_LowercaseNameNotTreatedAsID(t *testing.T) {
	_, err := messagesRegistry(t, seedMessagesDB(t)).CallRead(context.Background(), "list_messages", json.RawMessage(`{"person":"Ulyana"}`))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "no person matches")
}

func TestListMessages_UnknownPersonErrors(t *testing.T) {
	_, err := messagesRegistry(t, seedMessagesDB(t)).CallRead(context.Background(), "list_messages", json.RawMessage(`{"person":"Nonexistent Person"}`))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
}

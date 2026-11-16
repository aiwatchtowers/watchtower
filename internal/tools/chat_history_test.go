package tools

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func seedChatConversation(t *testing.T, d *db.DB, texts ...string) (int64, []int64) {
	t.Helper()
	res, err := d.Exec(`INSERT INTO chat_conversations (created_at, updated_at) VALUES (1, 1)`)
	require.NoError(t, err)
	conv, err := res.LastInsertId()
	require.NoError(t, err)
	var ids []int64
	for i, text := range texts {
		role := "user"
		if i%2 == 1 {
			role = "assistant"
		}
		r, err := d.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at) VALUES (?, ?, ?, ?)`,
			conv, role, text, float64(100+i))
		require.NoError(t, err)
		id, err := r.LastInsertId()
		require.NoError(t, err)
		ids = append(ids, id)
	}
	return conv, ids
}

func chatHistoryRegistry(t *testing.T, d *db.DB) *Registry {
	t.Helper()
	reg := New(d)
	for _, tool := range []*Tool{NewGetChatHistory(), NewListChatArtifacts(), NewGetChatArtifact()} {
		require.NoError(t, reg.Register(tool))
	}
	return reg
}

func callChatRead(t *testing.T, reg *Registry, name string, conv int64, args string) map[string]any {
	t.Helper()
	out, err := reg.CallRead(context.Background(), name, json.RawMessage(args), Binding{Surface: "main", ConversationID: conv})
	require.NoError(t, err)
	raw, err := json.Marshal(out)
	require.NoError(t, err)
	var m map[string]any
	require.NoError(t, json.Unmarshal(raw, &m))
	return m
}

func messageTexts(m map[string]any) []string {
	var out []string
	for _, x := range m["messages"].([]any) {
		out = append(out, x.(map[string]any)["text"].(string))
	}
	return out
}

func TestGetChatHistory_PagesBackOwnConversationOnly(t *testing.T) {
	d := openDB(t)
	reg := chatHistoryRegistry(t, d)
	conv, _ := seedChatConversation(t, d, "m0", "m1", "m2", "m3", "m4")
	other, _ := seedChatConversation(t, d, "secret of another chat")

	page := callChatRead(t, reg, "get_chat_history", conv, `{"limit":2}`)
	assert.Equal(t, []string{"m3", "m4"}, messageTexts(page))
	assert.Equal(t, true, page["has_more"])
	assert.EqualValues(t, 5, page["total"])

	before := int64(page["next_before"].(float64))
	page = callChatRead(t, reg, "get_chat_history", conv, `{"limit":2,"before":`+jsonInt(before)+`}`)
	assert.Equal(t, []string{"m1", "m2"}, messageTexts(page))

	page = callChatRead(t, reg, "get_chat_history", conv, `{"query":"M0"}`)
	assert.Equal(t, []string{"m0"}, messageTexts(page))
	assert.Equal(t, false, page["has_more"])

	page = callChatRead(t, reg, "get_chat_history", other, `{}`)
	assert.Equal(t, []string{"secret of another chat"}, messageTexts(page))
	for _, s := range messageTexts(callChatRead(t, reg, "get_chat_history", conv, `{"limit":50}`)) {
		assert.NotContains(t, s, "secret")
	}
}

func TestGetChatHistory_TruncatesLongMessages(t *testing.T) {
	d := openDB(t)
	reg := chatHistoryRegistry(t, d)
	conv, _ := seedChatConversation(t, d, strings.Repeat("я", 50))
	page := callChatRead(t, reg, "get_chat_history", conv, `{"max_chars":10}`)
	msg := page["messages"].([]any)[0].(map[string]any)
	assert.Equal(t, strings.Repeat("я", 10), msg["text"])
	assert.Equal(t, true, msg["truncated"])
	assert.EqualValues(t, 50, msg["chars"])
}

func TestChatHistory_RefusesWithoutConversation(t *testing.T) {
	d := openDB(t)
	reg := chatHistoryRegistry(t, d)
	for _, name := range []string{"get_chat_history", "list_chat_artifacts"} {
		_, err := reg.CallRead(context.Background(), name, json.RawMessage(`{}`), Binding{Surface: "main"})
		var ve *ValidationError
		require.ErrorAs(t, err, &ve, name)
	}
}

func TestChatArtifacts_ListLatestAndOpenVersions(t *testing.T) {
	d := openDB(t)
	reg := chatHistoryRegistry(t, d)
	conv, ids := seedChatConversation(t, d, "make a doc", "here it is", "fix it", "fixed")
	other, otherIDs := seedChatConversation(t, d, "x", "y")
	ins := func(c, msg int64, key string, version int, content string) {
		_, err := d.Exec(`INSERT INTO chat_artifacts (conversation_id, message_id, artifact_key, version, kind, title, content, created_at)
			VALUES (?, ?, ?, ?, 'document', 'Plan', ?, 1)`, c, msg, key, version, content)
		require.NoError(t, err)
	}
	ins(conv, ids[1], "plan", 1, "v1 body")
	ins(conv, ids[3], "plan", 2, "v2 body that is longer")
	ins(other, otherIDs[1], "foreign", 1, "not yours")

	list := callChatRead(t, reg, "list_chat_artifacts", conv, `{}`)
	arts := list["artifacts"].([]any)
	require.Len(t, arts, 1)
	a := arts[0].(map[string]any)
	assert.Equal(t, "plan", a["key"])
	assert.EqualValues(t, 2, a["version"])
	assert.EqualValues(t, 2, a["versions"])

	got := callChatRead(t, reg, "get_chat_artifact", conv, `{"key":"plan"}`)
	assert.Equal(t, "v2 body that is longer", got["content"])
	got = callChatRead(t, reg, "get_chat_artifact", conv, `{"key":"plan","version":1}`)
	assert.Equal(t, "v1 body", got["content"])
	got = callChatRead(t, reg, "get_chat_artifact", conv, `{"key":"plan","from_char":3,"max_chars":4}`)
	assert.Equal(t, "body", got["content"])
	assert.Equal(t, true, got["has_more"])
	assert.EqualValues(t, 7, got["next_from_char"])

	_, err := reg.CallRead(context.Background(), "get_chat_artifact", json.RawMessage(`{"key":"foreign"}`),
		Binding{Surface: "main", ConversationID: conv})
	var ve *ValidationError
	require.ErrorAs(t, err, &ve, "another chat's artifact must not open")
}

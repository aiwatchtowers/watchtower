package tools

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"unicode/utf8"

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
	conv, ids := seedChatConversation(t, d, "a", "b")
	_, err := d.Exec(`INSERT INTO chat_artifacts (conversation_id, message_id, artifact_key, version, kind, content, created_at)
		VALUES (?, ?, 'k', 1, 'document', 'c', 1)`, conv, ids[1])
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO chat_conversations (id, created_at, updated_at) VALUES (999, 1, 1)`)
	require.NoError(t, err)
	_, err = d.Exec(`DELETE FROM chat_conversations WHERE id = 999`)
	require.NoError(t, err)
	args := map[string]string{"get_chat_history": `{}`, "list_chat_artifacts": `{}`, "get_chat_artifact": `{"key":"k"}`}
	for name, a := range args {
		for _, b := range []Binding{{Surface: "main"}, {Surface: "main", ConversationID: 999}} {
			_, err := reg.CallRead(context.Background(), name, json.RawMessage(a), b)
			var ve *ValidationError
			require.ErrorAs(t, err, &ve, "%s on conversation %d", name, b.ConversationID)
		}
	}
}

// The newest page is cut by the encoded-byte budget, never by dropping a
// message mid-page, and the next page resumes where it stopped.
func TestGetChatHistory_ByteBudgetPagesWithoutLoss(t *testing.T) {
	d := openDB(t)
	reg := chatHistoryRegistry(t, d)
	big := strings.Repeat("<", 20000) // 120 000 encoded bytes each
	conv, ids := seedChatConversation(t, d, "old", big, big, big)
	page := callChatRead(t, reg, "get_chat_history", conv, `{"max_chars":30000}`)
	msgs := page["messages"].([]any)
	require.Len(t, msgs, 2)
	assert.EqualValues(t, ids[2], msgs[0].(map[string]any)["id"])
	assert.Equal(t, true, msgs[0].(map[string]any)["truncated"], "the older one is cut to the remaining budget")
	assert.Equal(t, false, msgs[1].(map[string]any)["truncated"])
	assert.EqualValues(t, ids[2], page["next_before"])
	page = callChatRead(t, reg, "get_chat_history", conv, `{"before":`+jsonInt(ids[2])+`}`)
	assert.Equal(t, []string{"old", strings.Repeat("<", 6000)}, messageTexts(page))
	assert.Equal(t, false, page["has_more"])
	_, hasNext := page["next_before"]
	assert.False(t, hasNext)
	assert.EqualValues(t, 2, page["matched"])
	assert.EqualValues(t, 4, page["total"])
}

// An abandoned branch (an edited-away message) stays out of the history.
func TestGetChatHistory_ActivePathOnly(t *testing.T) {
	d := openDB(t)
	reg := chatHistoryRegistry(t, d)
	conv, ids := seedChatConversation(t, d, "root", "answer")
	ins := func(parent int64, role, text string) int64 {
		r, err := d.Exec(`INSERT INTO chat_messages (conversation_id, parent_id, role, text, created_at) VALUES (?, ?, ?, ?, 1)`,
			conv, parent, role, text)
		require.NoError(t, err)
		id, err := r.LastInsertId()
		require.NoError(t, err)
		return id
	}
	_, err := d.Exec(`UPDATE chat_messages SET parent_id = ? WHERE id = ?`, ids[0], ids[1])
	require.NoError(t, err)
	ins(ids[1], "user", "abandoned question")
	leaf := ins(ids[1], "user", "kept question")
	_, err = d.Exec(`UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?`, leaf, conv)
	require.NoError(t, err)
	assert.Equal(t, []string{"root", "answer", "kept question"}, messageTexts(callChatRead(t, reg, "get_chat_history", conv, `{}`)))
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

	for args, want := range map[string]string{
		`{"key":"foreign"}`:             `no artifact "foreign"`,
		`{"key":"plan","version":3}`:    `has no version 3 (it has 2)`,
		`{"key":"plan","from_char":99}`: "past the end",
		`{"key":"  "}`:                  "key is required",
		`{"key":"plan","version":-1}`:   "must not be negative",
	} {
		_, err := reg.CallRead(context.Background(), "get_chat_artifact", json.RawMessage(args),
			Binding{Surface: "main", ConversationID: conv})
		var ve *ValidationError
		require.ErrorAs(t, err, &ve, args)
		assert.Contains(t, ve.Msg, want, args)
	}
}

// The attributes an email/slack/event/code artifact keeps outside its body
// come back, so a revision under the same key keeps them.
func TestGetChatArtifact_ReturnsMeta(t *testing.T) {
	d := openDB(t)
	reg := chatHistoryRegistry(t, d)
	conv, ids := seedChatConversation(t, d, "draft a mail", "here")
	_, err := d.Exec(`INSERT INTO chat_artifacts (conversation_id, message_id, artifact_key, version, kind, title, content, meta_json, edited, created_at)
		VALUES (?, ?, 'mail', 1, 'email', 'Hi', 'body', '{"to":["a@example.com"],"subject":"Hi"}', 1, 1)`, conv, ids[1])
	require.NoError(t, err)
	got := callChatRead(t, reg, "get_chat_artifact", conv, `{"key":"mail"}`)
	assert.Equal(t, map[string]any{"to": []any{"a@example.com"}, "subject": "Hi"}, got["meta"])
	assert.Equal(t, true, got["artifact"].(map[string]any)["edited_by_owner"])
}

// A default call on a large HTML artifact stays under READ-01's byte cap and
// pages instead of being refused.
func TestGetChatArtifact_HTMLStaysUnderByteCap(t *testing.T) {
	d := openDB(t)
	reg := chatHistoryRegistry(t, d)
	conv, ids := seedChatConversation(t, d, "page", "here")
	_, err := d.Exec(`INSERT INTO chat_artifacts (conversation_id, message_id, artifact_key, version, kind, content, created_at)
		VALUES (?, ?, 'p', 1, 'html', ?, 1)`, conv, ids[1], strings.Repeat("<b>&</b>", 20000))
	require.NoError(t, err)
	got := callChatRead(t, reg, "get_chat_artifact", conv, `{"key":"p","max_chars":50000}`)
	assert.Equal(t, true, got["has_more"])
	n := utf8.RuneCountInString(got["content"].(string))
	assert.Positive(t, n)
	assert.EqualValues(t, n, got["next_from_char"])
}

// The list keeps the most recently changed artifacts, in that order, and says
// when it left older ones out.
func TestListChatArtifacts_LimitKeepsRecent(t *testing.T) {
	d := openDB(t)
	reg := chatHistoryRegistry(t, d)
	conv, ids := seedChatConversation(t, d, "a", "b")
	for i, key := range []string{"a", "b", "c", "a"} {
		_, err := d.Exec(`INSERT INTO chat_artifacts (conversation_id, message_id, artifact_key, version, kind, content, created_at)
			VALUES (?, ?, ?, (SELECT COALESCE(MAX(version), 0) + 1 FROM chat_artifacts WHERE conversation_id = ? AND artifact_key = ?), 'document', 'я', ?)`,
			conv, ids[1], key, conv, key, i)
		require.NoError(t, err)
	}
	list := callChatRead(t, reg, "list_chat_artifacts", conv, `{"limit":2}`)
	var keys []string
	for _, a := range list["artifacts"].([]any) {
		keys = append(keys, a.(map[string]any)["key"].(string))
	}
	assert.Equal(t, []string{"c", "a"}, keys)
	assert.Equal(t, true, list["has_more"])
	all := callChatRead(t, reg, "list_chat_artifacts", conv, `{}`)
	assert.Len(t, all["artifacts"].([]any), 3)
	assert.Equal(t, false, all["has_more"])
}

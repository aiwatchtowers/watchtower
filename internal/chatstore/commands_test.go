package chatstore

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/tower"
	"watchtower/internal/tower/api"
)

// chatWritesFile is testdata/chat_writes.json, the golden the Swift chat
// writers were checked against until Task 18 deleted them; since the unified
// chat it covers the embedded chats' commands only.
type chatWritesFile struct {
	Cases []chatWriteCase `json:"cases"`
}

type chatWriteCase struct {
	Name    string          `json:"name"`
	Command string          `json:"command"`
	Swift   string          `json:"swift"`
	Seed    []string        `json:"seed"`
	Params  json.RawMessage `json:"params"`
	Refusal string          `json:"refusal"`
	Result  json.RawMessage `json:"result"`
	Check   []struct {
		SQL  string  `json:"sql"`
		Rows [][]any `json:"rows"`
	} `json:"check"`
}

var commandsNow = time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC)

func loadChatWrites(t *testing.T) []chatWriteCase {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "chat_writes.json"))
	require.NoError(t, err)
	var f chatWritesFile
	require.NoError(t, json.Unmarshal(b, &f))
	require.NotEmpty(t, f.Cases)
	return f.Cases
}

// chatTower is a tower over a fresh database with the chat commands.
func chatTower(t *testing.T) (*tower.Tower, *db.DB, *[][]string) {
	t.Helper()
	d := openDB(t)
	r := &tower.Registry{}
	RegisterCommands(r)
	var changed [][]string
	tw := tower.New(d, tower.Options{
		Registry: r,
		Now:      func() time.Time { return commandsNow },
		Changed:  func(tables []string) { changed = append(changed, tables) },
	})
	return tw, d, &changed
}

func callChat(t *testing.T, tw *tower.Tower, command, requestID string, params json.RawMessage, transport string) api.Response {
	t.Helper()
	p := map[string]any{}
	if len(params) > 0 {
		require.NoError(t, json.Unmarshal(params, &p))
	}
	p["request_id"] = requestID
	raw, err := json.Marshal(p)
	require.NoError(t, err)
	return tw.Call(context.Background(), api.Request{V: api.EnvelopeVersion, ID: "c", Command: command, Params: raw},
		tower.Origin{Transport: transport})
}

// rowsOf reads query's rows with every number as float64, as JSON decodes.
func rowsOf(t *testing.T, d *db.DB, query string) [][]any {
	t.Helper()
	rows, err := d.Query(query)
	require.NoError(t, err, query)
	defer rows.Close()
	cols, err := rows.Columns()
	require.NoError(t, err)
	out := [][]any{}
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		require.NoError(t, rows.Scan(ptrs...))
		for i, v := range vals {
			switch x := v.(type) {
			case int64:
				vals[i] = float64(x)
			case []byte:
				vals[i] = string(x)
			case bool:
				vals[i] = map[bool]float64{true: 1, false: 0}[x]
			}
		}
		out = append(out, vals)
	}
	require.NoError(t, rows.Err())
	return out
}

func TestChatWritesCases(t *testing.T) {
	for _, tc := range loadChatWrites(t) {
		t.Run(tc.Name, func(t *testing.T) {
			require.NotEmpty(t, tc.Swift, "every case names its Swift writer")
			tw, d, _ := chatTower(t)
			for _, s := range tc.Seed {
				_, err := d.Exec(s)
				require.NoError(t, err, s)
			}
			resp := callChat(t, tw, tc.Command, "req-"+tc.Name, tc.Params, "socket")
			if tc.Refusal != "" {
				require.Equal(t, api.StatusRefused, resp.Status, "result %s", resp.Result)
				require.NotNil(t, resp.Refusal)
				assert.Equal(t, api.RefusalCode(tc.Refusal), resp.Refusal.Code)
				assert.NotEmpty(t, resp.Refusal.Sentence)
			} else {
				require.Equal(t, api.StatusOK, resp.Status, "refusal %+v", resp.Refusal)
			}
			if len(tc.Result) > 0 {
				var want, got map[string]any
				require.NoError(t, json.Unmarshal(tc.Result, &want))
				require.NoError(t, json.Unmarshal(resp.Result, &got))
				for k, v := range want {
					assert.Equal(t, v, got[k], "result %s", k)
				}
			}
			for _, c := range tc.Check {
				want := c.Rows
				if want == nil {
					want = [][]any{}
				}
				assert.Equal(t, want, rowsOf(t, d, c.SQL), c.SQL)
			}
		})
	}
}

// chatCommandNames is every chat.* command; the fixture has a case for each.
var chatCommandNames = []string{
	"chat.code_question.delete_empty", "chat.context", "chat.delete", "chat.draft.clear", "chat.draft.save",
	"chat.message.append", "chat.new", "chat.reply.finish", "chat.reviewer_thread", "chat.set_model", "chat.set_title",
	"meetings.delete",
}

func TestChatCommands_RegisteredGuarded(t *testing.T) {
	r := &tower.Registry{}
	RegisterCommands(r)
	var names []string
	writeParams := reflect.TypeFor[api.WriteParams]()
	for _, c := range r.Commands() {
		names = append(names, c.Name)
		assert.False(t, c.Spec.Read, c.Name)
		assert.True(t, c.Spec.Idempotent, "%s is a guarded write", c.Name)
		assert.Equal(t, "chat", c.Spec.Grant, c.Name)
		assert.NotEmpty(t, c.Spec.ChangeTables, c.Name)
		f, ok := c.Req.FieldByName("WriteParams")
		assert.True(t, ok && f.Anonymous && f.Type == writeParams, "%s embeds WriteParams", c.Name)
	}
	assert.Equal(t, chatCommandNames, names)

	covered := map[string]bool{}
	for _, tc := range loadChatWrites(t) {
		covered[tc.Command] = true
	}
	var missing []string
	for _, n := range chatCommandNames {
		if !covered[n] {
			missing = append(missing, n)
		}
	}
	sort.Strings(missing)
	assert.Empty(t, missing, "commands with no chat_writes.json case")
}

// chat.delete removes an embedded chat's attachment folder after the
// commit; it deletes only a chat of the context type it names, and a main
// chat (no context type) is the chat engine's to delete.
func TestChatDelete_RemovesTheFolderOfAnEmbeddedChatOnly(t *testing.T) {
	tw, d, _ := chatTower(t)
	_, err := d.Exec(`INSERT INTO chat_conversations (id, title, created_at, updated_at) VALUES (1, 'A', 1, 1)`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO chat_conversations (id, title, context_type, context_id, created_at, updated_at) VALUES (2, 'T', 'target', '7', 1, 1)`)
	require.NoError(t, err)
	root := filesRoot(context.Background(), d)
	require.NotEmpty(t, root)
	dir := filepath.Join(root, filepath.FromSlash(ConversationDir(2)))
	require.NoError(t, os.MkdirAll(dir, 0o700))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "n.txt"), []byte("hello\n"), 0o600))

	resp := callChat(t, tw, "chat.delete", "d1", json.RawMessage(`{"conversation_id":2,"context_type":"track"}`), "socket")
	require.Equal(t, api.StatusRefused, resp.Status)
	assert.Equal(t, api.CodeNotFound, resp.Refusal.Code)
	assert.DirExists(t, dir)

	resp = callChat(t, tw, "chat.delete", "d2", json.RawMessage(`{"conversation_id":2,"context_type":"target"}`), "socket")
	require.Equal(t, api.StatusOK, resp.Status, "%+v", resp.Refusal)
	assert.NoDirExists(t, dir)

	resp = callChat(t, tw, "chat.delete", "d3", json.RawMessage(`{"conversation_id":1}`), "socket")
	require.Equal(t, api.StatusRefused, resp.Status)
	assert.Equal(t, api.CodeNotPermitted, resp.Refusal.Code)
	assert.Equal(t, [][]any{{1.0}}, rowsOf(t, d, `SELECT id FROM chat_conversations`))
}

// A resend of a done request answers the stored result and writes nothing.
func TestChatCommands_ResendAnswersTheStoredResult(t *testing.T) {
	tw, d, changed := chatTower(t)
	params := json.RawMessage(`{"context":{"type":"target","id":"7","title":"Plan"}}`)
	first := callChat(t, tw, "chat.new", "r1", params, "socket")
	require.Equal(t, api.StatusOK, first.Status)
	again := callChat(t, tw, "chat.new", "r1", params, "socket")
	require.Equal(t, api.StatusOK, again.Status)
	assert.JSONEq(t, string(first.Result), string(again.Result))
	assert.Equal(t, [][]any{{1.0}}, rowsOf(t, d, `SELECT COUNT(*) FROM chat_conversations`))
	assert.Equal(t, [][]string{{"chat_conversations"}}, *changed)
}

// meetings.delete removes the recording's audio file after the commit.
func TestMeetingsDelete_RemovesTheAudioFile(t *testing.T) {
	tw, d, _ := chatTower(t)
	audio := filepath.Join(t.TempDir(), "rec.m4a")
	require.NoError(t, os.WriteFile(audio, []byte("x"), 0o600))
	_, err := d.Exec(`INSERT INTO meeting_transcripts (id, title, audio_path, transcript_text) VALUES (1, 'Sync', ?, 'hello')`, audio)
	require.NoError(t, err)
	resp := callChat(t, tw, "meetings.delete", "m1", json.RawMessage(`{"transcript_id":1}`), "socket")
	require.Equal(t, api.StatusOK, resp.Status, "%+v", resp.Refusal)
	assert.NoFileExists(t, audio)
}

// TestEmbeddedWrites_RefusedForTheHubAndForTheMainChat: chat.reply.finish and
// chat.message.append serve the Mac's embedded chats only — the hub's `chat`
// grant cannot overwrite a reply or add a row, and no caller can write a
// main chat's rows through them (its session's alone). Review M3.
func TestEmbeddedWrites_RefusedForTheHubAndForTheMainChat(t *testing.T) {
	tw, d, _ := chatTower(t)
	for _, s := range []string{
		`INSERT INTO chat_conversations (id, title, context_type, context_id, created_at, updated_at) VALUES (1, 'Embedded', 'target', '7', 1, 1)`,
		`INSERT INTO chat_conversations (id, title, created_at, updated_at) VALUES (2, 'Main', 1, 1)`,
		`INSERT INTO chat_messages (id, conversation_id, role, text, created_at, turn_id, status) VALUES (5, 1, 'assistant', 'kept', 2, 't1', 'complete')`,
		`INSERT INTO chat_messages (id, conversation_id, role, text, created_at, turn_id, status) VALUES (6, 2, 'assistant', 'kept', 2, 't2', 'partial')`,
	} {
		_, err := d.Exec(s)
		require.NoError(t, err, s)
	}
	finish := func(conv, msg int) json.RawMessage {
		return json.RawMessage(fmt.Sprintf(`{"conversation_id":%d,"message_id":%d,"text":"overwritten","status":"complete"}`, conv, msg))
	}
	appendTo := func(conv int) json.RawMessage {
		return json.RawMessage(fmt.Sprintf(`{"conversation_id":%d,"role":"system","text":"injected"}`, conv))
	}
	for _, tc := range []struct {
		name, command, transport string
		params                   json.RawMessage
	}{
		{"hub finish", "chat.reply.finish", "hub", finish(1, 5)},
		{"hub append", "chat.message.append", "hub", appendTo(1)},
		{"main chat finish", "chat.reply.finish", "socket", finish(2, 6)},
		{"main chat append", "chat.message.append", "socket", appendTo(2)},
	} {
		resp := callChat(t, tw, tc.command, "req-"+tc.name, tc.params, tc.transport)
		require.Equal(t, api.StatusRefused, resp.Status, tc.name)
		assert.Equal(t, api.CodeNotPermitted, resp.Refusal.Code, tc.name)
		assert.NotEmpty(t, resp.Refusal.Sentence, tc.name)
	}
	assert.Equal(t, [][]any{{"kept", "complete"}, {"kept", "partial"}},
		rowsOf(t, d, `SELECT text, status FROM chat_messages ORDER BY id`), "no reply was overwritten")
	assert.Equal(t, [][]any{{2.0}}, rowsOf(t, d, `SELECT COUNT(*) FROM chat_messages`), "no row was added")
}

package chatstore

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/tower"
	"watchtower/internal/tower/api"
)

// chatWritesFile is testdata/chat_writes.json, read by the Swift
// ChatWritesFixtureTests too.
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
	"chat.archive", "chat.artifact.keep", "chat.artifact.save_edit", "chat.artifact.unkeep",
	"chat.attach", "chat.attach_delete", "chat.attach_link", "chat.branch",
	"chat.code_question.delete_empty", "chat.comment.add", "chat.comment.apply",
	"chat.comment.delete_unsent", "chat.comment.mark_sent", "chat.comment.resolve", "chat.context",
	"chat.delete", "chat.delete_untouched", "chat.draft.clear", "chat.draft.save", "chat.new", "chat.pin",
	"chat.project.add_source", "chat.project.archive", "chat.project.create", "chat.project.delete",
	"chat.project.instructions", "chat.project.remove_file", "chat.project.remove_source",
	"chat.project.rename", "chat.read", "chat.recover", "chat.release_launches", "chat.rename",
	"chat.reviewer_thread", "chat.set_model", "chat.set_project", "chat.set_routing", "chat.set_title",
	"chat.stop", "meetings.delete",
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

// A resend of a done request answers the stored result and writes nothing.
func TestChatCommands_ResendAnswersTheStoredResult(t *testing.T) {
	tw, d, changed := chatTower(t)
	first := callChat(t, tw, "chat.new", "r1", nil, "socket")
	require.Equal(t, api.StatusOK, first.Status)
	again := callChat(t, tw, "chat.new", "r1", nil, "socket")
	require.Equal(t, api.StatusOK, again.Status)
	assert.JSONEq(t, string(first.Result), string(again.Result))
	assert.Equal(t, [][]any{{1.0}}, rowsOf(t, d, `SELECT COUNT(*) FROM chat_conversations`))
	assert.Equal(t, [][]string{{"chat_conversations"}}, *changed)
}

func TestChatRecover_MarksSessionLostAndReleases(t *testing.T) {
	tw, d, _ := chatTower(t)
	for _, s := range []string{
		`INSERT INTO chat_conversations (id, title, created_at, updated_at) VALUES (1, 'A', 1, 1)`,
		`INSERT INTO chat_messages (id, conversation_id, role, text, created_at, turn_id) VALUES (1, 1, 'user', 'q', 2, 'T1')`,
		`INSERT INTO chat_messages (id, conversation_id, parent_id, role, text, created_at, turn_id, status) VALUES (2, 1, 1, 'assistant', 'half', 3, 'T1', 'partial')`,
		`INSERT INTO chat_messages (id, conversation_id, role, text, created_at, turn_id, status) VALUES (3, 1, 'assistant', 'old', 1, 'T0', 'partial')`,
		`INSERT INTO chat_turn_leases (conversation_id, owner, owner_id, turn_id, started_at_ms, heartbeat_at_ms) VALUES (1, 'desktop', 'L1', 'T1', 5, 5)`,
	} {
		_, err := d.Exec(s)
		require.NoError(t, err)
	}
	resp := callChat(t, tw, "chat.recover", "r1", json.RawMessage(`{"conversation_id":1,"turn_id":"T1"}`), "socket")
	require.Equal(t, api.StatusOK, resp.Status, "%+v", resp.Refusal)
	assert.JSONEq(t, `{"marked":1,"released":true}`, string(resp.Result))
	assert.Equal(t, [][]any{{2.0, "half", "partial", "session_lost"}, {3.0, "old", "partial", nil}},
		rowsOf(t, d, `SELECT id, text, status, error_code FROM chat_messages WHERE role = 'assistant' ORDER BY id`))
	assert.Equal(t, [][]any{{0.0}}, rowsOf(t, d, `SELECT COUNT(*) FROM chat_turn_leases`))

	// A later turn holds the lease now: a recover of the old turn leaves it
	// (its reply stays session_lost, marked again).
	_, err := d.Exec(`INSERT INTO chat_turn_leases (conversation_id, owner, owner_id, turn_id, started_at_ms, heartbeat_at_ms) VALUES (1, 'hub', 'H', 'T2', 5, 5)`)
	require.NoError(t, err)
	resp = callChat(t, tw, "chat.recover", "r2", json.RawMessage(`{"conversation_id":1,"turn_id":"T1"}`), "socket")
	require.Equal(t, api.StatusOK, resp.Status)
	assert.JSONEq(t, `{"marked":1,"released":false}`, string(resp.Result))
	assert.Equal(t, [][]any{{"hub", "T2"}}, rowsOf(t, d, `SELECT owner, turn_id FROM chat_turn_leases`))
}

func TestReleaseLaunches_KeepsTheCurrentLaunchAndNeverTouchesHubLeases(t *testing.T) {
	tw, d, _ := chatTower(t)
	for _, s := range []string{
		`INSERT INTO chat_conversations (id, title, created_at, updated_at) VALUES (1, 'A', 1, 1), (2, 'B', 1, 1), (3, 'C', 1, 1)`,
		`INSERT INTO chat_messages (id, conversation_id, role, text, created_at, turn_id, status) VALUES
			(1, 1, 'assistant', 'old launch', 1, 'T1', 'partial'),
			(2, 2, 'assistant', 'this launch', 1, 'T2', 'partial'),
			(3, 3, 'assistant', 'hub', 1, 'T3', 'partial')`,
		`INSERT INTO chat_turn_leases (conversation_id, owner, owner_id, turn_id, started_at_ms, heartbeat_at_ms) VALUES
			(1, 'desktop', 'L-old', 'T1', 5, 5), (2, 'desktop', 'L-now', 'T2', 5, 5), (3, 'hub', 'L-old', 'T3', 5, 5)`,
	} {
		_, err := d.Exec(s)
		require.NoError(t, err)
	}
	resp := callChat(t, tw, "chat.release_launches", "r1", json.RawMessage(`{"keep":"L-now"}`), "socket")
	require.Equal(t, api.StatusOK, resp.Status, "%+v", resp.Refusal)
	assert.JSONEq(t, `{"released":1}`, string(resp.Result))
	assert.Equal(t, [][]any{{2.0, "desktop", "L-now"}, {3.0, "hub", "L-old"}},
		rowsOf(t, d, `SELECT conversation_id, owner, owner_id FROM chat_turn_leases ORDER BY conversation_id`))
	assert.Equal(t, [][]any{{1.0, "session_lost"}, {2.0, nil}, {3.0, nil}},
		rowsOf(t, d, `SELECT id, error_code FROM chat_messages ORDER BY id`))
}

// chat.delete removes the conversation's attachment folder after the
// commit; a main-chat delete never takes an embedded chat.
func TestChatDelete_RemovesTheFolderAndKeepsEmbeddedChats(t *testing.T) {
	tw, d, _ := chatTower(t)
	_, err := d.Exec(`INSERT INTO chat_conversations (id, title, created_at, updated_at) VALUES (1, 'A', 1, 1)`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO chat_conversations (id, title, context_type, context_id, created_at, updated_at) VALUES (2, 'T', 'target', '7', 1, 1)`)
	require.NoError(t, err)
	resp := callChat(t, tw, "chat.attach", "a1", json.RawMessage(`{"conversation_id":1,"name":"n.txt","data_base64":"aGVsbG8K"}`), "socket")
	require.Equal(t, api.StatusOK, resp.Status, "%+v", resp.Refusal)
	var att api.ChatAttachResponse
	require.NoError(t, json.Unmarshal(resp.Result, &att))
	require.FileExists(t, att.Path)
	data, err := os.ReadFile(att.Path)
	require.NoError(t, err)
	assert.Equal(t, "hello\n", string(data))

	resp = callChat(t, tw, "chat.delete", "d1", json.RawMessage(`{"conversation_id":1}`), "socket")
	require.Equal(t, api.StatusOK, resp.Status)
	assert.NoDirExists(t, filepath.Dir(att.Path))

	resp = callChat(t, tw, "chat.delete", "d2", json.RawMessage(`{"conversation_id":2}`), "socket")
	require.Equal(t, api.StatusRefused, resp.Status)
	assert.Equal(t, api.CodeNotFound, resp.Refusal.Code)
	assert.Equal(t, [][]any{{2.0}}, rowsOf(t, d, `SELECT id FROM chat_conversations`))
}

// A path attachment is read only over the daemon socket: a hub caller (the
// phone) never makes the Mac read a local file.
func TestChatAttach_PathOnlyOverTheSocket(t *testing.T) {
	tw, d, _ := chatTower(t)
	_, err := d.Exec(`INSERT INTO chat_conversations (id, title, created_at, updated_at) VALUES (1, 'A', 1, 1)`)
	require.NoError(t, err)
	src := filepath.Join(t.TempDir(), "notes.md")
	require.NoError(t, os.WriteFile(src, []byte("# hi\n"), 0o600))
	params := json.RawMessage(`{"conversation_id":1,"name":"notes.md","path":` + strings.TrimSpace(mustJSON(t, src)) + `}`)

	resp := callChat(t, tw, "chat.attach", "h1", params, "hub")
	require.Equal(t, api.StatusRefused, resp.Status)
	assert.Equal(t, api.CodeNotPermitted, resp.Refusal.Code)
	assert.Equal(t, [][]any{{0.0}}, rowsOf(t, d, `SELECT COUNT(*) FROM chat_attachments`))

	resp = callChat(t, tw, "chat.attach", "s1", params, "socket")
	require.Equal(t, api.StatusOK, resp.Status, "%+v", resp.Refusal)
	assert.Equal(t, [][]any{{"notes.md", "text/markdown", 5.0}}, rowsOf(t, d, `SELECT name, mime, size FROM chat_attachments`))
}

// A rejected file (too big, wrong kind) is refused with the Mac's sentence.
func TestChatAttach_RejectionIsRefused(t *testing.T) {
	tw, d, _ := chatTower(t)
	_, err := d.Exec(`INSERT INTO chat_conversations (id, title, created_at, updated_at) VALUES (1, 'A', 1, 1)`)
	require.NoError(t, err)
	resp := callChat(t, tw, "chat.attach", "x1", json.RawMessage(`{"conversation_id":1,"name":"a.exe","data_base64":"AAEC"}`), "socket")
	require.Equal(t, api.StatusRefused, resp.Status)
	assert.Equal(t, api.CodeUnsupported, resp.Refusal.Code)
	assert.NotEmpty(t, resp.Refusal.Sentence)
}

// Deleting a project removes its files from disk after the commit.
func TestChatProjectDelete_RemovesItsFiles(t *testing.T) {
	tw, d, _ := chatTower(t)
	_, err := d.Exec(`INSERT INTO chat_projects (id, name, created_at, updated_at) VALUES (5, 'Alpha', 1, 1)`)
	require.NoError(t, err)
	resp := callChat(t, tw, "chat.attach", "a1", json.RawMessage(`{"project_id":5,"name":"n.txt","data_base64":"aGVsbG8K"}`), "socket")
	require.Equal(t, api.StatusOK, resp.Status, "%+v", resp.Refusal)
	var att api.ChatAttachResponse
	require.NoError(t, json.Unmarshal(resp.Result, &att))
	require.FileExists(t, att.Path)

	resp = callChat(t, tw, "chat.project.delete", "p1", json.RawMessage(`{"project_id":5}`), "socket")
	require.Equal(t, api.StatusOK, resp.Status)
	assert.NoFileExists(t, att.Path)
}

func mustJSON(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	require.NoError(t, err)
	return string(b)
}

// release_launches frees the Mac's own leases: a hub caller (the phone) is
// refused, and so is an empty keep (it would free this launch's leases).
func TestReleaseLaunches_MacOnlyAndNeedsKeep(t *testing.T) {
	tw, d, _ := chatTower(t)
	_, err := d.Exec(`INSERT INTO chat_conversations (id, title, created_at, updated_at) VALUES (1, 'A', 1, 1)`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO chat_turn_leases (conversation_id, owner, owner_id, turn_id, started_at_ms, heartbeat_at_ms) VALUES (1, 'desktop', 'L1', 'T1', 5, 5)`)
	require.NoError(t, err)
	resp := callChat(t, tw, "chat.release_launches", "h1", json.RawMessage(`{"keep":"other"}`), "hub")
	require.Equal(t, api.StatusRefused, resp.Status)
	assert.Equal(t, api.CodeNotPermitted, resp.Refusal.Code)
	resp = callChat(t, tw, "chat.release_launches", "s1", json.RawMessage(`{"keep":""}`), "socket")
	require.Equal(t, api.StatusRefused, resp.Status)
	assert.Equal(t, api.CodeUnsupported, resp.Refusal.Code)
	assert.Equal(t, [][]any{{1.0}}, rowsOf(t, d, `SELECT COUNT(*) FROM chat_turn_leases`))
}

// A hub caller's attach answer carries no Mac path.
func TestChatAttach_NoPathForTheHub(t *testing.T) {
	tw, d, _ := chatTower(t)
	_, err := d.Exec(`INSERT INTO chat_conversations (id, title, created_at, updated_at) VALUES (1, 'A', 1, 1)`)
	require.NoError(t, err)
	resp := callChat(t, tw, "chat.attach", "h1", json.RawMessage(`{"conversation_id":1,"name":"n.txt","data_base64":"aGVsbG8K"}`), "hub")
	require.Equal(t, api.StatusOK, resp.Status, "%+v", resp.Refusal)
	var att api.ChatAttachResponse
	require.NoError(t, json.Unmarshal(resp.Result, &att))
	assert.Empty(t, att.Path)
	assert.Positive(t, att.AttachmentID)
}

// A bad source kind is refused, not a constraint fault.
func TestChatProjectAddSource_RefusesAnUnknownKind(t *testing.T) {
	tw, d, _ := chatTower(t)
	_, err := d.Exec(`INSERT INTO chat_projects (id, name, created_at, updated_at) VALUES (5, 'Alpha', 1, 1)`)
	require.NoError(t, err)
	resp := callChat(t, tw, "chat.project.add_source", "k1", json.RawMessage(`{"project_id":5,"kind":"wiki","ref":"x","label":"x"}`), "socket")
	require.Equal(t, api.StatusRefused, resp.Status)
	assert.Equal(t, api.CodeUnsupported, resp.Refusal.Code)
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

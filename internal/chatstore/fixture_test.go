package chatstore

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat"
	"watchtower/internal/db"
)

// The shared fixture's shape (testdata/chat_turn_cases.json), read by the
// Swift ChatTurnStoreFixtureTests too. Message, step, artifact and
// attachment rows name each other by ref; the rows Start writes are
// "new_user", "new_assistant" and "placeholder" (an empty reply under a
// legacy unanswered owner question), mapped to ids by position.
type fixtureFile struct {
	Turns       []turnCase        `json:"turns"`
	SaveVersion []saveVersionCase `json:"save_version"`
}

type fixtureConv struct {
	Title          *string `json:"title"`
	TitleSource    string  `json:"title_source"`
	RoutingMode    string  `json:"routing_mode"`
	Provider       *string `json:"provider"`
	Model          *string `json:"model"`
	ActualProvider string  `json:"actual_provider"`
	ActualModel    string  `json:"actual_model"`
	RoutingReason  string  `json:"routing_reason"`
	SessionID      *string `json:"session_id"`
	ActiveLeaf     *string `json:"active_leaf"`
	LiveSlackSince *string `json:"live_slack_since"`
}

type fixtureMsg struct {
	Ref          string   `json:"ref"`
	Role         string   `json:"role"`
	Text         string   `json:"text"`
	Parent       *string  `json:"parent"`
	Status       string   `json:"status"`
	TurnID       string   `json:"turn_id"`
	Provider     *string  `json:"provider"`
	Model        *string  `json:"model"`
	TokensIn     *int64   `json:"tokens_in"`
	TokensOut    *int64   `json:"tokens_out"`
	ErrorCode    *string  `json:"error_code"`
	ErrorMessage *string  `json:"error_message"`
	CreatedAt    *float64 `json:"created_at"`
}

type fixtureArtifact struct {
	Key     string            `json:"key"`
	Version int               `json:"version"`
	Message string            `json:"message"`
	Kind    string            `json:"kind"`
	Title   string            `json:"title"`
	Content string            `json:"content"`
	Meta    map[string]string `json:"meta"`
	Edited  bool              `json:"edited"`
}

type fixtureAttachment struct {
	Ref     string  `json:"ref"`
	Name    string  `json:"name"`
	Mime    string  `json:"mime"`
	Path    string  `json:"path"`
	Message *string `json:"message"`
}

type fixtureAction struct {
	ID           int64
	Tool, Status string
	CreatedAt    string `json:"created_at"`
	DecidedAt    string `json:"decided_at"`
	AppliedAt    string `json:"applied_at"`
	ResultJSON   string `json:"result_json"`
	Error        string
}

type fixtureStep struct {
	Message string          `json:"message"`
	Seq     int             `json:"seq"`
	ToolID  string          `json:"tool_id"`
	Name    string          `json:"name"`
	Args    json.RawMessage `json:"args"`
	OK      *bool           `json:"ok"`
	Summary string          `json:"summary"`
	Sources json.RawMessage `json:"sources"`
	Ended   bool            `json:"ended"`
}

type turnCase struct {
	Name         string              `json:"name"`
	Conversation fixtureConv         `json:"conversation"`
	Messages     []fixtureMsg        `json:"messages"`
	ActiveLeaf   *string             `json:"active_leaf"`
	Artifacts    []fixtureArtifact   `json:"artifacts"`
	Attachments  []fixtureAttachment `json:"attachments"`
	Actions      []fixtureAction     `json:"actions"`
	Request      struct {
		Mode        string   `json:"mode"`
		Message     *string  `json:"message"`
		Text        string   `json:"text"`
		Attachments []string `json:"attachments"`
		TurnID      string   `json:"turn_id"`
		Routing     *struct {
			Automatic       bool
			Provider, Model string
		} `json:"routing"`
		ContinuousLeaf *string `json:"continuous_leaf"`
	} `json:"request"`
	Events []json.RawMessage `json:"events"`
	Expect struct {
		SendText        string             `json:"send_text"`
		Replay          bool               `json:"replay"`
		AttachmentsSent []string           `json:"attachments_sent"`
		Messages        []fixtureMsg       `json:"messages"`
		Steps           []fixtureStep      `json:"steps"`
		Artifacts       []fixtureArtifact  `json:"artifacts"`
		AttachmentLinks map[string]*string `json:"attachment_links"`
		Conversation    fixtureConv        `json:"conversation"`
		Lease           *db.ChatLease      `json:"lease"`
	} `json:"expect"`
}

type saveVersionCase struct {
	Name     string `json:"name"`
	Existing []struct {
		Key     string `json:"key"`
		Version int    `json:"version"`
		Message int64  `json:"message"`
		Title   string `json:"title"`
		Content string `json:"content"`
		Edited  bool   `json:"edited"`
	} `json:"existing"`
	Message int64 `json:"message"`
	Draft   struct {
		Key, Kind, Title, Content string
		Meta                      map[string]string
	} `json:"draft"`
	Expect []struct {
		Key     string            `json:"key"`
		Version int               `json:"version"`
		Message int64             `json:"message"`
		Title   string            `json:"title"`
		Content string            `json:"content"`
		Meta    map[string]string `json:"meta"`
		Edited  bool              `json:"edited"`
	} `json:"expect"`
}

func loadFixture(t *testing.T) fixtureFile {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "chat_turn_cases.json"))
	require.NoError(t, err)
	var f fixtureFile
	require.NoError(t, json.Unmarshal(raw, &f))
	return f
}

// fakeClock is the test's clock: it moves only when the test advances it.
type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time          { return c.t }
func (c *fakeClock) advance(d time.Duration) { c.t = c.t.Add(d) }
func newClock() *fakeClock                   { return &fakeClock{t: time.Unix(1_800_000_000, 0)} }

func openDB(t *testing.T) *db.DB {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "w.db"))
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	return d
}

func strOrNull(p *string) any {
	if p == nil {
		return nil
	}
	return *p
}

// seedTree writes a case's starting tree and returns its conversation id and
// the ids of its refs.
func seedTree(t *testing.T, d *db.DB, tc turnCase) (int64, map[string]int64) {
	t.Helper()
	c := tc.Conversation
	title := ""
	if c.Title != nil {
		title = *c.Title
	}
	res, err := d.Exec(`INSERT INTO chat_conversations (title, title_source, routing_mode, provider, model, actual_provider,
		actual_model, routing_reason, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, 1)`,
		title, c.TitleSource, c.RoutingMode, strOrNull(c.Provider), strOrNull(c.Model), c.ActualProvider, c.ActualModel, c.RoutingReason)
	require.NoError(t, err)
	conv, err := res.LastInsertId()
	require.NoError(t, err)
	ids := map[string]int64{}
	for i, m := range tc.Messages {
		var parent any
		if m.Parent != nil {
			parent = ids[*m.Parent]
		}
		created := 1_700_000_000 + float64(i)
		if m.CreatedAt != nil {
			created = *m.CreatedAt
		}
		res, err := d.Exec(`INSERT INTO chat_messages (conversation_id, parent_id, role, text, created_at, turn_id, status, provider, model, error_code)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, conv, parent, m.Role, m.Text, created, m.TurnID, m.Status,
			strOrNull(m.Provider), strOrNull(m.Model), strOrNull(m.ErrorCode))
		require.NoError(t, err)
		ids[m.Ref], err = res.LastInsertId()
		require.NoError(t, err)
	}
	if tc.ActiveLeaf != nil {
		_, err := d.Exec(`UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?`, ids[*tc.ActiveLeaf], conv)
		require.NoError(t, err)
	}
	for _, a := range tc.Artifacts {
		meta, err := metaJSON(a.Meta)
		require.NoError(t, err)
		_, err = d.Exec(`INSERT INTO chat_artifacts (conversation_id, message_id, artifact_key, version, kind, title, content, meta_json, edited, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1)`, conv, ids[a.Message], a.Key, a.Version, a.Kind, a.Title, a.Content, meta, a.Edited)
		require.NoError(t, err)
	}
	for _, f := range tc.Attachments {
		var msg any
		if f.Message != nil {
			msg = ids[*f.Message]
		}
		res, err := d.Exec(`INSERT INTO chat_attachments (conversation_id, message_id, name, mime, size, path, sha256, created_at)
			VALUES (?, ?, ?, ?, 1, ?, 'sha', 1)`, conv, msg, f.Name, f.Mime, f.Path)
		require.NoError(t, err)
		ids[f.Ref], err = res.LastInsertId()
		require.NoError(t, err)
	}
	for _, a := range tc.Actions {
		_, err := d.Exec(`INSERT INTO agent_actions (id, tool, args_json, conversation_id, status, result_json, error, created_at, decided_at, applied_at)
			VALUES (?, ?, '{}', ?, ?, ?, ?, ?, ?, ?)`, a.ID, a.Tool, conv, a.Status, a.ResultJSON, a.Error, a.CreatedAt, a.DecidedAt, a.AppliedAt)
		require.NoError(t, err)
	}
	return conv, ids
}

// runEvents drives the events through Apply (and Finalize for "stop", the
// Mac driver's finishRunningAsPartial), advancing the clock as asked.
func runEvents(t *testing.T, turn *Turn, clock *fakeClock, events []json.RawMessage) {
	t.Helper()
	for _, raw := range events {
		var meta struct {
			Type      string `json:"type"`
			AdvanceMS int64  `json:"advance_ms"`
		}
		require.NoError(t, json.Unmarshal(raw, &meta))
		clock.advance(time.Duration(meta.AdvanceMS) * time.Millisecond)
		if meta.Type == "stop" {
			require.NoError(t, turn.Finalize(StatusPartial, nil))
			continue
		}
		var ev chat.Event
		require.NoError(t, json.Unmarshal(raw, &ev))
		require.NoError(t, turn.Apply(ev))
	}
}

// TestChatstore_MatchesSwiftFixture runs every turn case through Start, the
// events and the end, and compares the rows with what the Swift write path
// leaves (ChatTurnStoreFixtureTests runs the same file).
func TestChatstore_MatchesSwiftFixture(t *testing.T) {
	f := loadFixture(t)
	require.GreaterOrEqual(t, len(f.Turns), 10)
	for _, tc := range f.Turns {
		t.Run(tc.Name, func(t *testing.T) {
			d := openDB(t)
			conv, ids := seedTree(t, d, tc)
			clock := newClock()
			s := New(d, db.ChatLeaseHub, "hub-1", WithClock(clock.now), WithPreferredProvider("claude"))
			r := StartRequest{ConversationID: conv, Mode: tc.Request.Mode, Text: tc.Request.Text, TurnID: tc.Request.TurnID}
			if tc.Request.Message != nil {
				r.MessageID = ids[*tc.Request.Message]
			}
			for _, ref := range tc.Request.Attachments {
				r.AttachmentIDs = append(r.AttachmentIDs, ids[ref])
			}
			if rt := tc.Request.Routing; rt != nil {
				r.Routing = &Routing{Automatic: rt.Automatic, Provider: rt.Provider, Model: rt.Model}
			}
			if tc.Request.ContinuousLeaf != nil {
				leaf := ids[*tc.Request.ContinuousLeaf]
				r.ContinuousLeafID = &leaf
			}
			st, err := s.Start(context.Background(), r)
			require.NoError(t, err)
			assert.Equal(t, tc.Expect.SendText, st.SendText)
			assert.Equal(t, tc.Expect.Replay, st.Replay)
			var sent []string
			for _, a := range st.Attachments {
				for _, fa := range tc.Attachments {
					if fa.Path == a.Path {
						sent = append(sent, fa.Ref)
					}
				}
			}
			assert.Equal(t, tc.Expect.AttachmentsSent, append([]string{}, sent...))

			runEvents(t, s.Turn(st), clock, tc.Events)
			checkRows(t, d, conv, ids, tc)
		})
	}
}

func checkRows(t *testing.T, d *db.DB, conv int64, ids map[string]int64, tc turnCase) {
	t.Helper()
	refOf := map[int64]string{}
	for _, m := range tc.Messages { // attachment ids live in another table and may repeat a message id
		refOf[ids[m.Ref]] = m.Ref
	}
	rows, err := d.Query(`SELECT id, role, text, parent_id, status, turn_id, provider, model, tokens_in, tokens_out, error_code, error_message
		FROM chat_messages WHERE conversation_id = ? ORDER BY id`, conv)
	require.NoError(t, err)
	defer rows.Close()
	type got struct {
		id                     int64
		role, text, status, tu string
		parent                 sql.NullInt64
		provider, model        sql.NullString
		in, out                sql.NullInt64
		code, msg              sql.NullString
	}
	var all []got
	for rows.Next() {
		var g got
		require.NoError(t, rows.Scan(&g.id, &g.role, &g.text, &g.parent, &g.status, &g.tu, &g.provider, &g.model, &g.in, &g.out, &g.code, &g.msg))
		all = append(all, g)
	}
	require.NoError(t, rows.Err())
	require.Len(t, all, len(tc.Expect.Messages), "message rows")
	for i, w := range tc.Expect.Messages {
		refOf[all[i].id] = w.Ref
	}
	ns := func(s sql.NullString) *string {
		if !s.Valid {
			return nil
		}
		return &s.String
	}
	ni := func(n sql.NullInt64) *int64 {
		if !n.Valid {
			return nil
		}
		return &n.Int64
	}
	for i, w := range tc.Expect.Messages {
		g := all[i]
		var parent *string
		if g.parent.Valid {
			p := refOf[g.parent.Int64]
			parent = &p
		}
		assert.Equal(t, fixtureMsg{Ref: w.Ref, Role: w.Role, Text: w.Text, Parent: w.Parent, Status: w.Status, TurnID: w.TurnID,
			Provider: w.Provider, Model: w.Model, TokensIn: w.TokensIn, TokensOut: w.TokensOut, ErrorCode: w.ErrorCode, ErrorMessage: w.ErrorMessage},
			fixtureMsg{Ref: w.Ref, Role: g.role, Text: g.text, Parent: parent, Status: g.status, TurnID: g.tu,
				Provider: ns(g.provider), Model: ns(g.model), TokensIn: ni(g.in), TokensOut: ni(g.out), ErrorCode: ns(g.code), ErrorMessage: ns(g.msg)},
			"message %s", w.Ref)
	}

	// Steps, in message then seq order.
	srows, err := d.Query(`SELECT s.message_id, s.seq, s.tool_id, s.name, s.args_json, s.ok, s.summary, s.sources_json, s.ended_at
		FROM chat_turn_steps s JOIN chat_messages m ON m.id = s.message_id WHERE m.conversation_id = ? ORDER BY s.message_id, s.seq, s.id`, conv)
	require.NoError(t, err)
	defer srows.Close()
	var steps []fixtureStep
	for srows.Next() {
		var msg int64
		var s fixtureStep
		var args, sources string
		var ok sql.NullInt64
		var ended sql.NullFloat64
		require.NoError(t, srows.Scan(&msg, &s.Seq, &s.ToolID, &s.Name, &args, &ok, &s.Summary, &sources, &ended))
		s.Message = refOf[msg]
		s.Args, s.Sources = normJSON(t, args), normJSON(t, sources)
		if ok.Valid {
			b := ok.Int64 == 1
			s.OK = &b
		}
		s.Ended = ended.Valid
		steps = append(steps, s)
	}
	require.NoError(t, srows.Err())
	want := make([]fixtureStep, 0, len(tc.Expect.Steps))
	for _, s := range tc.Expect.Steps {
		s.Args, s.Sources = normJSON(t, string(s.Args)), normJSON(t, string(s.Sources))
		want = append(want, s)
	}
	assert.Equal(t, want, append([]fixtureStep{}, steps...), "steps")

	// Artifacts, by key then version.
	arows, err := d.Query(`SELECT artifact_key, version, message_id, kind, title, content, meta_json, edited FROM chat_artifacts
		WHERE conversation_id = ? ORDER BY artifact_key, version`, conv)
	require.NoError(t, err)
	defer arows.Close()
	var arts []fixtureArtifact
	for arows.Next() {
		var a fixtureArtifact
		var msg int64
		var meta string
		require.NoError(t, arows.Scan(&a.Key, &a.Version, &msg, &a.Kind, &a.Title, &a.Content, &meta, &a.Edited))
		a.Message = refOf[msg]
		require.NoError(t, json.Unmarshal([]byte(meta), &a.Meta))
		arts = append(arts, a)
	}
	require.NoError(t, arows.Err())
	wantArts := append([]fixtureArtifact{}, tc.Expect.Artifacts...)
	sort.SliceStable(wantArts, func(i, j int) bool {
		if wantArts[i].Key != wantArts[j].Key {
			return wantArts[i].Key < wantArts[j].Key
		}
		return wantArts[i].Version < wantArts[j].Version
	})
	for i := range wantArts {
		if wantArts[i].Meta == nil {
			wantArts[i].Meta = map[string]string{}
		}
	}
	assert.Equal(t, wantArts, append([]fixtureArtifact{}, arts...), "artifacts")

	for ref, wantMsg := range tc.Expect.AttachmentLinks {
		var msg sql.NullInt64
		require.NoError(t, d.QueryRow(`SELECT message_id FROM chat_attachments WHERE id = ?`, ids[ref]).Scan(&msg))
		var gotRef *string
		if msg.Valid {
			r := refOf[msg.Int64]
			gotRef = &r
		}
		assert.Equal(t, wantMsg, gotRef, "attachment %s", ref)
	}

	var c fixtureConv
	var title string
	var provider, model, session sql.NullString
	var leaf, live sql.NullInt64
	require.NoError(t, d.QueryRow(`SELECT title, title_source, routing_mode, provider, model, actual_provider, actual_model,
		routing_reason, session_id, active_leaf_message_id, live_slack_since FROM chat_conversations WHERE id = ?`, conv).
		Scan(&title, &c.TitleSource, &c.RoutingMode, &provider, &model, &c.ActualProvider, &c.ActualModel, &c.RoutingReason,
			&session, &leaf, &live))
	c.Title, c.Provider, c.Model, c.SessionID = &title, ns(provider), ns(model), ns(session)
	refPtr := func(n sql.NullInt64) *string {
		if !n.Valid {
			return nil
		}
		r := refOf[n.Int64]
		return &r
	}
	c.ActiveLeaf, c.LiveSlackSince = refPtr(leaf), refPtr(live)
	assert.Equal(t, tc.Expect.Conversation, c, "conversation")

	lease, err := d.GetChatLease(conv)
	require.NoError(t, err)
	assert.Equal(t, tc.Expect.Lease, lease, "lease")
}

// normJSON re-encodes a JSON text so key order and spacing never matter.
func normJSON(t *testing.T, s string) json.RawMessage {
	t.Helper()
	if strings.TrimSpace(s) == "" {
		return nil
	}
	var v any
	require.NoError(t, json.Unmarshal([]byte(s), &v))
	b, err := json.Marshal(v)
	require.NoError(t, err)
	return b
}

// TestChatstore_SaveVersionMatchesSwiftFixture pins the saveVersion rule
// (overwrite the same message's unedited latest version, else MAX+1).
func TestChatstore_SaveVersionMatchesSwiftFixture(t *testing.T) {
	f := loadFixture(t)
	require.NotEmpty(t, f.SaveVersion)
	for _, tc := range f.SaveVersion {
		t.Run(tc.Name, func(t *testing.T) {
			d := openDB(t)
			res, err := d.Exec(`INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 1, 1)`)
			require.NoError(t, err)
			conv, _ := res.LastInsertId()
			for i := 0; i < 2; i++ {
				_, err := d.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at) VALUES (?, 'assistant', '', 1)`, conv)
				require.NoError(t, err)
			}
			for _, a := range tc.Existing {
				_, err := d.Exec(`INSERT INTO chat_artifacts (conversation_id, message_id, artifact_key, version, kind, title, content, edited, created_at)
					VALUES (?, ?, ?, ?, 'document', ?, ?, ?, 1)`, conv, a.Message, a.Key, a.Version, a.Title, a.Content, a.Edited)
				require.NoError(t, err)
			}
			dr := tc.Draft
			require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
				return saveArtifactVersionTx(tx, conv, tc.Message,
					ParsedArtifact{Key: dr.Key, Kind: dr.Kind, Title: dr.Title, Content: dr.Content, Meta: dr.Meta}, 2)
			}))
			rows, err := d.Query(`SELECT artifact_key, version, message_id, title, content, meta_json, edited FROM chat_artifacts
				WHERE conversation_id = ? ORDER BY artifact_key, version`, conv)
			require.NoError(t, err)
			defer rows.Close()
			n := 0
			for rows.Next() {
				require.Less(t, n, len(tc.Expect))
				w := tc.Expect[n]
				var key, title, content, meta string
				var version int
				var msg int64
				var edited bool
				require.NoError(t, rows.Scan(&key, &version, &msg, &title, &content, &meta, &edited))
				var gotMeta map[string]string
				require.NoError(t, json.Unmarshal([]byte(meta), &gotMeta))
				if w.Meta == nil {
					w.Meta = map[string]string{}
				}
				assert.Equal(t, []any{w.Key, w.Version, w.Message, w.Title, w.Content, w.Meta, w.Edited},
					[]any{key, version, msg, title, content, gotMeta, edited})
				n++
			}
			assert.Equal(t, len(tc.Expect), n)
		})
	}
}

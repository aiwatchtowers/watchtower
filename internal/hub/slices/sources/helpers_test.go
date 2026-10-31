package sources

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/gittest"
	hubslices "watchtower/internal/hub/slices"
)

// TestMain installs the db schema template cache before running tests.
// Without it, every db.Open(":memory:") call runs the full goose migration
// suite which under -race exceeds Go's 10-minute test timeout on CI.
func TestMain(m *testing.M) {
	gittest.DisableBackgroundGit()
	if err := db.InitTestTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}

// neverPublishedKeys are the raw columns no slice may carry (spec §4).
var neverPublishedKeys = []string{"folder_path", "claude_session_id", "agent_turn_end", "agent_tool_run"}

// dbStamp is the database's UTC `YYYY-MM-DDTHH:MM:SSZ` datetime.
func dbStamp(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05Z") }

func exec(t *testing.T, d *db.DB, q string, args ...any) sql.Result {
	t.Helper()
	res, err := d.Exec(q, args...)
	if err != nil {
		t.Fatalf("%s: %v", q, err)
	}
	return res
}

func lastID(t *testing.T, res sql.Result) int64 {
	t.Helper()
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	return id
}

// The seed helpers are the Swift TestDatabase / SliceSeed fixtures.

func insertWorkbench(t *testing.T, d *db.DB, name, folder string) int64 {
	t.Helper()
	return lastID(t, exec(t, d, `INSERT INTO projects (name, folder_path) VALUES (?, ?)`, name, folder))
}

type targetSeed struct {
	text, status, priority string
	parent                 *int64
}

func insertTarget(t *testing.T, d *db.DB, project int64, s targetSeed) int64 {
	t.Helper()
	if s.text == "" {
		s.text = "Feature"
	}
	if s.status == "" {
		s.status = "todo"
	}
	if s.priority == "" {
		s.priority = "medium"
	}
	return lastID(t, exec(t, d, `INSERT INTO targets (text, level, custom_label, period_start, period_end,
    parent_id, status, priority, ownership, source_type, project_id)
VALUES (?, 'custom', 'project', '2026-09-29', '2026-09-29', ?, ?, ?, 'mine', 'chat', ?)`,
		s.text, s.parent, s.status, s.priority, project))
}

type commentSeed struct {
	author, body, readAt string
	target, parent       *int64
}

func insertComment(t *testing.T, d *db.DB, project int64, s commentSeed) int64 {
	t.Helper()
	if s.author == "" {
		s.author = "agent"
	}
	if s.body == "" {
		s.body = "Question?"
	}
	return lastID(t, exec(t, d, `INSERT INTO project_comments (project_id, target_id, parent_id, author, body, status, read_at)
VALUES (?, ?, ?, ?, ?, 'open', ?)`, project, s.target, s.parent, s.author, s.body, s.readAt))
}

type askSeed struct {
	session, target                      *int64
	kind, title, docPath, status, answer string
	withdrawnReason, createdAt           string
}

func insertAsk(t *testing.T, d *db.DB, project int64, s askSeed) int64 {
	t.Helper()
	if s.kind == "" {
		s.kind = "question"
	}
	if s.title == "" {
		s.title = "Which way?"
	}
	if s.status == "" {
		s.status = "open"
	}
	if s.kind == "review" && s.docPath == "" {
		s.docPath = "docs/review.md"
	}
	var created any
	if s.createdAt != "" {
		created = s.createdAt
	}
	return lastID(t, exec(t, d, `INSERT INTO owner_asks (project_id, session_id, target_id, kind, title, payload, doc_path, status,
    answer, withdrawn_reason, created_at)
VALUES (?, ?, ?, ?, ?, '{}', ?, ?, ?, ?, COALESCE(?, strftime('%Y-%m-%dT%H:%M:%SZ','now')))`,
		project, s.session, s.target, s.kind, s.title, s.docPath, s.status, s.answer, s.withdrawnReason, created))
}

type sessionSeed struct {
	kind       string
	target     *int64
	lastActive time.Time
	folder     string
}

var sessionUUID int

func insertSession(t *testing.T, d *db.DB, project int64, s sessionSeed) int64 {
	t.Helper()
	if s.kind == "" {
		s.kind = "claude"
	}
	if s.lastActive.IsZero() {
		s.lastActive = time.Now()
	}
	if s.folder == "" {
		s.folder = "/tmp/acme"
	}
	var claudeID any
	if s.kind == "claude" {
		sessionUUID++
		claudeID = fmt.Sprintf("00000000-0000-4000-8000-%012d", sessionUUID)
	}
	return lastID(t, exec(t, d, `INSERT INTO terminal_sessions (project_id, kind, title, target_id, folder_path, claude_session_id,
    last_active_at, agent_turn_end, agent_tool_run)
VALUES (?, ?, 'Session', ?, ?, ?, ?, 10, 1)`, project, s.kind, s.target, s.folder, claudeID, dbStamp(s.lastActive)))
}

func linkSession(t *testing.T, d *db.DB, session, target int64) {
	t.Helper()
	now := dbStamp(time.Now())
	exec(t, d, `INSERT INTO terminal_session_targets (session_id, target_id, first_at, last_at) VALUES (?, ?, ?, ?)`,
		session, target, now, now)
}

// closeTarget is SliceSeed.close: status done, closed (history and
// updated_at) at at.
func closeTarget(t *testing.T, d *db.DB, id int64, at time.Time) {
	t.Helper()
	exec(t, d, `UPDATE targets SET status = 'done', status_actor = 'owner' WHERE id = ?`, id)
	exec(t, d, `UPDATE target_status_history SET changed_at = ? WHERE target_id = ?`, dbStamp(at), id)
	exec(t, d, `UPDATE targets SET updated_at = ?, created_at = ? WHERE id = ?`, dbStamp(at), dbStamp(at), id)
}

func ptr[T any](v T) *T { return &v }

// payloads runs src and decodes each item's payload, keyed by item id.
func payloads(t *testing.T, src hubslices.Source) map[int64]map[string]any {
	t.Helper()
	items, err := src.Items(context.Background())
	if err != nil {
		t.Fatalf("%s Items: %v", src.Kind(), err)
	}
	out := map[int64]map[string]any{}
	for _, it := range items {
		id, err := strconv.ParseInt(it.ID, 10, 64)
		if err != nil {
			t.Fatalf("item id %q", it.ID)
		}
		out[id] = decode(t, it.Payload)
	}
	return out
}

func decode(t *testing.T, b []byte) map[string]any {
	t.Helper()
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	var m map[string]any
	if err := dec.Decode(&m); err != nil {
		t.Fatalf("payload is not a JSON object: %v", err)
	}
	return m
}

func only(t *testing.T, all map[int64]map[string]any) map[string]any {
	t.Helper()
	if len(all) != 1 {
		t.Fatalf("%d records, want 1", len(all))
	}
	for _, p := range all {
		return p
	}
	return nil
}

// num reads a JSON number as an int64 (-1 when it is not one).
func num(v any) int64 {
	n, ok := v.(json.Number)
	if !ok {
		return -1
	}
	i, err := n.Int64()
	if err != nil {
		return -1
	}
	return i
}

func float(v any) float64 {
	n, ok := v.(json.Number)
	if !ok {
		return -1
	}
	f, _ := n.Float64()
	return f
}

func runes(v any) int {
	s, _ := v.(string)
	return len([]rune(s))
}

// kitFixture reads a Kit fixture, e.g. "workbench/workbench.json".
func kitFixture(t *testing.T, rel string) map[string]any {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "WatchtowerKit", "Tests", "Fixtures", rel))
	if err != nil {
		t.Fatal(err)
	}
	return decode(t, b)
}

// literalKind is the JSON literal type of a decoded value.
func literalKind(v any) string {
	switch v.(type) {
	case map[string]any:
		return "object"
	case []any:
		return "array"
	case string:
		return "string"
	case bool:
		return "bool"
	case json.Number:
		return "number"
	case nil:
		return "null"
	}
	return "unknown"
}

// assertWireShape is the Swift assertWireShape: every payload key is a
// fixture key or optional, every non-optional fixture key is present, and
// shared keys carry the same literal type, nested objects and the first
// elements of two non-empty arrays compared the same way (optional applies
// at the top only).
func assertWireShape(t *testing.T, payload, fixture map[string]any, optional ...string) {
	t.Helper()
	opt := map[string]bool{}
	for _, k := range optional {
		opt[k] = true
	}
	for k := range payload {
		if _, ok := fixture[k]; !ok && !opt[k] {
			t.Errorf("key %s is not in the Kit fixture", k)
		}
	}
	for k, want := range fixture {
		got, ok := payload[k]
		if !ok {
			if !opt[k] {
				t.Errorf("required key %s is missing", k)
			}
			continue
		}
		if literalKind(got) != literalKind(want) {
			t.Errorf("literal type of %s: %s, fixture %s", k, literalKind(got), literalKind(want))
			continue
		}
		assertNested(t, k, got, want)
	}
}

func assertNested(t *testing.T, path string, got, want any) {
	t.Helper()
	switch w := want.(type) {
	case map[string]any:
		assertWireShape(t, got.(map[string]any), w)
	case []any:
		g := got.([]any)
		if len(g) == 0 || len(w) == 0 {
			return
		}
		if literalKind(g[0]) != literalKind(w[0]) {
			t.Errorf("literal type of %s[0]: %s, fixture %s", path, literalKind(g[0]), literalKind(w[0]))
			return
		}
		assertNested(t, path+"[0]", g[0], w[0])
	}
}

// allKeys is every key at any depth.
func allKeys(v any) map[string]bool {
	out := map[string]bool{}
	switch x := v.(type) {
	case map[string]any:
		for k, e := range x {
			out[k] = true
			for kk := range allKeys(e) {
				out[kk] = true
			}
		}
	case []any:
		for _, e := range x {
			for kk := range allKeys(e) {
				out[kk] = true
			}
		}
	}
	return out
}

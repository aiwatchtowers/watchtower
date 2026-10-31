package sources

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/slices"
)

// Seeds and readers of the asks, permission and work alert tests (beside
// helpers_test.go's): raw inserts, as the Swift TestDatabase/SliceSeed do,
// and payloads keyed by item id with plain JSON numbers.

var seedFolder int

func openDB(t *testing.T) *db.DB {
	t.Helper()
	return db.OpenTestDB(t)
}

// execID runs q and returns the last insert id.
func execID(t *testing.T, d *db.DB, q string, args ...any) int64 {
	t.Helper()
	id, _ := exec(t, d, q, args...).LastInsertId()
	return id
}

func seedWorkbench(t *testing.T, d *db.DB, name string) int64 {
	t.Helper()
	seedFolder++
	return insertWorkbench(t, d, name, "/tmp/hubtest-"+strconv.Itoa(seedFolder))
}

func seedSession(t *testing.T, d *db.DB, project int64, kind string) int64 {
	t.Helper()
	return insertSession(t, d, project, sessionSeed{kind: kind})
}

type askSpec struct {
	project           int64
	session, target   any
	kind, title       string
	payload, status   string
	answer, createdAt string
}

func seedAsk(t *testing.T, d *db.DB, a askSpec) int64 {
	t.Helper()
	if a.kind == "" {
		a.kind = "question"
	}
	if a.title == "" {
		a.title = "Which way?"
	}
	if a.payload == "" {
		a.payload = `{"focus": [], "questions": [], "checklist": []}`
	}
	if a.status == "" {
		a.status = "open"
	}
	if (a.status == "answered" || a.status == "delivered") && a.answer == "" {
		a.answer = "{}"
	}
	if a.createdAt == "" {
		a.createdAt = dbStamp(time.Now())
	}
	docPath := ""
	if a.kind == "review" {
		docPath = "docs/plan.md"
	}
	return execID(t, d, `INSERT INTO owner_asks (project_id, session_id, target_id, kind, title, payload, doc_path,
		status, answer, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		a.project, a.session, a.target, a.kind, a.title, a.payload, docPath, a.status, a.answer, a.createdAt)
}

// payloadsByKey reads a source and returns each item's payload by item id.
func payloadsByKey(t *testing.T, s slices.Source) map[string]map[string]any {
	t.Helper()
	items, err := s.Items(context.Background())
	if err != nil {
		t.Fatalf("Items: %v", err)
	}
	out := map[string]map[string]any{}
	for _, it := range items {
		var m map[string]any
		if err := json.Unmarshal(it.Payload, &m); err != nil {
			t.Fatalf("payload of %s: %v", it.ID, err)
		}
		out[it.ID] = m
	}
	return out
}

func keysOf(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// assertKitKeys is assertWireShape at the top level over payloadsByKey's
// plain decoding.
func assertKitKeys(t *testing.T, payload map[string]any, fixture string, optional ...string) {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "WatchtowerKit", "Tests", "Fixtures", "workbench", fixture))
	if err != nil {
		t.Fatal(err)
	}
	var want map[string]any
	if err := json.Unmarshal(raw, &want); err != nil {
		t.Fatal(err)
	}
	opt := map[string]bool{}
	for _, k := range optional {
		opt[k] = true
	}
	for k := range payload {
		if _, ok := want[k]; !ok && !opt[k] {
			t.Errorf("payload key %q is not in the Kit fixture %s", k, fixture)
		}
	}
	for k := range want {
		if _, ok := payload[k]; !ok && !opt[k] {
			t.Errorf("Kit fixture key %q missing from the payload (keys %v)", k, keysOf(payload))
		}
	}
}

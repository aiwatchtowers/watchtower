package mcp

import (
	"context"
	"path/filepath"
	"strings"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

// seedDB opens a fresh temp database. Per-test seeding is layered on top.
func seedDB(t *testing.T) *db.DB {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test.db")
	database, err := db.Open(path)
	if err != nil {
		t.Fatalf("opening test db: %v", err)
	}
	t.Cleanup(func() { _ = database.Close() })
	return database
}

// newTestSession wires an in-memory MCP client to a server over our database.
func newTestSession(t *testing.T, database *db.DB) *mcpsdk.ClientSession {
	t.Helper()
	ctx := context.Background()
	srv := NewServer(database)
	client := mcpsdk.NewClient(&mcpsdk.Implementation{Name: "test", Version: "v0"}, nil)
	st, ct := mcpsdk.NewInMemoryTransports()
	if _, err := srv.s.Connect(ctx, st, nil); err != nil {
		t.Fatalf("server connect: %v", err)
	}
	cs, err := client.Connect(ctx, ct, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { _ = cs.Close() })
	return cs
}

// textContent extracts the first text content block from a tool result.
func textContent(t *testing.T, res *mcpsdk.CallToolResult) string {
	t.Helper()
	if len(res.Content) == 0 {
		t.Fatalf("result has no content")
	}
	tc, ok := res.Content[0].(*mcpsdk.TextContent)
	if !ok {
		t.Fatalf("first content is not text: %T", res.Content[0])
	}
	return tc.Text
}

func TestToolsList(t *testing.T) {
	cs := newTestSession(t, seedDB(t))

	res, err := cs.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatalf("list tools: %v", err)
	}
	got := map[string]bool{}
	for _, tool := range res.Tools {
		got[tool.Name] = true
	}
	want := []string{
		"list_targets", "get_target",
		"get_today_briefing", "list_digests", "get_digest",
		"list_people", "get_person", "list_tracks", "get_track", "list_upcoming_events",
		"list_jira_issues", "get_jira_issue",
	}
	for _, name := range want {
		if !got[name] {
			t.Errorf("missing tool %q", name)
		}
	}
	if len(res.Tools) != len(want) {
		t.Errorf("expected exactly %d tools, got %d", len(want), len(res.Tools))
	}
}

func TestAllToolsAreReadOnly(t *testing.T) {
	// Guard the read-only invariant: every exposed tool name must be a known
	// read verb. A new write tool would have to be added here deliberately —
	// which is the point: it forces a conscious change to this guard.
	cs := newTestSession(t, seedDB(t))
	res, err := cs.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatalf("list tools: %v", err)
	}
	for _, tool := range res.Tools {
		if !strings.HasPrefix(tool.Name, "list_") &&
			!strings.HasPrefix(tool.Name, "get_") {
			t.Errorf("tool %q is not a read-only verb (list_/get_)", tool.Name)
		}
	}
}

// TestNoToolMutatesDatabase is the behavioural read-only guard: invoking every
// tool must leave all tables byte-for-byte unchanged (row counts). It catches a
// future handler that mutates despite a read-y name — which the lexical
// TestAllToolsAreReadOnly cannot.
func TestNoToolMutatesDatabase(t *testing.T) {
	database := seedDB(t)
	if _, err := database.CreateTarget(db.Target{
		Text: "guard", Intent: "x", Level: "week", Status: "todo",
		Priority: "high", Ownership: "mine", SourceType: "manual",
	}); err != nil {
		t.Fatalf("seeding target: %v", err)
	}
	if _, err := database.UpsertDigest(db.Digest{ChannelID: "C1", Type: "daily", Summary: "s", PeriodFrom: 1, PeriodTo: 2}); err != nil {
		t.Fatalf("seeding digest: %v", err)
	}
	if _, err := database.UpsertTrack(db.Track{Text: "guard track", Ownership: "mine", Priority: "low"}); err != nil {
		t.Fatalf("seeding track: %v", err)
	}
	if err := database.UpsertJiraIssue(db.JiraIssue{
		Key: "ABC-1", ID: "ABC-1", ProjectKey: "ABC", Summary: "s", Status: "To Do", StatusCategory: "To Do",
		CreatedAt: "2026-06-01T00:00:00Z", UpdatedAt: "2026-06-02T00:00:00Z", SyncedAt: "2026-06-02T00:00:00Z",
	}); err != nil {
		t.Fatalf("seeding jira issue: %v", err)
	}

	tables := []string{"targets", "digests", "tracks", "jira_issues", "calendar_events", "people_cards", "briefings", "workspace"}
	counts := func() map[string]int {
		m := map[string]int{}
		for _, tbl := range tables {
			var n int
			if err := database.QueryRow("SELECT count(*) FROM " + tbl).Scan(&n); err != nil {
				t.Fatalf("counting %s: %v", tbl, err)
			}
			m[tbl] = n
		}
		return m
	}

	before := counts()
	cs := newTestSession(t, database)
	ctx := context.Background()
	calls := []mcpsdk.CallToolParams{
		{Name: "list_targets"}, {Name: "get_target", Arguments: map[string]any{"id": 1}},
		{Name: "get_today_briefing"}, {Name: "list_digests"}, {Name: "get_digest", Arguments: map[string]any{"id": 1}},
		{Name: "list_people"}, {Name: "get_person", Arguments: map[string]any{"user_id": "U1"}},
		{Name: "list_tracks"}, {Name: "get_track", Arguments: map[string]any{"id": 1}},
		{Name: "list_upcoming_events", Arguments: map[string]any{"hours": 48}},
		{Name: "list_jira_issues"}, {Name: "get_jira_issue", Arguments: map[string]any{"key": "ABC-1"}},
	}
	for _, c := range calls {
		if _, err := cs.CallTool(ctx, &c); err != nil {
			t.Fatalf("call %s: %v", c.Name, err)
		}
	}
	after := counts()

	for _, tbl := range tables {
		if before[tbl] != after[tbl] {
			t.Errorf("table %s row count changed %d -> %d after read tools ran", tbl, before[tbl], after[tbl])
		}
	}
}

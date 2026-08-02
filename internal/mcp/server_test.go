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
// Mirrors production wiring (cmd/mcp.go): the connection is flipped to
// query_only before serving, so every tool test runs under the same
// connection-level read-only enforcement as the real server.
func newTestSession(t *testing.T, database *db.DB) *mcpsdk.ClientSession {
	t.Helper()
	if err := database.SetReadOnly(); err != nil {
		t.Fatalf("setting read-only: %v", err)
	}
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
		"list_messages",
		"list_transcripts", "get_transcript",
		"memory_map", "memory_open", "memory_recall",
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
	// The memory_ tools are read surfaces over the vault + index; memory_open
	// additionally bumps memory_node_stats — best-effort usage telemetry, not
	// domain data — the one deliberate exception to "no writes".
	readVerbs := map[string]bool{"memory_map": true, "memory_open": true, "memory_recall": true}
	for _, tool := range res.Tools {
		if !strings.HasPrefix(tool.Name, "list_") &&
			!strings.HasPrefix(tool.Name, "get_") &&
			!readVerbs[tool.Name] {
			t.Errorf("tool %q is not a known read-only verb (list_/get_/memory_)", tool.Name)
		}
	}
}

// TestNoToolMutatesDatabase is the behavioural read-only guard. Two layers:
// the session runs over a query_only connection (any write inside a handler
// errors at the SQLite level), and row counts are compared before/after as a
// belt-and-braces check. Note the count check alone would not catch an UPDATE;
// the query_only pragma is the real guarantee.
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
	db.SeedTestJiraAccount(t, database)
	if err := database.UpsertJiraIssue(db.JiraIssue{
		AccountID: 1,
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
	// The session connection must reject direct writes — proves query_only is on.
	if _, err := database.Exec(`INSERT INTO users (id, name, is_stub) VALUES ('WGUARD', 'w', 1)`); err == nil {
		t.Fatalf("expected direct write to fail on the read-only MCP connection")
	}
	ctx := context.Background()
	calls := []mcpsdk.CallToolParams{
		{Name: "list_targets"}, {Name: "get_target", Arguments: map[string]any{"id": 1}},
		{Name: "get_today_briefing"}, {Name: "list_digests"}, {Name: "get_digest", Arguments: map[string]any{"id": 1}},
		{Name: "list_people"}, {Name: "get_person", Arguments: map[string]any{"query": "U1"}},
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

// TestListLimitClamp: 0/negative falls back to the default, oversized requests
// are capped so one tool call cannot dump an entire table into an LLM context.
func TestListLimitClamp(t *testing.T) {
	cases := []struct{ in, want int }{
		{0, defaultListLimit},
		{-5, defaultListLimit},
		{10, 10},
		{maxListLimit, maxListLimit},
		{maxListLimit + 1, maxListLimit},
		{100000, maxListLimit},
	}
	for _, c := range cases {
		if got := listLimit(c.in); got != c.want {
			t.Errorf("listLimit(%d) = %d, want %d", c.in, got, c.want)
		}
	}
}

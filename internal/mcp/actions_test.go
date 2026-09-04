package mcp

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// newChatSession mirrors cmd/mcp.go's --chat wiring: a WRITABLE connection
// (no SetReadOnly) with the registry mounted for one surface.
func newChatSession(t *testing.T, database *db.DB, reg *tools.Registry, binding tools.Binding) *mcpsdk.ClientSession {
	t.Helper()
	ctx := context.Background()
	srv := NewServer(database, WithRegistry(reg, binding))
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

func chatRegistry(t *testing.T, database *db.DB) *tools.Registry {
	t.Helper()
	reg := tools.New(database)
	if err := reg.Register(tools.NewCreateTarget()); err != nil {
		t.Fatal(err)
	}
	if err := reg.Register(tools.NewCreateJiraIssue(func(db.JiraAccount) (tools.JiraIssueClient, error) {
		t.Fatal("the Jira client must never be built on propose")
		return nil, nil
	})); err != nil {
		t.Fatal(err)
	}
	return reg
}

func toolNames(t *testing.T, cs *mcpsdk.ClientSession) map[string]bool {
	t.Helper()
	res, err := cs.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatalf("list tools: %v", err)
	}
	names := map[string]bool{}
	for _, tool := range res.Tools {
		names[tool.Name] = true
	}
	return names
}

func TestChatMode_ListsWriteToolsPerSurface(t *testing.T) {
	database := seedDB(t)
	main := toolNames(t, newChatSession(t, database, chatRegistry(t, database), tools.Binding{Surface: "main"}))
	if !main["create_target"] || !main["create_jira_issue"] || !main["get_action"] || !main["list_jira_projects"] {
		t.Fatalf("main surface tools = %v", main)
	}
	target := toolNames(t, newChatSession(t, seedDB(t), chatRegistry(t, database), tools.Binding{Surface: "target"}))
	if target["create_target"] {
		t.Fatalf("create_target must not be offered on the target surface (TGT-BRIEF-01)")
	}
	if !target["create_jira_issue"] {
		t.Fatalf("create_jira_issue missing on the target surface")
	}
}

// A registered AccessRead tool has no InputSchema (Register only requires one
// for AccessWrite) — the SDK's raw AddTool panics on a nil schema, so the
// registry adapter must skip it rather than mount it. Construction must not
// panic, and the tool must not appear on the chat surface.
func TestChatMode_SkipsReadToolWithoutPanicking(t *testing.T) {
	database := seedDB(t)
	reg := tools.New(database)
	if err := reg.Register(&tools.Tool{Name: "read_thing", Access: tools.AccessRead}); err != nil {
		t.Fatal(err)
	}
	names := toolNames(t, newChatSession(t, database, reg, tools.Binding{Surface: "main"}))
	if names["read_thing"] {
		t.Fatalf("a read tool must not be mounted by the registry adapter: %v", names)
	}
}

// AGENT-02: the developer-surface server never mounts a write tool.
func TestAgent02_DevModeRegistersNoWriteTools(t *testing.T) {
	names := toolNames(t, newTestSession(t, seedDB(t)))
	for _, n := range []string{"create_target", "create_jira_issue", "get_action"} {
		if names[n] {
			t.Errorf("dev mode exposes write/chat tool %q", n)
		}
	}
	if !names["list_jira_projects"] {
		t.Errorf("list_jira_projects is a read tool and belongs to both modes")
	}
}

// AGENT-01: a write tool called through the chat server with trust "ask"
// leaves every data table untouched and records exactly one proposal.
func TestAgent01_WriteToolCallRecordsProposalOnly(t *testing.T) {
	database := seedDB(t)
	seedGuardFixture(t, database)
	before := countRows(t, database, guardTables)
	cs := newChatSession(t, database, chatRegistry(t, database), tools.Binding{Surface: "main", ConversationID: 3, TurnID: "t9"})

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name: "create_target", Arguments: map[string]any{"text": "Call Vasya", "reason": "owner asked"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.IsError {
		t.Fatalf("unexpected tool error: %s", textContent(t, res))
	}
	var rc tools.Receipt
	if err := json.Unmarshal([]byte(textContent(t, res)), &rc); err != nil {
		t.Fatal(err)
	}
	if rc.Status != "pending" || !strings.Contains(rc.Message, "do not claim it is done") {
		t.Fatalf("receipt = %+v", rc)
	}
	after := countRows(t, database, guardTables)
	for _, tbl := range guardTables {
		if before[tbl] != after[tbl] {
			t.Errorf("table %s changed %d -> %d on propose", tbl, before[tbl], after[tbl])
		}
	}
	rows, _ := database.ListAgentActions(db.AgentActionFilter{ConversationID: 3})
	if len(rows) != 1 || rows[0].TurnID != "t9" || rows[0].Surface != "main" {
		t.Fatalf("agent_actions = %+v", rows)
	}
}

func TestChatMode_ValidationErrorIsToolErrorWithoutRow(t *testing.T) {
	database := seedDB(t)
	cs := newChatSession(t, database, chatRegistry(t, database), tools.Binding{Surface: "main"})
	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name: "create_target", Arguments: map[string]any{"reason": "no text"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !res.IsError || !strings.Contains(textContent(t, res), "text is required") {
		t.Fatalf("expected validation error, got %s", textContent(t, res))
	}
	rows, _ := database.ListAgentActions(db.AgentActionFilter{})
	if len(rows) != 0 {
		t.Fatalf("validation failure wrote %d rows", len(rows))
	}
}

func TestGetAction_ReturnsRowAndNotFound(t *testing.T) {
	database := seedDB(t)
	id, _ := database.InsertAgentAction(db.AgentAction{Tool: "create_target", ArgsJSON: `{"text":"x"}`, Reason: "r"})
	cs := newChatSession(t, database, chatRegistry(t, database), tools.Binding{Surface: "main"})
	res, _ := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{Name: "get_action", Arguments: map[string]any{"id": id}})
	if res.IsError || !strings.Contains(textContent(t, res), `"status": "pending"`) {
		t.Fatalf("get_action = %s", textContent(t, res))
	}
	res, _ = cs.CallTool(context.Background(), &mcpsdk.CallToolParams{Name: "get_action", Arguments: map[string]any{"id": 999}})
	if !res.IsError {
		t.Fatalf("expected not-found error")
	}
}

func TestListJiraProjects_GroupsByAccount(t *testing.T) {
	database := seedDB(t)
	acct, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c", SiteURL: "https://acme.atlassian.net", SiteName: "Acme"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`INSERT INTO jira_sync_state (account_id, project_key, last_synced_at, issues_synced) VALUES (?, 'ABC', 'x', 2)`, acct); err != nil {
		t.Fatal(err)
	}
	for _, it := range []string{"Task", "Bug", "Task"} {
		key := "ABC-" + it + "1"
		if err := database.UpsertJiraIssue(db.JiraIssue{AccountID: acct, Key: key, ProjectKey: "ABC", Summary: "s", IssueType: it,
			Status: "To Do", StatusCategory: "new", Labels: "[]", Components: "[]", FixVersions: "[]",
			CreatedAt: "2026-01-01T00:00:00Z", UpdatedAt: "2026-01-01T00:00:00Z", SyncedAt: "2026-01-01T00:00:00Z"}); err != nil {
			t.Fatal(err)
		}
	}
	cs := newTestSession(t, database)
	res, _ := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{Name: "list_jira_projects"})
	out := textContent(t, res)
	for _, want := range []string{`"account_id": ` + strconv.FormatInt(acct, 10), `"project_key": "ABC"`, `"Bug"`, `"Task"`} {
		if !strings.Contains(out, want) {
			t.Errorf("list_jira_projects output missing %s:\n%s", want, out)
		}
	}
}

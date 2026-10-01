package mcp

import (
	"context"
	"encoding/json"
	"strconv"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
	"watchtower/internal/projectfiles"
	"watchtower/internal/tools"
)

// newProjectSession mirrors cmd/mcp.go's --project wiring: a writable
// connection, the project tools plus every read tool, bound to projectID
// with DirectApply.
func newProjectSession(t *testing.T, database *db.DB, projectID int64) *mcpsdk.ClientSession {
	t.Helper()
	reg := tools.New(database)
	for _, tool := range append(tools.ProjectTools(projectfiles.New(t.TempDir())), tools.ReadTools()...) {
		if err := reg.Register(tool); err != nil {
			t.Fatal(err)
		}
	}
	return newChatSession(t, database, reg, tools.Binding{Surface: "project", ProjectID: projectID, DirectApply: true})
}

func seedMCPProject(t *testing.T, database *db.DB) int64 {
	t.Helper()
	folder, err := db.ResolveProjectFolder(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	id, err := database.CreateProject("acme", folder)
	if err != nil {
		t.Fatal(err)
	}
	return id
}

// Review Focus #5: the project is deleted while the session is connected —
// every tool, project tool or not, read or write, answers the same line.
func TestProjectMode_DeletedProjectEveryToolAnswersNoLongerExists(t *testing.T) {
	database := seedDB(t)
	pid := seedMCPProject(t, database)
	cs := newProjectSession(t, database, pid)
	if err := database.DeleteProject(pid); err != nil {
		t.Fatal(err)
	}
	want := "project " + strconv.FormatInt(pid, 10) + " no longer exists"
	for _, c := range []mcpsdk.CallToolParams{
		{Name: "project_info", Arguments: map[string]any{}},
		{Name: "list_comments", Arguments: map[string]any{}},
		{Name: "list_targets", Arguments: map[string]any{}},
		{Name: "list_digests", Arguments: map[string]any{}},
		{Name: "create_targets", Arguments: map[string]any{"items": []any{map[string]any{"text": "x"}}, "reason": "r"}},
		{Name: "update_project", Arguments: map[string]any{"description": "x", "reason": "r"}},
		{Name: "get_action", Arguments: map[string]any{"id": 1}},
	} {
		res, err := cs.CallTool(context.Background(), &c)
		if err != nil {
			t.Fatalf("call %s: %v", c.Name, err)
		}
		if !res.IsError || textContent(t, res) != want {
			t.Errorf("%s: want tool error %q, got error=%v %q", c.Name, want, res.IsError, textContent(t, res))
		}
	}
	rows, err := database.ListAgentActions(db.AgentActionFilter{})
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 0 {
		t.Errorf("a call on a deleted project wrote %d audit rows", len(rows))
	}
}

// get_action in a project session shows that project's rows only.
func TestGetAction_ProjectSessionSeesOnlyItsRows(t *testing.T) {
	database := seedDB(t)
	pid := seedMCPProject(t, database)
	mainRow, err := database.InsertAgentAction(db.AgentAction{Tool: "create_target", ArgsJSON: `{}`, Reason: "r",
		Surface: "main", ConversationID: 0, Status: "pending", TrustAtCreate: "ask"})
	if err != nil {
		t.Fatal(err)
	}
	// A row of a second project: same context_type, different context_id —
	// only actionVisible's context_id clause keeps it out of project A's view.
	otherFolder, err := db.ResolveProjectFolder(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	otherPID, err := database.CreateProject("other", otherFolder)
	if err != nil {
		t.Fatal(err)
	}
	otherProjectRow, err := database.InsertAgentAction(db.AgentAction{Tool: "create_targets", ArgsJSON: `{}`, Reason: "r",
		Surface: "project", ContextType: tools.ProjectContextType, ContextID: strconv.FormatInt(otherPID, 10),
		Status: "pending", TrustAtCreate: "execute"})
	if err != nil {
		t.Fatal(err)
	}
	cs := newProjectSession(t, database, pid)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{Name: "create_targets",
		Arguments: map[string]any{"items": []any{map[string]any{"text": "x"}}, "reason": "r"}})
	if err != nil || res.IsError {
		t.Fatalf("create_targets: %v %v", err, res)
	}
	var rc tools.Receipt
	if err := json.Unmarshal([]byte(textContent(t, res)), &rc); err != nil {
		t.Fatal(err)
	}
	if rc.Status != "applied" {
		t.Fatalf("want applied, got %+v", rc)
	}

	for id, visible := range map[int64]bool{rc.ActionID: true, mainRow: false, otherProjectRow: false} {
		res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{Name: "get_action", Arguments: map[string]any{"id": id}})
		if err != nil {
			t.Fatal(err)
		}
		if res.IsError == visible {
			t.Errorf("action #%d: visible=%v but IsError=%v (%s)", id, visible, res.IsError, textContent(t, res))
		}
	}
}

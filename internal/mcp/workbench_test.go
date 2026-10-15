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
	"watchtower/internal/workbenchfiles"
)

// newWorkbenchSession mirrors cmd/mcp.go's --workbench wiring: a writable
// connection, the workbench tools plus every read tool, bound to workbenchID
// with DirectApply.
func newWorkbenchSession(t *testing.T, database *db.DB, workbenchID int64) *mcpsdk.ClientSession {
	t.Helper()
	reg := tools.New(database)
	for _, tool := range append(tools.WorkbenchTools(workbenchfiles.New(t.TempDir())), tools.ReadTools()...) {
		if err := reg.Register(tool); err != nil {
			t.Fatal(err)
		}
	}
	return newChatSession(t, database, reg, tools.Binding{Surface: "project", WorkbenchID: workbenchID, DirectApply: true})
}

func seedMCPWorkbench(t *testing.T, database *db.DB) int64 {
	t.Helper()
	folder, err := db.ResolveWorkbenchFolder(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	id, err := database.CreateWorkbench("acme", folder)
	if err != nil {
		t.Fatal(err)
	}
	return id
}

// Review Focus #5: the project is deleted while the session is connected —
// every tool, project tool or not, read or write, answers the same line.
func TestProjectMode_DeletedProjectEveryToolAnswersNoLongerExists(t *testing.T) {
	database := seedDB(t)
	pid := seedMCPWorkbench(t, database)
	cs := newWorkbenchSession(t, database, pid)
	if err := database.DeleteWorkbench(pid); err != nil {
		t.Fatal(err)
	}
	want := "workbench " + strconv.FormatInt(pid, 10) + " no longer exists"
	for _, c := range []mcpsdk.CallToolParams{
		{Name: "workbench_info", Arguments: map[string]any{}},
		{Name: "list_comments", Arguments: map[string]any{}},
		{Name: "list_targets", Arguments: map[string]any{}},
		{Name: "list_digests", Arguments: map[string]any{}},
		{Name: "create_targets", Arguments: map[string]any{"items": []any{map[string]any{"text": "x"}}, "reason": "r"}},
		{Name: "update_workbench", Arguments: map[string]any{"description": "x", "reason": "r"}},
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
	pid := seedMCPWorkbench(t, database)
	mainRow, err := database.InsertAgentAction(db.AgentAction{Tool: "create_target", ArgsJSON: `{}`, Reason: "r",
		Surface: "main", ConversationID: 0, Status: "pending", TrustAtCreate: "ask"})
	if err != nil {
		t.Fatal(err)
	}
	// A row of a second project: same context_type, different context_id —
	// only actionVisible's context_id clause keeps it out of project A's view.
	otherFolder, err := db.ResolveWorkbenchFolder(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	otherPID, err := database.CreateWorkbench("other", otherFolder)
	if err != nil {
		t.Fatal(err)
	}
	otherWorkbenchRow, err := database.InsertAgentAction(db.AgentAction{Tool: "create_targets", ArgsJSON: `{}`, Reason: "r",
		Surface: "project", ContextType: tools.WorkbenchContextType, ContextID: strconv.FormatInt(otherPID, 10),
		Status: "pending", TrustAtCreate: "execute"})
	if err != nil {
		t.Fatal(err)
	}
	cs := newWorkbenchSession(t, database, pid)

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

	for id, visible := range map[int64]bool{rc.ActionID: true, mainRow: false, otherWorkbenchRow: false} {
		res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{Name: "get_action", Arguments: map[string]any{"id": id}})
		if err != nil {
			t.Fatal(err)
		}
		if res.IsError == visible {
			t.Errorf("action #%d: visible=%v but IsError=%v (%s)", id, visible, res.IsError, textContent(t, res))
		}
	}
}

// workbenchToolsListed is every listed tool of the session that is a
// workbench tool (surface "project") under either spelling, by listed name,
// with every text the agent reads about it: its description and its input
// schema (the argument descriptions), as JSON.
func workbenchToolsListed(t *testing.T, cs *mcpsdk.ClientSession) map[string]string {
	t.Helper()
	res, err := cs.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	workbench := map[string]bool{}
	for _, tool := range tools.WorkbenchTools(workbenchfiles.Store{}) {
		workbench[tool.Name] = true
	}
	out := map[string]string{}
	for _, tool := range res.Tools {
		if workbench[tools.CanonicalToolName(tool.Name)] {
			schema, err := json.Marshal(tool.InputSchema)
			if err != nil {
				t.Fatal(err)
			}
			out[tool.Name] = tool.Description + "\n" + string(schema)
		}
	}
	return out
}

// Spec 2026-10-02 §5.2 (extends DEV-06): `mcp --workbench N` lists the
// sixteen workbench tools under their current names only, with no
// description or input schema pointing at a pre-rename name.
func TestWorkbenchMode_ListsSixteenToolsUnderTheCurrentNames(t *testing.T) {
	database := seedDB(t)
	pid := seedMCPWorkbench(t, database)
	listed := workbenchToolsListed(t, newWorkbenchSession(t, database, pid))
	if len(listed) != 16 {
		t.Errorf("want 16 workbench tools, got %d: %v", len(listed), listed)
	}
	renamed := map[string]string{
		"project_info": tools.WorkbenchInfoTool, "project_board": tools.WorkbenchBoardTool,
		"update_project": tools.UpdateWorkbenchTool, "add_project_source": tools.AddWorkbenchSourceTool,
		"remove_project_source": tools.RemoveWorkbenchSourceTool,
	}
	for oldName, newName := range renamed {
		if _, ok := listed[newName]; !ok {
			t.Errorf("%s is not listed", newName)
		}
		if _, ok := listed[oldName]; ok {
			t.Errorf("%s must not be listed", oldName)
		}
		for name, desc := range listed {
			if strings.Contains(desc, oldName) {
				t.Errorf("%s's description or input schema names %s", name, oldName)
			}
		}
	}
	if want := "the source id from workbench_info"; !strings.Contains(listed[tools.RemoveWorkbenchSourceTool], want) {
		t.Errorf("%s's schema lacks %q: %s", tools.RemoveWorkbenchSourceTool, want, listed[tools.RemoveWorkbenchSourceTool])
	}
}

// Spec 2026-10-03 §4: the workbench session serves the ask tools, and an ask
// filed through it applies directly with its audit row.
func TestWorkbenchMode_ServesTheAskTools(t *testing.T) {
	database := seedDB(t)
	pid := seedMCPWorkbench(t, database)
	cs := newWorkbenchSession(t, database, pid)
	listed := workbenchToolsListed(t, cs)
	for _, name := range []string{"ask_owner", "get_ask", "list_asks", "withdraw_ask"} {
		if _, ok := listed[name]; !ok {
			t.Errorf("%s is not listed", name)
		}
	}
	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{Name: "ask_owner",
		Arguments: map[string]any{"kind": "check", "title": "Run it", "reason": "r",
			"checklist": []any{map[string]any{"text": "Open the app"}}}})
	if err != nil || res.IsError {
		t.Fatalf("ask_owner: %v %v", err, res)
	}
	var rc tools.Receipt
	if err := json.Unmarshal([]byte(textContent(t, res)), &rc); err != nil {
		t.Fatal(err)
	}
	if rc.Status != "applied" || rc.Tool != "ask_owner" {
		t.Errorf("want an applied ask_owner receipt, got %+v", rc)
	}
	asks, err := database.ListOwnerAsks(pid, db.OwnerAskFilter{})
	if err != nil {
		t.Fatal(err)
	}
	if len(asks) != 1 {
		t.Errorf("want 1 open ask, got %d", len(asks))
	}
}

// Spec 2026-10-03 §4: attach_document is gone — the session does not list
// it, and a call to it is an unknown tool, not a workbench write.
func TestWorkbenchMode_AttachDocumentIsUnknown(t *testing.T) {
	database := seedDB(t)
	pid := seedMCPWorkbench(t, database)
	cs := newWorkbenchSession(t, database, pid)
	res, err := cs.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, tool := range res.Tools {
		if tool.Name == "attach_document" {
			t.Errorf("attach_document is listed")
		}
	}
	_, err = cs.CallTool(context.Background(), &mcpsdk.CallToolParams{Name: "attach_document",
		Arguments: map[string]any{"rel_path": "a.md", "kind": "doc", "reason": "r"}})
	if err == nil || !strings.Contains(err.Error(), "unknown tool") {
		t.Errorf("attach_document call: want an unknown-tool error, got %v", err)
	}
	var n int
	if err := database.QueryRow(`SELECT COUNT(*) FROM agent_actions`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("an unknown tool leaves no audit row, got %d", n)
	}
}

// A pre-rename name is not served: a call to it is an unknown tool. A row
// recorded before the rename under the old name still reads, through
// get_action, under the tool's current name.
func TestWorkbenchMode_OldNamesAreUnknownAndOldRowsResolve(t *testing.T) {
	database := seedDB(t)
	pid := seedMCPWorkbench(t, database)
	cs := newWorkbenchSession(t, database, pid)

	_, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{Name: "update_project",
		Arguments: map[string]any{"description": "Set up before the rename.", "reason": "setup"}})
	if err == nil || !strings.Contains(err.Error(), "unknown tool") {
		t.Errorf("update_project call: want an unknown-tool error, got %v", err)
	}
	var n int
	if err := database.QueryRow(`SELECT COUNT(*) FROM agent_actions`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("a refused old name leaves no audit row, got %d", n)
	}

	oldRow, err := database.InsertAgentAction(db.AgentAction{Tool: "add_project_source", ArgsJSON: `{}`, Reason: "r",
		Surface: "project", ContextType: tools.WorkbenchContextType, ContextID: strconv.FormatInt(pid, 10),
		Status: "applied", TrustAtCreate: "execute"})
	if err != nil {
		t.Fatal(err)
	}
	if got := getActionTool(t, cs, oldRow); got != tools.AddWorkbenchSourceTool {
		t.Errorf("get_action #%d names %q, want %q", oldRow, got, tools.AddWorkbenchSourceTool)
	}
}

// getActionTool returns the tool get_action names for action id in session.
func getActionTool(t *testing.T, session *mcpsdk.ClientSession, id int64) string {
	t.Helper()
	res, err := session.CallTool(context.Background(), &mcpsdk.CallToolParams{Name: "get_action", Arguments: map[string]any{"id": id}})
	if err != nil || res.IsError {
		t.Fatalf("get_action #%d: %v %s", id, err, textContent(t, res))
	}
	var view struct {
		Tool string `json:"tool"`
	}
	if err := json.Unmarshal([]byte(textContent(t, res)), &view); err != nil {
		t.Fatal(err)
	}
	return view.Tool
}

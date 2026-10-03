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
// connection, the workbench tools plus every read tool, bound to projectID
// with DirectApply.
func newWorkbenchSession(t *testing.T, database *db.DB, projectID int64) *mcpsdk.ClientSession {
	t.Helper()
	return newBoundWorkbenchSession(t, database, projectID, false)
}

// newLegacyWorkbenchSession is the pre-rename `mcp --project N` wiring: the
// same session, listing the renamed tools under their old names.
func newLegacyWorkbenchSession(t *testing.T, database *db.DB, projectID int64) *mcpsdk.ClientSession {
	t.Helper()
	return newBoundWorkbenchSession(t, database, projectID, true)
}

func newBoundWorkbenchSession(t *testing.T, database *db.DB, projectID int64, legacy bool) *mcpsdk.ClientSession {
	t.Helper()
	reg := tools.New(database)
	for _, tool := range append(tools.WorkbenchTools(workbenchfiles.New(t.TempDir())), tools.ReadTools()...) {
		if err := reg.Register(tool); err != nil {
			t.Fatal(err)
		}
	}
	return newChatSession(t, database, reg, tools.Binding{Surface: "project", WorkbenchID: projectID, DirectApply: true, LegacyNames: legacy})
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
	otherProjectRow, err := database.InsertAgentAction(db.AgentAction{Tool: "create_targets", ArgsJSON: `{}`, Reason: "r",
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

// Spec 2026-10-02 §5.2 (extends DEV-06): `mcp --workbench N` lists only the
// new names, `mcp --project N` only the old ones — fourteen workbench tools
// either way, with no description or input schema pointing at a tool the
// session lacks.
func TestWorkbenchMode_EachVocabularyListsFourteenToolsUnderItsOwnNames(t *testing.T) {
	database := seedDB(t)
	pid := seedMCPWorkbench(t, database)
	for _, legacy := range []bool{false, true} {
		listed := workbenchToolsListed(t, newBoundWorkbenchSession(t, database, pid, legacy))
		if len(listed) != 14 {
			t.Errorf("legacy=%v: want 14 workbench tools, got %d: %v", legacy, len(listed), listed)
		}
		for newName, oldName := range tools.LegacyWorkbenchToolNames {
			want, unwanted := newName, oldName
			if legacy {
				want, unwanted = oldName, newName
			}
			if _, ok := listed[want]; !ok {
				t.Errorf("legacy=%v: %s is not listed", legacy, want)
			}
			if _, ok := listed[unwanted]; ok {
				t.Errorf("legacy=%v: %s must not be listed", legacy, unwanted)
			}
			for name, desc := range listed {
				if strings.Contains(desc, unwanted) {
					t.Errorf("legacy=%v: %s's description or input schema names %s", legacy, name, unwanted)
				}
			}
		}
		// The argument descriptions are spelled too, not only the tool's own.
		want := map[bool]string{false: "the source id from workbench_info", true: "the source id from project_info"}[legacy]
		remove := tools.Binding{LegacyNames: legacy}.Spell(tools.RemoveWorkbenchSourceTool)
		if !strings.Contains(listed[remove], want) {
			t.Errorf("legacy=%v: %s's schema lacks %q: %s", legacy, remove, want, listed[remove])
		}
	}
}

// Spec 2026-10-03 §4: the ask tools have no legacy spelling — both
// vocabularies serve them under the same names, and an ask filed through one
// applies directly with its audit row.
func TestWorkbenchMode_AskToolsServedUnderTheSameNamesInBothVocabularies(t *testing.T) {
	database := seedDB(t)
	pid := seedMCPWorkbench(t, database)
	for _, legacy := range []bool{false, true} {
		cs := newBoundWorkbenchSession(t, database, pid, legacy)
		listed := workbenchToolsListed(t, cs)
		for _, name := range []string{"ask_owner", "get_ask", "list_asks", "withdraw_ask"} {
			if _, ok := listed[name]; !ok {
				t.Errorf("legacy=%v: %s is not listed", legacy, name)
			}
		}
		res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{Name: "ask_owner",
			Arguments: map[string]any{"kind": "check", "title": "Run it", "reason": "r",
				"checklist": []any{map[string]any{"text": "Open the app"}}}})
		if err != nil || res.IsError {
			t.Fatalf("legacy=%v: ask_owner: %v %v", legacy, err, res)
		}
		var rc tools.Receipt
		if err := json.Unmarshal([]byte(textContent(t, res)), &rc); err != nil {
			t.Fatal(err)
		}
		if rc.Status != "applied" || rc.Tool != "ask_owner" {
			t.Errorf("legacy=%v: want an applied ask_owner receipt, got %+v", legacy, rc)
		}
	}
	asks, err := database.ListOwnerAsks(pid, db.OwnerAskFilter{})
	if err != nil {
		t.Fatal(err)
	}
	if len(asks) != 2 {
		t.Errorf("want 2 open asks, got %d", len(asks))
	}
}

// Spec 2026-10-03 §4: attach_document is gone — neither vocabulary lists it,
// and a call to it is an unknown tool, not a workbench write.
func TestWorkbenchMode_AttachDocumentIsUnknown(t *testing.T) {
	database := seedDB(t)
	pid := seedMCPWorkbench(t, database)
	for _, legacy := range []bool{false, true} {
		cs := newBoundWorkbenchSession(t, database, pid, legacy)
		res, err := cs.ListTools(context.Background(), nil)
		if err != nil {
			t.Fatal(err)
		}
		for _, tool := range res.Tools {
			if tool.Name == "attach_document" {
				t.Errorf("legacy=%v: attach_document is listed", legacy)
			}
		}
		_, err = cs.CallTool(context.Background(), &mcpsdk.CallToolParams{Name: "attach_document",
			Arguments: map[string]any{"rel_path": "a.md", "kind": "doc", "reason": "r"}})
		if err == nil || !strings.Contains(err.Error(), "unknown tool") {
			t.Errorf("legacy=%v: attach_document call: want an unknown-tool error, got %v", legacy, err)
		}
	}
	var n int
	if err := database.QueryRow(`SELECT COUNT(*) FROM agent_actions`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("an unknown tool leaves no audit row, got %d", n)
	}
}

// A write through a legacy name records the canonical name; get_action names
// a row's tool in the asking session's vocabulary, whether the row was
// recorded under the new name or (before the rename) the old one; a refusal
// names the tools the legacy session lists.
func TestLegacyMode_WritesRecordTheCanonicalNameAndOldRowsResolve(t *testing.T) {
	database := seedDB(t)
	pid := seedMCPWorkbench(t, database)
	cs := newLegacyWorkbenchSession(t, database, pid)

	rc := applyLegacyUpdateProject(t, cs)
	row, err := database.GetAgentAction(rc.ActionID)
	if err != nil || row == nil {
		t.Fatalf("action row: %v", err)
	}
	if row.Tool != tools.UpdateWorkbenchTool {
		t.Errorf("agent_actions.tool = %q, want the canonical %q", row.Tool, tools.UpdateWorkbenchTool)
	}
	p, err := database.GetWorkbench(pid)
	if err != nil || p.Description != "Set up before the rename." {
		t.Fatalf("description not applied: %+v %v", p, err)
	}

	oldRow, err := database.InsertAgentAction(db.AgentAction{Tool: "add_project_source", ArgsJSON: `{}`, Reason: "r",
		Surface: "project", ContextType: tools.WorkbenchContextType, ContextID: strconv.FormatInt(pid, 10),
		Status: "applied", TrustAtCreate: "execute"})
	if err != nil {
		t.Fatal(err)
	}
	// get_action names a row's tool the way the asking session lists it,
	// whichever spelling the row was recorded under.
	current := newWorkbenchSession(t, database, pid)
	for _, c := range []struct {
		session  *mcpsdk.ClientSession
		legacy   bool
		id       int64
		wantTool string
	}{
		{cs, true, rc.ActionID, "update_project"}, // recorded as update_workbench
		{cs, true, oldRow, "add_project_source"},  // recorded before the rename
		{current, false, rc.ActionID, "update_workbench"},
		{current, false, oldRow, "add_workbench_source"},
	} {
		if got := getActionTool(t, c.session, c.id); got != c.wantTool {
			t.Errorf("get_action #%d (legacy=%v) names %q, want %q", c.id, c.legacy, got, c.wantTool)
		}
	}

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{Name: "search_knowledge",
		Arguments: map[string]any{"queries": []any{"x"}, "project_scope": "only"}})
	if err != nil || !res.IsError {
		t.Fatalf("a scope with no sources must be refused: %v", err)
	}
	if got := textContent(t, res); !strings.Contains(got, "add one with add_project_source") || strings.Contains(got, "add_workbench_source") {
		t.Errorf("the legacy session's refusal must name its own tools: %s", got)
	}
}

// applyLegacyUpdateProject sets the description through the legacy
// update_project name and returns the receipt, which names the tool the
// session called.
func applyLegacyUpdateProject(t *testing.T, cs *mcpsdk.ClientSession) tools.Receipt {
	t.Helper()
	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{Name: "update_project",
		Arguments: map[string]any{"description": "Set up before the rename.", "reason": "setup"}})
	if err != nil || res.IsError {
		t.Fatalf("update_project: %v %s", err, textContent(t, res))
	}
	var rc tools.Receipt
	if err := json.Unmarshal([]byte(textContent(t, res)), &rc); err != nil {
		t.Fatal(err)
	}
	if rc.Status != "applied" || rc.Tool != "update_project" {
		t.Fatalf("the legacy session's receipt names the tool it called: %+v", rc)
	}
	return rc
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

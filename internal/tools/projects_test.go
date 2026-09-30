package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// projectFixture is two projects side by side plus a plain (non-project)
// target, so every scope test can aim a call at the other project.
type projectFixture struct {
	d                            *db.DB
	a, b                         int64 // project ids; sessions are bound to a
	aTarget, bTarget, plain      int64
	bSource, bComment, bDocument int64
}

func newProjectFixture(t *testing.T) projectFixture {
	t.Helper()
	d := openDB(t)
	fx := projectFixture{d: d, a: seedProject(t, d, "alpha"), b: seedProject(t, d, "beta")}
	var err error
	fx.aTarget, err = d.CreateProjectTarget(fx.a, sql.NullInt64{}, "Alpha feature", "")
	require.NoError(t, err)
	fx.bTarget, err = d.CreateProjectTarget(fx.b, sql.NullInt64{}, "Beta feature", "")
	require.NoError(t, err)
	fx.plain, err = d.CreateTarget(db.Target{Text: "Personal task", Level: "day", Status: "todo",
		Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	fx.bSource, err = d.AddProjectSource(db.ProjectSource{ProjectID: fx.b, Kind: "link", Ref: "https://example.com/beta"})
	require.NoError(t, err)
	fx.bComment, err = d.AddProjectComment(db.ProjectComment{ProjectID: fx.b,
		TargetID: sql.NullInt64{Int64: fx.bTarget, Valid: true}, Author: "owner", Body: "why?"})
	require.NoError(t, err)
	fx.bDocument, _, err = d.UpsertProjectDocument(db.ProjectDocument{ProjectID: fx.b, RelPath: "docs/beta.md", Kind: "doc"})
	require.NoError(t, err)
	return fx
}

func projectRegistry(t *testing.T, d *db.DB) *Registry {
	t.Helper()
	reg := New(d)
	for _, tool := range append(ProjectTools(), NewListTargets(), NewGetTarget()) {
		require.NoError(t, reg.Register(tool))
	}
	return reg
}

// proposeIn runs a write tool the way `mcp --project` does: DirectApply,
// bound to projectID.
func proposeIn(t *testing.T, reg *Registry, projectID int64, name, args string) (Receipt, error) {
	t.Helper()
	return reg.Propose(context.Background(), name, json.RawMessage(args), directBinding(projectID))
}

func mustApply(t *testing.T, reg *Registry, projectID int64, name, args string) map[string]any {
	t.Helper()
	rc, err := proposeIn(t, reg, projectID, name, args)
	require.NoError(t, err)
	require.Equal(t, "applied", rc.Status, "receipt: %+v", rc)
	out, ok := rc.Result.(map[string]any)
	require.True(t, ok, "result %T", rc.Result)
	return out
}

func countProjectTargets(t *testing.T, d *db.DB, projectID int64) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(`SELECT count(*) FROM targets WHERE project_id = ?`, projectID).Scan(&n))
	return n
}

func countActions(t *testing.T, d *db.DB) int {
	t.Helper()
	rows, err := d.ListAgentActions(db.AgentActionFilter{})
	require.NoError(t, err)
	return len(rows)
}

func TestProjectTools_AllOnProjectSurfaceNeverExternal(t *testing.T) {
	for _, tool := range ProjectTools() {
		assert.Equal(t, []string{"project"}, tool.Surfaces, tool.Name)
		assert.False(t, tool.External, "%s must stay on this machine (DEV-06)", tool.Name)
		if tool.Access == AccessWrite {
			assert.NotNil(t, tool.Scope, "%s must scope its writes to the bound project", tool.Name)
		}
	}
}

func TestProjectInfo_DescribesTheBoundProject(t *testing.T) {
	fx := newProjectFixture(t)
	reg := projectRegistry(t, fx.d)
	mustApply(t, reg, fx.a, "update_project", `{"description":"A test project.","reason":"setup"}`)

	got := callReadIn(t, reg, fx.a, "project_info", `{}`)
	assert.Contains(t, got, `"name":"alpha"`)
	assert.Contains(t, got, `"description":"A test project."`)
	assert.Contains(t, got, `"targets_by_status":{"todo":1}`)
	assert.NotContains(t, got, "beta", "another project's data never leaks into project_info")
}

func callReadIn(t *testing.T, reg *Registry, projectID int64, name, args string) string {
	t.Helper()
	data, err := reg.CallRead(context.Background(), name, json.RawMessage(args), directBinding(projectID))
	require.NoError(t, err)
	b, err := json.Marshal(data)
	require.NoError(t, err)
	return string(b)
}

func TestProjectBoard_ReturnsTheTreeAndDocuments(t *testing.T) {
	fx := newProjectFixture(t)
	reg := projectRegistry(t, fx.d)
	mustApply(t, reg, fx.a, "create_targets", fmt.Sprintf(
		`{"items":[{"text":"Task 1","parent_id":%d}],"reason":"plan"}`, fx.aTarget))

	got := callReadIn(t, reg, fx.a, "project_board", `{}`)
	assert.Contains(t, got, `"text":"Alpha feature"`)
	assert.Contains(t, got, `"children":[{"id":`)
	assert.Contains(t, got, `"text":"Task 1"`)
	assert.NotContains(t, got, "Beta feature")
}

func TestProjectSources_AddAndRemove(t *testing.T) {
	fx := newProjectFixture(t)
	reg := projectRegistry(t, fx.d)
	out := mustApply(t, reg, fx.a, "add_project_source", `{"kind":"jira_project","ref":"ACME","reason":"named in README"}`)
	id := int64(out["source_id"].(float64))

	sources, err := fx.d.ListProjectSources(fx.a)
	require.NoError(t, err)
	require.Len(t, sources, 1)
	assert.Equal(t, "ACME", sources[0].Ref)

	mustApply(t, reg, fx.a, "remove_project_source", fmt.Sprintf(`{"source_id":%d,"reason":"wrong"}`, id))
	sources, err = fx.d.ListProjectSources(fx.a)
	require.NoError(t, err)
	assert.Empty(t, sources)

	_, err = proposeIn(t, reg, fx.a, "add_project_source", `{"kind":"wiki","ref":"x","reason":"r"}`)
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
}

// Review Focus #3: a whole plan in one call — a feature, its tasks under it by
// parent_key, a sub-step two levels down, and one more task under an existing
// target by parent_id.
func TestCreateTargets_NestedPlanInOneCall(t *testing.T) {
	fx := newProjectFixture(t)
	reg := projectRegistry(t, fx.d)
	out := mustApply(t, reg, fx.a, "create_targets", fmt.Sprintf(`{"items":[
		{"key":"f","text":"Feature X","intent":"spec docs/x.md"},
		{"key":"t1","text":"Task 1","intent":"plan docs/x-plan.md task 1","parent_key":"f"},
		{"text":"Task 1a","parent_key":"t1"},
		{"text":"Task 2","parent_key":"f"},
		{"text":"Follow-up","parent_id":%d}
	],"reason":"plan docs/x-plan.md"}`, fx.aTarget))

	created := out["created"].([]any)
	require.Len(t, created, 5)
	id := func(i int) int { return int(created[i].(map[string]any)["target_id"].(float64)) }
	assert.Equal(t, 6, countProjectTargets(t, fx.d, fx.a))

	sub, err := fx.d.GetTargetByID(id(2))
	require.NoError(t, err)
	assert.Equal(t, int64(id(1)), sub.ParentID.Int64, "Task 1a nests under Task 1 via parent_key")
	task1, err := fx.d.GetTargetByID(id(1))
	require.NoError(t, err)
	assert.Equal(t, int64(id(0)), task1.ParentID.Int64)
	assert.Equal(t, "plan docs/x-plan.md task 1", task1.Intent)
	assert.Equal(t, fx.a, task1.ProjectID.Int64, "project_id comes from the binding")
	followUp, err := fx.d.GetTargetByID(id(4))
	require.NoError(t, err)
	assert.Equal(t, fx.aTarget, followUp.ParentID.Int64)
}

// Review Focus #3: one bad item and nothing is created — no target, no row.
func TestCreateTargets_OneBadItemCreatesNothing(t *testing.T) {
	fx := newProjectFixture(t)
	reg := projectRegistry(t, fx.d)
	cases := map[string]string{
		"unknown parent_key":          `{"items":[{"key":"f","text":"F"},{"text":"T","parent_key":"nope"}],"reason":"r"}`,
		"parent_key forward ref":      `{"items":[{"text":"T","parent_key":"f"},{"key":"f","text":"F"}],"reason":"r"}`,
		"empty text":                  `{"items":[{"key":"f","text":"F"},{"text":"  ","parent_key":"f"}],"reason":"r"}`,
		"duplicate key":               `{"items":[{"key":"f","text":"F"},{"key":"f","text":"G"}],"reason":"r"}`,
		"both parents":                fmt.Sprintf(`{"items":[{"key":"f","text":"F"},{"text":"T","parent_key":"f","parent_id":%d}],"reason":"r"}`, fx.aTarget),
		"parent in other project":     fmt.Sprintf(`{"items":[{"text":"F"},{"text":"T","parent_id":%d}],"reason":"r"}`, fx.bTarget),
		"parent not a project target": fmt.Sprintf(`{"items":[{"text":"F"},{"text":"T","parent_id":%d}],"reason":"r"}`, fx.plain),
		"no items":                    `{"items":[],"reason":"r"}`,
	}
	for name, args := range cases {
		_, err := proposeIn(t, reg, fx.a, "create_targets", args)
		var verr *ValidationError
		require.ErrorAs(t, err, &verr, name)
	}
	assert.Equal(t, 1, countProjectTargets(t, fx.d, fx.a), "only the fixture's own target")
	assert.Equal(t, 0, countActions(t, fx.d), "a refused batch writes no audit row")
}

// A failure inside the transaction (forced by a trigger on the third insert)
// rolls the whole batch back; the audit row records the failure.
func TestCreateTargets_MidBatchFailureRollsBack(t *testing.T) {
	fx := newProjectFixture(t)
	reg := projectRegistry(t, fx.d)
	_, err := fx.d.Exec(`CREATE TRIGGER fail_boom BEFORE INSERT ON targets WHEN NEW.text = 'boom'
		BEGIN SELECT RAISE(ABORT, 'boom'); END`)
	require.NoError(t, err)

	rc, err := proposeIn(t, reg, fx.a, "create_targets",
		`{"items":[{"key":"f","text":"F"},{"text":"ok","parent_key":"f"},{"text":"boom","parent_key":"f"}],"reason":"r"}`)
	require.NoError(t, err)
	assert.Equal(t, "failed", rc.Status)
	assert.Contains(t, rc.Error, "boom")
	assert.Equal(t, 1, countProjectTargets(t, fx.d, fx.a), "nothing half-created")
}

func TestUpdateTarget_ChangesStatusProgressAndText(t *testing.T) {
	fx := newProjectFixture(t)
	reg := projectRegistry(t, fx.d)
	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(
		`{"target_id":%d,"status":"in_progress","progress":0.4,"text":"Alpha feature v2","intent":"ship it","reason":"started"}`, fx.aTarget))

	got, err := fx.d.GetTargetByID(int(fx.aTarget))
	require.NoError(t, err)
	assert.Equal(t, "in_progress", got.Status)
	assert.InDelta(t, 0.4, got.Progress, 1e-9)
	assert.Equal(t, "Alpha feature v2", got.Text)
	assert.Equal(t, "ship it", got.Intent)
	assert.Equal(t, fx.a, got.ProjectID.Int64, "an edit keeps the target on its board")

	for _, args := range []string{
		fmt.Sprintf(`{"target_id":%d,"reason":"r"}`, fx.aTarget),
		fmt.Sprintf(`{"target_id":%d,"status":"snoozed","reason":"r"}`, fx.aTarget),
		fmt.Sprintf(`{"target_id":%d,"progress":1.5,"reason":"r"}`, fx.aTarget),
	} {
		_, err := proposeIn(t, reg, fx.a, "update_target", args)
		var verr *ValidationError
		require.ErrorAs(t, err, &verr, args)
	}
}

// I4 (docs/superpowers/sdd/2026-09-29-projects-poc/final-review.md): a
// text/intent-only update must never reset a leaf's progress. Before the
// fix, applyTargetText rewrote the whole row through db.UpdateTarget, which
// re-derives progress from status on every call — a rename would have
// silently dropped 0.4 back to statusToProgress("in_progress") == 0.5.
func TestUpdateTarget_TextOnlyLeavesProgressAlone(t *testing.T) {
	fx := newProjectFixture(t)
	reg := projectRegistry(t, fx.d)
	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(
		`{"target_id":%d,"status":"in_progress","progress":0.4,"reason":"started"}`, fx.aTarget))

	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(
		`{"target_id":%d,"text":"Alpha feature, renamed","reason":"rename"}`, fx.aTarget))

	got, err := fx.d.GetTargetByID(int(fx.aTarget))
	require.NoError(t, err)
	assert.Equal(t, "Alpha feature, renamed", got.Text)
	assert.Equal(t, "in_progress", got.Status, "status is untouched by a text-only update")
	assert.InDelta(t, 0.4, got.Progress, 1e-9, "a rename must not reset progress to the status default")
}

// list_targets/get_target follow the session: a project session sees only its
// board, every other session never sees a project target (PROJ-01).
func TestProj01_TargetReadsFollowTheSessionScope(t *testing.T) {
	fx := newProjectFixture(t)
	reg := projectRegistry(t, fx.d)

	inA := callReadIn(t, reg, fx.a, "list_targets", `{}`)
	assert.Contains(t, inA, "Alpha feature")
	assert.NotContains(t, inA, "Beta feature")
	assert.NotContains(t, inA, "Personal task")

	plain := callReadString(t, reg, "list_targets", `{}`)
	assert.Contains(t, plain, "Personal task")
	assert.NotContains(t, plain, "Alpha feature", "a project target never reaches a non-project session")

	_, err := reg.CallRead(context.Background(), "get_target", json.RawMessage(fmt.Sprintf(`{"id":%d}`, fx.bTarget)), directBinding(fx.a))
	assert.ErrorContains(t, err, "no target with id")
	_, err = reg.CallRead(context.Background(), "get_target", json.RawMessage(fmt.Sprintf(`{"id":%d}`, fx.aTarget)), Binding{})
	assert.ErrorContains(t, err, "no target with id")
}

// outsideProjectCall is one write aimed at data outside the bound project.
// wantNotInProject is true when the refusal must specifically be
// db.ErrNotInProject (as opposed to some other ValidationError, e.g. an
// unknown-field decode failure from a smuggled project_id).
type outsideProjectCall struct {
	name             string
	tool             string
	args             string
	wantNotInProject bool
}

// outsideProjectCalls lists every write the DEV-06 guard aims at project b (or
// at no project) from a session bound to project a. Task 8 appends the
// document and comment tools. The attach_document case needs a real file
// inside project a's folder — otherwise resolveInsideFolder's "does not
// exist" check refuses the call before optionalTarget ever runs, making the
// case vacuous for the cross-project-target guard it is meant to exercise.
func outsideProjectCalls(t *testing.T, fx projectFixture) []outsideProjectCall {
	t.Helper()
	writeProjectFile(t, fx.d, fx.a, "docs/other-project-link.md", "# doc\n")
	return []outsideProjectCall{
		{"update another project's target", "update_target", fmt.Sprintf(`{"target_id":%d,"status":"done","reason":"r"}`, fx.bTarget), true},
		{"update a non-project target", "update_target", fmt.Sprintf(`{"target_id":%d,"status":"done","reason":"r"}`, fx.plain), true},
		{"nest under another project's target", "create_targets", fmt.Sprintf(`{"items":[{"text":"x","parent_id":%d}],"reason":"r"}`, fx.bTarget), true},
		{"smuggle a project_id", "create_targets", fmt.Sprintf(`{"project_id":%d,"items":[{"text":"x"}],"reason":"r"}`, fx.b), false},
		{"smuggle a project_id into a source", "add_project_source", fmt.Sprintf(`{"project_id":%d,"kind":"link","ref":"x","reason":"r"}`, fx.b), false},
		{"remove another project's source", "remove_project_source", fmt.Sprintf(`{"source_id":%d,"reason":"r"}`, fx.bSource), true},
		{"comment on another project's target", "add_comment", fmt.Sprintf(`{"target_id":%d,"body":"hi","reason":"r"}`, fx.bTarget), true},
		{"comment on a non-project target", "add_comment", fmt.Sprintf(`{"target_id":%d,"body":"hi","reason":"r"}`, fx.plain), true},
		{"reply in another project's thread", "add_comment", fmt.Sprintf(`{"parent_id":%d,"body":"hi","reason":"r"}`, fx.bComment), true},
		{"resolve another project's comment", "resolve_comment", fmt.Sprintf(`{"comment_id":%d,"reply":"done","reason":"r"}`, fx.bComment), true},
		{"link a document to another project's target", "attach_document", fmt.Sprintf(`{"rel_path":"docs/other-project-link.md","kind":"doc","target_id":%d,"reason":"r"}`, fx.bTarget), true},
	}
}

// DEV-06: a project session writes only its own project's rows. Every write
// aimed elsewhere is refused before any row — data or audit — is written.
func TestDev06_WriteOutsideTheBoundProjectIsRefused(t *testing.T) {
	fx := newProjectFixture(t)
	reg := projectRegistry(t, fx.d)
	before := snapshotProject(t, fx.d, fx.b)
	plainBefore, err := fx.d.GetTargetByID(int(fx.plain))
	require.NoError(t, err)

	for _, c := range outsideProjectCalls(t, fx) {
		_, err := proposeIn(t, reg, fx.a, c.tool, c.args)
		var verr *ValidationError
		require.ErrorAs(t, err, &verr, c.name)
		if c.wantNotInProject {
			assert.ErrorIs(t, err, db.ErrNotInProject, c.name)
		}
	}

	assert.Equal(t, before, snapshotProject(t, fx.d, fx.b), "project b is byte-identical")
	plainAfter, err := fx.d.GetTargetByID(int(fx.plain))
	require.NoError(t, err)
	assert.Equal(t, plainBefore, plainAfter, "the non-project target is untouched")
	assert.Equal(t, 1, countProjectTargets(t, fx.d, fx.a), "nothing landed on the bound project either")
	assert.Equal(t, 0, countActions(t, fx.d), "a refused write leaves no audit row")
}

// snapshotProject dumps every row of one project across the project tables
// and its targets, for a byte-identical before/after comparison.
func snapshotProject(t *testing.T, d *db.DB, projectID int64) []string {
	t.Helper()
	queries := []string{
		`SELECT id || '|' || name || '|' || description || '|' || updated_at FROM projects WHERE id = ?`,
		`SELECT id || '|' || kind || '|' || ref FROM project_sources WHERE project_id = ? ORDER BY id`,
		`SELECT id || '|' || text || '|' || status || '|' || progress || '|' || updated_at FROM targets WHERE project_id = ? ORDER BY id`,
		`SELECT id || '|' || rel_path || '|' || updated_at FROM project_documents WHERE project_id = ? ORDER BY id`,
		`SELECT id || '|' || status || '|' || body FROM project_comments WHERE project_id = ? ORDER BY id`,
	}
	var out []string
	for _, q := range queries {
		out = append(out, queryStrings(t, d, q, projectID)...)
	}
	return out
}

func queryStrings(t *testing.T, d *db.DB, q string, args ...any) []string {
	t.Helper()
	rows, err := d.Query(q, args...)
	require.NoError(t, err)
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		require.NoError(t, rows.Scan(&s))
		out = append(out, s)
	}
	require.NoError(t, rows.Err())
	return out
}

// update_target's text, status and progress writes are one transaction: a
// failure on the last step leaves the target exactly as it was.
func TestUpdateTarget_FailureMidUpdateRollsBack(t *testing.T) {
	fx := newProjectFixture(t)
	reg := projectRegistry(t, fx.d)
	_, err := fx.d.Exec(`CREATE TRIGGER fail_progress BEFORE UPDATE OF progress ON targets
		WHEN NEW.progress = 0.37 BEGIN SELECT RAISE(ABORT, 'boom'); END`)
	require.NoError(t, err)

	rc, err := proposeIn(t, reg, fx.a, "update_target", fmt.Sprintf(
		`{"target_id":%d,"status":"in_progress","progress":0.37,"text":"Renamed","reason":"r"}`, fx.aTarget))
	require.NoError(t, err)
	assert.Equal(t, "failed", rc.Status)
	got, err := fx.d.GetTargetByID(int(fx.aTarget))
	require.NoError(t, err)
	assert.Equal(t, "Alpha feature", got.Text, "the rename rolled back")
	assert.Equal(t, "todo", got.Status, "the status change rolled back")
}

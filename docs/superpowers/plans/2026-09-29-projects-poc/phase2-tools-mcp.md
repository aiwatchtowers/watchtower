# Projects POC — Phase 2: Tools + MCP (Tasks 6–9)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Claude Code a project-bound, writable MCP mode: `watchtower mcp --project N` mounts eleven project tools (board, sources, targets, documents, comments) that apply directly to project N — audited, scoped, never External — while plain `watchtower mcp` stays the read-only developer surface.

**Architecture:** The registry (`internal/tools/registry.go`) gains two `Binding` fields — `ProjectID` and `DirectApply` — and one optional `Tool.Scope` hook for binding-aware checks. `Propose` under `DirectApply` records the `agent_actions` row as approved (`trust_at_create='execute'`) and applies it inline, for that call only; it refuses an `External` tool and any tool that does not name the binding's surface explicitly. The project id travels in the row's existing `context_type='project'`/`context_id=N` columns, so `Apply` rebuilds the same binding and re-runs `Scope` (no migration). Every call on a project binding first checks the project still exists ("project N no longer exists"). `CallRead` now takes the `Binding` too, so `list_targets`/`get_target` scope themselves (0 = non-project session: project targets never appear, PROJ-01). The project tools live in `internal/tools/projects.go` (info/board/project/sources), `project_targets.go` (`create_targets`, `update_target`) and `project_docs.go` (documents + comments); `cmd/mcp.go` adds `--project N`.

**Tech Stack:** Go 1.25, `github.com/google/jsonschema-go`, `github.com/modelcontextprotocol/go-sdk` (existing), testify, modernc SQLite.

**Spec:** `docs/superpowers/specs/2026-09-29-project-board-poc-design.md` §4.2, §4.3, §7 (revision 4). Read `docs/inventory/dev-surface.md` (DEV-01..05) and `docs/inventory/agent-actions.md` (AGENT-01..06) before starting — DEV-06 is new and DEV-01/DEV-05/AGENT-01/AGENT-02 are amended in Task 9 with owner approval via spec decision D5; nothing else may weaken.

**Global rules for this phase** (plan index Global Constraints are binding):
- Go inner loop: `go test ./internal/<pkg> -run <Name>` (no `-count=1`); `go test ./cmd -run <Name>` targeted; `make lint-diff`. The full gate runs once per phase, by the controller.
- Everything in English. One commit per task; stage only the files the task lists (never `git add -A`).
- Keep functions small (the complexity gate): every helper below is already split to stay well under it — do not merge them back.

**Consumes from Phase 1** (package `db`): `Project`, `ProjectSource`, `ProjectDocument`, `ProjectComment`, `ProjectCommentFilter`, `BoardNode` (`Target.ID` is `int`), `ErrProjectNotFound`, `ResolveProjectFolder`, `CreateProject`, `GetProject` (a missing id returns an error for which `errors.Is(err, db.ErrProjectNotFound)`), `DeleteProject`, `UpdateProjectDescription`, `AddProjectSource`, `RemoveProjectSource`, `ListProjectSources`, `UpsertProjectDocument`, `GetProjectDocument`, `ListProjectDocuments`, `AddProjectComment`, `GetProjectComment`, `ListProjectComments`, `SetProjectCommentStatus`, `GetProjectBoard` (no existence check), `CreateProjectTarget`, `ProjectTargetInput`, `CreateProjectTargetsTx` (batch), `WithTx` (Task 2), `ErrNotInProject`; `Target.ProjectID sql.NullInt64` scanned by `GetTargetByID`/`GetTargets` and preserved by `UpdateTarget`; `TargetFilter.ProjectID` (0 = exclude project targets, N = only N). Exact signatures used here are listed under **Interface errata** at the end.

**Review Focus covered in this phase:**
- **#1 (folder edge cases, the `attach_document` half):** `TestDev06_AttachDocumentStaysInsideTheFolder` (Task 8) — `../`, nested `../`, absolute path, symlinked file, symlinked directory, plus a path with a space and non-ASCII characters that does attach.
- **#3 (a whole plan in one `create_targets` call):** `TestCreateTargets_NestedPlanInOneCall` (three levels by `parent_key` + one `parent_id`), `TestCreateTargets_OneBadItemCreatesNothing` (unknown/forward `parent_key`, empty text, duplicate key, both parents, parent in another project, non-project parent, empty batch — no target, no audit row), `TestCreateTargets_MidBatchFailureRollsBack` (a trigger aborts the third insert; nothing half-created, the audit row records `failed`) — Task 7.
- **#5 (project deleted while CC is connected, the tool half):** `TestProjectBinding_DeletedProjectAnswersNoLongerExists` (Task 6) and `TestProjectMode_DeletedProjectEveryToolAnswersNoLongerExists` (Task 9, through the MCP adapter, project and non-project tools alike).

---

## Task 6: Registry DirectApply + bound reads

**Files:**
- Modify: `internal/tools/registry.go` (Binding fields, `Tool.Scope`, `ValidationError.Err`, `Propose` split into gates, `CallRead` binding, `Apply` re-scope)
- Create: `internal/tools/project_scope.go` (`projectContextType`, `projectOf`)
- Create: `internal/tools/registry_project_test.go`
- Modify: every `internal/tools/*_test.go` calling `CallRead` (mechanical: append `Binding{}`)
- Modify: `internal/agentloop/client.go`, `internal/agentloop/loop_test.go`
- Modify: `internal/mcp/actions.go` (the read handler passes its binding — required here, the signature change breaks the package otherwise)

**Interfaces:**
- Consumes: `db.GetProject`, `db.ErrProjectNotFound`, `db.ResolveProjectFolder`, `db.CreateProject`, `db.DeleteProject` (Phase 1); existing `db.AgentAction`, `InsertAgentAction`, `TransitionAgentAction`, `GetAgentAction`.
- Produces (binding for Tasks 7–9):
  - `tools.Binding` gains `ProjectID int64` and `DirectApply bool`.
  - `tools.ValidationError` gains `Err error` + `Unwrap() error`, so a model-facing refusal can carry a sentinel (`errors.Is(err, db.ErrNotInProject)`).
  - `tools.Tool` gains `Scope func(ctx context.Context, d *db.DB, args json.RawMessage, b Binding) error` — runs after `Validate` in `Propose` (a `*ValidationError` writes no row) and again in `Apply` before `Execute`, against the binding rebuilt from the row.
  - `func (r *Registry) CallRead(ctx context.Context, name string, args json.RawMessage, b Binding) (any, error)` — `Call.Binding` is populated for reads.
  - `func projectOf(ctx context.Context, d *db.DB, b Binding) (*db.Project, error)` — `ProjectID == 0` → ValidationError "this tool works only in a project session (watchtower mcp --project N)"; missing → ValidationError `project N no longer exists`.
  - `const projectContextType = "project"` — a project-bound row stores `context_type='project'`, `context_id='<N>'`.
  - agentloop's `registry` interface: `CallRead(ctx, name, args, b tools.Binding)`; the loop passes `c.binding`.
- DirectApply rules (spec §4.2): execute trust for this call only (row inserted approved, `trust_at_create='execute'`, applied inline, audit kept; `tool_trust` never read or written); an `External` tool is refused with a ValidationError; a tool whose `Surfaces` does not explicitly contain `Binding.Surface` is refused (a surface-less tool is visible everywhere and must not inherit direct apply).

- [ ] **Step 1: Write the failing tests**

First — before creating any new test file, so the rewrite never touches a call that already has four arguments — update every existing `CallRead` call in the tools tests to the new signature (appends `, Binding{}` as the last argument; the recursive pattern handles nested parentheses and the one multi-line call in `knowledge_test.go`):

```bash
perl -0777 -pi -e 's/\.CallRead(\((?:[^()]++|(?1))*\))/".CallRead" . substr($1, 0, -1) . ", Binding{})"/ge' internal/tools/*_test.go
git diff --shortstat -- internal/tools
```

Expected: `14 files changed, 47 insertions(+), 47 deletions(-)` — one line per call site (the multi-line call in `knowledge_test.go` changes only its argument line). Step 5's compile is the real check.

Then create `internal/tools/registry_project_test.go`:


```go
package tools

import (
	"context"
	"encoding/json"
	"strconv"
	"testing"

	"github.com/google/jsonschema-go/jsonschema"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// seedProject creates a project bound to a fresh temp folder and returns its id.
func seedProject(t *testing.T, d *db.DB, name string) int64 {
	t.Helper()
	folder, err := db.ResolveProjectFolder(t.TempDir())
	require.NoError(t, err)
	id, err := d.CreateProject(name, folder)
	require.NoError(t, err)
	return id
}

// newProjectEchoTool is a write tool on the given surfaces that records every
// Execute call, so a test can see whether and with which binding it ran.
func newProjectEchoTool(t *testing.T, external bool, surfaces []string, executed *[]Call) *Tool {
	t.Helper()
	schema, err := jsonschema.For[echoArgs](nil)
	require.NoError(t, err)
	return &Tool{
		Name: "pecho", Description: "test tool", InputSchema: schema,
		Access: AccessWrite, External: external, Surfaces: surfaces,
		Validate: func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Execute: func(_ context.Context, _ *db.DB, call Call) (any, error) {
			*executed = append(*executed, call)
			return map[string]any{"ok": true}, nil
		},
	}
}

func directBinding(projectID int64) Binding {
	return Binding{Surface: "project", ProjectID: projectID, DirectApply: true}
}

const pechoArgs = `{"text":"hi","reason":"r"}`

// DEV-06: DirectApply never runs an External tool — not even once, not as a
// pending proposal: the call is refused before any row is written.
func TestDev06_ExternalToolRefusedUnderDirectApply(t *testing.T) {
	d := openDB(t)
	pid := seedProject(t, d, "acme")
	var executed []Call
	reg := New(d)
	require.NoError(t, reg.Register(newProjectEchoTool(t, true, []string{"project"}, &executed)))

	_, err := reg.Propose(context.Background(), "pecho", json.RawMessage(pechoArgs), directBinding(pid))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "never runs in a direct-apply session")
	assert.Empty(t, executed, "an External tool must never execute under DirectApply")
	rows, err := d.ListAgentActions(db.AgentActionFilter{})
	require.NoError(t, err)
	assert.Empty(t, rows, "a refused direct-apply call writes no row")
}

// DirectApply applies a non-External tool inline with a full audit row, for
// this call only: the owner's stored trust stays "ask".
func TestDirectApply_AppliesInlineWithAuditRow(t *testing.T) {
	d := openDB(t)
	pid := seedProject(t, d, "acme")
	var executed []Call
	reg := New(d)
	require.NoError(t, reg.Register(newProjectEchoTool(t, false, []string{"project"}, &executed)))

	rc, err := reg.Propose(context.Background(), "pecho", json.RawMessage(pechoArgs), directBinding(pid))
	require.NoError(t, err)
	assert.Equal(t, "applied", rc.Status)
	require.Len(t, executed, 1)
	assert.Equal(t, pid, executed[0].Binding.ProjectID, "Execute sees the bound project")

	row, err := d.GetAgentAction(rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "applied", row.Status)
	assert.Equal(t, "execute", row.TrustAtCreate)
	assert.Equal(t, "project", row.ContextType)
	assert.Equal(t, strconv.FormatInt(pid, 10), row.ContextID)
	assert.Equal(t, "r", row.Reason)

	trust, err := reg.Trust("pecho")
	require.NoError(t, err)
	assert.Equal(t, TrustAsk, trust, "DirectApply is not global trust")
}

// A tool that does not name the project surface (or names none, which means
// "every surface") never inherits direct apply.
func TestDirectApply_RefusesToolNotOnTheSurface(t *testing.T) {
	d := openDB(t)
	pid := seedProject(t, d, "acme")
	for _, surfaces := range [][]string{nil, {"main"}} {
		var executed []Call
		reg := New(d)
		require.NoError(t, reg.Register(newProjectEchoTool(t, false, surfaces, &executed)))
		_, err := reg.Propose(context.Background(), "pecho", json.RawMessage(pechoArgs), directBinding(pid))
		var verr *ValidationError
		require.ErrorAs(t, err, &verr, "surfaces %v", surfaces)
		assert.Empty(t, executed)
	}
}

// Review Focus #5: once the bound project is deleted, every call — write or
// read, project tool or not — answers "project N no longer exists".
func TestProjectBinding_DeletedProjectAnswersNoLongerExists(t *testing.T) {
	d := openDB(t)
	pid := seedProject(t, d, "acme")
	var executed, reads []Call
	reg := New(d)
	require.NoError(t, reg.Register(newProjectEchoTool(t, false, []string{"project"}, &executed)))
	require.NoError(t, reg.Register(newPeekTool(t, &reads)))
	require.NoError(t, d.DeleteProject(pid))
	want := "project " + strconv.FormatInt(pid, 10) + " no longer exists"

	_, err := reg.Propose(context.Background(), "pecho", json.RawMessage(pechoArgs), directBinding(pid))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Equal(t, want, verr.Msg)

	_, err = reg.CallRead(context.Background(), "peek", json.RawMessage(`{"query":"x"}`), directBinding(pid))
	require.ErrorAs(t, err, &verr)
	assert.Equal(t, want, verr.Msg)
	assert.Empty(t, executed)
	assert.Empty(t, reads)
}

// CallRead hands the binding to Execute.
func TestCallRead_PassesBindingToExecute(t *testing.T) {
	d := openDB(t)
	pid := seedProject(t, d, "acme")
	var reads []Call
	reg := New(d)
	require.NoError(t, reg.Register(newPeekTool(t, &reads)))

	_, err := reg.CallRead(context.Background(), "peek", json.RawMessage(`{"query":"x"}`), Binding{Surface: "project", ProjectID: pid})
	require.NoError(t, err)
	require.Len(t, reads, 1)
	assert.Equal(t, pid, reads[0].Binding.ProjectID)
}

// Scope runs in Propose (a refusal writes no row) and again in Apply against
// the binding rebuilt from the row: an approved project proposal whose
// project was deleted meanwhile fails instead of executing.
func TestScope_RunsInProposeAndAgainInApply(t *testing.T) {
	d := openDB(t)
	pid := seedProject(t, d, "acme")
	var executed []Call
	tool := newProjectEchoTool(t, false, []string{"project"}, &executed)
	var scoped []Binding
	tool.Scope = func(_ context.Context, _ *db.DB, raw json.RawMessage, b Binding) error {
		scoped = append(scoped, b)
		if string(raw) == `{"text":"bad","reason":"r"}` {
			return &ValidationError{Msg: "out of scope"}
		}
		return nil
	}
	reg := New(d)
	require.NoError(t, reg.Register(tool))
	bound := Binding{Surface: "project", ProjectID: pid} // ask trust: stays pending

	_, err := reg.Propose(context.Background(), "pecho", json.RawMessage(`{"text":"bad","reason":"r"}`), bound)
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	rows, _ := d.ListAgentActions(db.AgentActionFilter{})
	assert.Empty(t, rows, "a Scope refusal writes no row")

	rc, err := reg.Propose(context.Background(), "pecho", json.RawMessage(pechoArgs), bound)
	require.NoError(t, err)
	require.Equal(t, "pending", rc.Status)
	ok, err := d.TransitionAgentAction(rc.ActionID, []string{"pending"}, "approved", "", "")
	require.NoError(t, err)
	require.True(t, ok)
	require.NoError(t, d.DeleteProject(pid))

	row, err := reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Contains(t, row.Error, "no longer exists")
	assert.Empty(t, executed, "a de-scoped row never executes")
	require.Len(t, scoped, 2, "Scope ran for both proposals, never again once the project was gone")
	assert.Equal(t, pid, scoped[1].ProjectID)
}
```

Append to `internal/agentloop/loop_test.go` — first extend `fakeReg` so it records the binding of each read. Replace:

```go
	reads    []string
	readData any
}
```

with:

```go
	reads    []string
	readData any

	readBindings []tools.Binding
}
```

and replace its `CallRead`:

```go
func (f *fakeReg) CallRead(_ context.Context, name string, _ json.RawMessage) (any, error) {
	f.reads = append(f.reads, name)
```

with:

```go
func (f *fakeReg) CallRead(_ context.Context, name string, _ json.RawMessage, b tools.Binding) (any, error) {
	f.reads = append(f.reads, name)
	f.readBindings = append(f.readBindings, b)
```

Then append the test:

```go
// A read tool call reaches the registry with the loop's binding, so a
// binding-scoped read (list_targets in a project session) sees its scope.
func TestLoop_ReadCallCarriesTheBinding(t *testing.T) {
	reg := &fakeReg{tools: map[string]*tools.Tool{"list_targets": tools.NewListTargets()}, readData: []any{}}
	srv, _ := scriptedServer(t, toolCallResp("list_targets", `{}`), finalResp("done"))
	c := clientWith(reg, srv.URL)
	c.binding = tools.Binding{Surface: "main", ConversationID: 12}

	_, _, err := c.run(context.Background(), "sys", "list", nil)
	require.NoError(t, err)
	require.Len(t, reg.readBindings, 1)
	assert.Equal(t, int64(12), reg.readBindings[0].ConversationID)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `go test ./internal/tools ./internal/agentloop > /tmp/p2t6.log 2>&1; echo "exit=$?"; grep -m5 -E "undefined|too many|unknown field" /tmp/p2t6.log`
Expected: `exit=1`, compile errors such as `unknown field ProjectID in struct literal of type Binding`, `unknown field DirectApply`, `t.Scope undefined`, `too many arguments in call to reg.CallRead`, and in agentloop `*fakeReg does not implement registry (wrong type for method CallRead)`.

- [ ] **Step 3: Implement the registry changes**

In `internal/tools/registry.go`:

(a) Imports — add `"strconv"` between `"slices"` and `"strings"`.

(b) Replace the `Binding` doc comment and struct:

```go
// Binding is where a proposal came from: the chat surface, conversation and
// turn the Desktop passed to the chat-mode server. TurnIDFunc, when set, is
// read at propose time and wins over TurnID — a warm `ai session` spans many
// turns and publishes the running one through a turn file (spec §1.2).
type Binding struct {
	Surface        string
	ConversationID int64
	ContextType    string
	ContextID      string
	TurnID         string
	TurnIDFunc     func() string
}
```

with:


```go
// Binding is where a proposal came from: the chat surface, conversation and
// turn the Desktop passed to the chat-mode server. TurnIDFunc, when set, is
// read at propose time and wins over TurnID — a warm `ai session` spans many
// turns and publishes the running one through a turn file (spec §1.2).
//
// ProjectID binds the session to one project (`watchtower mcp --project N`):
// every call first checks the project still exists, and project tools scope
// every row they touch to it (DEV-06). DirectApply makes Propose apply a
// non-External tool inline for this call only — the owner's standing trust
// rows are neither read nor changed — and refuses an External one outright.
type Binding struct {
	Surface        string
	ConversationID int64
	ContextType    string
	ContextID      string
	TurnID         string
	TurnIDFunc     func() string
	ProjectID      int64
	DirectApply    bool
}
```

(c) In `type Tool struct`, directly after the `Normalize func(...)` field and before the blank line + `// resolved is InputSchema prepared for validation.` comment, add:


```go
	// Scope runs the checks that need the binding — "does this row belong to
	// the bound project" — after Validate in Propose, and again in Apply
	// before Execute, against the binding rebuilt from the stored row. A
	// *ValidationError from Propose writes no row. Optional.
	Scope func(ctx context.Context, d *db.DB, args json.RawMessage, b Binding) error
```

(c2) Replace

```go
// ValidationError carries a model-facing message; no row is written for it.
type ValidationError struct{ Msg string }

func (e *ValidationError) Error() string { return e.Msg }
```

with (additive — every existing `&ValidationError{Msg: …}` literal keeps compiling; Task 7 wraps `db.ErrNotInProject` in it):


```go
// ValidationError carries a model-facing message; no row is written for it.
// Err, when set, is the sentinel behind it (e.g. db.ErrNotInProject), so a
// caller can still match the cause with errors.Is.
type ValidationError struct {
	Msg string
	Err error
}

func (e *ValidationError) Error() string { return e.Msg }

func (e *ValidationError) Unwrap() error { return e.Err }
```

(d) Replace the body of `Propose` from `args, err := r.prepareProposalArgs(ctx, t, args)` to the end of the function — i.e. this block:

```go
	args, err := r.prepareProposalArgs(ctx, t, args)
	if err != nil {
		return Receipt{}, err
	}
	reason := reasonOf(args)
	if reason == "" {
		return Receipt{}, &ValidationError{Msg: `"reason" is required: say why you propose this`}
	}
	trust, err := r.Trust(name)
	if err != nil {
		return Receipt{}, err
	}
	// Defense in depth for AGENT-03: SetTrust refuses `execute` for an external
	// tool, but db.SetToolTrust does not, and a trust row keyed by tool NAME
	// outlives a tool later being marked External. The read side decides too.
	if t.External {
		trust = TrustAsk
	}
	row := db.AgentAction{
		Tool: name, External: t.External, ArgsJSON: string(args), Reason: reason,
		Surface: b.Surface, ConversationID: b.ConversationID,
		ContextType: b.ContextType, ContextID: b.ContextID, TurnID: b.turnID(),
		Status: "pending", TrustAtCreate: string(trust),
	}
	if trust == TrustExecute {
		row.Status = "approved"
	}
	id, err := r.db.InsertAgentAction(row)
	if err != nil {
		return Receipt{}, err
	}
	if trust == TrustExecute {
		return r.applyTrusted(ctx, id)
	}
	return Receipt{
		ActionID: id, Status: "pending", Tool: name,
		Message: fmt.Sprintf("Proposal #%d recorded (%s). The owner must approve it in this chat before "+
			"anything happens — tell the owner it awaits their approval and do not claim it is done.", id, name),
	}, nil
}
```

with (the new tail of `Propose` plus its helpers, placed right after it):


```go
	args, err := r.admitProposal(ctx, t, args, b)
	if err != nil {
		return Receipt{}, err
	}
	trust, err := r.resolveTrust(t, b)
	if err != nil {
		return Receipt{}, err
	}
	id, err := r.db.InsertAgentAction(newProposalRow(t, args, trust, b))
	if err != nil {
		return Receipt{}, err
	}
	if trust == TrustExecute {
		return r.applyTrusted(ctx, id)
	}
	return Receipt{
		ActionID: id, Status: "pending", Tool: name,
		Message: fmt.Sprintf("Proposal #%d recorded (%s). The owner must approve it in this chat before "+
			"anything happens — tell the owner it awaits their approval and do not claim it is done.", id, name),
	}, nil
}

// admitProposal runs every gate a write call passes before a row is written:
// the bound project is alive, the direct-apply gate, the args checks, the
// mandatory reason, then the tool's Scope. Any failure writes nothing.
func (r *Registry) admitProposal(ctx context.Context, t *Tool, args json.RawMessage, b Binding) (json.RawMessage, error) {
	if err := r.projectAlive(ctx, b); err != nil {
		return nil, err
	}
	if err := directApplyGate(t, b); err != nil {
		return nil, err
	}
	args, err := r.prepareProposalArgs(ctx, t, args)
	if err != nil {
		return nil, err
	}
	if reasonOf(args) == "" {
		return nil, &ValidationError{Msg: `"reason" is required: say why you propose this`}
	}
	if err := t.scope(ctx, r.db, args, b); err != nil {
		return nil, err
	}
	return args, nil
}

// directApplyGate is what keeps DirectApply narrow: it never runs an External
// tool (AGENT-03, DEV-06), and it runs only a tool that names the binding's
// surface explicitly — a surface-less tool is visible everywhere, so it must
// not inherit direct apply by accident.
func directApplyGate(t *Tool, b Binding) error {
	if !b.DirectApply {
		return nil
	}
	if t.External {
		return &ValidationError{Msg: t.Name + " leaves this machine and never runs in a direct-apply session"}
	}
	if !slices.Contains(t.Surfaces, b.Surface) {
		return &ValidationError{Msg: fmt.Sprintf("%s is not available on the %s surface", t.Name, b.Surface)}
	}
	return nil
}

// resolveTrust decides how this one call runs. External is always ask:
// SetTrust refuses `execute` for an external tool, but db.SetToolTrust does
// not, and a trust row keyed by tool NAME outlives a tool later being marked
// External — the read side decides too (AGENT-03). DirectApply is execute for
// this call only; the stored trust row is not consulted or changed.
func (r *Registry) resolveTrust(t *Tool, b Binding) (Trust, error) {
	if t.External {
		return TrustAsk, nil
	}
	if b.DirectApply {
		return TrustExecute, nil
	}
	return r.Trust(t.Name)
}

// newProposalRow is the agent_actions row a proposal records. A project-bound
// call stores its project in context_type/context_id, so Apply — possibly a
// later `actions apply` — rebuilds the same binding (bindingOf).
func newProposalRow(t *Tool, args json.RawMessage, trust Trust, b Binding) db.AgentAction {
	ctxType, ctxID := b.ContextType, b.ContextID
	if b.ProjectID != 0 {
		ctxType, ctxID = projectContextType, strconv.FormatInt(b.ProjectID, 10)
	}
	row := db.AgentAction{
		Tool: t.Name, External: t.External, ArgsJSON: string(args), Reason: reasonOf(args),
		Surface: b.Surface, ConversationID: b.ConversationID,
		ContextType: ctxType, ContextID: ctxID, TurnID: b.turnID(),
		Status: "pending", TrustAtCreate: string(trust),
	}
	if trust == TrustExecute {
		row.Status = "approved"
	}
	return row
}

// bindingOf rebuilds the binding a stored row was proposed under.
func bindingOf(row *db.AgentAction) Binding {
	b := Binding{
		Surface: row.Surface, ConversationID: row.ConversationID,
		ContextType: row.ContextType, ContextID: row.ContextID, TurnID: row.TurnID,
	}
	if row.ContextType == projectContextType {
		// A malformed id leaves ProjectID 0, which every project tool refuses.
		b.ProjectID, _ = strconv.ParseInt(row.ContextID, 10, 64)
	}
	return b
}

// projectAlive fails a project-bound call once its project is gone — the
// first check of every call, read or write, project tool or not, so a
// session outliving its project answers "project N no longer exists".
func (r *Registry) projectAlive(ctx context.Context, b Binding) error {
	if b.ProjectID == 0 {
		return nil
	}
	_, err := projectOf(ctx, r.db, b)
	return err
}

// scope runs the tool's optional Scope.
func (t *Tool) scope(ctx context.Context, d *db.DB, args json.RawMessage, b Binding) error {
	if t.Scope == nil {
		return nil
	}
	return t.Scope(ctx, d, args, b)
}
```

(e) Replace the `CallRead` doc comment, signature and first checks. Before:

```go
// CallRead runs a read tool's Execute and returns its data. It is the runtime-B
// in-process read path (the Go tool loop for HTTP providers) — the read twin of
// Propose. It writes NO agent_actions row: a read is not a proposal. A write
// tool is refused with ErrNotReadable, so the proposal flow can never be
// bypassed by calling a write through the read path.
func (r *Registry) CallRead(ctx context.Context, name string, args json.RawMessage) (any, error) {
	t, ok := r.tools[name]
	if !ok {
		return nil, ErrUnknownTool
	}
	if t.Access != AccessRead {
		return nil, ErrNotReadable
	}
```

After:


```go
// CallRead runs a read tool's Execute and returns its data. It is the read
// path of both adapters (MCP and the runtime-B loop) — the read twin of
// Propose. It writes NO agent_actions row: a read is not a proposal. A write
// tool is refused with ErrNotReadable, so the proposal flow can never be
// bypassed by calling a write through the read path. b reaches Execute as
// Call.Binding, so a read can scope itself (list_targets in a project session).
func (r *Registry) CallRead(ctx context.Context, name string, args json.RawMessage, b Binding) (any, error) {
	t, ok := r.tools[name]
	if !ok {
		return nil, ErrUnknownTool
	}
	if t.Access != AccessRead {
		return nil, ErrNotReadable
	}
	if err := r.projectAlive(ctx, b); err != nil {
		return nil, err
	}
```

and its last line `return t.Execute(ctx, r.db, Call{Args: args})` becomes:

```go
	return t.Execute(ctx, r.db, Call{Args: args, Binding: b})
```

(f) In `Apply`, replace:

```go
	call := Call{ActionID: id, Args: json.RawMessage(row.ArgsJSON), Binding: Binding{
		Surface: row.Surface, ConversationID: row.ConversationID,
		ContextType: row.ContextType, ContextID: row.ContextID, TurnID: row.TurnID,
	}}
	result, execErr := t.Execute(ctx, r.db, call)
	if execErr != nil {
		row, dbErr := r.finishTransition(id, from, "failed", "", execErr.Error())
		if dbErr != nil {
			// finishTransition's own CAS can lose a race too (something else
			// moved the row out of `executing` while Execute was still
			// running) — the caller must still learn what the tool itself
			// failed on, not just that recording the failure didn't stick.
			return nil, fmt.Errorf("recording failure %q: %w", execErr, dbErr)
		}
		return row, nil
	}
```

with:


```go
	call := Call{ActionID: id, Args: json.RawMessage(row.ArgsJSON), Binding: bindingOf(row)}
	// Re-scope against the stored binding: a retried or late-applied project
	// row must still belong to a live project and touch only its rows.
	if err := r.projectAlive(ctx, call.Binding); err != nil {
		return r.recordFailure(id, from, err)
	}
	if err := t.scope(ctx, r.db, call.Args, call.Binding); err != nil {
		return r.recordFailure(id, from, err)
	}
	result, execErr := t.Execute(ctx, r.db, call)
	if execErr != nil {
		return r.recordFailure(id, from, execErr)
	}
```

and add `recordFailure` directly before the `// finishTransition moves id …` comment:


```go
// recordFailure lands a claimed row in `failed` with cause as its error.
func (r *Registry) recordFailure(id int64, from []string, cause error) (*db.AgentAction, error) {
	row, dbErr := r.finishTransition(id, from, "failed", "", cause.Error())
	if dbErr != nil {
		// finishTransition's own CAS can lose a race too (something else
		// moved the row out of `executing` while Execute was still running) —
		// the caller must still learn what the tool itself failed on, not
		// just that recording the failure didn't stick.
		return nil, fmt.Errorf("recording failure %q: %w", cause, dbErr)
	}
	return row, nil
}
```

Create `internal/tools/project_scope.go`:


```go
package tools

import (
	"context"
	"errors"
	"fmt"

	"watchtower/internal/db"
)

// projectContextType is the agent_actions.context_type of a project-bound
// proposal; context_id then holds the project id (newProposalRow/bindingOf).
const projectContextType = "project"

// projectOf loads the project the binding is bound to. A binding with no
// project, or a project deleted while the session runs, is a model-facing
// ValidationError — the latter always worded "project N no longer exists".
func projectOf(_ context.Context, d *db.DB, b Binding) (*db.Project, error) {
	if b.ProjectID == 0 {
		return nil, &ValidationError{Msg: "this tool works only in a project session (watchtower mcp --project N)"}
	}
	p, err := d.GetProject(b.ProjectID)
	if errors.Is(err, db.ErrProjectNotFound) || (err == nil && p == nil) {
		return nil, &ValidationError{Msg: fmt.Sprintf("project %d no longer exists", b.ProjectID)}
	}
	if err != nil {
		return nil, fmt.Errorf("loading project %d: %w", b.ProjectID, err)
	}
	return p, nil
}
```

- [ ] **Step 4: Update the other `CallRead` callers**

`internal/agentloop/client.go` — in the `registry` interface replace

```go
	CallRead(ctx context.Context, name string, args json.RawMessage) (any, error)
```

with

```go
	CallRead(ctx context.Context, name string, args json.RawMessage, b tools.Binding) (any, error)
```

and in the dispatch `default:` branch replace `data, err := c.reg.CallRead(ctx, name, args)` with `data, err := c.reg.CallRead(ctx, name, args, c.binding)`. Also update the package doc's last sentence to: `Read-tool calls go through Registry.CallRead with the loop's binding and touch no proposal row.`

`internal/mcp/actions.go` — in `registerRegistry`'s read handler replace `data, err := reg.CallRead(ctx, tool.Name, req.Params.Arguments)` with `data, err := reg.CallRead(ctx, tool.Name, req.Params.Arguments, binding)` (dev mode's `binding` is the zero value, so its reads are unchanged).

- [ ] **Step 5: Run the tests to verify they pass**

Run: `go test ./internal/tools ./internal/agentloop ./internal/mcp > /tmp/p2t6.log 2>&1; echo "exit=$?"; tail -4 /tmp/p2t6.log`
Expected: `exit=0`; `ok` for all three packages — the new `TestDev06_ExternalToolRefusedUnderDirectApply`, `TestDirectApply_*`, `TestProjectBinding_DeletedProjectAnswersNoLongerExists`, `TestCallRead_PassesBindingToExecute`, `TestScope_RunsInProposeAndAgainInApply`, `TestLoop_ReadCallCarriesTheBinding`, and every pre-existing registry/AGENT test unchanged (the AGENT-01/03/05 guards pass byte-identical: a zero `Binding` takes exactly the old path).

Then: `make lint-diff`
Expected: no new issues.

- [ ] **Step 6: Commit**


```bash
git add internal/tools/registry.go internal/tools/project_scope.go internal/tools/registry_project_test.go internal/tools/*_test.go internal/agentloop/client.go internal/agentloop/loop_test.go internal/mcp/actions.go
git commit -m "$(cat <<'EOF'
feat(tools): project binding and DirectApply in the registry

Binding gains ProjectID and DirectApply; Tool gains an optional Scope
hook run in Propose and again in Apply. DirectApply applies a
non-External tool inline for one call (audit row kept, stored trust
untouched) and refuses External tools and tools not on the binding's
surface. A project-bound call fails with "project N no longer exists"
once the project is gone. CallRead now takes the Binding so reads can
scope themselves.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lo9jbbmXQcr3qHo5f3pLD8
EOF
)"
```

---

## Task 7: Project tools — info, board, sources, targets

**Files:**
- Create: `internal/tools/projects.go` (surface constant, `ProjectTools`, `targetInProject`, `project_info`, `project_board`, `update_project`, `add_project_source`, `remove_project_source`)
- Create: `internal/tools/project_targets.go` (`create_targets`, `update_target`)
- Create: `internal/tools/projects_test.go`
- Modify: `internal/tools/targets_read.go` (`list_targets`/`get_target` follow `Call.Binding.ProjectID`)
- Modify: `internal/db/targets.go` (add `SetTargetProgress`)
- Create: `internal/db/target_progress_test.go`

**Interfaces:**
- Consumes: Task 6's `Binding.ProjectID/DirectApply`, `Tool.Scope`, `projectOf`, `directBinding`/`seedProject` test helpers (`registry_project_test.go`), `callReadString` (`digests_test.go`); Phase 1's `CreateProject`, `CreateProjectTarget`, `ProjectTargetInput` + `CreateProjectTargetsTx` (batch; parents recomputed inside the tx), `WithTx` (Task 2; the callback may use only its `*sql.Tx`), `ErrNotInProject`, `GetProjectBoard` (does not check the project exists — callers go through `projectOf` first), `ListProjectSources`, `AddProjectSource`, `RemoveProjectSource`, `UpdateProjectDescription`, `ListProjectDocuments`, `ListProjectComments`, `UpsertProjectDocument`, `AddProjectComment`, `TargetFilter.ProjectID`, `Target.ProjectID`; existing `GetTargetByID`, `UpdateTarget` (writes `project_id` back unchanged, Phase 1), `UpdateTargetStatus`, `RecomputeParentProgress` (from `SetTargetProgress`), `decodeStrict`, `validateEnum`, `mustSchema`.
- Produces:
  - `func ProjectTools() []*Tool` — every project tool, in registration order (Task 8 appends its four; Task 9 registers the result).
  - `func NewProjectInfo() *Tool`, `NewProjectBoard`, `NewUpdateProject`, `NewAddProjectSource`, `NewRemoveProjectSource`, `NewCreateTargets`, `NewUpdateTarget` — all `Surfaces: []string{"project"}`, never `External`; every write tool has a `Scope`.
  - `func targetInProject(d *db.DB, projectID, targetID int64) (*db.Target, error)` — ValidationError `target N is not in this project`, wrapping `db.ErrNotInProject`, for another project's, a non-project, or a missing target; `func notInProject(noun string, id int64) error` builds that refusal (Task 8 reuses it for documents and comments).
  - `func requireText(field, s string, limit int) (string, error)`, `projectScope` (Scope for a tool touching no existing row).
  - `func (db *DB) SetTargetProgress(id int, progress float64) error` (package `db`; Phase 1 has no progress writer — `UpdateTarget`/`UpdateTargetStatus` re-derive progress from status).
  - Test helpers (package `tools`, `projects_test.go`): `projectFixture`, `newProjectFixture`, `projectRegistry`, `proposeIn`, `mustApply`, `callReadIn`, `countProjectTargets`, `countActions`, `outsideProjectCalls`, `snapshotProject`, `queryStrings`.
- Model-facing contracts: `create_targets` args `{items:[{key?, text, intent?, parent_id? | parent_key?}], reason}` — ≤ 100 items, keys unique, a `parent_key` must name an **earlier** item (so parents insert first and a cycle is impossible), `parent_id` must be a target of this project; one `db.WithTx` around one `CreateProjectTargetsTx` call, each `parent_key` mapped to the 1-based `BatchParent` of the earlier item holding that key and each `parent_id` to `ParentID` — all or nothing; result `{"created":[{"key","target_id"}]}`. `update_target` args `{target_id, status?, progress?, text?, intent?, reason}` — at least one change; status ∈ todo|in_progress|blocked|done|dismissed; progress 0..1, written after status. New rows take `project_id` from the binding only — a `project_id` argument is an unknown field and refused.

- [ ] **Step 1: Write the failing tests**

Create `internal/tools/projects_test.go`:


```go
package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
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
type outsideProjectCall struct{ name, tool, args string }

// outsideProjectCalls lists every write the DEV-06 guard aims at project b (or
// at no project) from a session bound to project a. Task 8 appends the
// document and comment tools.
func outsideProjectCalls(fx projectFixture) []outsideProjectCall {
	return []outsideProjectCall{
		{"update another project's target", "update_target", fmt.Sprintf(`{"target_id":%d,"status":"done","reason":"r"}`, fx.bTarget)},
		{"update a non-project target", "update_target", fmt.Sprintf(`{"target_id":%d,"status":"done","reason":"r"}`, fx.plain)},
		{"nest under another project's target", "create_targets", fmt.Sprintf(`{"items":[{"text":"x","parent_id":%d}],"reason":"r"}`, fx.bTarget)},
		{"smuggle a project_id", "create_targets", fmt.Sprintf(`{"project_id":%d,"items":[{"text":"x"}],"reason":"r"}`, fx.b)},
		{"smuggle a project_id into a source", "add_project_source", fmt.Sprintf(`{"project_id":%d,"kind":"link","ref":"x","reason":"r"}`, fx.b)},
		{"remove another project's source", "remove_project_source", fmt.Sprintf(`{"source_id":%d,"reason":"r"}`, fx.bSource)},
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

	for _, c := range outsideProjectCalls(fx) {
		_, err := proposeIn(t, reg, fx.a, c.tool, c.args)
		var verr *ValidationError
		require.ErrorAs(t, err, &verr, c.name)
		if strings.Contains(verr.Msg, "is not in this project") {
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
```

Create `internal/db/target_progress_test.go`:


```go
package db

import (
	"database/sql"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// SetTargetProgress stores an explicit leaf progress and rolls it up into
// the parent, the way a status change does.
func TestSetTargetProgress_StoresValueAndRecomputesParent(t *testing.T) {
	d := openTestDB(t)
	parent, err := d.CreateTarget(Target{Text: "parent", Level: "week", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	child, err := d.CreateTarget(Target{Text: "child", Level: "week", Status: "in_progress", Priority: "medium",
		Ownership: "mine", SourceType: "manual", ParentID: sql.NullInt64{Int64: parent, Valid: true}})
	require.NoError(t, err)

	require.NoError(t, d.SetTargetProgress(int(child), 0.5))

	got, err := d.GetTargetByID(int(child))
	require.NoError(t, err)
	assert.InDelta(t, 0.5, got.Progress, 1e-9)
	up, err := d.GetTargetByID(int(parent))
	require.NoError(t, err)
	assert.InDelta(t, 0.5, up.Progress, 1e-9)

	assert.Error(t, d.SetTargetProgress(99999, 0.1), "a missing target is an error")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `go test ./internal/tools ./internal/db -run 'TestProject|TestCreateTargets|TestUpdateTarget|TestProj01_TargetReads|TestDev06_Write|TestSetTargetProgress' > /tmp/p2t7.log 2>&1; echo "exit=$?"; grep -m5 undefined /tmp/p2t7.log`
Expected: `exit=1`, `undefined: ProjectTools`, `undefined: d.SetTargetProgress` (compile errors).

- [ ] **Step 3: Implement**

Append to `internal/db/targets.go`:


```go
// SetTargetProgress stores an explicit progress (0..1) on one target and
// recomputes its parent's. A target with children has its progress
// re-derived from them on their next change; this is for leaves.
func (db *DB) SetTargetProgress(id int, progress float64) error {
	var parentID sql.NullInt64
	if err := db.QueryRow(`SELECT parent_id FROM targets WHERE id = ?`, id).Scan(&parentID); err != nil {
		return fmt.Errorf("loading target %d: %w", id, err)
	}
	if _, err := db.Exec(`UPDATE targets SET progress = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`, progress, id); err != nil {
		return fmt.Errorf("setting target %d progress: %w", id, err)
	}
	if parentID.Valid {
		return db.RecomputeParentProgress(parentID.Int64)
	}
	return nil
}
```

Create `internal/tools/projects.go`:


```go
package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"watchtower/internal/db"
)

// projectSurface is the registry surface of `watchtower mcp --project N`.
// Every project tool is visible there and nowhere else.
const projectSurface = "project"

var projectSurfaces = []string{projectSurface}

// maxBatchTargets caps one create_targets call — a whole plan, not a backlog.
const maxBatchTargets = 100

// ProjectTools returns every project tool (surface "project"), in the order
// buildToolRegistry registers them.
func ProjectTools() []*Tool {
	return []*Tool{
		NewProjectInfo(), NewProjectBoard(), NewUpdateProject(),
		NewAddProjectSource(), NewRemoveProjectSource(),
		NewCreateTargets(), NewUpdateTarget(),
	}
}

// targetInProject loads a target and fails unless it belongs to projectID —
// a target of another project, of no project, or a missing one all read as
// "not in this project" (wrapping db.ErrNotInProject), never as a different
// error that would confirm it exists.
func targetInProject(d *db.DB, projectID, targetID int64) (*db.Target, error) {
	notHere := notInProject("target", targetID)
	if projectID <= 0 || targetID <= 0 {
		return nil, notHere
	}
	t, err := d.GetTargetByID(int(targetID))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, notHere
	}
	if err != nil {
		return nil, fmt.Errorf("loading target %d: %w", targetID, err)
	}
	if t.ProjectID.Int64 != projectID {
		return nil, notHere
	}
	return t, nil
}

// notInProject is the model-facing refusal for a row outside the bound
// project; it wraps db.ErrNotInProject.
func notInProject(noun string, id int64) error {
	return &ValidationError{Msg: fmt.Sprintf("%s %d is not in this project", noun, id), Err: db.ErrNotInProject}
}

// projectScope is the Scope of a project tool that touches no existing row:
// the binding must name a live project.
func projectScope(ctx context.Context, d *db.DB, _ json.RawMessage, b Binding) error {
	_, err := projectOf(ctx, d, b)
	return err
}

// requireText trims s and checks it is non-empty and at most limit runes.
func requireText(field, s string, limit int) (string, error) {
	s = strings.TrimSpace(s)
	switch {
	case s == "":
		return "", &ValidationError{Msg: field + " is required"}
	case len([]rune(s)) > limit:
		return "", &ValidationError{Msg: fmt.Sprintf("%s must be at most %d characters", field, limit)}
	}
	return s, nil
}

type emptyArgs struct{}

// ---- project_info ------------------------------------------------------

type sourceView struct {
	ID    int64  `json:"id"`
	Kind  string `json:"kind"`
	Ref   string `json:"ref"`
	Label string `json:"label,omitempty"`
}

type projectInfoView struct {
	ID          int64          `json:"id"`
	Name        string         `json:"name"`
	Folder      string         `json:"folder"`
	Description string         `json:"description"`
	Sources     []sourceView   `json:"sources"`
	Targets     map[string]int `json:"targets_by_status"`
	Documents   int            `json:"documents"`
	NewComments int            `json:"comments_new_for_agent"`
}

// NewProjectInfo describes the bound project: what it is, its sources and
// how much is on its board.
func NewProjectInfo() *Tool {
	return &Tool{
		Name: "project_info",
		Description: "Describe this Watchtower project: name, folder, description, sources, target counts by " +
			"status, attached documents and owner comments waiting for you. An empty description means the " +
			"project is not set up yet (run the watchtower-project skill's setup).",
		InputSchema: mustSchema[emptyArgs]("project_info"),
		Access:      AccessRead,
		Surfaces:    projectSurfaces,
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			p, err := projectOf(ctx, d, call.Binding)
			if err != nil {
				return nil, err
			}
			return buildProjectInfo(d, p)
		},
	}
}

func buildProjectInfo(d *db.DB, p *db.Project) (*projectInfoView, error) {
	sources, err := d.ListProjectSources(p.ID)
	if err != nil {
		return nil, fmt.Errorf("listing sources: %w", err)
	}
	board, err := d.GetProjectBoard(p.ID)
	if err != nil {
		return nil, fmt.Errorf("loading board: %w", err)
	}
	docs, err := d.ListProjectDocuments(p.ID)
	if err != nil {
		return nil, fmt.Errorf("listing documents: %w", err)
	}
	fresh, err := d.ListProjectComments(db.ProjectCommentFilter{ProjectID: p.ID, NewForAgent: true})
	if err != nil {
		return nil, fmt.Errorf("listing comments: %w", err)
	}
	v := &projectInfoView{
		ID: p.ID, Name: p.Name, Folder: p.FolderPath, Description: p.Description,
		Sources: make([]sourceView, 0, len(sources)), Targets: map[string]int{},
		Documents: len(docs), NewComments: len(fresh),
	}
	for _, s := range sources {
		v.Sources = append(v.Sources, sourceView{ID: s.ID, Kind: s.Kind, Ref: s.Ref, Label: s.Label})
	}
	countStatuses(board, v.Targets)
	return v, nil
}

func countStatuses(nodes []db.BoardNode, into map[string]int) {
	for _, n := range nodes {
		into[n.Target.Status]++
		countStatuses(n.Children, into)
	}
}

// ---- project_board -----------------------------------------------------

type documentView struct {
	ID       int64  `json:"id"`
	RelPath  string `json:"rel_path"`
	Kind     string `json:"kind"`
	Title    string `json:"title,omitempty"`
	TargetID int64  `json:"target_id,omitempty"`
	Updated  string `json:"updated_at"`
}

type boardNodeView struct {
	ID             int             `json:"id"`
	Text           string          `json:"text"`
	Intent         string          `json:"intent,omitempty"`
	Status         string          `json:"status"`
	Progress       float64         `json:"progress"`
	NewForAgent    int             `json:"comments_new_for_agent,omitempty"`
	UnreadForOwner int             `json:"comments_unread_for_owner,omitempty"`
	Documents      []documentView  `json:"documents,omitempty"`
	Children       []boardNodeView `json:"children,omitempty"`
}

type projectBoardView struct {
	ProjectID int64           `json:"project_id"`
	Targets   []boardNodeView `json:"targets"`
	Documents []documentView  `json:"documents"`
}

// NewProjectBoard returns the bound project's target tree with comment
// counters, plus every attached document.
func NewProjectBoard() *Tool {
	return &Tool{
		Name: "project_board",
		Description: "The project board: the target tree (ids, status, progress, comment counters, linked " +
			"documents) and every attached document. Read it before changing the board.",
		InputSchema: mustSchema[emptyArgs]("project_board"),
		Access:      AccessRead,
		Surfaces:    projectSurfaces,
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			p, err := projectOf(ctx, d, call.Binding)
			if err != nil {
				return nil, err
			}
			board, err := d.GetProjectBoard(p.ID)
			if err != nil {
				return nil, fmt.Errorf("loading board: %w", err)
			}
			docs, err := d.ListProjectDocuments(p.ID)
			if err != nil {
				return nil, fmt.Errorf("listing documents: %w", err)
			}
			return projectBoardView{ProjectID: p.ID, Targets: boardViews(board), Documents: documentViews(docs)}, nil
		},
	}
}

func boardViews(nodes []db.BoardNode) []boardNodeView {
	out := make([]boardNodeView, 0, len(nodes))
	for _, n := range nodes {
		out = append(out, boardNodeView{
			ID: n.Target.ID, Text: n.Target.Text, Intent: n.Target.Intent,
			Status: n.Target.Status, Progress: n.Target.Progress,
			NewForAgent: n.NewForAgent, UnreadForOwner: n.UnreadForOwner,
			Documents: documentViews(n.Documents), Children: boardViews(n.Children),
		})
	}
	return out
}

func documentViews(docs []db.ProjectDocument) []documentView {
	out := make([]documentView, 0, len(docs))
	for _, doc := range docs {
		out = append(out, documentView{
			ID: doc.ID, RelPath: doc.RelPath, Kind: doc.Kind, Title: doc.Title,
			TargetID: doc.TargetID.Int64, Updated: doc.UpdatedAt,
		})
	}
	return out
}

// ---- update_project ----------------------------------------------------

type updateProjectArgs struct {
	Description string `json:"description" jsonschema:"what the project is, a few sentences; replaces the current description"`
	Reason      string `json:"reason" jsonschema:"one sentence: why you make this change"`
}

// NewUpdateProject sets the bound project's description.
func NewUpdateProject() *Tool {
	return &Tool{
		Name:        "update_project",
		Description: "Set this project's description (what it is, a few sentences). Applied immediately.",
		InputSchema: mustSchema[updateProjectArgs]("update_project"),
		Access:      AccessWrite,
		Surfaces:    projectSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a updateProjectArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			_, err := requireText("description", a.Description, 4000)
			return err
		},
		Scope: projectScope,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a updateProjectArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding update_project args: %w", err)
			}
			if err := d.UpdateProjectDescription(call.Binding.ProjectID, strings.TrimSpace(a.Description)); err != nil {
				return nil, fmt.Errorf("updating project: %w", err)
			}
			return map[string]any{"project_id": call.Binding.ProjectID}, nil
		},
	}
}

// ---- add_project_source / remove_project_source -------------------------

type addProjectSourceArgs struct {
	Kind   string `json:"kind" jsonschema:"slack_channel | jira_project | confluence_space | person | link"`
	Ref    string `json:"ref" jsonschema:"the source reference: channel id or name, Jira project key, space key, person email, URL"`
	Label  string `json:"label,omitempty" jsonschema:"short human label"`
	Reason string `json:"reason" jsonschema:"one sentence: why this source belongs to the project"`
}

// NewAddProjectSource records a source (channel, Jira project, space, person,
// link) as belonging to the bound project. Idempotent on (kind, ref).
func NewAddProjectSource() *Tool {
	return &Tool{
		Name: "add_project_source",
		Description: "Record a source that belongs to this project (a Slack channel, Jira project, Confluence " +
			"space, person or link). Add only sources the project's docs clearly name. Applied immediately.",
		InputSchema: mustSchema[addProjectSourceArgs]("add_project_source"),
		Access:      AccessWrite,
		Surfaces:    projectSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a addProjectSourceArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if a.Kind == "" {
				return &ValidationError{Msg: "kind is required"}
			}
			if err := validateEnum("kind", a.Kind, "slack_channel", "jira_project", "confluence_space", "person", "link"); err != nil {
				return err
			}
			_, err := requireText("ref", a.Ref, 500)
			return err
		},
		Scope: projectScope,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a addProjectSourceArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding add_project_source args: %w", err)
			}
			id, err := d.AddProjectSource(db.ProjectSource{
				ProjectID: call.Binding.ProjectID, Kind: a.Kind,
				Ref: strings.TrimSpace(a.Ref), Label: strings.TrimSpace(a.Label),
			})
			if err != nil {
				return nil, fmt.Errorf("adding source: %w", err)
			}
			return map[string]any{"source_id": id}, nil
		},
	}
}

type removeProjectSourceArgs struct {
	SourceID int64  `json:"source_id" jsonschema:"the source id from project_info"`
	Reason   string `json:"reason" jsonschema:"one sentence: why the source no longer belongs"`
}

// NewRemoveProjectSource drops one of the bound project's sources.
func NewRemoveProjectSource() *Tool {
	return &Tool{
		Name:        "remove_project_source",
		Description: "Remove a source from this project (id from project_info). Applied immediately.",
		InputSchema: mustSchema[removeProjectSourceArgs]("remove_project_source"),
		Access:      AccessWrite,
		Surfaces:    projectSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a removeProjectSourceArgs
			return decodeStrict(raw, &a)
		},
		Scope: func(_ context.Context, d *db.DB, raw json.RawMessage, b Binding) error {
			var a removeProjectSourceArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "invalid arguments"}
			}
			return sourceInProject(d, b.ProjectID, a.SourceID)
		},
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a removeProjectSourceArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding remove_project_source args: %w", err)
			}
			if err := d.RemoveProjectSource(call.Binding.ProjectID, a.SourceID); err != nil {
				return nil, fmt.Errorf("removing source: %w", err)
			}
			return map[string]any{"source_id": a.SourceID, "removed": true}, nil
		},
	}
}

func sourceInProject(d *db.DB, projectID, sourceID int64) error {
	sources, err := d.ListProjectSources(projectID)
	if err != nil {
		return fmt.Errorf("listing sources: %w", err)
	}
	for _, s := range sources {
		if s.ID == sourceID {
			return nil
		}
	}
	return notInProject("source", sourceID)
}
```

Create `internal/tools/project_targets.go`:


```go
package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"

	"watchtower/internal/db"
)

// ---- create_targets ----------------------------------------------------

type newTargetItem struct {
	Key       string `json:"key,omitempty" jsonschema:"a short handle for this item, unique in the call, so a later item can name it as parent_key"`
	Text      string `json:"text" jsonschema:"the target title, imperative, at most 200 characters"`
	Intent    string `json:"intent,omitempty" jsonschema:"why it matters / what done means; for a plan task, the plan path and task number"`
	ParentID  int64  `json:"parent_id,omitempty" jsonschema:"an existing target of this project to nest under"`
	ParentKey string `json:"parent_key,omitempty" jsonschema:"the key of an EARLIER item in this call to nest under"`
}

type createTargetsArgs struct {
	Items  []newTargetItem `json:"items" jsonschema:"the targets to create, parents before their children"`
	Reason string          `json:"reason" jsonschema:"one sentence: why these targets, e.g. the plan they come from"`
}

type createdTarget struct {
	Key      string `json:"key,omitempty"`
	TargetID int64  `json:"target_id"`
}

// NewCreateTargets creates a batch of project targets in one transaction —
// a whole plan in one call. Nesting is by parent_id (an existing target of
// the project) or parent_key (an earlier item). All or nothing.
func NewCreateTargets() *Tool {
	return &Tool{
		Name: "create_targets",
		Description: "Create targets on this project's board in one all-or-nothing call — e.g. a feature " +
			"target plus one sub-target per plan task. Nest with parent_id (an existing target of this " +
			"project) or parent_key (the key of an earlier item in the same call). Applied immediately.",
		InputSchema: mustSchema[createTargetsArgs]("create_targets"),
		Access:      AccessWrite,
		Surfaces:    projectSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a createTargetsArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			return validateTargetItems(a.Items)
		},
		Scope: func(ctx context.Context, d *db.DB, raw json.RawMessage, b Binding) error {
			var a createTargetsArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "invalid arguments"}
			}
			return scopeTargetItems(ctx, d, a.Items, b)
		},
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a createTargetsArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding create_targets args: %w", err)
			}
			created, err := insertTargetItems(d, call.Binding.ProjectID, a.Items)
			if err != nil {
				return nil, err
			}
			return map[string]any{"created": created}, nil
		},
	}
}

// validateTargetItems checks the batch shape without the database: a
// non-empty batch under the cap, every text present, keys unique, at most one
// parent per item, and every parent_key naming an EARLIER item — so the
// insert order is always parents first and a key cycle is impossible.
func validateTargetItems(items []newTargetItem) error {
	if len(items) == 0 || len(items) > maxBatchTargets {
		return &ValidationError{Msg: fmt.Sprintf("items must hold 1 to %d targets", maxBatchTargets)}
	}
	seen := map[string]bool{}
	for i, it := range items {
		if err := validateTargetItem(i, it, seen); err != nil {
			return err
		}
		if it.Key != "" {
			seen[it.Key] = true
		}
	}
	return nil
}

func validateTargetItem(i int, it newTargetItem, earlier map[string]bool) error {
	if _, err := requireText(fmt.Sprintf("items[%d].text", i), it.Text, 200); err != nil {
		return err
	}
	switch {
	case it.Key != "" && earlier[it.Key]:
		return &ValidationError{Msg: fmt.Sprintf("items[%d].key %q is used twice", i, it.Key)}
	case it.ParentID != 0 && it.ParentKey != "":
		return &ValidationError{Msg: fmt.Sprintf("items[%d] has both parent_id and parent_key; give one", i)}
	case it.ParentKey != "" && !earlier[it.ParentKey]:
		return &ValidationError{Msg: fmt.Sprintf("items[%d].parent_key %q names no earlier item", i, it.ParentKey)}
	}
	return nil
}

// scopeTargetItems checks every parent_id belongs to the bound project.
func scopeTargetItems(ctx context.Context, d *db.DB, items []newTargetItem, b Binding) error {
	if _, err := projectOf(ctx, d, b); err != nil {
		return err
	}
	for _, it := range items {
		if it.ParentID == 0 {
			continue
		}
		if _, err := targetInProject(d, b.ProjectID, it.ParentID); err != nil {
			return err
		}
	}
	return nil
}

// insertTargetItems inserts the batch in one transaction through
// db.CreateProjectTargetsTx, which also rolls progress up into every parent.
// A parent_key becomes the 1-based BatchParent of the earlier item holding
// that key (validateTargetItems guaranteed it is earlier).
func insertTargetItems(d *db.DB, projectID int64, items []newTargetItem) ([]createdTarget, error) {
	inputs := targetInputs(items)
	var ids []int64
	err := d.WithTx(func(tx *sql.Tx) error {
		var err error
		ids, err = d.CreateProjectTargetsTx(tx, projectID, inputs)
		return err
	})
	if err != nil {
		return nil, fmt.Errorf("creating targets: %w", err)
	}
	created := make([]createdTarget, 0, len(ids))
	for i, id := range ids {
		created = append(created, createdTarget{Key: items[i].Key, TargetID: id})
	}
	return created, nil
}

func targetInputs(items []newTargetItem) []db.ProjectTargetInput {
	position := map[string]int{} // key -> 1-based batch position
	inputs := make([]db.ProjectTargetInput, 0, len(items))
	for i, it := range items {
		in := db.ProjectTargetInput{Title: strings.TrimSpace(it.Text), Intent: strings.TrimSpace(it.Intent)}
		if it.ParentKey != "" {
			in.BatchParent = position[it.ParentKey]
		} else if it.ParentID != 0 {
			in.ParentID = sql.NullInt64{Int64: it.ParentID, Valid: true}
		}
		if it.Key != "" {
			position[it.Key] = i + 1
		}
		inputs = append(inputs, in)
	}
	return inputs
}

// ---- update_target -----------------------------------------------------

type updateTargetArgs struct {
	TargetID int64    `json:"target_id" jsonschema:"the project target to change"`
	Status   string   `json:"status,omitempty" jsonschema:"todo | in_progress | blocked | done | dismissed"`
	Progress *float64 `json:"progress,omitempty" jsonschema:"0.0 to 1.0; set after status (a status change resets a leaf's progress)"`
	Text     string   `json:"text,omitempty" jsonschema:"new title, at most 200 characters"`
	Intent   string   `json:"intent,omitempty" jsonschema:"new intent"`
	Reason   string   `json:"reason" jsonschema:"one sentence: why, e.g. 'task 3 passed review'"`
}

// NewUpdateTarget changes one project target's status, progress, title or
// intent.
func NewUpdateTarget() *Tool {
	return &Tool{
		Name: "update_target",
		Description: "Change a target on this project's board: status (todo, in_progress, blocked, done, " +
			"dismissed), progress (0..1), title or intent. Applied immediately.",
		InputSchema: mustSchema[updateTargetArgs]("update_target"),
		Access:      AccessWrite,
		Surfaces:    projectSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a updateTargetArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			return validateTargetUpdate(a)
		},
		Scope: func(ctx context.Context, d *db.DB, raw json.RawMessage, b Binding) error {
			var a updateTargetArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "invalid arguments"}
			}
			if _, err := projectOf(ctx, d, b); err != nil {
				return err
			}
			_, err := targetInProject(d, b.ProjectID, a.TargetID)
			return err
		},
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a updateTargetArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding update_target args: %w", err)
			}
			if err := applyTargetUpdate(d, call.Binding.ProjectID, a); err != nil {
				return nil, err
			}
			return map[string]any{"target_id": a.TargetID}, nil
		},
	}
}

func validateTargetUpdate(a updateTargetArgs) error {
	if a.Status == "" && a.Progress == nil && strings.TrimSpace(a.Text) == "" && strings.TrimSpace(a.Intent) == "" {
		return &ValidationError{Msg: "give at least one of status, progress, text, intent"}
	}
	if a.Progress != nil && (*a.Progress < 0 || *a.Progress > 1) {
		return &ValidationError{Msg: "progress must be between 0 and 1"}
	}
	if len([]rune(strings.TrimSpace(a.Text))) > 200 {
		return &ValidationError{Msg: "text must be at most 200 characters"}
	}
	return validateEnum("status", a.Status, "todo", "in_progress", "blocked", "done", "dismissed")
}

// applyTargetUpdate writes title/intent, then status, then progress — status
// first because a status change re-derives a leaf's progress.
func applyTargetUpdate(d *db.DB, projectID int64, a updateTargetArgs) error {
	t, err := targetInProject(d, projectID, a.TargetID)
	if err != nil {
		return err
	}
	if err := applyTargetText(d, t, a); err != nil {
		return err
	}
	if a.Status != "" && a.Status != t.Status {
		if err := d.UpdateTargetStatus(t.ID, a.Status); err != nil {
			return fmt.Errorf("updating status: %w", err)
		}
	}
	if a.Progress != nil {
		if err := d.SetTargetProgress(t.ID, *a.Progress); err != nil {
			return fmt.Errorf("updating progress: %w", err)
		}
	}
	return nil
}

func applyTargetText(d *db.DB, t *db.Target, a updateTargetArgs) error {
	text, intent := strings.TrimSpace(a.Text), strings.TrimSpace(a.Intent)
	if text == "" && intent == "" {
		return nil
	}
	if text != "" {
		t.Text = text
	}
	if intent != "" {
		t.Intent = intent
	}
	if err := d.UpdateTarget(*t); err != nil {
		return fmt.Errorf("updating target: %w", err)
	}
	return nil
}
```

In `internal/tools/targets_read.go`, `NewListTargets`' filter — after the line `Limit: listLimit(a.Limit),` add:

```go
				// 0 (every non-project session) excludes project targets
				// (PROJ-01); a project session sees only its own board.
				ProjectID: call.Binding.ProjectID,
```

and in `NewGetTarget`, replace

```go
				return nil, fmt.Errorf("getting target: %w", err)
			}
			return target, nil
```

with

```go
				return nil, fmt.Errorf("getting target: %w", err)
			}
			// A target outside the session's scope reads as missing: a project
			// target never reaches a non-project session (PROJ-01), and a
			// project session sees only its own project's targets (DEV-06).
			if target.ProjectID.Int64 != call.Binding.ProjectID {
				return nil, fmt.Errorf("no target with id %d", a.ID)
			}
			return target, nil
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `go test ./internal/tools ./internal/db -run 'TestProject|TestCreateTargets|TestUpdateTarget|TestProj01_TargetReads|TestDev06|TestSetTargetProgress|TestListTargets|TestGetTarget' > /tmp/p2t7.log 2>&1; echo "exit=$?"; tail -3 /tmp/p2t7.log`
Expected: `exit=0`, both packages `ok`. Then the whole tools package once: `go test ./internal/tools > /tmp/p2t7b.log 2>&1; echo "exit=$?"` → `exit=0`.

Mutation check (after the commit in Step 6, per the house rule): in `targetInProject` change `if t.ProjectID.Int64 != projectID {` to `if false {`, run `go test ./internal/tools -run TestDev06_WriteOutsideTheBoundProjectIsRefused` → FAIL; restore with `git checkout internal/tools/projects.go` → PASS.

- [ ] **Step 5: Lint**

Run: `make lint-diff`
Expected: no new issues (note: the `limit` parameter name in `requireText` avoids the `predeclared` linter's `max`; `queryStrings` closes rows with `defer` for `sqlclosecheck`).

- [ ] **Step 6: Commit**


```bash
git add internal/tools/projects.go internal/tools/project_targets.go internal/tools/projects_test.go internal/tools/targets_read.go internal/db/targets.go internal/db/target_progress_test.go
git commit -m "$(cat <<'EOF'
feat(tools): project board tools on the project surface

project_info, project_board, update_project, add/remove_project_source,
create_targets (a whole plan in one all-or-nothing transaction, nested
by parent_key or parent_id) and update_target. Every write is scoped to
the bound project (DEV-06); list_targets/get_target follow the session:
a project session sees only its board, any other session never sees a
project target (PROJ-01).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lo9jbbmXQcr3qHo5f3pLD8
EOF
)"
```

---

## Task 8: Document + comment tools

**Files:**
- Create: `internal/tools/project_docs.go` (`resolveInsideFolder`, `attach_document`, `list_comments`, `add_comment`, `resolve_comment`)
- Create: `internal/tools/project_docs_test.go`
- Modify: `internal/tools/projects.go` (`ProjectTools` gains the four tools)
- Modify: `internal/tools/projects_test.go` (`outsideProjectCalls` gains five cases)

**Interfaces:**
- Consumes: Task 6's `projectOf`, `Scope`; Task 7's `targetInProject`, `requireText`, `projectSurfaces`, fixtures/helpers; Phase 1's `UpsertProjectDocument`, `GetProjectDocument`, `ListProjectDocuments`, `AddProjectComment`, `GetProjectComment`, `ListProjectComments`, `SetProjectCommentStatus`, `GetProject` (`FolderPath` stored symlink-resolved).
- Produces:
  - `func resolveInsideFolder(folder, rel string) (string, error)` — refuses an empty or absolute `rel`, a path that does not exist, anything that after `filepath.EvalSymlinks` lies outside `folder` (`../`, a symlinked file or directory pointing out), and anything that is not a regular `.md`/`.txt` file; returns the resolved absolute path.
  - `func documentInProject(d *db.DB, projectID, documentID int64) (*db.ProjectDocument, error)`, `func commentInProject(d *db.DB, projectID, commentID int64) (*db.ProjectComment, error)` — ValidationError `… is not in this project`.
  - `NewAttachDocument` (`{rel_path, kind: spec|plan|doc, title?, target_id?, reason}` → `{document_id, rel_path, created}`; stored `rel_path` is the resolved, slash-separated path relative to the folder; title defaults to the file name; re-attaching bumps `updated_at` = "revised"), `NewListComments` (read; `{target_id?, document_id?, new_for_agent?}`, default new-for-agent when no id), `NewAddComment` (`{target_id | parent_id, body, reason}`, author always `agent`, `agent_label` `claude-code`), `NewResolveComment` (`{comment_id, reply?, reason}`, root comments only, reply posted before the status flips).

- [ ] **Step 1: Write the failing tests**

Create `internal/tools/project_docs_test.go`:


```go
package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// writeProjectFile creates rel (and its directories) inside project id's folder.
func writeProjectFile(t *testing.T, d *db.DB, projectID int64, rel, body string) {
	t.Helper()
	p, err := d.GetProject(projectID)
	require.NoError(t, err)
	path := filepath.Join(p.FolderPath, rel)
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o755))
	require.NoError(t, os.WriteFile(path, []byte(body), 0o644))
}

func countProjectDocuments(t *testing.T, d *db.DB, projectID int64) int {
	t.Helper()
	docs, err := d.ListProjectDocuments(projectID)
	require.NoError(t, err)
	return len(docs)
}

func TestAttachDocument_AttachesAndReattaches(t *testing.T) {
	fx := newProjectFixture(t)
	reg := projectRegistry(t, fx.d)
	writeProjectFile(t, fx.d, fx.a, "docs/plans/x-plan.md", "# Plan\n")

	args := fmt.Sprintf(`{"rel_path":"docs/plans/x-plan.md","kind":"plan","target_id":%d,"reason":"plan for X"}`, fx.aTarget)
	out := mustApply(t, reg, fx.a, "attach_document", args)
	assert.Equal(t, true, out["created"])
	assert.Equal(t, "docs/plans/x-plan.md", out["rel_path"])

	docs, err := fx.d.ListProjectDocuments(fx.a)
	require.NoError(t, err)
	require.Len(t, docs, 1)
	assert.Equal(t, "plan", docs[0].Kind)
	assert.Equal(t, "x-plan", docs[0].Title, "title defaults to the file name")
	assert.Equal(t, fx.aTarget, docs[0].TargetID.Int64)

	out = mustApply(t, reg, fx.a, "attach_document", args)
	assert.Equal(t, false, out["created"], "re-attaching marks the same document revised")
	assert.Equal(t, 1, countProjectDocuments(t, fx.d, fx.a))
}

// DEV-06 / Review Focus #1: attach_document never reaches a file outside the
// project folder — not by `../`, an absolute path, a symlinked file or a
// symlinked directory — and only an existing .md/.txt regular file attaches.
func TestDev06_AttachDocumentStaysInsideTheFolder(t *testing.T) {
	fx := newProjectFixture(t)
	reg := projectRegistry(t, fx.d)
	p, err := fx.d.GetProject(fx.a)
	require.NoError(t, err)
	outsideDir := t.TempDir()
	outsideFile := filepath.Join(outsideDir, "secret.md")
	require.NoError(t, os.WriteFile(outsideFile, []byte("secret"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(filepath.Dir(p.FolderPath), "sibling.md"), []byte("x"), 0o644))
	require.NoError(t, os.MkdirAll(filepath.Join(p.FolderPath, "docs"), 0o755))
	require.NoError(t, os.Symlink(outsideFile, filepath.Join(p.FolderPath, "docs", "link.md")))
	require.NoError(t, os.Symlink(outsideDir, filepath.Join(p.FolderPath, "docs", "ext")))
	writeProjectFile(t, fx.d, fx.a, "docs/diagram.pdf", "%PDF")
	require.NoError(t, os.MkdirAll(filepath.Join(p.FolderPath, "docs", "dir.md"), 0o755))

	for name, rel := range map[string]string{
		"dot-dot":           "../sibling.md",
		"nested dot-dot":    "docs/../../sibling.md",
		"absolute":          outsideFile,
		"symlinked file":    "docs/link.md",
		"symlinked dir":     "docs/ext/secret.md",
		"missing":           "docs/nope.md",
		"wrong extension":   "docs/diagram.pdf",
		"directory":         "docs/dir.md",
		"the folder itself": ".",
	} {
		args := fmt.Sprintf(`{"rel_path":%q,"kind":"doc","reason":"r"}`, rel)
		_, err := proposeIn(t, reg, fx.a, "attach_document", args)
		var verr *ValidationError
		require.ErrorAs(t, err, &verr, name)
	}
	assert.Equal(t, 0, countProjectDocuments(t, fx.d, fx.a), "nothing attached")
	assert.Equal(t, 0, countActions(t, fx.d), "a refused attach writes no audit row")

	// The folder path itself may hold spaces and non-ASCII characters.
	writeProjectFile(t, fx.d, fx.a, "docs/spec ü.md", "# Spec\n")
	mustApply(t, reg, fx.a, "attach_document", `{"rel_path":"docs/spec ü.md","kind":"spec","reason":"r"}`)
	assert.Equal(t, 1, countProjectDocuments(t, fx.d, fx.a))
}

func TestComments_AgentThreadLifecycle(t *testing.T) {
	fx := newProjectFixture(t)
	reg := projectRegistry(t, fx.d)
	writeProjectFile(t, fx.d, fx.a, "docs/spec.md", "# Spec\n")
	doc := mustApply(t, reg, fx.a, "attach_document", `{"rel_path":"docs/spec.md","kind":"spec","reason":"r"}`)
	docID := int64(doc["document_id"].(float64))
	ownerRoot, err := fx.d.AddProjectComment(db.ProjectComment{ProjectID: fx.a,
		DocumentID: nullInt(docID), Author: "owner", Body: "tighten this", AnchorQuote: "Spec", AnchorHeading: "Spec"})
	require.NoError(t, err)

	fresh := callReadIn(t, reg, fx.a, "list_comments", `{}`)
	assert.Contains(t, fresh, `"body":"tighten this"`)
	assert.Contains(t, fresh, `"anchor_quote":"Spec"`)
	assert.NotContains(t, fresh, "why?", "another project's comment is not listed")

	mustApply(t, reg, fx.a, "resolve_comment", fmt.Sprintf(`{"comment_id":%d,"reply":"Tightened.","reason":"addressed"}`, ownerRoot))
	root, err := fx.d.GetProjectComment(ownerRoot)
	require.NoError(t, err)
	assert.Equal(t, "resolved", root.Status)
	thread := callReadIn(t, reg, fx.a, "list_comments", fmt.Sprintf(`{"document_id":%d}`, docID))
	assert.Contains(t, thread, `"body":"Tightened."`)
	assert.Contains(t, thread, `"author":"agent"`)

	out := mustApply(t, reg, fx.a, "add_comment", fmt.Sprintf(`{"target_id":%d,"body":"Which DB?","reason":"blocked"}`, fx.aTarget))
	c, err := fx.d.GetProjectComment(int64(out["comment_id"].(float64)))
	require.NoError(t, err)
	assert.Equal(t, "agent", c.Author)
	assert.Equal(t, "claude-code", c.AgentLabel)
	assert.Equal(t, fx.a, c.ProjectID)

	reply := mustApply(t, reg, fx.a, "add_comment", fmt.Sprintf(`{"parent_id":%d,"body":"Answer?","reason":"r"}`, c.ID))
	_, err = proposeIn(t, reg, fx.a, "resolve_comment", fmt.Sprintf(`{"comment_id":%d,"reason":"r"}`, int64(reply["comment_id"].(float64))))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.True(t, strings.Contains(verr.Msg, "is a reply"), verr.Msg)

	for _, args := range []string{
		`{"body":"x","reason":"r"}`,
		fmt.Sprintf(`{"target_id":%d,"parent_id":%d,"body":"x","reason":"r"}`, fx.aTarget, c.ID),
		fmt.Sprintf(`{"target_id":%d,"body":" ","reason":"r"}`, fx.aTarget),
	} {
		_, err := proposeIn(t, reg, fx.a, "add_comment", args)
		require.ErrorAs(t, err, &verr, args)
	}
}

func TestListComments_RefusesAnotherProjectsDocument(t *testing.T) {
	fx := newProjectFixture(t)
	reg := projectRegistry(t, fx.d)
	_, err := reg.CallRead(context.Background(), "list_comments",
		json.RawMessage(fmt.Sprintf(`{"document_id":%d}`, fx.bDocument)), directBinding(fx.a))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "not in this project")
}

func nullInt(v int64) sql.NullInt64 { return sql.NullInt64{Int64: v, Valid: true} }
```

In `internal/tools/projects_test.go`, extend `outsideProjectCalls` — after the `"remove another project's source"` entry add:

```go
		{"comment on another project's target", "add_comment", fmt.Sprintf(`{"target_id":%d,"body":"hi","reason":"r"}`, fx.bTarget)},
		{"comment on a non-project target", "add_comment", fmt.Sprintf(`{"target_id":%d,"body":"hi","reason":"r"}`, fx.plain)},
		{"reply in another project's thread", "add_comment", fmt.Sprintf(`{"parent_id":%d,"body":"hi","reason":"r"}`, fx.bComment)},
		{"resolve another project's comment", "resolve_comment", fmt.Sprintf(`{"comment_id":%d,"reply":"done","reason":"r"}`, fx.bComment)},
		{"link a document to another project's target", "attach_document", fmt.Sprintf(`{"rel_path":"README.md","kind":"doc","target_id":%d,"reason":"r"}`, fx.bTarget)},
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `go test ./internal/tools -run 'TestAttachDocument|TestDev06|TestComments|TestListComments' > /tmp/p2t8.log 2>&1; echo "exit=$?"; grep -m3 -E "FAIL|Error:" /tmp/p2t8.log`
Expected: `exit=1` with exactly these five failing: `TestAttachDocument_AttachesAndReattaches`, `TestDev06_AttachDocumentStaysInsideTheFolder`, `TestComments_AgentThreadLifecycle`, `TestListComments_RefusesAnotherProjectsDocument`, `TestDev06_WriteOutsideTheBoundProjectIsRefused` — the four tools are not registered yet, so every call returns `ErrUnknownTool`, which is not the `*ValidationError` the guards require (`TestDev06_ExternalToolRefusedUnderDirectApply` keeps passing).

- [ ] **Step 3: Implement**

Create `internal/tools/project_docs.go`:


```go
package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"watchtower/internal/db"
)

// projectAgentLabel is the agent_label every agent comment carries.
const projectAgentLabel = "claude-code"

// resolveInsideFolder resolves rel against the project folder — symlinks
// included — and returns the absolute path only when it stays inside the
// folder and names an existing .md/.txt file. `../` and a symlink (file or
// directory) pointing out of the folder are both refused.
func resolveInsideFolder(folder, rel string) (string, error) {
	if strings.TrimSpace(rel) == "" || filepath.IsAbs(rel) {
		return "", &ValidationError{Msg: "rel_path must be a path relative to the project folder"}
	}
	abs, err := filepath.EvalSymlinks(filepath.Join(folder, rel))
	if err != nil {
		return "", &ValidationError{Msg: fmt.Sprintf("%s does not exist in the project folder", rel)}
	}
	inside, err := filepath.Rel(folder, abs)
	if err != nil || inside == ".." || strings.HasPrefix(inside, ".."+string(filepath.Separator)) {
		return "", &ValidationError{Msg: fmt.Sprintf("%s resolves outside the project folder", rel)}
	}
	return abs, checkDocumentFile(rel, abs)
}

func checkDocumentFile(rel, abs string) error {
	ext := strings.ToLower(filepath.Ext(abs))
	if ext != ".md" && ext != ".txt" {
		return &ValidationError{Msg: fmt.Sprintf("%s is not a .md or .txt file", rel)}
	}
	st, err := os.Stat(abs)
	if err != nil || !st.Mode().IsRegular() {
		return &ValidationError{Msg: fmt.Sprintf("%s is not a regular file", rel)}
	}
	return nil
}

// documentInProject loads a document and fails unless it belongs to projectID.
func documentInProject(d *db.DB, projectID, documentID int64) (*db.ProjectDocument, error) {
	doc, err := d.GetProjectDocument(documentID)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("loading document %d: %w", documentID, err)
	}
	if doc == nil || doc.ProjectID != projectID {
		return nil, notInProject("document", documentID)
	}
	return doc, nil
}

// commentInProject loads a comment and fails unless it belongs to projectID.
func commentInProject(d *db.DB, projectID, commentID int64) (*db.ProjectComment, error) {
	c, err := d.GetProjectComment(commentID)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("loading comment %d: %w", commentID, err)
	}
	if c == nil || c.ProjectID != projectID {
		return nil, notInProject("comment", commentID)
	}
	return c, nil
}

// optionalTarget checks an optional target id against the project.
func optionalTarget(d *db.DB, projectID, targetID int64) (sql.NullInt64, error) {
	if targetID == 0 {
		return sql.NullInt64{}, nil
	}
	if _, err := targetInProject(d, projectID, targetID); err != nil {
		return sql.NullInt64{}, err
	}
	return sql.NullInt64{Int64: targetID, Valid: true}, nil
}

// ---- attach_document ---------------------------------------------------

type attachDocumentArgs struct {
	RelPath  string `json:"rel_path" jsonschema:"path of the .md/.txt file relative to the project folder, e.g. docs/specs/x.md"`
	Kind     string `json:"kind" jsonschema:"spec | plan | doc"`
	Title    string `json:"title,omitempty" jsonschema:"display title; defaults to the file name"`
	TargetID int64  `json:"target_id,omitempty" jsonschema:"the project target this document belongs to"`
	Reason   string `json:"reason" jsonschema:"one sentence: what the document is, e.g. 'plan for feature X'"`
}

// NewAttachDocument attaches (or re-attaches, marking it revised) a file in
// the project folder so the owner can review and comment on it.
func NewAttachDocument() *Tool {
	return &Tool{
		Name: "attach_document",
		Description: "Attach a spec, plan or doc (a .md/.txt file inside the project folder) so the owner can " +
			"review and comment on it in Watchtower. Attach again after revising it — that marks it revised. " +
			"Applied immediately.",
		InputSchema: mustSchema[attachDocumentArgs]("attach_document"),
		Access:      AccessWrite,
		Surfaces:    projectSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a attachDocumentArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if a.Kind == "" {
				return &ValidationError{Msg: "kind is required"}
			}
			return validateEnum("kind", a.Kind, "spec", "plan", "doc")
		},
		Scope: func(ctx context.Context, d *db.DB, raw json.RawMessage, b Binding) error {
			var a attachDocumentArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "invalid arguments"}
			}
			_, _, err := resolveAttachment(ctx, d, b, a)
			return err
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a attachDocumentArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding attach_document args: %w", err)
			}
			return attachDocument(ctx, d, call.Binding, a)
		},
	}
}

// resolveAttachment returns the folder-relative clean path of the file and
// the checked target link.
func resolveAttachment(ctx context.Context, d *db.DB, b Binding, a attachDocumentArgs) (string, sql.NullInt64, error) {
	p, err := projectOf(ctx, d, b)
	if err != nil {
		return "", sql.NullInt64{}, err
	}
	abs, err := resolveInsideFolder(p.FolderPath, a.RelPath)
	if err != nil {
		return "", sql.NullInt64{}, err
	}
	target, err := optionalTarget(d, p.ID, a.TargetID)
	if err != nil {
		return "", sql.NullInt64{}, err
	}
	rel, err := filepath.Rel(p.FolderPath, abs)
	if err != nil {
		return "", sql.NullInt64{}, fmt.Errorf("relativizing %s: %w", abs, err)
	}
	return filepath.ToSlash(rel), target, nil
}

func attachDocument(ctx context.Context, d *db.DB, b Binding, a attachDocumentArgs) (any, error) {
	rel, target, err := resolveAttachment(ctx, d, b, a)
	if err != nil {
		return nil, err
	}
	title := strings.TrimSpace(a.Title)
	if title == "" {
		title = strings.TrimSuffix(filepath.Base(rel), filepath.Ext(rel))
	}
	id, created, err := d.UpsertProjectDocument(db.ProjectDocument{
		ProjectID: b.ProjectID, TargetID: target, RelPath: rel, Kind: a.Kind, Title: title,
	})
	if err != nil {
		return nil, fmt.Errorf("attaching %s: %w", rel, err)
	}
	return map[string]any{"document_id": id, "rel_path": rel, "created": created}, nil
}

// ---- list_comments -----------------------------------------------------

type listCommentsArgs struct {
	TargetID    int64 `json:"target_id,omitempty" jsonschema:"comments on this project target"`
	DocumentID  int64 `json:"document_id,omitempty" jsonschema:"comments on this attached document"`
	NewForAgent *bool `json:"new_for_agent,omitempty" jsonschema:"only what is new for you (open owner comments, unanswered owner replies); default true when no id is given"`
}

type commentView struct {
	ID         int64  `json:"id"`
	TargetID   int64  `json:"target_id,omitempty"`
	DocumentID int64  `json:"document_id,omitempty"`
	ParentID   int64  `json:"parent_id,omitempty"`
	Author     string `json:"author"`
	Body       string `json:"body"`
	Status     string `json:"status"`
	Quote      string `json:"anchor_quote,omitempty"`
	Heading    string `json:"anchor_heading,omitempty"`
	CreatedAt  string `json:"created_at"`
}

// NewListComments lists project comments by target, by document, or — the
// default — everything new for the agent.
func NewListComments() *Tool {
	return &Tool{
		Name: "list_comments",
		Description: "List comments on this project: on a target (target_id), on a document (document_id, " +
			"with the quoted passage and its heading), or — by default — every owner comment new for you. " +
			"Read a document's comments before revising it.",
		InputSchema: mustSchema[listCommentsArgs]("list_comments"),
		Access:      AccessRead,
		Surfaces:    projectSurfaces,
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a listCommentsArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			f, err := commentFilter(ctx, d, call.Binding, a)
			if err != nil {
				return nil, err
			}
			comments, err := d.ListProjectComments(f)
			if err != nil {
				return nil, fmt.Errorf("listing comments: %w", err)
			}
			return commentViews(comments), nil
		},
	}
}

func commentFilter(ctx context.Context, d *db.DB, b Binding, a listCommentsArgs) (db.ProjectCommentFilter, error) {
	p, err := projectOf(ctx, d, b)
	if err != nil {
		return db.ProjectCommentFilter{}, err
	}
	f := db.ProjectCommentFilter{ProjectID: p.ID, TargetID: a.TargetID, DocumentID: a.DocumentID}
	f.NewForAgent = a.TargetID == 0 && a.DocumentID == 0
	if a.NewForAgent != nil {
		f.NewForAgent = *a.NewForAgent
	}
	if a.TargetID != 0 {
		if _, err := targetInProject(d, p.ID, a.TargetID); err != nil {
			return f, err
		}
	}
	if a.DocumentID != 0 {
		if _, err := documentInProject(d, p.ID, a.DocumentID); err != nil {
			return f, err
		}
	}
	return f, nil
}

func commentViews(comments []db.ProjectComment) []commentView {
	out := make([]commentView, 0, len(comments))
	for _, c := range comments {
		out = append(out, commentView{
			ID: c.ID, TargetID: c.TargetID.Int64, DocumentID: c.DocumentID.Int64, ParentID: c.ParentID.Int64,
			Author: c.Author, Body: c.Body, Status: c.Status,
			Quote: c.AnchorQuote, Heading: c.AnchorHeading, CreatedAt: c.CreatedAt,
		})
	}
	return out
}

// ---- add_comment -------------------------------------------------------

type addCommentArgs struct {
	TargetID int64  `json:"target_id,omitempty" jsonschema:"start a thread on this project target"`
	ParentID int64  `json:"parent_id,omitempty" jsonschema:"reply to this comment instead"`
	Body     string `json:"body" jsonschema:"the comment: a question, a blocker or a done-summary"`
	Reason   string `json:"reason" jsonschema:"one sentence: why you comment"`
}

// NewAddComment posts an agent comment on a project target, or a reply.
func NewAddComment() *Tool {
	return &Tool{
		Name: "add_comment",
		Description: "Comment on a project target (target_id) or reply to a comment (parent_id) — questions for " +
			"the owner, blockers, done-summaries only. The owner is notified; keep working meanwhile. " +
			"Applied immediately.",
		InputSchema: mustSchema[addCommentArgs]("add_comment"),
		Access:      AccessWrite,
		Surfaces:    projectSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a addCommentArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if (a.TargetID == 0) == (a.ParentID == 0) {
				return &ValidationError{Msg: "give exactly one of target_id or parent_id"}
			}
			_, err := requireText("body", a.Body, 8000)
			return err
		},
		Scope: func(ctx context.Context, d *db.DB, raw json.RawMessage, b Binding) error {
			var a addCommentArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "invalid arguments"}
			}
			return scopeComment(ctx, d, b, a.TargetID, a.ParentID)
		},
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a addCommentArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding add_comment args: %w", err)
			}
			id, err := addAgentComment(d, call.Binding.ProjectID, a.TargetID, a.ParentID, a.Body)
			if err != nil {
				return nil, err
			}
			return map[string]any{"comment_id": id}, nil
		},
	}
}

func scopeComment(ctx context.Context, d *db.DB, b Binding, targetID, parentID int64) error {
	if _, err := projectOf(ctx, d, b); err != nil {
		return err
	}
	if targetID != 0 {
		_, err := targetInProject(d, b.ProjectID, targetID)
		return err
	}
	_, err := commentInProject(d, b.ProjectID, parentID)
	return err
}

func addAgentComment(d *db.DB, projectID, targetID, parentID int64, body string) (int64, error) {
	c := db.ProjectComment{ProjectID: projectID, Author: "agent", AgentLabel: projectAgentLabel, Body: strings.TrimSpace(body)}
	if targetID != 0 {
		c.TargetID = sql.NullInt64{Int64: targetID, Valid: true}
	}
	if parentID != 0 {
		c.ParentID = sql.NullInt64{Int64: parentID, Valid: true}
	}
	id, err := d.AddProjectComment(c)
	if err != nil {
		return 0, fmt.Errorf("adding comment: %w", err)
	}
	return id, nil
}

// ---- resolve_comment ---------------------------------------------------

type resolveCommentArgs struct {
	CommentID int64  `json:"comment_id" jsonschema:"the thread's root comment"`
	Reply     string `json:"reply,omitempty" jsonschema:"one line: what you changed"`
	Reason    string `json:"reason" jsonschema:"one sentence: why it is resolved"`
}

// NewResolveComment resolves a comment thread, optionally with a reply.
func NewResolveComment() *Tool {
	return &Tool{
		Name: "resolve_comment",
		Description: "Resolve a comment thread (its root comment id) after addressing it, optionally with a " +
			"one-line reply saying what changed. Applied immediately.",
		InputSchema: mustSchema[resolveCommentArgs]("resolve_comment"),
		Access:      AccessWrite,
		Surfaces:    projectSurfaces,
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a resolveCommentArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if len([]rune(a.Reply)) > 8000 {
				return &ValidationError{Msg: "reply must be at most 8000 characters"}
			}
			return nil
		},
		Scope: func(ctx context.Context, d *db.DB, raw json.RawMessage, b Binding) error {
			var a resolveCommentArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "invalid arguments"}
			}
			return scopeResolve(ctx, d, b, a.CommentID)
		},
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a resolveCommentArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding resolve_comment args: %w", err)
			}
			return resolveComment(d, call.Binding.ProjectID, a)
		},
	}
}

func scopeResolve(ctx context.Context, d *db.DB, b Binding, commentID int64) error {
	if _, err := projectOf(ctx, d, b); err != nil {
		return err
	}
	c, err := commentInProject(d, b.ProjectID, commentID)
	if err != nil {
		return err
	}
	if c.ParentID.Valid {
		return &ValidationError{Msg: fmt.Sprintf("comment %d is a reply; resolve its thread's root comment %d", commentID, c.ParentID.Int64)}
	}
	return nil
}

// resolveComment posts the optional reply first, then resolves the root, so
// a failure never leaves a thread marked resolved without its answer.
func resolveComment(d *db.DB, projectID int64, a resolveCommentArgs) (any, error) {
	out := map[string]any{"comment_id": a.CommentID}
	if strings.TrimSpace(a.Reply) != "" {
		id, err := addAgentComment(d, projectID, 0, a.CommentID, a.Reply)
		if err != nil {
			return nil, err
		}
		out["reply_id"] = id
	}
	if err := d.SetProjectCommentStatus(a.CommentID, "resolved"); err != nil {
		return nil, fmt.Errorf("resolving comment %d: %w", a.CommentID, err)
	}
	return out, nil
}
```

In `internal/tools/projects.go`, `ProjectTools` — replace

```go
		NewCreateTargets(), NewUpdateTarget(),
	}
```

with

```go
		NewCreateTargets(), NewUpdateTarget(),
		NewAttachDocument(), NewListComments(), NewAddComment(), NewResolveComment(),
	}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `go test ./internal/tools > /tmp/p2t8.log 2>&1; echo "exit=$?"; tail -2 /tmp/p2t8.log`
Expected: `exit=0`. `TestProjectTools_AllOnProjectSurfaceNeverExternal` now also covers the four new tools.

Mutation check (after the commit): in `resolveInsideFolder` change `if err != nil || inside == ".." || strings.HasPrefix(inside, ".."+string(filepath.Separator)) {` to `if false {` → `go test ./internal/tools -run TestDev06_AttachDocumentStaysInsideTheFolder` FAILS (the symlink and `../` cases attach); `git checkout internal/tools/project_docs.go` → PASS.

- [ ] **Step 5: Lint**

Run: `make lint-diff`
Expected: no new issues.

- [ ] **Step 6: Commit**


```bash
git add internal/tools/project_docs.go internal/tools/project_docs_test.go internal/tools/projects.go internal/tools/projects_test.go
git commit -m "$(cat <<'EOF'
feat(tools): project document and comment tools

attach_document (a .md/.txt inside the project folder only: ../,
absolute paths and symlink escapes are refused; re-attach marks it
revised), list_comments, add_comment (author always agent) and
resolve_comment (reply first, then resolve; roots only). All scoped to
the bound project (DEV-06).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lo9jbbmXQcr3qHo5f3pLD8
EOF
)"
```

---

## Task 9: `mcp --project N` + registry assembly + contracts

**Files:**
- Modify: `cmd/mcp.go` (`--project` flag, `mcpProjectOptions`, help text)
- Modify: `cmd/actions_registry.go` (`buildToolRegistry` registers `tools.ProjectTools()`)
- Modify: `cmd/mcp_test.go`, `cmd/actions_registry_test.go`
- Modify: `internal/mcp/actions.go` (`get_action` visibility via `actionVisible`)
- Create: `internal/mcp/project_test.go`
- Modify: `docs/inventory/dev-surface.md` (DEV-06 + DEV-01/DEV-05 amendments + changelog), `docs/inventory/agent-actions.md` (AGENT-01/AGENT-02 amendments + changelog)
- Create: `docs/inventory/projects.md` (PROJ-01..04)
- Modify: `docs/inventory/README.md` (mapping row)

**Interfaces:**
- Consumes: Tasks 6–8 (`Binding{Surface:"project", ProjectID, DirectApply}`, `tools.ProjectTools()`, the `CallRead` binding already passed by `internal/mcp` since Task 6); Phase 1's `GetProject`, `ErrProjectNotFound`, `CreateProject`, `ResolveProjectFolder`, `DeleteProject`, `GetProjectBoard`; existing `internal/mcp` test helpers `seedDB`, `newChatSession`, `textContent` and `LocalSession` (`ConnectLocal`/`Tools`/`Call`).
- Produces:
  - CLI: `watchtower mcp --project N` (int64; 0 = off). Refuses a missing project (error wraps `db.ErrProjectNotFound`) and `--chat`. Never calls `SetReadOnly`.
  - `func mcpProjectOptions(cfg *config.Config, database *db.DB, projectID int64) ([]internalmcp.ServerOption, error)` (package `cmd`).
  - `func actionVisible(row db.AgentAction, binding tools.Binding) bool` (package `mcp`) — a project session sees only rows with `context_type='project'` and `context_id=N`.
  - Inventory: DEV-06 (new), DEV-01/DEV-05/AGENT-01/AGENT-02 amended, `docs/inventory/projects.md` with PROJ-01..04 (later tasks fill its guard lines: Task 12 for PROJ-02/04, Task 16 for PROJ-03, Task 20 for PROJ-01's Desktop half).

- [ ] **Step 1: Write the failing tests**

In `cmd/mcp_test.go`, replace the import block

```go
import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)
```

with

```go
import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	internalmcp "watchtower/internal/mcp"
	"watchtower/internal/tools"
)
```

and append:


```go
// resetMCPFlags restores the mcp command's package-level flags after a test.
func resetMCPFlags(t *testing.T) {
	t.Helper()
	chat, project := mcpFlagChat, mcpFlagProject
	t.Cleanup(func() { mcpFlagChat, mcpFlagProject = chat, project })
	mcpFlagChat, mcpFlagProject = false, 0
}

func openMCPTestDB(t *testing.T) *db.DB {
	t.Helper()
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	database.SetMaxOpenConns(1) // one connection, so query_only covers every query
	t.Cleanup(func() { _ = database.Close() })
	return database
}

func localToolNames(t *testing.T, database *db.DB, opts []internalmcp.ServerOption) (map[string]bool, *internalmcp.LocalSession) {
	t.Helper()
	ls, err := internalmcp.NewServer(database, opts...).ConnectLocal(context.Background())
	require.NoError(t, err)
	t.Cleanup(func() { _ = ls.Close() })
	infos, err := ls.Tools(context.Background())
	require.NoError(t, err)
	names := map[string]bool{}
	for _, info := range infos {
		names[info.Name] = true
	}
	return names, ls
}

// DEV-06 / DEV-01: plain `watchtower mcp` (no --chat, no --project) is still
// the read-only developer surface — query_only on, no write tool, no project
// tool, no get_action.
func TestDev06_PlainMCPStaysReadOnly(t *testing.T) {
	resetMCPFlags(t)
	database := openMCPTestDB(t)
	cfg := &config.Config{ActiveWorkspace: "test-ws"}

	opts, err := mcpModeOptions(cfg, database, "", nil)
	require.NoError(t, err)
	assert.Empty(t, opts, "dev mode passes no registry")
	_, err = database.Exec(`INSERT INTO projects (name, folder_path) VALUES ('x', '/tmp/x')`)
	require.Error(t, err, "the dev connection must refuse writes (query_only)")

	names, _ := localToolNames(t, database, opts)
	for _, tool := range buildToolRegistry(cfg, openMCPTestDB(t)).All() {
		if tool.Access == tools.AccessWrite || slices.Contains(tool.Surfaces, "project") {
			assert.False(t, names[tool.Name], "dev mode must not mount %s", tool.Name)
		}
	}
	assert.False(t, names["get_action"])
	assert.True(t, names["list_targets"], "the read tools stay")
}

func TestMCPProjectMode_BindsTheProjectAndAppliesDirectly(t *testing.T) {
	resetMCPFlags(t)
	database := openMCPTestDB(t)
	folder, err := db.ResolveProjectFolder(t.TempDir())
	require.NoError(t, err)
	pid, err := database.CreateProject("acme", folder)
	require.NoError(t, err)
	mcpFlagProject = pid

	opts, err := mcpModeOptions(&config.Config{ActiveWorkspace: "test-ws"}, database, "", nil)
	require.NoError(t, err)
	require.Len(t, opts, 1)

	names, ls := localToolNames(t, database, opts)
	for _, n := range []string{"project_info", "project_board", "create_targets", "attach_document", "get_action", "list_targets"} {
		assert.True(t, names[n], "project mode mounts %s", n)
	}
	for _, n := range []string{"create_target", "create_jira_issue", "connect_jira_board", "create_idea"} {
		assert.False(t, names[n], "project mode must not mount %s", n)
	}

	text, isErr, err := ls.Call(context.Background(), "create_targets", map[string]any{
		"items": []any{map[string]any{"text": "Feature X"}}, "reason": "first board",
	})
	require.NoError(t, err)
	require.False(t, isErr, text)
	assert.Contains(t, text, `"status": "applied"`)
	board, err := database.GetProjectBoard(pid)
	require.NoError(t, err)
	require.Len(t, board, 1)
	assert.Equal(t, "Feature X", board[0].Target.Text)
}

func TestMCPProjectMode_RefusesMissingProjectAndChat(t *testing.T) {
	resetMCPFlags(t)
	database := openMCPTestDB(t)
	cfg := &config.Config{ActiveWorkspace: "test-ws"}

	mcpFlagProject = 404
	_, err := mcpModeOptions(cfg, database, "", nil)
	assert.ErrorIs(t, err, db.ErrProjectNotFound)

	mcpFlagChat = true
	_, err = mcpModeOptions(cfg, database, "", nil)
	assert.ErrorContains(t, err, "mutually exclusive")
}
```

In `cmd/actions_registry_test.go`, at the end of `TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces` (after the `for _, w := range jiraWrites { assert.False(t, reaction[w], …) }` loop, before the closing `}`), add:


```go
	// The project surface (`mcp --project N`, DEV-06): exactly the project
	// tools plus the surface-less read tools — no other write tool, nothing
	// External — and no project tool leaks onto another surface.
	projectTools := []string{
		"project_info", "project_board", "update_project", "add_project_source", "remove_project_source",
		"create_targets", "update_target", "attach_document", "list_comments", "add_comment", "resolve_comment",
	}
	project := names("project")
	for _, p := range projectTools {
		assert.True(t, project[p], "%s missing on the project surface", p)
		assert.False(t, main[p] || target[p] || reaction[p], "%s is project-surface only", p)
	}
	for _, rt := range tools.ReadTools() {
		assert.True(t, project[rt.Name], "read tool %s missing on the project surface", rt.Name)
	}
	assert.Len(t, project, len(projectTools)+len(tools.ReadTools()), "nothing else on the project surface")
	for _, tool := range reg.List("project") {
		assert.False(t, tool.External, "%s is External on the project surface (DEV-06)", tool.Name)
	}
```

Create `internal/mcp/project_test.go`:


```go
package mcp

import (
	"context"
	"encoding/json"
	"strconv"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// newProjectSession mirrors cmd/mcp.go's --project wiring: a writable
// connection, the project tools plus every read tool, bound to projectID
// with DirectApply.
func newProjectSession(t *testing.T, database *db.DB, projectID int64) *mcpsdk.ClientSession {
	t.Helper()
	reg := tools.New(database)
	for _, tool := range append(tools.ProjectTools(), tools.ReadTools()...) {
		if err := reg.Register(tool); err != nil {
			t.Fatal(err)
		}
	}
	return newChatSession(t, database, reg, tools.Binding{Surface: "project", ProjectID: projectID, DirectApply: true})
}

func seedMCPProject(t *testing.T, database *db.DB) int64 {
	t.Helper()
	folder, err := db.ResolveProjectFolder(t.TempDir())
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
	other, err := database.InsertAgentAction(db.AgentAction{Tool: "create_target", ArgsJSON: `{}`, Reason: "r",
		Surface: "main", ConversationID: 0, Status: "pending", TrustAtCreate: "ask"})
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

	for id, visible := range map[int64]bool{rc.ActionID: true, other: false} {
		res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{Name: "get_action", Arguments: map[string]any{"id": id}})
		if err != nil {
			t.Fatal(err)
		}
		if res.IsError == visible {
			t.Errorf("action #%d: visible=%v but IsError=%v (%s)", id, visible, res.IsError, textContent(t, res))
		}
	}
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `go test ./cmd -run 'TestDev06|TestMCPProjectMode|TestBuildToolRegistry' > /tmp/p2t9.log 2>&1; echo "exit=$?"; grep -m3 undefined /tmp/p2t9.log`
Expected: `exit=1`, `undefined: mcpFlagProject` (compile error).

Run: `go test ./internal/mcp -run 'TestProjectMode|TestGetAction_ProjectSession' > /tmp/p2t9m.log 2>&1; echo "exit=$?"; grep -E "^--- FAIL" /tmp/p2t9m.log`
Expected: `exit=1`, `--- FAIL: TestGetAction_ProjectSessionSeesOnlyItsRows` (the zero-conversation project binding still sees the unrelated main-chat row). `TestProjectMode_DeletedProjectEveryToolAnswersNoLongerExists` already passes — Task 6's `projectAlive` delivers it; it is here to pin the behaviour through the MCP adapter.

- [ ] **Step 3: Implement**

`cmd/mcp.go`:

(a) In the flag `var (…)` block, after `mcpFlagContextID    string` add `mcpFlagProject      int64`.

(b) In `init()`, after the `--context-id` line add:

```go
	mcpCmd.Flags().Int64Var(&mcpFlagProject, "project", 0, "project mode: bind to project N and apply its project tools directly (installed by 'integrate claude-code --project N')")
```

(c) In `mcpCmd.Long`, replace

```go
Add it to Claude Code with:
  claude mcp add watchtower -- watchtower mcp`,
```

with

```go
Add it to Claude Code with:
  claude mcp add watchtower -- watchtower mcp

With --project N the server is bound to one Watchtower project: its project
tools (board, documents, comments) apply directly to that project only, and
nothing else becomes writable. 'watchtower integrate claude-code --project N'
registers this mode in the project folder; never register it by hand for an
unrelated client.`,
```

(d) Replace

```go
// mcpModeOptions sets up chat mode (the write-tool registry) or dev mode (the
// read-only fence) on the opened database.
func mcpModeOptions(cfg *config.Config, database *db.DB, turn string, turnFunc func() string) ([]internalmcp.ServerOption, error) {
	if !mcpFlagChat {
```

with

```go
// mcpModeOptions sets up project mode, chat mode (the write-tool registry) or
// dev mode (the read-only fence) on the opened database.
func mcpModeOptions(cfg *config.Config, database *db.DB, turn string, turnFunc func() string) ([]internalmcp.ServerOption, error) {
	if mcpFlagProject != 0 {
		return mcpProjectOptions(cfg, database, mcpFlagProject)
	}
	if !mcpFlagChat {
```

(e) Add directly before `func runMCP(`:


```go
// mcpProjectOptions is `watchtower mcp --project N` (DEV-06): the connection
// stays writable, the registry is bound to project N on the "project" surface,
// and its tools apply directly (DirectApply) with an agent_actions audit row —
// never an External tool. The project must exist when the server starts; if
// it is deleted later, every tool answers "project N no longer exists".
func mcpProjectOptions(cfg *config.Config, database *db.DB, projectID int64) ([]internalmcp.ServerOption, error) {
	if mcpFlagChat {
		return nil, errors.New("--project and --chat are mutually exclusive")
	}
	if projectID < 0 {
		return nil, fmt.Errorf("--project must be a project id, got %d", projectID)
	}
	if _, err := database.GetProject(projectID); err != nil {
		return nil, fmt.Errorf("project %d: %w", projectID, err)
	}
	return []internalmcp.ServerOption{internalmcp.WithRegistry(buildToolRegistry(cfg, database), tools.Binding{
		Surface: "project", ProjectID: projectID, DirectApply: true,
	})}, nil
}
```

`cmd/actions_registry.go` — in `buildToolRegistry`, before the comment `// Every migrated read tool. Chat mode dispatches these through the registry's`, add:

```go
	// The project tools (surface "project" only): mounted by `mcp --project N`,
	// which applies them directly under Binding.DirectApply (DEV-06).
	regTools = append(regTools, tools.ProjectTools()...)
```

`internal/mcp/actions.go`:

(a) Add `"strconv"` to the imports after `"fmt"`.

(b) In the `get_action` handler replace

```go
		// A binding with no conversation (conversation_id 0: a CLI-only
		// install, spec §12, or a dev/test session with none bound) sees every
		// row; otherwise a row from a different conversation answers the same
		// not-found error as a missing row, so the model cannot learn that an
		// id it invented belongs to someone else's chat.
		if row == nil || (binding.ConversationID != 0 && row.ConversationID != binding.ConversationID) {
```

with

```go
		if row == nil || !actionVisible(*row, binding) {
```

(c) Add before `// actionView is the model-facing shape of an agent_actions row.`:

```go
// actionVisible decides whether get_action may show row to this session. A
// project session sees only its own project's rows. A binding with no
// conversation (conversation_id 0: a CLI-only install, spec §12, or a
// dev/test session with none bound) sees every other row; otherwise a row
// from a different conversation answers the same not-found error as a
// missing row, so the model cannot learn that an id it invented belongs to
// someone else's chat.
func actionVisible(row db.AgentAction, binding tools.Binding) bool {
	if binding.ProjectID != 0 {
		return row.ContextType == "project" && row.ContextID == strconv.FormatInt(binding.ProjectID, 10)
	}
	return binding.ConversationID == 0 || row.ConversationID == binding.ConversationID
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `go test ./internal/mcp > /tmp/p2t9m.log 2>&1; echo "exit=$?"; tail -2 /tmp/p2t9m.log`
Expected: `exit=0` — the new project tests plus every DEV/AGENT guard in the package unchanged (`TestToolsList`, `TestAllToolsAreReadOnly`, `TestNoToolMutatesDatabase`, `TestAgent01/02/06_*`, `TestGetAction_ScopedToBindingConversation`): dev mode still builds `tools.NewReadRegistry`, which holds no project tool.

Run: `go test ./cmd -run 'TestDev06|TestMCP|TestBuildToolRegistry|TestActions' > /tmp/p2t9.log 2>&1; echo "exit=$?"; tail -2 /tmp/p2t9.log`
Expected: `exit=0`.

Phase-scope checks (spec §10's inner loop for this phase): `go test ./internal/tools ./internal/agentloop ./internal/reactioncmd > /tmp/p2all.log 2>&1; echo "exit=$?"` → `exit=0`; `make lint-diff` → no new issues.

- [ ] **Step 5: Write the contracts**

**5a. `docs/inventory/dev-surface.md`.**

Replace the AI-assistant note's first sentence

```markdown
> AI assistant: when working in `internal/mcp/` or the registry's read tools
> (`internal/tools/taskcontext.go`, `experts.go`), `internal/devpack/`, or
> `cmd/integrate.go`, read this file first.
```

with

```markdown
> AI assistant: when working in `internal/mcp/`, the registry's read tools
> (`internal/tools/taskcontext.go`, `experts.go`), the project tools
> (`internal/tools/projects.go`, `project_targets.go`, `project_docs.go`,
> `project_scope.go`) or the registry's `DirectApply` path, `internal/devpack/`,
> `cmd/mcp.go`, or `cmd/integrate.go`, read this file first.
```

Replace the module line

```markdown
**Module:** `internal/mcp/` (`get_task_context`, `find_experts`) +
`internal/devpack/` + `cmd/integrate.go`
```

with

```markdown
**Module:** `internal/mcp/` (`get_task_context`, `find_experts`) +
`internal/devpack/` + `cmd/integrate.go` + `cmd/mcp.go` (`--project`, DEV-06) +
`internal/tools/{projects,project_targets,project_docs,project_scope}.go`
```

In **DEV-01**, replace

```markdown
**Observable:** Every tool on this surface is a read. The real enforcement is
```

with

```markdown
**Scope (amended 2026-09-29, spec `docs/superpowers/specs/2026-09-29-project-board-poc-design.md` D5):**
"read-only forever" is a promise about `watchtower mcp` **without**
`--project` — the server plain `integrate claude-code` registers for any
coding agent. `watchtower mcp --project N` is the one writable mode of this
surface and has its own contract, DEV-06; `--chat` is governed by
AGENT-01/02/06 (`agent-actions.md`). Plain `watchtower mcp` still mounts no
project tool, no write tool and no `get_action`, and still runs under
`query_only` (`TestDev06_PlainMCPStaysReadOnly`).

**Observable:** Every tool on the plain `watchtower mcp` surface is a read. The real enforcement is
```

and in DEV-01's **Test guards:** list add, as the last bullet:

```markdown
- `cmd/mcp_test.go::TestDev06_PlainMCPStaysReadOnly` (the `cmd` wiring: no `--chat`/`--project` → `query_only` on, no write/project tool, no `get_action`)
```

In **DEV-05**, insert before its `**Why locked:**` line:

```markdown
**Amended 2026-09-29 (spec `docs/superpowers/specs/2026-09-29-project-board-poc-design.md` D5/D6):**
the one hook on this surface is the `SessionStart` hook
`watchtower integrate claude-code --project N` installs into that project
folder's `.claude/settings.local.json`, running
`watchtower project brief --project N`. It is the explicit, CLI-controlled
opt-in this contract requires: only that command installs it (typed by the
owner, or run by the Desktop's New-project flow the owner starts);
`integrate remove --project N` and `watchtower project delete N` remove it;
plain `integrate claude-code` never installs one; and it runs only when the
owner's own Claude Code session starts in that folder. There is still no
daemon phase for this surface, and the brief only reads.
```

Append DEV-06 after DEV-05 (before `## Changelog`):

```markdown
## DEV-06 — the project-bound mode writes only its own project

**Status:** Enforced

**Observable:** `watchtower mcp --project N` (`cmd/mcp.go`'s
`mcpProjectOptions`; registered in the project folder as the local
`watchtower-project` server by `watchtower integrate claude-code --project N`)
is the one writable mode of this surface. It refuses to start when project N
does not exist or together with `--chat`, keeps the connection writable, and
mounts the registry (`buildToolRegistry`) on the `project` surface with
`tools.Binding{Surface: "project", ProjectID: N, DirectApply: true}`: the
eleven project tools (`internal/tools/projects.go`, `project_targets.go`,
`project_docs.go`) plus every surface-less read tool and `get_action`; no
other write tool is visible there. Three rules keep it narrow:

1. **Only project N's rows.** Every project write resolves what it touches —
   target, parent, source, document, comment — and its `Tool.Scope` refuses
   anything outside `Binding.ProjectID` ("… is not in this project") before
   any row, data or audit, is written; new rows take `project_id` from the
   binding only (a `project_id` argument is an unknown field and refused).
   `attach_document` accepts only an existing `.md`/`.txt` regular file that
   resolves, after symlinks, inside the project's `folder_path`
   (`resolveInsideFolder`: `../`, absolute paths, and symlinked files or
   directories pointing out are refused). `list_targets`/`get_target` see only
   project N's targets; `get_action` shows only project N's rows
   (`actionVisible`).
2. **Applied directly, audited.** Under `DirectApply`, `Registry.Propose`
   inserts the call's `agent_actions` row `approved` with
   `trust_at_create='execute'` and `context_type='project'`/`context_id=N`,
   then applies it inline through the ordinary `Apply` claim (AGENT-05) — for
   that call only: `tool_trust` is neither read nor written. `Apply` rebuilds
   the binding from the row (`bindingOf`) and re-runs `Scope`, so a retried
   row (`watchtower actions apply`) is re-scoped too.
3. **Never External.** `DirectApply` refuses an `External` tool outright (a
   ValidationError, no row) and any tool whose `Surfaces` does not name
   `project` explicitly — a surface-less tool cannot inherit direct apply
   (`directApplyGate`).

Once project N is deleted, every tool on a still-connected session — project
tool or not, read or write — answers `project N no longer exists` and writes
nothing (`Registry.projectAlive`, the first check of every call).

**Why locked:** This is the only place an external coding agent writes into
Watchtower without a per-call owner click. It is acceptable because the blast
radius is one project the owner created and bound to the very folder the agent
works in. A tool that wrote outside it, a non-project write tool visible on
this surface, or an External call would turn a folder-scoped board into an
unreviewed write path into the owner's whole app — or off the machine.

**Test guards:**
- `internal/tools/projects_test.go::TestDev06_WriteOutsideTheBoundProjectIsRefused` (every write aimed at another project's target/source/comment, a non-project target, or smuggling a `project_id` is refused; the other project's rows are byte-identical; no audit row)
- `internal/tools/registry_project_test.go::TestDev06_ExternalToolRefusedUnderDirectApply`
- `internal/tools/project_docs_test.go::TestDev06_AttachDocumentStaysInsideTheFolder` (`../`, nested `../`, absolute path, symlinked file, symlinked directory, missing file, wrong extension, directory, the folder itself)
- `cmd/mcp_test.go::TestDev06_PlainMCPStaysReadOnly` (the boundary with DEV-01)
- supporting: `TestDirectApply_AppliesInlineWithAuditRow`, `TestDirectApply_RefusesToolNotOnTheSurface`, `TestScope_RunsInProposeAndAgainInApply`, `TestProjectBinding_DeletedProjectAnswersNoLongerExists` (`internal/tools`); `TestProjectMode_DeletedProjectEveryToolAnswersNoLongerExists`, `TestGetAction_ProjectSessionSeesOnlyItsRows` (`internal/mcp`); `TestMCPProjectMode_BindsTheProjectAndAppliesDirectly`, `TestMCPProjectMode_RefusesMissingProjectAndChat`, and the project-surface block of `TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces` (exact tool set, none External) (`cmd`).

**Locked since:** 2026-09-29
```

Prepend to `## Changelog`:

```markdown
- 2026-09-29 (Projects POC, spec `docs/superpowers/specs/2026-09-29-project-board-poc-design.md` §4.2/§4.3/§7, owner decision D5): **DEV-06 added** (Enforced) — `watchtower mcp --project N`, this surface's one writable mode: eleven project tools on the `project` registry surface, applied directly under `tools.Binding.DirectApply` with an `agent_actions` audit row, scoped to project N, never an `External` tool. **DEV-01 amended**: "read-only forever" is scoped to `watchtower mcp` without `--project`; no DEV-01 guard changed, and `TestDev06_PlainMCPStaysReadOnly` joins its guard list. **DEV-05 amended**: the `SessionStart` hook installed by `integrate claude-code --project N` is the explicit CLI opt-in the contract requires (the installer itself lands in Phase 3). `Registry.CallRead` now takes the caller's `Binding` (dev mode passes the zero value, so its reads are unchanged), and `get_target` answers "no target with id N" for a project target outside that project's session (PROJ-01, `projects.md`).
```

**5b. `docs/inventory/agent-actions.md`.**

In **AGENT-01**, append to the end of its `**Observable:**` paragraph:

```markdown
 **Exception (2026-09-29, DEV-06):** on the `project` surface under `Binding.DirectApply` — reachable only through `watchtower mcp --project N` — a write is applied inline like an execute-trust call, without a per-call owner approval: still exactly one `agent_actions` row (`trust_at_create='execute'`), still through `Apply`'s claim, never an `External` tool, never a tool that does not name the `project` surface. See `docs/inventory/dev-surface.md` DEV-06.
```

In **AGENT-02**, replace

```markdown
**Observable:** `watchtower mcp` without `--chat` registers no write tool and no `get_action`, and keeps `PRAGMA query_only=ON`.
```

with

```markdown
**Observable:** `watchtower mcp` without `--chat` or `--project` registers no write tool and no `get_action`, and keeps `PRAGMA query_only=ON`. (`--project N` is DEV-06's project-bound mode: it mounts only the `project` surface's tools plus `get_action`, never a chat write tool.)
```

Prepend to its `## Changelog` (the list is not strictly ordered; put it first):

```markdown
- 2026-09-29 (Projects POC, spec `docs/superpowers/specs/2026-09-29-project-board-poc-design.md` §4.2, owner decision D5): `tools.Binding` gains `ProjectID` and `DirectApply`, `tools.Tool` gains an optional `Scope` hook (run in `Propose` after `Validate`, and again in `Apply` against the binding rebuilt from the row), and `Registry.CallRead` takes the `Binding`. **AGENT-01 amended** with the DirectApply exception (project surface only, one audit row, never External); **AGENT-02 amended** to name `--project`. AGENT-03..06 unchanged: `resolveTrust` still forces `ask` for an `External` tool before anything else, `directApplyGate` refuses one under `DirectApply`, and a zero `Binding` takes exactly the old path — every existing `TestAgent0N_*` guard passes unmodified.
```

**5c. Create `docs/inventory/projects.md`:**

```markdown
# Projects — Behavior Inventory

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/db/projects.go`,
> `project_comments.go`, `project_board.go`, the `project_id` exclusions in
> the targets readers, `internal/tools/project*.go`, `cmd/project*.go`,
> `internal/devpack/project*.go`, or `WatchtowerDesktop/Sources/**/Project*`,
> read this file first. Any proposed change that would break a guard test or
> remove a contract must be raised as a question before touching code.

A project is a folder with a board of targets, attached documents and
owner↔agent comments, worked on by Claude Code through
`watchtower mcp --project N` (DEV-06 in `dev-surface.md`), a project skill and
a `SessionStart` hook. Design:
`docs/superpowers/specs/2026-09-29-project-board-poc-design.md`.

**Module:** `internal/db/{projects,project_comments,project_board}.go` +
`internal/tools/{projects,project_targets,project_docs,project_scope}.go` +
`cmd/{project,project_brief}.go` + `internal/devpack/{project,project_settings}.go` +
`WatchtowerDesktop/Sources/Views/Projects/`
**Last full audit:** 2026-09-29

## PROJ-01 — project targets never reach a non-board reader

**Status:** Enforced (Go); the Desktop half lands with Task 20

**Observable:** A target with `project_id` set lives only on its project's
board. Every non-board Go reader filters `project_id IS NULL`: `GetTargets` by
default (`TargetFilter.ProjectID == 0`), `GetTargetsNeedingNextStep`,
`GetTargetsForBriefing`, `GetTargetCounts`, `NotifyDueTargets`,
`ListCatchupTargets`, `ListTargetsForMirror`, `internal/dayplan/gather.go`,
`internal/db/channel_stats.go`, and the extract/dedup snapshots in
`internal/targets/pipeline.go`; `nextstep.go`'s single-target path skips a
project target. The registry's `list_targets`/`get_target` return a project
target only inside that project's own session (`watchtower mcp --project N`);
any other session is told `no target with id N`.

**Why locked:** Owner decision D4. An agent decomposes a plan into dozens of
sub-targets; letting them into the Targets tab, the day plan, next-step,
Catch-Up, memory mirrors or the inbox overdue notification would flood every
personal surface with the agent's own bookkeeping — and spend next-step AI
calls on it.

**Test guards:**
- `internal/db` — `TestProj01_ProjectTargetsNeverReachNonBoardReaders` (Task 3)
- `internal/tools/projects_test.go::TestProj01_TargetReadsFollowTheSessionScope`

**Locked since:** 2026-09-29

## PROJ-02 — delete leaves nothing

**Status:** Enforced for the database; the folder half lands with Task 12

**Observable:** `watchtower project delete N` first runs the folder removal
(`projectRemoveInstall`, wired to `devpack.RemoveProject` in Task 12: the
`watchtower-project` skill, our `SessionStart` hook entry, the local
`watchtower-project` MCP registration and the `.git/info/exclude` lines
Watchtower added) — a removal failure is reported and the delete still
happens — then deletes the project row, which removes every project target,
source, document entry and comment in the same transaction
(`db.DeleteProject`, `ON DELETE CASCADE` from `projects`). A Claude Code
session still connected answers `project N no longer exists` on every tool
(DEV-06). The document files themselves are the owner's and stay in the
folder.

**Why locked:** Owner decision D7. A half-deleted project — orphan targets, a
hook that briefs about a project that no longer exists, an MCP server
registered against a dead id — is worse than no project at all, and the owner
must be able to undo the whole feature for a folder in one step.

**Test guards:**
- `internal/db` — the delete-cascade guard Task 4 added (the implementer of this task writes its exact name here: `grep -rn "func TestProj02_" internal/db`)
- `internal/tools/registry_project_test.go::TestProjectBinding_DeletedProjectAnswersNoLongerExists`
- `internal/mcp/project_test.go::TestProjectMode_DeletedProjectEveryToolAnswersNoLongerExists`

**Locked since:** 2026-09-29

## PROJ-03 — the Desktop never writes a project document

**Status:** Planned (the Desktop document view lands with Task 16)

**Observable:** The Desktop reads an attached document (`project_documents.rel_path`
under the project folder) to render it and re-anchor its comments, and writes
only `project_comments` rows — owner comments, replies, status, `read_at` —
never the file. Only the agent edits a document; the Desktop watches the file
and re-anchors, and a comment whose quote is gone becomes `outdated`, never
re-attached elsewhere. No project tool writes a file either:
`attach_document` only resolves and stats it.

**Why locked:** Owner decision D8. Two writers on one file — Claude Code in
the terminal and the Desktop view — would race and lose either the agent's or
the owner's edits; comments are the owner's channel into the document.

**Test guards:** the Desktop guards (`testProj03_…`) land with Task 16. Go
side, by review: `grep -nE "os\.(WriteFile|Create|OpenFile|Rename|Remove)" internal/tools/project_docs.go`
(expected: no match).

**Locked since:** 2026-09-29

## PROJ-04 — the install never overwrites the owner's content

**Status:** Planned (the installer lands with Tasks 11–12)

**Observable:** `watchtower integrate claude-code --project N` merges into
`DIR/.claude/settings.local.json` preserving every key and every hook the
owner has, adding exactly one `SessionStart` entry recognised by its exact
command string (installing twice leaves one); a malformed settings file is
left byte-identical and reported; `integrate remove --project N` deletes only
that entry. The `watchtower-project` skill follows DEV-04: a copy the owner
edited (differs from both what we ship and its `.watchtower-shipped` digest)
is never overwritten or deleted.

**Why locked:** The project folder is the owner's repository. An installer
that dropped one of the owner's settings keys or hooks, or clobbered an edited
skill, would make every later `integrate` a risk to the owner's own setup.

**Test guards:** land with Tasks 11–12 (Task 12 Step 9 records them here).

**Locked since:** 2026-09-29

## Changelog

- 2026-09-29: file created with PROJ-01..04 by the Projects POC (spec `docs/superpowers/specs/2026-09-29-project-board-poc-design.md` §7, plan `docs/superpowers/plans/2026-09-29-projects-poc.md`). PROJ-01 Enforced on the Go side (Task 3's reader exclusions + the registry's session-scoped `list_targets`/`get_target`, Task 7); PROJ-02 Enforced for the database (Task 4) with the folder half pending Task 12; PROJ-03 Planned (Task 16); PROJ-04 Planned (Tasks 11–12). The write path into these tables from Claude Code is contract DEV-06 in `dev-surface.md`.
```

**5d. `docs/inventory/README.md`** — add a row at the end of the mapping table (after the `Chat (main AI Chat)` row):

```markdown
| Projects | [projects.md](projects.md) | `internal/db/projects.go`, `internal/db/project_comments.go`, `internal/db/project_board.go`, `internal/db/migrations/00081_projects.sql`, `internal/tools/projects.go`, `internal/tools/project_targets.go`, `internal/tools/project_docs.go`, `internal/tools/project_scope.go`, `cmd/project.go`, `cmd/project_brief.go`, `cmd/mcp.go` (`--project`), `internal/devpack/project.go`, `internal/devpack/project_settings.go`, `WatchtowerDesktop/Sources/Views/Projects/`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/CommentAnchor.swift` |
```

and in the `Developer Surface` row replace its code-paths cell

```markdown
`internal/mcp/`, `internal/tools/` (`taskcontext.go`, `experts.go`), `internal/devpack/`, `cmd/integrate.go`
```

with

```markdown
`internal/mcp/`, `internal/tools/` (`taskcontext.go`, `experts.go`, `project_scope.go`), `internal/devpack/`, `cmd/integrate.go`, `cmd/mcp.go` (`--project`, DEV-06)
```

Fill PROJ-02's first guard bullet now: run `grep -rn "func TestProj02_" internal/db` and replace the parenthetical with the test name(s) it prints, in the form `` `internal/db/<file>::<TestName>` ``. If it prints nothing, stop and report to the controller — Task 4 owes that guard.

- [ ] **Step 6: Lint and verify the docs**

Run: `make lint-diff` → no new issues.
Run: `grep -n "DEV-06" docs/inventory/dev-surface.md docs/inventory/agent-actions.md docs/inventory/projects.md | head; grep -c "^## PROJ-0" docs/inventory/projects.md`
Expected: DEV-06 appears in all three files; `4`.

- [ ] **Step 7: Commit**


```bash
git add cmd/mcp.go cmd/mcp_test.go cmd/actions_registry.go cmd/actions_registry_test.go internal/mcp/actions.go internal/mcp/project_test.go docs/inventory/dev-surface.md docs/inventory/agent-actions.md docs/inventory/projects.md docs/inventory/README.md
git commit -m "$(cat <<'EOF'
feat(mcp): watchtower mcp --project N and the DEV-06 contract

A project-bound MCP mode: the registry on the "project" surface with
DirectApply, refused for a missing project or with --chat. Plain
watchtower mcp stays read-only. get_action in a project session shows
only that project's rows. Inventory: DEV-06 added, DEV-01/DEV-05 and
AGENT-01/AGENT-02 amended, projects.md with PROJ-01..04.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lo9jbbmXQcr3qHo5f3pLD8
EOF
)"
```

---

## Interface errata

Signatures and placements that differ from, or are more exact than, the plan index's "Tasks & cross-task interfaces":

1. **Aligned with Phase 1's final signatures** (`phase1-go-core.md` "Interface errata"): `create_targets` calls `func (db *DB) CreateProjectTargetsTx(tx *sql.Tx, projectID int64, items []db.ProjectTargetInput) ([]int64, error)` once, inside `func (db *DB) WithTx(fn func(*sql.Tx) error) error` (Task 2), mapping each `parent_key` to the 1-based `BatchParent` of the earlier item holding that key and each `parent_id` to `ParentID`; the parent-progress roll-up happens inside that call, so Task 7 does no recompute of its own. `targetInProject`/`documentInProject`/`commentInProject`/`sourceInProject` return a `*ValidationError` wrapping `db.ErrNotInProject` (hence Task 6's additive `ValidationError.Err` + `Unwrap`). `BoardNode.Target.ID` is `int`; `project_info`/`project_board` call `projectOf` before `GetProjectBoard`, which does not check existence. The deleted-project text is exactly `project N no longer exists` — the same words `project brief` prints as `Watchtower: project N no longer exists.`
2. **Phase 1 lookups relied on:** `GetProject` wraps `ErrProjectNotFound` (Task 9 asserts `ErrorIs` through `mcpProjectOptions`'s `%w`); `GetProjectDocument`/`GetProjectComment` wrap `sql.ErrNoRows` when absent; `UpdateTarget` writes `project_id` back unchanged (so `update_target` needs no change there). Phase 1 has **no** `SetTargetProgress`, so Task 7 adds it (item 9).
3. **`projectOf` moves from Task 7 to Task 6** (`internal/tools/project_scope.go`, same signature): the registry's `projectAlive` check needs it before any project tool exists. `targetInProject` stays in Task 7 (`projects.go`).
4. **New in Task 6, not in the index:** `tools.Tool.Scope func(ctx context.Context, d *db.DB, args json.RawMessage, b Binding) error` — `Validate` has no binding, so every "belongs to the bound project" check lives here; `Propose` runs it before writing a row and `Apply` re-runs it against the row's rebuilt binding. The project id is persisted in the existing `agent_actions.context_type='project'`/`context_id='<N>'` columns (`projectContextType`), so no migration is needed.
5. **DirectApply is narrower than the spec sentence:** besides refusing `External` tools it refuses any tool whose `Surfaces` does not explicitly contain the binding's surface (a surface-less write tool would otherwise inherit direct apply). No current write tool is surface-less; the rule is defensive.
6. **"Every tool returns `project N no longer exists`" is registry-level** (`Registry.projectAlive`, first check of `Propose`, `CallRead` and `Apply` when `Binding.ProjectID != 0`), so it covers the non-project read tools on the session too, not only project tools.
7. **The `internal/mcp` read handler passes the binding to `CallRead` in Task 6**, not Task 9 — the signature change would not compile otherwise. Task 9 adds only `get_action`'s project scoping (`actionVisible`).
8. **New file `internal/tools/project_targets.go`** (Task 7) holds `create_targets`/`update_target`, beside `projects.go`, to keep files and functions small. `ProjectTools() []*Tool` is new (Task 7, extended in Task 8) and is what `buildToolRegistry` registers.
9. **New `func (db *DB) SetTargetProgress(id int, progress float64) error`** (Task 7, `internal/db/targets.go`): `update_target`'s `progress` has no writer in Phase 1 or before (`UpdateTarget`/`UpdateTargetStatus` re-derive progress from status).
12. **`tools.ValidationError` gains `Err error` + `Unwrap()`** (Task 6, additive): the project refusals stay model-facing messages while `errors.Is(err, db.ErrNotInProject)` still holds (asserted in `TestDev06_WriteOutsideTheBoundProjectIsRefused`).
10. **`get_target` now refuses a project target outside its project's session** ("no target with id N") — the registry-read half of PROJ-01, beyond the spec's "limited to the project" on the project surface.
11. **AGENT-01 and AGENT-02 are amended too** (Task 9, `agent-actions.md`): DirectApply is an approval-free write path, so AGENT-01's "the model never writes" gains the DEV-06 exception, and AGENT-02's "without `--chat`" becomes "without `--chat` or `--project`". Owner-approved through spec D5; flagged here because the spec names only DEV-01/DEV-05.

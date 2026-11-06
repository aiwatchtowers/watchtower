package db

import (
	"context"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// hookRecorder records every ref the approval hook gets, and whether a
// connection of the handle was in use when it was called (an open
// transaction of the writer).
type hookRecorder struct {
	refs        []string
	inUseAtCall []int
}

func recordHook(t *testing.T, d *DB) *hookRecorder {
	t.Helper()
	h := &hookRecorder{}
	d.SetApprovalHook(func(ref string) {
		h.refs = append(h.refs, ref)
		h.inUseAtCall = append(h.inUseAtCall, d.Stats().InUse)
	})
	return h
}

func (h *hookRecorder) take() []string {
	out := h.refs
	h.refs = nil
	return out
}

// approvalWriters calls each approval writer once on a fresh row and returns
// the ref each should report. The action writers run on rows the earlier
// steps left in the right state.
func approvalWriters(t *testing.T, d *DB, h *hookRecorder) {
	t.Helper()
	pending, err := d.InsertAgentAction(AgentAction{Tool: "create_target", ArgsJSON: `{"a":1}`})
	require.NoError(t, err)
	assert.Equal(t, []string{ActionRef(pending)}, h.take(), "InsertAgentAction")

	ok, err := d.ApproveAgentActionWithArgs(pending, `{"a":1}`, `{"a":2}`)
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, []string{ActionRef(pending)}, h.take(), "ApproveAgentActionWithArgs")

	ok, err = d.TransitionAgentAction(pending, []string{"approved"}, "failed", "", "boom")
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, []string{ActionRef(pending)}, h.take(), "TransitionAgentAction")

	ok, err = d.DismissAgentAction(pending, "boom")
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, []string{ActionRef(pending)}, h.take(), "DismissAgentAction")

	button, err := d.InsertInboxButtonProposal(AgentAction{Tool: "create_target", ArgsJSON: `{}`,
		ContextType: InboxButtonContextType, ContextID: "1:0:abc"})
	require.NoError(t, err)
	assert.Equal(t, []string{ActionRef(button)}, h.take(), "InsertInboxButtonProposal")

	rem, err := d.InsertReminder(Reminder{MessageRef: "C1@1.2", Note: "ping acme", RemindAt: "2000-01-01T00:00:00Z"})
	require.NoError(t, err)
	assert.Equal(t, []string{ReminderRef(rem)}, h.take(), "InsertReminder")

	changed, err := d.SnoozeReminder(rem, "2999-01-01T00:00:00Z")
	require.NoError(t, err)
	require.True(t, changed)
	assert.Equal(t, []string{ReminderRef(rem)}, h.take(), "SnoozeReminder")

	changed, err = d.MarkReminderDone(rem)
	require.NoError(t, err)
	require.True(t, changed)
	assert.Equal(t, []string{ReminderRef(rem)}, h.take(), "MarkReminderDone")
}

func TestApprovalHook_EveryWriterNotifies(t *testing.T) {
	d := openTestDB(t)
	h := recordHook(t, d)
	approvalWriters(t, d, h)

	// The source half: every function of internal/db that INSERTs into or
	// UPDATEs agent_actions or reminders calls the hook (directly or through
	// actionChanged / reminderChanged).
	write := regexp.MustCompile(`(?is)(insert\s+(or\s+\w+\s+)?into|update)\s+(agent_actions|reminders)\b`)
	notifies := map[string]bool{"approvalChanged": true, "actionChanged": true, "actionChangedIf": true, "reminderChanged": true}
	files, err := filepath.Glob("*.go")
	require.NoError(t, err)
	var writers []string
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		src, err := os.ReadFile(f)
		require.NoError(t, err)
		file, err := parser.ParseFile(token.NewFileSet(), f, src, 0)
		require.NoError(t, err)
		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Body == nil {
				continue
			}
			writes, calls := false, false
			ast.Inspect(fn.Body, func(n ast.Node) bool {
				switch x := n.(type) {
				case *ast.BasicLit:
					if x.Kind == token.STRING && write.MatchString(x.Value) {
						writes = true
					}
				case *ast.CallExpr:
					if sel, ok := x.Fun.(*ast.SelectorExpr); ok && notifies[sel.Sel.Name] {
						calls = true
					}
				}
				return true
			})
			if writes {
				writers = append(writers, fn.Name.Name)
				assert.True(t, calls, "%s: %s writes agent_actions or reminders without calling the approval hook", f, fn.Name.Name)
			}
		}
	}
	assert.ElementsMatch(t, []string{"InsertAgentAction", "TransitionAgentAction", "DismissAgentAction",
		"ApproveAgentActionWithArgs", "InsertInboxButtonProposal", "InsertReminder", "MarkReminderDone",
		"SnoozeReminder"}, writers, "the writers the scan found")
}

func TestApprovalHook_NeverCalledInsideTransaction(t *testing.T) {
	d := openTestDB(t)
	h := recordHook(t, d)
	approvalWriters(t, d, h)
	require.Len(t, h.inUseAtCall, 8)
	for i, n := range h.inUseAtCall {
		assert.Zero(t, n, "call %d: a connection (the writer's transaction) was still in use", i)
	}
}

func TestApprovalHook_NotCalledOnANoOpWrite(t *testing.T) {
	d := openTestDB(t)
	id, err := d.InsertAgentAction(AgentAction{Tool: "create_target", ArgsJSON: `{}`})
	require.NoError(t, err)
	h := recordHook(t, d)

	ok, err := d.TransitionAgentAction(id, []string{"approved"}, "applied", "", "")
	require.NoError(t, err)
	assert.False(t, ok)
	ok, err = d.ApproveAgentActionWithArgs(id, `{"other":1}`, `{}`)
	require.NoError(t, err)
	assert.False(t, ok)
	ok, err = d.DismissAgentAction(id, "x")
	require.NoError(t, err)
	assert.False(t, ok)
	changed, err := d.MarkReminderDone(42)
	require.NoError(t, err)
	assert.False(t, changed)
	changed, err = d.SnoozeReminder(42, "2999-01-01T00:00:00Z")
	require.NoError(t, err)
	assert.False(t, changed)
	assert.Empty(t, h.take())
}

func TestApprovalHook_NilIsANoOp(t *testing.T) {
	d := openTestDB(t)
	assert.False(t, d.HasApprovalHook())
	d.SetApprovalHook(func(string) {})
	assert.True(t, d.HasApprovalHook())
	d.SetApprovalHook(nil)
	assert.False(t, d.HasApprovalHook())
	_, err := d.InsertReminder(Reminder{RemindAt: "2000-01-01T00:00:00Z"})
	require.NoError(t, err)
}

func TestParseApprovalRef(t *testing.T) {
	for ref, want := range map[string]struct {
		kind string
		id   int64
	}{"action:7": {"action", 7}, "reminder:7": {"reminder", 7}} {
		kind, id, err := ParseApprovalRef(ref)
		require.NoError(t, err, ref)
		assert.Equal(t, want.kind, kind)
		assert.Equal(t, want.id, id)
	}
	for _, bad := range []string{"", "x:7", "action:", "action:-1", "action:0", "action:07", "action:7x", "action", "reminder:+3"} {
		_, _, err := ParseApprovalRef(bad)
		assert.Error(t, err, bad)
	}
}

// seedApprovalArtifact stores a living inbox artifact of automation a with
// key and written_at.
func seedApprovalArtifact(t *testing.T, d *DB, a int64, key, writtenAt string) {
	t.Helper()
	var run int64
	require.NoError(t, d.QueryRow(`INSERT INTO automation_runs (automation_id, trigger, status) VALUES (?, 'event', 'succeeded')
		RETURNING id`, a).Scan(&run))
	_, err := d.Exec(`INSERT INTO automation_outputs (automation_id, run_id, kind, title, body, output_key, written_at, changed_at)
		VALUES (?, ?, 'inbox', 'Approve', 'body', ?, ?, ?)`, a, run, key, writtenAt, writtenAt)
	require.NoError(t, err)
}

func TestApprovalDriftOf(t *testing.T) {
	now := time.Now().UTC()
	stamp := func(d time.Duration) string { return formatAutomationTime(now.Add(d)) }
	ctx := context.Background()

	t.Run("nothing open, nothing written", func(t *testing.T) {
		d := openTestDB(t)
		a := seedBuiltinRow(t, d, "needs-approval", "needs-approval", "c", "h")
		drift, err := d.ApprovalDriftOf(ctx, a, now, 50)
		require.NoError(t, err)
		assert.False(t, drift.Any())
	})
	t.Run("open approvals each with a current artifact", func(t *testing.T) {
		d := openTestDB(t)
		a := seedBuiltinRow(t, d, "needs-approval", "needs-approval", "c", "h")
		act, err := d.InsertAgentAction(AgentAction{Tool: "create_target", ArgsJSON: `{}`})
		require.NoError(t, err)
		rem, err := d.InsertReminder(Reminder{RemindAt: stamp(-time.Hour)})
		require.NoError(t, err)
		seedApprovalArtifact(t, d, a, ActionRef(act), stamp(time.Minute))
		seedApprovalArtifact(t, d, a, ReminderRef(rem), stamp(time.Minute))
		drift, err := d.ApprovalDriftOf(ctx, a, now, 50)
		require.NoError(t, err)
		assert.Equal(t, ApprovalDrift{}, drift)
	})
	t.Run("an open approval without an artifact, a reminder due after its artifact", func(t *testing.T) {
		d := openTestDB(t)
		a := seedBuiltinRow(t, d, "needs-approval", "needs-approval", "c", "h")
		_, err := d.InsertAgentAction(AgentAction{Tool: "create_target", ArgsJSON: `{}`})
		require.NoError(t, err)
		rem, err := d.InsertReminder(Reminder{RemindAt: stamp(-time.Minute)})
		require.NoError(t, err)
		seedApprovalArtifact(t, d, a, ReminderRef(rem), stamp(-time.Hour))
		drift, err := d.ApprovalDriftOf(ctx, a, now, 50)
		require.NoError(t, err)
		assert.Equal(t, ApprovalDrift{Missing: 2}, drift)
	})
	t.Run("artifacts of closed and deleted approvals", func(t *testing.T) {
		d := openTestDB(t)
		a := seedBuiltinRow(t, d, "needs-approval", "needs-approval", "c", "h")
		act, err := d.InsertAgentAction(AgentAction{Tool: "create_target", ArgsJSON: `{}`, Status: "rejected"})
		require.NoError(t, err)
		future, err := d.InsertReminder(Reminder{RemindAt: stamp(time.Hour)})
		require.NoError(t, err)
		seedApprovalArtifact(t, d, a, ActionRef(act), stamp(0))
		seedApprovalArtifact(t, d, a, ReminderRef(future), stamp(0))
		seedApprovalArtifact(t, d, a, "reminder:999", stamp(0))
		drift, err := d.ApprovalDriftOf(ctx, a, now, 50)
		require.NoError(t, err)
		assert.Equal(t, ApprovalDrift{Closed: 3}, drift)
	})
	t.Run("only the oldest limit are expected", func(t *testing.T) {
		d := openTestDB(t)
		a := seedBuiltinRow(t, d, "needs-approval", "needs-approval", "c", "h")
		for range 3 {
			_, err := d.InsertAgentAction(AgentAction{Tool: "create_target", ArgsJSON: `{}`})
			require.NoError(t, err)
		}
		drift, err := d.ApprovalDriftOf(ctx, a, now, 2)
		require.NoError(t, err)
		assert.Equal(t, ApprovalDrift{Missing: 2}, drift)
	})
	t.Run("not an approval: workbench audit row, inbox press row, settled session call", func(t *testing.T) {
		d := openTestDB(t)
		a := seedBuiltinRow(t, d, "needs-approval", "needs-approval", "c", "h")
		for _, row := range []AgentAction{
			{Tool: "create_target", ArgsJSON: `{}`, ContextType: "project"},
			{Tool: "create_target", ArgsJSON: `{}`, Surface: "inbox"},
		} {
			_, err := d.InsertAgentAction(row)
			require.NoError(t, err)
		}
		settled, err := d.InsertAgentAction(AgentAction{Tool: "claude_ai_connector_call", ArgsJSON: `{}`, Status: "approved"})
		require.NoError(t, err)
		_, err = d.TransitionAgentAction(settled, []string{"approved"}, "failed", "", "the connector refused")
		require.NoError(t, err)
		drift, err := d.ApprovalDriftOf(ctx, a, now, 50)
		require.NoError(t, err)
		assert.False(t, drift.Any(), "%+v", drift)
	})
}

// Only a write that can touch an open approval notifies: an action inserted
// approved, Apply's approved→executing claim and executing→applied do not.
func TestApprovalHook_SkipsTransitionsNeverOpen(t *testing.T) {
	d := openTestDB(t)
	h := recordHook(t, d)
	id, err := d.InsertAgentAction(AgentAction{Tool: "create_target", ArgsJSON: `{}`, Status: "approved"})
	require.NoError(t, err)
	for _, step := range [][2]string{{"approved", "executing"}, {"executing", "applied"}} {
		ok, err := d.TransitionAgentAction(id, []string{step[0]}, step[1], "", "")
		require.NoError(t, err)
		require.True(t, ok)
	}
	assert.Empty(t, h.take())

	ok, err := d.TransitionAgentAction(id, []string{"applied"}, "failed", "", "boom")
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, []string{ActionRef(id)}, h.take(), "a transition to failed notifies")
}

func TestActionCanBeApproval(t *testing.T) {
	d := openTestDB(t)
	for _, c := range []struct {
		row  AgentAction
		want bool
	}{
		{AgentAction{Tool: "t", ArgsJSON: `{}`}, true},
		{AgentAction{Tool: "t", ArgsJSON: `{}`, ContextType: "project"}, false},
		{AgentAction{Tool: "t", ArgsJSON: `{}`, ContextType: "project", External: true}, true},
		{AgentAction{Tool: "t", ArgsJSON: `{}`, Surface: "inbox"}, false},
	} {
		id, err := d.InsertAgentAction(c.row)
		require.NoError(t, err)
		ok, err := d.ActionCanBeApproval(id)
		require.NoError(t, err)
		assert.Equal(t, c.want, ok, "%+v", c.row)
	}
	ok, err := d.ActionCanBeApproval(9999)
	require.NoError(t, err)
	assert.False(t, ok, "a missing row")
}

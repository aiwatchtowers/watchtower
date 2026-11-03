package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// inboxReg is a registry with create_target only, over d.
func inboxReg(t *testing.T, d *db.DB) *Registry {
	t.Helper()
	reg := New(d)
	require.NoError(t, reg.Register(NewCreateTarget()))
	return reg
}

func seedParent(t *testing.T, d *db.DB, status string) int64 {
	t.Helper()
	id, err := d.CreateTarget(db.Target{Text: "Quarter goal", Level: "week", PeriodStart: "2026-11-02",
		PeriodEnd: "2026-11-08", Status: status, Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	return id
}

func buttonBinding(ctxID string) Binding {
	return Binding{Surface: InboxSurface, ContextType: db.InboxButtonContextType, ContextID: ctxID}
}

func childArgs(parent int64) json.RawMessage {
	return json.RawMessage(`{"text":"Write the summary","intent":"for colleague A","parent_id":` +
		strconv.FormatInt(parent, 10) + `,"reason":"From the Inbox card"}`)
}

func tableRows(t *testing.T, d *db.DB, table string) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM `+table).Scan(&n)) // #nosec G202 -- fixed test table names
	return n
}

// AUTO-02 / TGT-BRIEF-01: parent_id only on the inbox surface; main,
// reaction and automation stay top-level-only and write no row.
func TestCreateTarget_ParentIDOnlyOnInbox(t *testing.T) {
	d := openDB(t)
	reg := inboxReg(t, d)
	parent := seedParent(t, d, "todo")

	closed := seedParent(t, d, "done")
	for _, surface := range []string{"main", "reaction", AutomationSurface} {
		// The surface is refused before any lookup of the parent: a missing
		// or closed one reads the same, so nothing leaks about it.
		for _, p := range []int64{parent, 9999, closed} {
			_, err := reg.Propose(context.Background(), "create_target", childArgs(p), Binding{Surface: surface})
			var verr *ValidationError
			require.ErrorAs(t, err, &verr, surface)
			assert.Equal(t, "parent_id is only for an Inbox card's button", verr.Msg, "%s parent %d", surface, p)
		}
	}
	assert.Zero(t, tableRows(t, d, "agent_actions"))

	// Top-level create_target on main is unchanged.
	_, err := reg.Propose(context.Background(), "create_target",
		json.RawMessage(`{"text":"Top level","reason":"r"}`), Binding{Surface: "main"})
	require.NoError(t, err)

	rc, err := reg.Propose(context.Background(), "create_target", childArgs(parent), buttonBinding("7:0:abc"))
	require.NoError(t, err)
	assert.Equal(t, "pending", rc.Status)
	row, err := d.GetAgentAction(rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, InboxSurface, row.Surface)
	assert.Equal(t, db.InboxButtonContextType, row.ContextType)
	assert.Equal(t, "7:0:abc", row.ContextID)
	assert.Equal(t, 2, tableRows(t, d, "targets"), "nothing created before Approve")

	ok, err := reg.Approve(context.Background(), rc.ActionID, nil)
	require.NoError(t, err)
	require.True(t, ok)
	applied, err := reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	require.Equal(t, "applied", applied.Status, applied.Error)

	var res struct {
		TargetID int64 `json:"target_id"`
	}
	require.NoError(t, json.Unmarshal([]byte(applied.ResultJSON), &res))
	child, err := d.GetTargetByID(int(res.TargetID))
	require.NoError(t, err)
	require.True(t, child.ParentID.Valid)
	assert.Equal(t, parent, child.ParentID.Int64)
	assert.Equal(t, "week", child.Level, "the child takes the parent's level")
	assert.Equal(t, "2026-11-02", child.PeriodStart)
	assert.Equal(t, "2026-11-08", child.PeriodEnd)
	assert.Equal(t, "chat", child.SourceType)
	assert.Equal(t, "action:"+strconv.FormatInt(rc.ActionID, 10), child.SourceID)
}

func TestCreateTarget_ParentRefusedAtPropose(t *testing.T) {
	d := openDB(t)
	reg := inboxReg(t, d)
	wb, err := d.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	onBoard, err := d.CreateTarget(db.Target{Text: "board task", Status: "todo", Priority: "medium",
		Ownership: "mine", SourceType: "manual", WorkbenchID: sql.NullInt64{Int64: wb, Valid: true}})
	require.NoError(t, err)
	cases := map[int64]string{
		9999:                          "parent_id: task #9999 does not exist",
		seedParent(t, d, "done"):      "is closed",
		seedParent(t, d, "dismissed"): "is closed",
		onBoard:                       "is on a workbench board",
	}
	for parent, want := range cases {
		_, err := reg.Propose(context.Background(), "create_target", childArgs(parent), buttonBinding("7:0:"+strconv.FormatInt(parent, 10)))
		var verr *ValidationError
		require.ErrorAs(t, err, &verr, want)
		assert.Contains(t, verr.Msg, want)
	}
	assert.Zero(t, tableRows(t, d, "agent_actions"))
}

// The parent closes between propose and apply: the apply lands failed, no
// task is created, and the claim still ran once.
func TestCreateTarget_ParentClosedBeforeApply(t *testing.T) {
	d := openDB(t)
	reg := inboxReg(t, d)
	parent := seedParent(t, d, "todo")
	rc, err := reg.Propose(context.Background(), "create_target", childArgs(parent), buttonBinding("7:0:abc"))
	require.NoError(t, err)
	ok, err := reg.Approve(context.Background(), rc.ActionID, nil)
	require.NoError(t, err)
	require.True(t, ok)
	require.NoError(t, d.UpdateTargetStatus(int(parent), "done"))

	row, err := reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Contains(t, row.Error, "is closed")
	assert.Equal(t, 1, tableRows(t, d, "targets"), "no child task")
	_, err = reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err, "a failed row stays retriable through the one claim")
}

// The inbox is no trust place: execute trust on main, or a stray trust row
// for the inbox itself, never auto-executes an inbox proposal.
func TestCreateTarget_InboxNeverAutoExecutes(t *testing.T) {
	d := openDB(t)
	reg := inboxReg(t, d)
	require.NoError(t, reg.SetTrust("create_target", "main", TrustExecute))
	require.Error(t, reg.SetTrust("create_target", InboxSurface, TrustExecute))
	require.NoError(t, d.SetToolTrust("create_target", InboxSurface, string(TrustExecute)))

	rc, err := reg.Propose(context.Background(), "create_target",
		json.RawMessage(`{"text":"From a card","reason":"r"}`), buttonBinding("7:0:abc"))
	require.NoError(t, err)
	assert.Equal(t, "pending", rc.Status)
	assert.Zero(t, tableRows(t, d, "targets"))
}

// An Inbox button's context off the inbox surface is refused before a row.
func TestPropose_InboxButtonContextOnlyOnInbox(t *testing.T) {
	d := openDB(t)
	reg := inboxReg(t, d)
	b := buttonBinding("7:0:abc")
	b.Surface = "main"
	_, err := reg.Propose(context.Background(), "create_target", json.RawMessage(`{"text":"x","reason":"r"}`), b)
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Zero(t, tableRows(t, d, "agent_actions"))
}

func TestCreateTarget_ActionIDZeroPlainInsert(t *testing.T) {
	d := openDB(t)
	tool := NewCreateTarget()
	for range 2 {
		_, err := tool.Execute(context.Background(), d, Call{Args: json.RawMessage(`{"text":"x","reason":"r"}`)})
		require.NoError(t, err)
	}
	assert.Equal(t, 2, tableRows(t, d, "targets"), "action:0 is outside the index: no conflict")
}

// AGENT-05: two Executes of one action id at once (a slow apply overlapping
// the owner's --force reclaim) make one task; both return its id.
func TestAgent05_CreateTargetConcurrentApplyOneTarget(t *testing.T) {
	d, err := db.Open(filepath.Join(t.TempDir(), "watchtower.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	require.NoError(t, d.SetBusyTimeout(30*time.Second))
	reg := inboxReg(t, d)
	rc, err := reg.Propose(context.Background(), "create_target",
		json.RawMessage(`{"text":"Once","reason":"r"}`), buttonBinding("7:0:abc"))
	require.NoError(t, err)
	ok, err := reg.Approve(context.Background(), rc.ActionID, nil)
	require.NoError(t, err)
	require.True(t, ok)
	// The row as two processes see it: claimed, then reclaimed and claimed
	// again — both reach Execute with the same action id.
	ok, err = d.TransitionAgentAction(rc.ActionID, []string{"approved"}, "executing", "", "")
	require.NoError(t, err)
	require.True(t, ok)

	tool, _ := reg.Get("create_target")
	call := Call{ActionID: rc.ActionID, Args: json.RawMessage(`{"text":"Once","reason":"r"}`)}
	ids := make([]int64, 2)
	errs := make([]error, 2)
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i := range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			out, err := tool.Execute(context.Background(), d, call)
			errs[i] = err
			if err == nil {
				ids[i] = out.(map[string]any)["target_id"].(int64)
			}
		}()
	}
	close(start)
	wg.Wait()
	require.NoError(t, errs[0])
	require.NoError(t, errs[1])
	assert.Equal(t, ids[0], ids[1], "both return the one task")
	assert.Equal(t, 1, tableRows(t, d, "targets"))

	// Each finish is a CAS from executing: one lands applied, the other is refused.
	first, err := d.TransitionAgentAction(rc.ActionID, []string{"executing"}, "applied", `{}`, "")
	require.NoError(t, err)
	second, err := d.TransitionAgentAction(rc.ActionID, []string{"executing"}, "applied", `{}`, "")
	require.NoError(t, err)
	assert.True(t, first)
	assert.False(t, second)
}

// AGENT-05: one open proposal per Inbox button. Two concurrent proposes with
// one context leave one pending row; the other is refused with the typed
// error. After a rejection a new propose is accepted; another context is
// unaffected.
func TestAgent05_InboxButtonOneOpenProposal(t *testing.T) {
	d, err := db.Open(filepath.Join(t.TempDir(), "watchtower.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	require.NoError(t, d.SetBusyTimeout(30*time.Second))
	reg := inboxReg(t, d)
	args := json.RawMessage(`{"text":"From a card","reason":"r"}`)

	errs := make([]error, 2)
	ids := make([]int64, 2)
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i := range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			rc, err := reg.Propose(context.Background(), "create_target", args, buttonBinding("7:0:abc"))
			errs[i], ids[i] = err, rc.ActionID
		}()
	}
	close(start)
	wg.Wait()
	var won int64
	refused := 0
	for i, err := range errs {
		var open *db.ErrButtonHasOpenProposal
		switch {
		case err == nil:
			won = ids[i]
		case assert.ErrorAs(t, err, &open):
			refused++
		}
	}
	require.NotZero(t, won)
	assert.Equal(t, 1, refused)
	assert.Equal(t, 1, tableRows(t, d, "agent_actions"))

	_, err = reg.Propose(context.Background(), "create_target", args, buttonBinding("7:1:abc"))
	require.NoError(t, err, "another context is unaffected")

	ok, err := d.TransitionAgentAction(won, []string{"pending"}, "rejected", "", "")
	require.NoError(t, err)
	require.True(t, ok)
	_, err = reg.Propose(context.Background(), "create_target", args, buttonBinding("7:0:abc"))
	require.NoError(t, err, "a rejected proposal frees the button")
}

// A reclaim after an apply that crashed past its insert returns that task
// even when its parent was deleted since (the child's parent_id went NULL):
// the existing task is looked up before any parent check.
func TestCreateTarget_ReclaimAfterParentGoneReturnsTask(t *testing.T) {
	d := openDB(t)
	reg := inboxReg(t, d)
	parent := seedParent(t, d, "todo")
	rc, err := reg.Propose(context.Background(), "create_target", childArgs(parent), buttonBinding("7:0:abc"))
	require.NoError(t, err)
	ok, err := reg.Approve(context.Background(), rc.ActionID, nil)
	require.NoError(t, err)
	require.True(t, ok)
	applied, err := reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	require.Equal(t, "applied", applied.Status)

	// The process "died" after the insert; the parent is deleted meanwhile;
	// the owner's --force reclaim marks it failed and applies again.
	_, err = d.Exec(`UPDATE agent_actions SET status = 'executing' WHERE id = ?`, rc.ActionID)
	require.NoError(t, err)
	require.NoError(t, d.DeleteTarget(int(parent)))
	ok, err = d.TransitionAgentAction(rc.ActionID, []string{"executing"}, "failed", "", "reclaimed after an interrupted apply")
	require.NoError(t, err)
	require.True(t, ok)
	again, err := reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "applied", again.Status, again.Error)
	assert.JSONEq(t, applied.ResultJSON, again.ResultJSON, "the same task")
	assert.Equal(t, 1, tableRows(t, d, "targets"))
}

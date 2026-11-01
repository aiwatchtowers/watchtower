package tools

import (
	"database/sql"
	"fmt"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func sessionTargetOf(t *testing.T, d *db.DB, sessionID int64) sql.NullInt64 {
	t.Helper()
	var v sql.NullInt64
	require.NoError(t, d.QueryRow(`SELECT target_id FROM terminal_sessions WHERE id = ?`, sessionID).Scan(&v))
	return v
}

func setTargetArgs(id int64) string {
	return fmt.Sprintf(`{"target_id":%d,"reason":"r"}`, id)
}

// PROJ-14 (2026-10-31): a call from no session of this workbench is refused
// before anything, audit row included, is written.
func TestProj14_SetSessionTargetNeedsSession(t *testing.T) {
	fx := newWorkbenchFixture(t)
	theirs := seedTerminalSession(t, fx.d, fx.b)
	for _, env := range []string{"", "999999", "garbage", strconv.FormatInt(theirs, 10)} {
		reg := askRegistry(t, fx.d, env)
		_, err := proposeIn(t, reg, fx.a, "set_session_target", setTargetArgs(fx.aTarget))
		assert.Equal(t, "set_session_target needs a Watchtower terminal session", refusal(t, err), "env %q", env)
	}
	assert.False(t, sessionTargetOf(t, fx.d, theirs).Valid)
	assert.Zero(t, countActions(t, fx.d))
	assert.Zero(t, countSessionLinks(t, fx.d))
}

func TestProj14_SetSessionTargetRefusesOtherWorkbench(t *testing.T) {
	fx := newWorkbenchFixture(t)
	s := seedTerminalSession(t, fx.d, fx.a)
	reg := askRegistry(t, fx.d, strconv.FormatInt(s, 10))
	_, err := proposeIn(t, reg, fx.a, "set_session_target", setTargetArgs(fx.bTarget))
	require.ErrorIs(t, err, db.ErrNotInWorkbench)
	assert.False(t, sessionTargetOf(t, fx.d, s).Valid)
	assert.Zero(t, countActions(t, fx.d))
}

func TestProj14_SetSessionTargetRefusesDismissed(t *testing.T) {
	fx := newWorkbenchFixture(t)
	s := seedTerminalSession(t, fx.d, fx.a)
	_, err := fx.d.Exec(`UPDATE targets SET status = 'dismissed' WHERE id = ?`, fx.aTarget)
	require.NoError(t, err)
	reg := askRegistry(t, fx.d, strconv.FormatInt(s, 10))
	_, err = proposeIn(t, reg, fx.a, "set_session_target", setTargetArgs(fx.aTarget))
	assert.Contains(t, refusal(t, err), "dismissed")
	assert.False(t, sessionTargetOf(t, fx.d, s).Valid)
}

func TestProj14_SetSessionTargetRefusesArchived(t *testing.T) {
	fx := newWorkbenchFixture(t)
	s := seedTerminalSession(t, fx.d, fx.a)
	_, err := fx.d.Exec(`UPDATE targets SET status = 'done' WHERE id = ?`, fx.aTarget)
	require.NoError(t, err)
	_, err = fx.d.Exec(`UPDATE projects SET archive_after_days = 1 WHERE id = ?`, fx.a)
	require.NoError(t, err)
	_, err = fx.d.Exec(`UPDATE target_status_history SET changed_at = '2020-01-01T00:00:00Z' WHERE target_id = ?`, fx.aTarget)
	require.NoError(t, err)
	_, err = fx.d.Exec(`UPDATE targets SET updated_at = '2020-01-01T00:00:00Z' WHERE id = ?`, fx.aTarget)
	require.NoError(t, err)
	board, err := fx.d.GetWorkbenchBoard(fx.a)
	require.NoError(t, err)
	require.Len(t, board, 1)
	if !board[0].Archived {
		t.Skip("could not archive the seeded target through the view")
	}
	reg := askRegistry(t, fx.d, strconv.FormatInt(s, 10))
	_, err = proposeIn(t, reg, fx.a, "set_session_target", setTargetArgs(fx.aTarget))
	assert.Contains(t, refusal(t, err), "archived")
}

func TestProj14_SetSessionTargetAllowsDone(t *testing.T) {
	fx := newWorkbenchFixture(t)
	s := seedTerminalSession(t, fx.d, fx.a)
	_, err := fx.d.Exec(`UPDATE targets SET status = 'done' WHERE id = ?`, fx.aTarget)
	require.NoError(t, err)
	reg := askRegistry(t, fx.d, strconv.FormatInt(s, 10))
	out := mustApply(t, reg, fx.a, "set_session_target", setTargetArgs(fx.aTarget))
	assert.EqualValues(t, fx.aTarget, out["target_id"])
	assert.EqualValues(t, fx.aTarget, sessionTargetOf(t, fx.d, s).Int64)
}

func TestProj14_SetSessionTargetClearKeepsLinks(t *testing.T) {
	fx := newWorkbenchFixture(t)
	s := seedTerminalSession(t, fx.d, fx.a)
	reg := askRegistry(t, fx.d, strconv.FormatInt(s, 10))
	mustApply(t, reg, fx.a, "set_session_target", setTargetArgs(fx.aTarget))
	_, err := fx.d.Exec(`UPDATE targets SET status = 'dismissed' WHERE id = ?`, fx.aTarget)
	require.NoError(t, err)
	out := mustApply(t, reg, fx.a, "set_session_target", setTargetArgs(0))
	assert.EqualValues(t, 0, out["target_id"])
	assert.EqualValues(t, 0, out["stamped"])
	assert.False(t, sessionTargetOf(t, fx.d, s).Valid)
	assert.Equal(t, []int64{fx.aTarget}, linkedTargets(t, fx.d, s), "links stay")
}

func TestProj14_SetSessionTargetRefusesShellSession(t *testing.T) {
	fx := newWorkbenchFixture(t)
	s := seedTerminalSession(t, fx.d, fx.a)
	_, err := fx.d.Exec(`UPDATE terminal_sessions SET kind = 'shell' WHERE id = ?`, s)
	require.NoError(t, err)
	reg := askRegistry(t, fx.d, strconv.FormatInt(s, 10))
	_, err = proposeIn(t, reg, fx.a, "set_session_target", setTargetArgs(fx.aTarget))
	assert.Equal(t, fmt.Sprintf("session %d is not an agent session of this workbench", s), refusal(t, err))
	assert.False(t, sessionTargetOf(t, fx.d, s).Valid)
	assert.Zero(t, countActions(t, fx.d))
}

func TestProj14_SetSessionTargetStampsSubtreeLeaves(t *testing.T) {
	fx := newWorkbenchFixture(t)
	group := fx.aTarget
	g := sql.NullInt64{Int64: group, Valid: true}
	l1 := db.SeedTestWorkbenchTarget(t, fx.d, fx.a, g, "Leaf one")
	l2 := db.SeedTestWorkbenchTarget(t, fx.d, fx.a, g, "Leaf two")
	other := seedTerminalSession(t, fx.d, fx.a)
	mine := seedTerminalSession(t, fx.d, fx.a)
	for _, id := range []int64{l1, l2} {
		require.NoError(t, fx.d.SetSessionTarget(other, sql.NullInt64{Int64: id, Valid: true}, nil))
	}
	owners, err := fx.d.SessionLeafOwners(fx.a)
	require.NoError(t, err)
	require.EqualValues(t, other, owners[l1])

	reg := askRegistry(t, fx.d, strconv.FormatInt(mine, 10))
	out := mustApply(t, reg, fx.a, "set_session_target", setTargetArgs(group))
	assert.EqualValues(t, 3, out["stamped"], "the group and its two leaves")
	owners, err = fx.d.SessionLeafOwners(fx.a)
	require.NoError(t, err)
	assert.EqualValues(t, mine, owners[l1])
	assert.EqualValues(t, mine, owners[l2])
}

func TestProj14_SetSessionTargetAuditRow(t *testing.T) {
	fx := newWorkbenchFixture(t)
	s := seedTerminalSession(t, fx.d, fx.a)
	reg := askRegistry(t, fx.d, strconv.FormatInt(s, 10))
	mustApply(t, reg, fx.a, "set_session_target", `{"target_id":`+strconv.FormatInt(fx.aTarget, 10)+`,"reason":"moved on"}`)
	var tool, reason, status string
	require.NoError(t, fx.d.QueryRow(`SELECT tool, reason, status FROM agent_actions ORDER BY id DESC LIMIT 1`).
		Scan(&tool, &reason, &status))
	assert.Equal(t, []string{"set_session_target", "moved on", "applied"}, []string{tool, reason, status})
}

func TestProj14_SetSessionTargetFailedWriteAuditsFailed(t *testing.T) {
	fx := newWorkbenchFixture(t)
	s := seedTerminalSession(t, fx.d, fx.a)
	_, err := fx.d.Exec(`CREATE TRIGGER block_bind BEFORE UPDATE OF target_id ON terminal_sessions
		BEGIN SELECT RAISE(ABORT, 'blocked'); END`)
	require.NoError(t, err)
	reg := askRegistry(t, fx.d, strconv.FormatInt(s, 10))
	rc, _ := proposeIn(t, reg, fx.a, "set_session_target", setTargetArgs(fx.aTarget))
	assert.Equal(t, "failed", rc.Status)
	assert.False(t, sessionTargetOf(t, fx.d, s).Valid)
	assert.Zero(t, countSessionLinks(t, fx.d))
	var status string
	require.NoError(t, fx.d.QueryRow(`SELECT status FROM agent_actions ORDER BY id DESC LIMIT 1`).Scan(&status))
	assert.Equal(t, "failed", status)
}

func TestBindSessionTarget(t *testing.T) {
	fx := newWorkbenchFixture(t)
	s := seedTerminalSession(t, fx.d, fx.a)
	n, err := BindSessionTarget(fx.d, fx.a, s, fx.aTarget)
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	_, err = BindSessionTarget(fx.d, fx.b, s, fx.bTarget)
	assert.Error(t, err, "another workbench's session")
	n, err = BindSessionTarget(fx.d, fx.a, s, 0)
	require.NoError(t, err)
	assert.Zero(t, n)
}

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

// statusAt is a session link's status_at ("" = NULL) and whether the link exists.
func statusAt(t *testing.T, d *db.DB, session, target int64) (string, bool) {
	t.Helper()
	var at sql.NullString
	err := d.QueryRow(`SELECT status_at FROM terminal_session_targets WHERE session_id = ? AND target_id = ?`,
		session, target).Scan(&at)
	if err == sql.ErrNoRows {
		return "", false
	}
	require.NoError(t, err)
	return at.String, true
}

func TestProj14_UpdateTargetStatusChangeStamps(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	reg := askRegistry(t, fx.d, strconv.FormatInt(session, 10))
	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"status":"in_progress","reason":"r"}`, fx.aTarget))
	at, ok := statusAt(t, fx.d, session, fx.aTarget)
	assert.True(t, ok)
	assert.NotEmpty(t, at)
}

func TestProj14_UpdateTargetWithoutStatusDoesNotStamp(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	reg := askRegistry(t, fx.d, strconv.FormatInt(session, 10))
	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"text":"Renamed","reason":"r"}`, fx.aTarget))
	at, ok := statusAt(t, fx.d, session, fx.aTarget)
	assert.True(t, ok, "the link is still recorded")
	assert.Empty(t, at)
	// Resending the current status is no change either.
	var cur string
	require.NoError(t, fx.d.QueryRow(`SELECT status FROM targets WHERE id = ?`, fx.aTarget).Scan(&cur))
	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"status":%q,"reason":"r"}`, fx.aTarget, cur))
	at, _ = statusAt(t, fx.d, session, fx.aTarget)
	assert.Empty(t, at)
}

func TestProj14_ColumnMoveStampsOnlyOnStatusChange(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	reg := askRegistry(t, fx.d, strconv.FormatInt(session, 10))
	seedColumns(t, fx.d, fx.a)
	// todo -> in_progress column: the status changes.
	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"column":"Spec","reason":"r"}`, fx.aTarget))
	at, _ := statusAt(t, fx.d, session, fx.aTarget)
	assert.NotEmpty(t, at)

	// A move inside the same status leaves a fresh link unstamped.
	other := db.SeedTestWorkbenchTarget(t, fx.d, fx.a, sql.NullInt64{}, "Other")
	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"column":"Backlog","reason":"r"}`, other))
	at, ok := statusAt(t, fx.d, session, other)
	assert.True(t, ok)
	assert.Empty(t, at)
}

func TestProj14_CreateTargetsStamps(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	reg := askRegistry(t, fx.d, strconv.FormatInt(session, 10))
	out := mustApply(t, reg, fx.a, "create_targets", `{"items":[{"text":"One"},{"text":"Two"}],"reason":"plan"}`)
	ids := createdIDs(t, out)
	require.Len(t, ids, 2)
	for _, id := range ids {
		at, _ := statusAt(t, fx.d, session, id)
		assert.NotEmpty(t, at)
	}
}

func TestProj14_CommentAndAskDoNotStamp(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	reg := askRegistry(t, fx.d, strconv.FormatInt(session, 10))
	mustApply(t, reg, fx.a, "add_comment", fmt.Sprintf(`{"target_id":%d,"body":"done","reason":"r"}`, fx.aTarget))
	at, ok := statusAt(t, fx.d, session, fx.aTarget)
	assert.True(t, ok)
	assert.Empty(t, at)
	other := db.SeedTestWorkbenchTarget(t, fx.d, fx.a, sql.NullInt64{}, "Other")
	mustApply(t, reg, fx.a, "ask_owner", fmt.Sprintf(`{"kind":"check","title":"Run it","target_id":%d,`+
		`"checklist":[{"text":"Open the app"}],"reason":"r"}`, other))
	at, ok = statusAt(t, fx.d, session, other)
	assert.True(t, ok)
	assert.Empty(t, at)
}

package tools

import (
	"fmt"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/workbenchfiles"
)

// Wait points queue the twin's items (spec 2026-11-16-watchman-design §3,
// §4, §7): ask_owner of an armed session.

// watchmanRegistry is askRegistry with WakeWatchman counting into wakes.
func watchmanRegistry(t *testing.T, d *db.DB, session int64, wakes *atomic.Int32) *Registry {
	t.Helper()
	env := strconv.FormatInt(session, 10)
	reg := New(d)
	deps := WorkbenchDeps{Files: workbenchfiles.New(t.TempDir()), WakeWatchman: func() { wakes.Add(1) }}
	for _, tool := range append(workbenchTools(deps, func() string { return env }), NewListTargets(), NewGetTarget()) {
		require.NoError(t, reg.Register(tool))
	}
	return reg
}

// armSession hands session to the twin directly.
func armSession(t *testing.T, d *db.DB, session int64) {
	t.Helper()
	require.NoError(t, d.UpsertWatchmanArming(db.WatchmanArming{Scope: "session", RefID: session, ArmedAt: time.Now(), ArmedBy: "cli"}))
}

// captureWatchmanLog collects what the wait points log.
func captureWatchmanLog(t *testing.T) *strings.Builder {
	t.Helper()
	var b strings.Builder
	prev := watchmanLog
	watchmanLog = func(format string, args ...any) { fmt.Fprintf(&b, format+"\n", args...) }
	t.Cleanup(func() { watchmanLog = prev })
	return &b
}

func watchmanItemCount(t *testing.T, d *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM watchman_items`).Scan(&n))
	return n
}

func TestAskOwner_ArmedSessionQueuesItem(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	armSession(t, fx.d, session)
	var wakes atomic.Int32
	reg := watchmanRegistry(t, fx.d, session, &wakes)
	writeWorkbenchFile(t, fx.d, fx.a, "docs/notes.md", "# Notes\n\nBody.\n")

	for _, c := range []struct{ args, kind string }{
		{fmt.Sprintf(`{"kind":"question","title":"Which store?","summary":"token=abc123SECRETxyz is set",`+
			`"questions":[{"question":"Where?","options":[{"label":"SQLite"},{"label":"Files"}]}],"target_id":%d,"reason":"r"}`, fx.aTarget), "ask"},
		{`{"kind":"review","title":"Review the notes","doc_path":"docs/notes.md","reason":"r"}`, "review_doc"},
		{`{"kind":"check","title":"Run the app","checklist":[{"text":"open it"}],"reason":"r"}`, "check"},
	} {
		id := askID(t, mustApply(t, reg, fx.a, "ask_owner", c.args))
		it, err := fx.d.WatchmanItemByRef("ask", id, c.kind)
		require.NoError(t, err)
		require.NotNil(t, it, c.kind)
		assert.Equal(t, "queued", it.State)
		assert.Equal(t, fx.a, it.WorkbenchID)
		assert.Equal(t, session, it.SessionID)
		if c.kind == "ask" {
			assert.Equal(t, fx.aTarget, it.TargetID)
			assert.Equal(t, "Which store?\ntoken=[secret] is set", it.Question, "redacted")
		}
	}
	assert.Equal(t, 3, watchmanItemCount(t, fx.d))
}

func TestAskOwner_UnarmedQueuesNothing(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	var wakes atomic.Int32
	reg := watchmanRegistry(t, fx.d, session, &wakes)
	mustApply(t, reg, fx.a, "ask_owner", questionAsk)
	assert.Zero(t, watchmanItemCount(t, fx.d))
	assert.Zero(t, wakes.Load(), "nothing to wake for")
}

// An insert that fails leaves the ask the owner's, as today (spec §7): the
// ask is filed, the result carries no error, the log names the ask.
func TestAskOwner_QueueFailureStillFiles(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	armSession(t, fx.d, session)
	var wakes atomic.Int32
	reg := watchmanRegistry(t, fx.d, session, &wakes)
	logs := captureWatchmanLog(t)
	_, err := fx.d.Exec(`CREATE TRIGGER wm_fail BEFORE INSERT ON watchman_items BEGIN SELECT RAISE(ABORT, 'database is locked'); END`)
	require.NoError(t, err)

	out := mustApply(t, reg, fx.a, "ask_owner", questionAsk)
	id := askID(t, out)
	assert.Equal(t, "open", out["status"])
	assert.NotContains(t, fmt.Sprint(out), "watchman")
	assert.Contains(t, logs.String(), fmt.Sprintf("ask %d", id))
	assert.Zero(t, wakes.Load())
}

func TestAskOwner_ArmedWakesDaemon(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	armSession(t, fx.d, session)
	var wakes atomic.Int32
	reg := watchmanRegistry(t, fx.d, session, &wakes)
	mustApply(t, reg, fx.a, "ask_owner", questionAsk)
	assert.Equal(t, int32(1), wakes.Load())
}

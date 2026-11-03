package db

import (
	"database/sql"
	"errors"
	"regexp"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// squashSpace collapses runs of whitespace, so a stored index definition
// compares with its clause whatever the line breaks.
func squashSpace(s string) string {
	return strings.TrimSpace(regexp.MustCompile(`\s+`).ReplaceAllString(s, " "))
}

// AGENT-05: both partial unique indexes exist on a migrated database, are
// UNIQUE, and keep exactly their WHERE clauses. A later rebuild of targets or
// agent_actions that drops either, or changes its clause, fails here.
func TestAgent05_ButtonIndexesPresent(t *testing.T) {
	d := openTestDB(t)
	want := map[string]struct{ table, where string }{
		"idx_targets_action_source": {"targets",
			"WHERE source_type = 'chat' AND source_id LIKE 'action:%' AND source_id != 'action:0'"},
		"idx_agent_actions_open_context": {"agent_actions",
			"WHERE context_type = 'automation_output' AND status IN ('pending','approved','executing')"},
	}
	for name, w := range want {
		var table, stmt string
		err := d.QueryRow(`SELECT tbl_name, sql FROM sqlite_master WHERE type = 'index' AND name = ?`, name).
			Scan(&table, &stmt)
		require.NoError(t, err, "%s missing", name)
		assert.Equal(t, w.table, table, name)
		stmt = squashSpace(stmt)
		assert.True(t, strings.HasPrefix(stmt, "CREATE UNIQUE INDEX"), "%s is not UNIQUE: %s", name, stmt)
		assert.True(t, strings.HasSuffix(stmt, w.where), "%s WHERE clause changed: %s", name, stmt)
	}
}

func TestMigration_TargetsActionSourceDuplicatesRenamed(t *testing.T) {
	raw, err := sql.Open("sqlite3", ":memory:")
	require.NoError(t, err)
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	require.NoError(t, gooseUpTo(raw, "migrations", 173))
	for _, src := range []string{"action:7", "action:7", "action:7", "action:8", "action:0", "action:0", "target:3", "target:3"} {
		_, err := raw.Exec(`INSERT INTO targets (text, period_start, period_end, source_type, source_id)
			VALUES ('t', '2026-11-03', '2026-11-03', 'chat', ?)`, src)
		require.NoError(t, err)
	}
	require.NoError(t, gooseUpTo(raw, "migrations", 174))

	rows, err := raw.Query(`SELECT id, source_id FROM targets ORDER BY id`)
	require.NoError(t, err)
	defer rows.Close()
	var got []string
	for rows.Next() {
		var id int64
		var src string
		require.NoError(t, rows.Scan(&id, &src))
		got = append(got, src)
	}
	require.NoError(t, rows.Err())
	assert.Equal(t, []string{"action:7", "action:7:dup2", "action:7:dup3", "action:8", "action:0", "action:0",
		"target:3", "target:3"}, got, "every duplicate but the oldest renamed, none deleted, action:0 and other spaces untouched")
	var n int
	require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type = 'index'
		AND name IN ('idx_targets_action_source', 'idx_agent_actions_open_context')`).Scan(&n))
	assert.Equal(t, 2, n)

	// A clean database migrates unchanged.
	clean, err := sql.Open("sqlite3", ":memory:")
	require.NoError(t, err)
	defer clean.Close()
	clean.SetMaxOpenConns(1)
	require.NoError(t, gooseUpTo(clean, "migrations", 173))
	_, err = clean.Exec(`INSERT INTO targets (text, period_start, period_end, source_type, source_id)
		VALUES ('t', '2026-11-03', '2026-11-03', 'chat', 'action:9')`)
	require.NoError(t, err)
	require.NoError(t, gooseUpTo(clean, "migrations", 174))
	var src string
	require.NoError(t, clean.QueryRow(`SELECT source_id FROM targets`).Scan(&src))
	assert.Equal(t, "action:9", src)
}

func buttonRow(ctxID string) AgentAction {
	return AgentAction{Tool: "create_target", ArgsJSON: `{"text":"x","reason":"r"}`, Reason: "r",
		Surface: "inbox", ContextType: InboxButtonContextType, ContextID: ctxID}
}

func TestInsertInboxButtonProposal_OneOpenPerContext(t *testing.T) {
	d := openTestDB(t)
	first, err := d.InsertInboxButtonProposal(buttonRow("7:0:abc"))
	require.NoError(t, err)

	_, err = d.InsertInboxButtonProposal(buttonRow("7:0:abc"))
	var open *ErrButtonHasOpenProposal
	require.ErrorAs(t, err, &open)
	assert.Equal(t, first, open.ID)
	assert.Equal(t, "This button already has a proposal (#"+itoa(first)+")", err.Error())

	// Another context is unaffected.
	_, err = d.InsertInboxButtonProposal(buttonRow("7:1:abc"))
	require.NoError(t, err)

	// The index refuses a plain insert too (the backstop).
	_, err = d.InsertAgentAction(buttonRow("7:0:abc"))
	require.Error(t, err)
	assert.True(t, isOpenContextViolation(err), err.Error())

	// Rejected → the button takes a new proposal.
	ok, err := d.TransitionAgentAction(first, []string{"pending"}, "rejected", "", "")
	require.NoError(t, err)
	require.True(t, ok)
	_, err = d.InsertInboxButtonProposal(buttonRow("7:0:abc"))
	require.NoError(t, err)
}

func TestInsertInboxButtonProposal_AppliedTaskLocksUntilDeleted(t *testing.T) {
	d := openTestDB(t)
	id, err := d.InsertInboxButtonProposal(buttonRow("7:0:abc"))
	require.NoError(t, err)
	targetID, created, err := d.CreateTargetForAction(Target{Text: "x", Status: "todo", Priority: "medium", Ownership: "mine"}, id)
	require.NoError(t, err)
	require.True(t, created)
	ok, err := d.TransitionAgentAction(id, []string{"pending"}, "applied", `{}`, "")
	require.NoError(t, err)
	require.True(t, ok)

	_, err = d.InsertInboxButtonProposal(buttonRow("7:0:abc"))
	var exists *ErrButtonTaskExists
	require.ErrorAs(t, err, &exists)
	assert.Equal(t, id, exists.ID)
	assert.Equal(t, targetID, exists.TargetID)
	assert.Equal(t, "This button's task already exists (task #"+itoa(targetID)+")", err.Error())

	require.NoError(t, d.DeleteTarget(int(targetID)))
	_, err = d.InsertInboxButtonProposal(buttonRow("7:0:abc"))
	require.NoError(t, err, "a deleted task never locks the button")
}

func TestInsertInboxButtonProposal_RefusesOtherContexts(t *testing.T) {
	d := openTestDB(t)
	row := buttonRow("1")
	row.ContextType = "track_event"
	_, err := d.InsertInboxButtonProposal(row)
	require.Error(t, err)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM agent_actions`).Scan(&n))
	assert.Zero(t, n)
}

func TestCreateTargetForAction_InsertOrReturn(t *testing.T) {
	d := openTestDB(t)
	tg := Target{Text: "Call colleague A", Status: "todo", Priority: "medium", Ownership: "mine"}
	id, created, err := d.CreateTargetForAction(tg, 42)
	require.NoError(t, err)
	assert.True(t, created)
	again, created, err := d.CreateTargetForAction(Target{Text: "other", Status: "todo", Priority: "low", Ownership: "mine"}, 42)
	require.NoError(t, err)
	assert.False(t, created)
	assert.Equal(t, id, again)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM targets`).Scan(&n))
	assert.Equal(t, 1, n)
	got, err := d.GetTargetByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, "Call colleague A", got.Text)
	assert.Equal(t, "chat", got.SourceType)
	assert.Equal(t, "action:42", got.SourceID)

	_, _, err = d.CreateTargetForAction(tg, 0)
	assert.Error(t, err, "action:0 is outside the index; it never takes this path")
}

func TestCreateTargetForAction_ChildRecomputesParent(t *testing.T) {
	d := openTestDB(t)
	parent, err := d.CreateTarget(Target{Text: "parent", Level: "week", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	_, _, err = d.CreateTargetForAction(Target{Text: "child", Status: "done", Priority: "medium", Ownership: "mine", ParentID: sql.NullInt64{Int64: parent, Valid: true}}, 5)
	require.NoError(t, err)
	p, err := d.GetTargetByID(int(parent))
	require.NoError(t, err)
	assert.InDelta(t, 1.0, p.Progress, 0.001, "the parent's progress follows its one done child")
}

func TestNewerOpenButtonProposal_AndClaimViolation(t *testing.T) {
	d := openTestDB(t)
	older, err := d.InsertInboxButtonProposal(buttonRow("7:0:abc"))
	require.NoError(t, err)
	ok, err := d.TransitionAgentAction(older, []string{"pending"}, "failed", "", "boom")
	require.NoError(t, err)
	require.True(t, ok)
	newer, err := d.InsertInboxButtonProposal(buttonRow("7:0:abc"))
	require.NoError(t, err)

	row, err := d.GetAgentAction(older)
	require.NoError(t, err)
	got, err := d.NewerOpenButtonProposal(row)
	require.NoError(t, err)
	assert.Equal(t, newer, got)
	newerRow, err := d.GetAgentAction(newer)
	require.NoError(t, err)
	got, err = d.NewerOpenButtonProposal(newerRow)
	require.NoError(t, err)
	assert.Zero(t, got)

	// The retry's claim hits the open-context index: typed, row unchanged.
	ok, err = d.TransitionAgentAction(older, []string{"failed"}, "executing", "", "boom")
	assert.False(t, ok)
	var newerErr *ErrButtonNewerProposalOpen
	require.True(t, errors.As(err, &newerErr), "%v", err)
	assert.Equal(t, newer, newerErr.ID)
	assert.Equal(t, "A newer proposal for this button is open (#"+itoa(newer)+")", err.Error())
	row, err = d.GetAgentAction(older)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Equal(t, "boom", row.Error)
}

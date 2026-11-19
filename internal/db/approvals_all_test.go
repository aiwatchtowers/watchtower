package db

import (
	"context"
	"database/sql"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func readNeedsApproval(t *testing.T, d *DB, now time.Time) NeedsApprovalView {
	t.Helper()
	ctx := context.Background()
	tx, err := d.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	require.NoError(t, err)
	defer func() { _ = tx.Rollback() }()
	view, err := ReadNeedsApprovalTx(ctx, tx, now)
	require.NoError(t, err)
	return view
}

func TestReadNeedsApprovalTx_SpansEveryAutomation(t *testing.T) {
	now := time.Now().UTC()
	stamp := func(d time.Duration) string { return formatAutomationTime(now.Add(d)) }
	d := openTestDB(t)
	builtin := seedBuiltinRow(t, d, NeedsApprovalBuiltinID, "needs-approval", "c", "h")
	other := seedBuiltinRow(t, d, "waiting-for-me", "waiting-for-me", "c", "h")

	pending, err := d.InsertAgentAction(AgentAction{Tool: "create_target", ArgsJSON: `{}`})
	require.NoError(t, err)
	failed, err := d.InsertAgentAction(AgentAction{Tool: "create_target", ArgsJSON: `{}`, Status: "failed"})
	require.NoError(t, err)
	// A failed row the owner dismissed still waits in the Inbox's rule
	// (db's own openActionClause leaves it out).
	_, err = d.Exec(`UPDATE agent_actions SET dismissed_at = ? WHERE id = ?`, stamp(0), failed)
	require.NoError(t, err)
	approved, err := d.InsertAgentAction(AgentAction{Tool: "create_target", ArgsJSON: `{}`, Status: "approved"})
	require.NoError(t, err)
	_, err = d.InsertAgentAction(AgentAction{Tool: "create_target", ArgsJSON: `{}`, Status: "applied"})
	require.NoError(t, err)
	due, err := d.InsertReminder(Reminder{RemindAt: stamp(-time.Hour)})
	require.NoError(t, err)
	_, err = d.InsertReminder(Reminder{RemindAt: stamp(time.Hour)})
	require.NoError(t, err)

	seedApprovalArtifact(t, d, builtin, ActionRef(pending), stamp(time.Minute))
	seedApprovalArtifact(t, d, other, ReminderRef(due), stamp(2*time.Minute))
	// One key of two automations: the built-in's wins.
	seedApprovalArtifact(t, d, other, ActionRef(failed), stamp(3*time.Minute))
	seedApprovalArtifact(t, d, builtin, ActionRef(failed), stamp(4*time.Minute))
	// A done artifact draws nothing.
	seedApprovalArtifact(t, d, builtin, "action:999", stamp(0))
	_, err = d.Exec(`UPDATE automation_outputs SET done_at = ? WHERE output_key = 'action:999'`, stamp(0))
	require.NoError(t, err)

	view := readNeedsApproval(t, d, now)
	var refs []string
	for _, a := range view.Open {
		refs = append(refs, a.Ref())
	}
	assert.ElementsMatch(t, []string{ActionRef(pending), ActionRef(failed), ReminderRef(due)}, refs)
	require.Len(t, view.Cards, 3)
	assert.Equal(t, builtin, view.Cards[ActionRef(pending)].AutomationID)
	assert.Equal(t, other, view.Cards[ReminderRef(due)].AutomationID, "every automation's artifacts")
	assert.Equal(t, builtin, view.Cards[ActionRef(failed)].AutomationID, "the built-in wins a shared key")
	assert.Equal(t, stamp(4*time.Minute), view.Cards[ActionRef(failed)].WrittenAt)
	assert.Equal(t, ApprovalBuiltinState{AutomationID: builtin, FeatureOn: true, LastRunOK: true}, view.Builtin)
	require.Len(t, view.Settled, 1)
	assert.Equal(t, approved, view.Settled[0].ID)
}

func TestReadNeedsApprovalTx_BuiltinState(t *testing.T) {
	d := openTestDB(t)
	view := readNeedsApproval(t, d, time.Now())
	assert.Equal(t, ApprovalBuiltinState{FeatureOn: true, LastRunOK: true}, view.Builtin, "not indexed")

	a := seedBuiltinRow(t, d, NeedsApprovalBuiltinID, "needs-approval", "c", "h")
	_, err := d.Exec(`INSERT INTO automation_runs (automation_id, trigger, status) VALUES (?, 'event', 'failed'),
		(?, 'dry_run', 'succeeded'), (?, 'event', 'running')`, a, a, a)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE automations SET disabled_reason = 'the run would not end' WHERE id = ?`, a)
	require.NoError(t, err)
	view = readNeedsApproval(t, d, time.Now())
	assert.Equal(t, ApprovalBuiltinState{AutomationID: a, FeatureOn: true, Stopped: true}, view.Builtin,
		"the latest finished non-dry run failed; stopped")
}

// OwnerKnownTx agrees with ResolveOwner: no rung, then each rung alone, set
// and unset.
func TestOwnerKnownTx_AgreesWithResolveOwner(t *testing.T) {
	check := func(t *testing.T, d *DB, want bool) {
		t.Helper()
		// ResolveOwner first: the test handle has one connection, which
		// the read-only transaction then holds.
		o, err := d.ResolveOwner()
		require.NoError(t, err)
		ctx := context.Background()
		tx, err := d.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
		require.NoError(t, err)
		defer func() { _ = tx.Rollback() }()
		known, err := OwnerKnownTx(ctx, tx)
		require.NoError(t, err)
		assert.Equal(t, want, known)
		assert.Equal(t, o.Known(), known)
	}
	check(t, openTestDB(t), false)
	for _, seed := range []struct {
		name, sql string
		want      bool
	}{
		{"slack", `INSERT INTO slack_accounts (id, current_user_id) VALUES (1, 'U1')`, true},
		{"slack removed", `INSERT INTO slack_accounts (id, current_user_id, status) VALUES (1, 'U1', 'removed')`, false},
		{"google", `INSERT INTO google_accounts (id, email) VALUES (1, 'owner@example.com')`, true},
		{"jira", `INSERT INTO jira_accounts (id, enabled, owner_account_id) VALUES (1, 1, 'acc-1')`, true},
		{"jira disabled", `INSERT INTO jira_accounts (id, enabled, owner_account_id) VALUES (1, 0, 'acc-1')`, false},
		{"linear", `INSERT INTO linear_accounts (id, enabled, owner_user_id) VALUES (1, 1, 'lin-1')`, true},
		{"mailbox", `INSERT INTO email_accounts (id, provider, email_address) VALUES (1, 'imap', 'owner@example.com')`, true},
		{"mailbox without @", `INSERT INTO email_accounts (id, provider, email_address) VALUES (1, 'imap', 'no-at-sign')`, false},
	} {
		t.Run(seed.name, func(t *testing.T) {
			d := openTestDB(t)
			_, err := d.Exec(seed.sql)
			require.NoError(t, err)
			check(t, d, seed.want)
		})
	}
}

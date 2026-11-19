package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// NeedsApprovalBuiltinID is the needs-approval built-in's id (builtin.Entry).
const NeedsApprovalBuiltinID = "needs-approval"

// NeedsApprovalView is what Needs approval draws, read across every
// automation in the caller's transaction (ReadNeedsApprovalTx): the open
// approvals in the Inbox's sense (AwaitingOwnerClause, the due reminders),
// the living action:/reminder: artifacts that may draw them, the
// needs-approval built-in's state, and the settled rows drawn below them.
type NeedsApprovalView struct {
	// Open are the open approvals, oldest created first (actions before
	// reminders on a tie, then id).
	Open []OpenApproval
	// Cards are the open (neither done nor dismissed) inbox artifacts keyed
	// action:<id> / reminder:<id>, of every automation. Two automations
	// with one key: the needs-approval built-in's wins.
	Cards map[string]ApprovalCard
	// Builtin is the needs-approval built-in's state.
	Builtin ApprovalBuiltinState
	// Settled are the actions the owner approved that are still approved or
	// executing (APPROVAL-01's 2026-11-10 amendment): drawn below the open
	// approvals, never counted. Newest created first.
	Settled []AgentAction
}

// ApprovalCard is one living artifact that may draw an approval.
type ApprovalCard struct {
	OutputID, AutomationID int64
	// WrittenAt is its last write (created_at when it has none), RFC 3339.
	WrittenAt string
}

// ApprovalBuiltinState is the needs-approval built-in as Needs approval's
// pick reads it (the Desktop's NeedsApprovalState).
type ApprovalBuiltinState struct {
	// AutomationID is its row; 0 before it is indexed.
	AutomationID int64
	// FeatureOn is the approval-cards switch. The config holds it, not the
	// database: the reader sets it true and the caller clears it.
	FeatureOn bool
	// Stopped: the daemon stopped it (its disabled_reason is set).
	Stopped bool
	// LastRunOK: its latest finished run (dry runs aside) did not fail —
	// true too before its first run.
	LastRunOK bool
}

// ReadNeedsApprovalTx reads the NeedsApprovalView at now inside tx (one
// snapshot with the rest of the caller's read). It writes nothing.
func ReadNeedsApprovalTx(ctx context.Context, tx *sql.Tx, now time.Time) (NeedsApprovalView, error) {
	view := NeedsApprovalView{Cards: map[string]ApprovalCard{}, Builtin: ApprovalBuiltinState{FeatureOn: true, LastRunOK: true}}
	var err error
	if view.Open, err = openApprovals(ctx, tx, formatAutomationTime(now), inboxApprovalsQuery); err != nil {
		return view, err
	}
	if view.Builtin, err = needsApprovalBuiltin(ctx, tx); err != nil {
		return view, err
	}
	if err := readApprovalCards(ctx, tx, view.Cards); err != nil {
		return view, err
	}
	rows, err := tx.QueryContext(ctx, `SELECT `+agentActionColumns+` FROM agent_actions
		WHERE status IN ('approved','executing') AND `+approvalRowClause+`
		ORDER BY created_at DESC, id DESC`)
	if err != nil {
		return view, fmt.Errorf("reading the settled approvals: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		a, err := scanAgentAction(rows)
		if err != nil {
			return view, fmt.Errorf("reading a settled approval: %w", err)
		}
		view.Settled = append(view.Settled, *a)
	}
	if err := rows.Err(); err != nil {
		return view, fmt.Errorf("reading the settled approvals: %w", err)
	}
	return view, nil
}

// needsApprovalBuiltin reads the built-in's state (InboxFolderQueries.needsApproval).
func needsApprovalBuiltin(ctx context.Context, tx *sql.Tx) (ApprovalBuiltinState, error) {
	out := ApprovalBuiltinState{FeatureOn: true, LastRunOK: true}
	var reason string
	err := tx.QueryRowContext(ctx, `SELECT id, disabled_reason FROM automations WHERE builtin_id = ?`,
		NeedsApprovalBuiltinID).Scan(&out.AutomationID, &reason)
	if errors.Is(err, sql.ErrNoRows) {
		return out, nil
	}
	if err != nil {
		return out, fmt.Errorf("reading the needs-approval built-in: %w", err)
	}
	out.Stopped = reason != ""
	var status string
	err = tx.QueryRowContext(ctx, `SELECT status FROM automation_runs
		WHERE automation_id = ? AND trigger != 'dry_run' AND status NOT IN ('queued', 'running', 'waiting')
		ORDER BY id DESC LIMIT 1`, out.AutomationID).Scan(&status)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return out, fmt.Errorf("reading the needs-approval built-in's last run: %w", err)
	}
	out.LastRunOK = errors.Is(err, sql.ErrNoRows) || status == "succeeded"
	return out, nil
}

// readApprovalCards fills cards with every automation's open action:/reminder:
// artifacts; the built-in's rows are read last, so they win a shared key.
func readApprovalCards(ctx context.Context, tx *sql.Tx, cards map[string]ApprovalCard) error {
	rows, err := tx.QueryContext(ctx, `SELECT o.output_key, o.id, o.automation_id, COALESCE(o.written_at, o.created_at)
		FROM automation_outputs o JOIN automations a ON a.id = o.automation_id
		WHERE o.kind = 'inbox' AND o.done_at IS NULL AND o.dismissed_at IS NULL AND o.output_key IS NOT NULL
		  AND (o.output_key LIKE 'action:%' OR o.output_key LIKE 'reminder:%')
		ORDER BY COALESCE(a.builtin_id, '') = ?, o.id`, NeedsApprovalBuiltinID)
	if err != nil {
		return fmt.Errorf("reading the approval artifacts: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var key string
		var c ApprovalCard
		if err := rows.Scan(&key, &c.OutputID, &c.AutomationID, &c.WrittenAt); err != nil {
			return fmt.Errorf("reading an approval artifact: %w", err)
		}
		cards[key] = c
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("reading the approval artifacts: %w", err)
	}
	return nil
}

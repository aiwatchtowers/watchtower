package db

import (
	"context"
	"database/sql"
	"fmt"
	"maps"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// Approval refs: the ref of an approval — an agent_actions row or a
// reminder — as the approval hook, the needs-approval built-in's artifact
// keys and `inbox approvals changed --ref` spell it.
const (
	ApprovalKindAction   = "action"
	ApprovalKindReminder = "reminder"
)

// ActionRef is the approval ref of agent_actions row id.
func ActionRef(id int64) string { return ApprovalKindAction + ":" + strconv.FormatInt(id, 10) }

// ReminderRef is the approval ref of reminder id.
func ReminderRef(id int64) string { return ApprovalKindReminder + ":" + strconv.FormatInt(id, 10) }

// ParseApprovalRef splits "<kind>:<id>" into its kind (action or reminder)
// and a positive id; anything else is an error.
func ParseApprovalRef(ref string) (kind string, id int64, err error) {
	kind, rest, ok := strings.Cut(ref, ":")
	if !ok || (kind != ApprovalKindAction && kind != ApprovalKindReminder) {
		return "", 0, fmt.Errorf("ref %q must be action:<id> or reminder:<id>", ref)
	}
	id, err = strconv.ParseInt(rest, 10, 64)
	if err != nil || id <= 0 || strconv.FormatInt(id, 10) != rest {
		return "", 0, fmt.Errorf("ref %q must be action:<id> or reminder:<id> with a positive id", ref)
	}
	return kind, id, nil
}

// SetApprovalHook sets the function every approval writer (InsertAgentAction,
// InsertInboxButtonProposal, TransitionAgentAction, DismissAgentAction,
// ApproveAgentActionWithArgs, InsertReminder, MarkReminderDone,
// SnoozeReminder) calls with the approval's ref after its statement changed
// a row that is or was an open approval: an action inserted pending, a
// transition from or to pending/failed, a dismiss, an approve with edits,
// every reminder write. It is called once the statement has returned and
// outside any transaction of the writer, synchronously, and its outcome
// never changes the writer's result. Set once per process; nil removes it.
func (db *DB) SetApprovalHook(fn func(ref string)) {
	if db.approvalHook == nil {
		db.approvalHook = new(atomic.Pointer[func(ref string)])
	}
	if fn == nil {
		db.approvalHook.Store(nil)
		return
	}
	db.approvalHook.Store(&fn)
}

// HasApprovalHook reports whether an approval hook is set on the handle.
func (db *DB) HasApprovalHook() bool {
	return db.approvalHook != nil && db.approvalHook.Load() != nil
}

// approvalChanged calls the approval hook, if one is set, with ref.
func (db *DB) approvalChanged(ref string) {
	if db.approvalHook == nil {
		return
	}
	if fn := db.approvalHook.Load(); fn != nil {
		(*fn)(ref)
	}
}

// inboxReplyToolNames are the tools a Reply from an Inbox row proposes
// (Inbox builder B, asks #445 and #451) — the one list; tools.InboxReplyTools
// reads it.
var inboxReplyToolNames = []string{"send_slack_message", "add_jira_comment", "add_linear_comment"}

// InboxReplyToolNames returns a fresh copy of the Reply tools' names.
func InboxReplyToolNames() []string { return slices.Clone(inboxReplyToolNames) }

// approvalRowClause is the half of openActionClause that never changes over
// a row's life: not a workbench's direct-apply audit row unless External,
// and not the inbox surface's one-press tool apply_track_action (proposed
// and approved by the same press). Every other inbox row waits for the
// owner's Approve — a card's target button (create_target) and a Reply —
// so it is an approval (the spec's STRIP-01 narrowing, ask #451).
const approvalRowClause = `(context_type IS NOT 'project' OR external = 1) AND NOT (surface = 'inbox' AND tool = 'apply_track_action')`

// ActionCanBeApproval reports whether agent_actions row id is a row that can
// ever be an open approval (approvalRowClause) — one indexed read, so the
// approval hook skips the rows that never are. A missing row is false.
func (db *DB) ActionCanBeApproval(id int64) (bool, error) {
	var ok bool
	err := db.QueryRow(`SELECT EXISTS (SELECT 1 FROM agent_actions WHERE id = ? AND `+approvalRowClause+`)`, id).Scan(&ok)
	if err != nil {
		return false, fmt.Errorf("reading agent action %d: %w", id, err)
	}
	return ok, nil
}

// openActionClause is the Go twin of the Desktop's "an action waits on the
// owner" predicate (AgentActionQueries.awaitingOwnerCount, InboxRefState):
// pending, or failed and not dismissed and not a settled session call (a
// claude_ai_connector_call failed with anything but the unknown-outcome
// error has no Retry); never a workbench's direct-apply audit row unless
// External, never an Inbox button's one-press row.
const openActionClause = `(status = 'pending'
	OR (status = 'failed' AND dismissed_at = ''
	    AND NOT (tool = 'claude_ai_connector_call' AND error != 'session ended while the call ran; outcome unknown')))
	AND ` + approvalRowClause

// openReminderClause is REMIND-01's due set: pending and remind_at <= ?.
const openReminderClause = `status = 'pending' AND remind_at <= ?`

// HasUnfinishedAutomationRun reports whether automation id has a run queued,
// running or waiting (dry runs aside) — the approval sweep leaves the
// comparison to the run that is coming.
func (db *DB) HasUnfinishedAutomationRun(id int64) (bool, error) {
	var ok bool
	err := db.QueryRow(`SELECT EXISTS (SELECT 1 FROM automation_runs WHERE automation_id = ?
		AND status IN ('queued','running','waiting') AND trigger != 'dry_run')`, id).Scan(&ok)
	if err != nil {
		return false, fmt.Errorf("reading the unfinished runs of automation %d: %w", id, err)
	}
	return ok, nil
}

// ApprovalDrift is what ApprovalDriftOf found: how many open approvals have
// no artifact written at or after their last change (Missing), and how many
// artifacts belong to an approval that is closed or gone (Closed).
type ApprovalDrift struct {
	Missing int
	Closed  int
}

// Any reports whether the artifacts disagree with the open approvals.
func (d ApprovalDrift) Any() bool { return d.Missing > 0 || d.Closed > 0 }

// ApprovalDriftOf compares the open approvals at now with automation
// automationID's living inbox artifacts keyed action:<id> / reminder:<id>
// (an artifact counts only when written strictly after the last change),
// in one read-only transaction (it never blocks a writer and writes
// nothing). An approval's last change is the latest of an action's
// created_at, decided_at and applied_at, or of a reminder's created_at and
// remind_at (so a reminder that came due after its artifact was written
// counts as missing). Only the oldest limit open approvals (created_at, then
// id) are expected to have an artifact — a run writes at most that many;
// limit ≤ 0 expects every one.
func (db *DB) ApprovalDriftOf(ctx context.Context, automationID int64, now time.Time, limit int) (ApprovalDrift, error) {
	var drift ApprovalDrift
	tx, err := db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return drift, fmt.Errorf("reading approval drift: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	written, err := approvalArtifacts(ctx, tx, automationID)
	if err != nil {
		return drift, err
	}
	open, err := openApprovals(ctx, tx, formatAutomationTime(now))
	if err != nil {
		return drift, err
	}
	for i, a := range open {
		at, ok := written[a.Ref()]
		delete(written, a.Ref())
		// A tie is drift: both stamps have whole seconds, so an artifact
		// written in the second of the change may predate it. The redraw
		// writes a later written_at, so the sweep converges.
		if (limit <= 0 || i < limit) && (!ok || at <= a.ChangedAt) {
			drift.Missing++
		}
	}
	drift.Closed = len(written)
	return drift, nil
}

// OpenApproval is one open approval as the needs-approval built-in reads it
// (approvals.list): an agent_actions row (Kind action) or a due reminder
// (Kind reminder). ChangedAt is its last change: the latest of an action's
// created_at, decided_at and applied_at, or of a reminder's created_at and
// remind_at. The action fields are empty for a reminder and the reminder
// fields for an action.
type OpenApproval struct {
	Kind      string // ApprovalKindAction | ApprovalKindReminder
	ID        int64
	CreatedAt string
	ChangedAt string
	// An action's.
	Tool, ArgsJSON, Reason, Status, Error, ContextType, ContextID string
	// A reminder's.
	Note, RemindAt, MessageRef string
}

// Ref is the approval's ref, action:<id> or reminder:<id> — the
// needs-approval built-in's artifact key.
func (a OpenApproval) Ref() string {
	if a.Kind == ApprovalKindReminder {
		return ReminderRef(a.ID)
	}
	return ActionRef(a.ID)
}

// ApprovalsView is what approvals.list reads in one read-only transaction:
// the open approvals at now in ApprovalDriftOf's order (created_at, actions
// before reminders, id) — the oldest limit of them (limit ≤ 0: every one) —
// with their total count, and Closed, the action:/reminder: keys of
// automation automationID's living inbox artifacts whose approval is not
// open (closed or gone), sorted. A run that writes Open and removes Closed
// leaves ApprovalDriftOf nothing to find.
type ApprovalsView struct {
	Open   []OpenApproval
	Total  int
	Closed []string
}

// ReadApprovalsView reads the ApprovalsView of automation automationID at
// now; it never blocks a writer and writes nothing.
func (db *DB) ReadApprovalsView(ctx context.Context, automationID int64, now time.Time, limit int) (ApprovalsView, error) {
	var view ApprovalsView
	tx, err := db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return view, fmt.Errorf("reading open approvals: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	written, err := approvalArtifacts(ctx, tx, automationID)
	if err != nil {
		return view, err
	}
	open, err := openApprovals(ctx, tx, formatAutomationTime(now))
	if err != nil {
		return view, err
	}
	for _, a := range open {
		delete(written, a.Ref())
	}
	view.Total = len(open)
	if limit > 0 && len(open) > limit {
		open = open[:limit]
	}
	view.Open = open
	view.Closed = slices.Sorted(maps.Keys(written))
	return view, nil
}

// openApprovals lists the open approvals, oldest created first (actions
// before reminders on a tie, then id).
func openApprovals(ctx context.Context, tx *sql.Tx, now string) ([]OpenApproval, error) {
	rows, err := tx.QueryContext(ctx, `
		SELECT k, id, created_at, changed_at, tool, args_json, reason, status, error, context_type, context_id,
		       note, remind_at, message_ref FROM (
			SELECT 0 AS k, id, created_at, MAX(created_at, decided_at, applied_at) AS changed_at,
			       tool, args_json, reason, status, error, context_type, context_id,
			       '' AS note, '' AS remind_at, '' AS message_ref
			FROM agent_actions WHERE `+openActionClause+`
			UNION ALL
			SELECT 1, id, created_at, MAX(created_at, remind_at), '', '', '', status, '', '', '', note, remind_at, message_ref
			FROM reminders WHERE `+openReminderClause+`)
		ORDER BY created_at, k, id`, now)
	if err != nil {
		return nil, fmt.Errorf("reading open approvals: %w", err)
	}
	defer rows.Close()
	var out []OpenApproval
	for rows.Next() {
		var a OpenApproval
		var k int
		if err := rows.Scan(&k, &a.ID, &a.CreatedAt, &a.ChangedAt, &a.Tool, &a.ArgsJSON, &a.Reason, &a.Status, &a.Error,
			&a.ContextType, &a.ContextID, &a.Note, &a.RemindAt, &a.MessageRef); err != nil {
			return nil, fmt.Errorf("reading open approvals: %w", err)
		}
		a.Kind = ApprovalKindAction
		if k == 1 {
			a.Kind = ApprovalKindReminder
		}
		out = append(out, a)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading open approvals: %w", err)
	}
	return out, nil
}

// approvalArtifacts maps each action:/reminder: key of automationID's
// living inbox artifacts to its written_at.
func approvalArtifacts(ctx context.Context, tx *sql.Tx, automationID int64) (map[string]string, error) {
	rows, err := tx.QueryContext(ctx, `SELECT output_key, COALESCE(written_at, created_at) FROM automation_outputs
		WHERE automation_id = ? AND kind = 'inbox' AND output_key IS NOT NULL
		  AND (output_key LIKE 'action:%' OR output_key LIKE 'reminder:%')`, automationID)
	if err != nil {
		return nil, fmt.Errorf("reading approval artifacts of automation %d: %w", automationID, err)
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var key, at string
		if err := rows.Scan(&key, &at); err != nil {
			return nil, fmt.Errorf("reading approval artifacts of automation %d: %w", automationID, err)
		}
		out[key] = at
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading approval artifacts of automation %d: %w", automationID, err)
	}
	return out, nil
}

// AutomationRunLabels maps each of runIDs to its card label, "⚙ <name> · run
// #<id>" (the automation's name, else its slug) — the Go twin of the
// Desktop's AutomationQueries.runLabels; a run that is gone is absent.
func (db *DB) AutomationRunLabels(ctx context.Context, runIDs []int64) (map[int64]string, error) {
	out := map[int64]string{}
	if len(runIDs) == 0 {
		return out, nil
	}
	marks := strings.TrimSuffix(strings.Repeat("?,", len(runIDs)), ",")
	args := make([]any, len(runIDs))
	for i, id := range runIDs {
		args[i] = id
	}
	rows, err := db.QueryContext(ctx, `SELECT r.id, COALESCE(NULLIF(a.name, ''), a.slug)
		FROM automation_runs r JOIN automations a ON a.id = r.automation_id WHERE r.id IN (`+marks+`)`, args...)
	if err != nil {
		return nil, fmt.Errorf("reading run labels: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		var name string
		if err := rows.Scan(&id, &name); err != nil {
			return nil, fmt.Errorf("reading run labels: %w", err)
		}
		out[id] = fmt.Sprintf("⚙ %s · run #%d", name, id)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading run labels: %w", err)
	}
	return out, nil
}

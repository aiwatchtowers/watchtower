package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"watchtower/internal/sqlcipher"
)

// InboxButtonContextType is the context of a proposal made by an Inbox card's
// target button: context_id is `<output id>:<flattened index>:<action hash>`.
// At most one such row per context is open (pending/approved/executing,
// idx_agent_actions_open_context, AGENT-05).
const InboxButtonContextType = "automation_output"

// ErrButtonHasOpenProposal is the refusal of a press on a button that
// already has an open proposal (#ID).
type ErrButtonHasOpenProposal struct{ ID int64 }

func (e *ErrButtonHasOpenProposal) Error() string {
	return fmt.Sprintf("This button already has a proposal (#%d)", e.ID)
}

// ErrButtonTaskExists is the refusal of a press on a button whose proposal
// #ID was applied and whose task #TargetID still exists, so a new proposal
// would duplicate it.
type ErrButtonTaskExists struct{ ID, TargetID int64 }

func (e *ErrButtonTaskExists) Error() string {
	return fmt.Sprintf("This button's task already exists (task #%d)", e.TargetID)
}

// ErrButtonNewerProposalOpen is the refusal of a retry of an older row of a
// button whose newer proposal #ID is open, before any state change.
type ErrButtonNewerProposalOpen struct{ ID int64 }

func (e *ErrButtonNewerProposalOpen) Error() string {
	return fmt.Sprintf("A newer proposal for this button is open (#%d)", e.ID)
}

// isOpenContextViolation reports a unique violation
// (SQLITE_CONSTRAINT_UNIQUE) of idx_agent_actions_open_context. SQLite names
// a partial index's columns, not the index, in the message; no other unique
// constraint covers these two columns.
func isOpenContextViolation(err error) bool {
	var se sqlcipher.Error
	return errors.As(err, &se) && se.ExtendedCode == sqlcipher.ErrConstraintUnique &&
		strings.Contains(err.Error(), "agent_actions.context_type, agent_actions.context_id")
}

type rowQuerier interface {
	QueryRow(query string, args ...any) *sql.Row
}

// openButtonProposal is the id of the open proposal for (ctxType, ctxID)
// other than exceptID; 0 when there is none.
func openButtonProposal(q rowQuerier, ctxType, ctxID string, exceptID int64) (int64, error) {
	var id int64
	err := q.QueryRow(`SELECT id FROM agent_actions WHERE context_type = ? AND context_id = ?
		AND status IN ('pending','approved','executing') AND id != ? ORDER BY id DESC LIMIT 1`,
		ctxType, ctxID, exceptID).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("reading the open proposal of %s %s: %w", ctxType, ctxID, err)
	}
	return id, nil
}

// InsertInboxButtonProposal records an Inbox button's proposal (a.ContextType
// = InboxButtonContextType) in one BEGIN IMMEDIATE transaction with its
// checks: an open proposal for the context refuses it
// (*ErrButtonHasOpenProposal, also when the unique index fires), and so does
// an applied one whose task still exists (*ErrButtonTaskExists). An applied
// row whose task the owner deleted does not lock the button.
func (db *DB) InsertInboxButtonProposal(a AgentAction) (int64, error) {
	if a.ContextType != InboxButtonContextType {
		return 0, fmt.Errorf("inbox button proposal: context type %q is not %q", a.ContextType, InboxButtonContextType)
	}
	if a.Status == "" {
		a.Status = "pending"
	}
	if a.TrustAtCreate == "" {
		a.TrustAtCreate = "ask"
	}
	tx, err := db.Begin()
	if err != nil {
		return 0, fmt.Errorf("inbox button proposal: %w", err)
	}
	defer tx.Rollback()
	if err := checkButtonFree(tx, a.ContextType, a.ContextID); err != nil {
		return 0, err
	}
	res, err := tx.Exec(`INSERT INTO agent_actions
		(tool, external, args_json, reason, surface, conversation_id, context_type, context_id,
		 turn_id, status, trust_at_create, session_token)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		a.Tool, a.External, a.ArgsJSON, a.Reason, a.Surface, a.ConversationID, a.ContextType, a.ContextID,
		a.TurnID, a.Status, a.TrustAtCreate, a.SessionToken)
	if isOpenContextViolation(err) {
		// Unreachable under BEGIN IMMEDIATE after checkButtonFree; the
		// index is the backstop. Roll back before reading: a one-connection
		// pool would wait on its own transaction.
		_ = tx.Rollback()
		open, qerr := openButtonProposal(db, a.ContextType, a.ContextID, 0)
		if qerr != nil {
			return 0, fmt.Errorf("inserting inbox button proposal: %w", err)
		}
		return 0, &ErrButtonHasOpenProposal{ID: open}
	}
	if err != nil {
		return 0, fmt.Errorf("inserting inbox button proposal: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("inserting inbox button proposal: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("committing inbox button proposal: %w", err)
	}
	// After Commit: the hook writes automation_runs, and inside the
	// transaction it would wait on this transaction's own write lock.
	if approvalStatus(a.Status) {
		db.approvalChanged(ActionRef(id))
	}
	return id, nil
}

// checkButtonFree is InsertInboxButtonProposal's check, inside its write
// transaction. The task check looks at every proposal of the button, not
// only `applied` ones: an apply that crashed after its insert leaves the
// task behind a `failed` (reclaimed) or `executing` row, and a press in that
// gap must not start a second task for the same button.
func checkButtonFree(tx *sql.Tx, ctxType, ctxID string) error {
	open, err := openButtonProposal(tx, ctxType, ctxID, 0)
	if err != nil {
		return err
	}
	if open != 0 {
		return &ErrButtonHasOpenProposal{ID: open}
	}
	var actionID, targetID int64
	err = tx.QueryRow(`SELECT a.id, t.id FROM agent_actions a
		JOIN targets t ON t.source_type = 'chat' AND t.source_id = 'action:' || a.id
		WHERE a.context_type = ? AND a.context_id = ?
		ORDER BY a.id DESC LIMIT 1`, ctxType, ctxID).Scan(&actionID, &targetID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("reading the task of %s %s: %w", ctxType, ctxID, err)
	}
	return &ErrButtonTaskExists{ID: actionID, TargetID: targetID}
}

// NewerOpenButtonProposal is, for an Inbox button's row, the id of a newer
// open proposal of the same button (0 when none, or for any other row) — a
// retry of the older row would violate idx_agent_actions_open_context.
func (db *DB) NewerOpenButtonProposal(row *AgentAction) (int64, error) {
	if row == nil || row.ContextType != InboxButtonContextType {
		return 0, nil
	}
	var id int64
	err := db.QueryRow(`SELECT id FROM agent_actions WHERE context_type = ? AND context_id = ?
		AND status IN ('pending','approved','executing') AND id > ? ORDER BY id DESC LIMIT 1`,
		row.ContextType, row.ContextID, row.ID).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("reading newer proposals of action #%d: %w", row.ID, err)
	}
	return id, nil
}

// openProposalAfterViolation is, for a transition of row id that hit
// idx_agent_actions_open_context (a retry's claim while another proposal of
// the button is open; the failed UPDATE changed nothing), the id of that open
// proposal. 0 for any other error, or when it cannot be read — the caller
// then reports the error as it is.
func (db *DB) openProposalAfterViolation(id int64, err error) int64 {
	if !isOpenContextViolation(err) {
		return 0
	}
	var ctxType, ctxID string
	if db.QueryRow(`SELECT context_type, context_id FROM agent_actions WHERE id = ?`, id).Scan(&ctxType, &ctxID) != nil {
		return 0
	}
	open, qerr := openButtonProposal(db, ctxType, ctxID, id)
	if qerr != nil {
		return 0
	}
	return open
}

// ParentUnavailableError refuses a parent task a new child cannot go under:
// it does not exist, is closed (done or dismissed) or lives on a workbench
// board. Reason is the words after "task #N".
type ParentUnavailableError struct {
	ID     int64
	Reason string
}

func (e *ParentUnavailableError) Error() string {
	return fmt.Sprintf("task #%d %s", e.ID, e.Reason)
}

// checkOpenPersonalParent refuses parent id unless it exists, is a personal
// task (project_id IS NULL) and is neither done nor dismissed.
func checkOpenPersonalParent(q targetsQuerier, id int64) error {
	var project sql.NullInt64
	var status string
	err := q.QueryRow(`SELECT project_id, status FROM targets WHERE id = ?`, id).Scan(&project, &status)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return &ParentUnavailableError{ID: id, Reason: "does not exist"}
	case err != nil:
		return fmt.Errorf("reading parent task #%d: %w", id, err)
	case project.Valid:
		return &ParentUnavailableError{ID: id, Reason: "is on a workbench board"}
	case status == "done" || status == "dismissed":
		return &ParentUnavailableError{ID: id, Reason: "is closed"}
	}
	return nil
}

// OpenPersonalParent returns parent task id, or *ParentUnavailableError
// when a new child cannot go under it (checkOpenPersonalParent).
func (db *DB) OpenPersonalParent(id int64) (*Target, error) {
	if err := checkOpenPersonalParent(db, id); err != nil {
		return nil, err
	}
	return db.GetTargetByID(int(id))
}

// TargetForAction is the id of the task create_target made for
// agent_actions row actionID (source 'chat' / 'action:<actionID>'); 0 when
// there is none.
func (db *DB) TargetForAction(actionID int64) (int64, error) {
	return targetForAction(db, actionID)
}

func targetForAction(q rowQuerier, actionID int64) (int64, error) {
	var id int64
	err := q.QueryRow(`SELECT id FROM targets WHERE source_type = 'chat' AND source_id = ?`,
		"action:"+strconv.FormatInt(actionID, 10)).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("reading the task of action #%d: %w", actionID, err)
	}
	return id, nil
}

// CreateTargetForAction creates create_target's task for agent_actions row
// actionID (source 'chat' / 'action:<actionID>') at most once. In one write
// transaction it first returns an existing task of the action (created =
// false) — before any parent check, so a reclaim after a crashed apply
// returns the task even when its parent has gone since —, then checks
// t.ParentID (checkOpenPersonalParent, *ParentUnavailableError), then
// inserts; idx_targets_action_source keeps the insert a no-op should
// another writer have won. actionID must be > 0 ('action:0' is outside the
// index).
func (db *DB) CreateTargetForAction(t Target, actionID int64) (int64, bool, error) {
	if actionID <= 0 {
		return 0, false, fmt.Errorf("create target for action: action id %d", actionID)
	}
	t = withTargetDefaults(t)
	t.SourceType = "chat"
	t.SourceID = "action:" + strconv.FormatInt(actionID, 10)
	tx, err := db.Begin()
	if err != nil {
		return 0, false, fmt.Errorf("create target for action #%d: %w", actionID, err)
	}
	defer tx.Rollback()
	existing, err := targetForAction(tx, actionID)
	if err != nil {
		return 0, false, err
	}
	if existing != 0 {
		if err := tx.Commit(); err != nil {
			return 0, false, fmt.Errorf("committing the task of action #%d: %w", actionID, err)
		}
		return existing, false, nil
	}
	if t.ParentID.Valid {
		if err := checkOpenPersonalParent(tx, t.ParentID.Int64); err != nil {
			return 0, false, err
		}
	}
	if err := checkParentBoard(tx, t.ParentID, t.WorkbenchID); err != nil {
		return 0, false, err
	}
	var id int64
	err = tx.QueryRow(`INSERT INTO targets
		(text, intent, level, custom_label, period_start, period_end, parent_id,
		 status, priority, ownership, ball_on, due_date, snooze_until, blocking,
		 tags, sub_items, notes, progress, source_type, source_id, ai_level_confidence, project_id)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT DO NOTHING RETURNING id`,
		t.Text, t.Intent, t.Level, t.CustomLabel, t.PeriodStart, t.PeriodEnd, t.ParentID,
		t.Status, t.Priority, t.Ownership, t.BallOn, t.DueDate, t.SnoozeUntil, t.Blocking,
		t.Tags, t.SubItems, t.Notes, statusToProgress(t.Status), t.SourceType, t.SourceID, t.AILevelConfidence, t.WorkbenchID,
	).Scan(&id)
	created := err == nil
	switch {
	case errors.Is(err, sql.ErrNoRows):
		if err := tx.QueryRow(`SELECT id FROM targets WHERE source_type = 'chat' AND source_id = ?`, t.SourceID).
			Scan(&id); err != nil {
			return 0, false, fmt.Errorf("reading the task of action #%d: %w", actionID, err)
		}
	case err != nil:
		return 0, false, fmt.Errorf("inserting the task of action #%d: %w", actionID, err)
	}
	if created && t.ParentID.Valid {
		if err := recomputeParentProgressOn(tx, t.ParentID.Int64); err != nil {
			return 0, false, err
		}
	}
	if err := tx.Commit(); err != nil {
		return 0, false, fmt.Errorf("committing the task of action #%d: %w", actionID, err)
	}
	return id, created, nil
}

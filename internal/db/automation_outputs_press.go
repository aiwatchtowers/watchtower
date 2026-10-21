package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

var (
	// ErrOutputNotFound is wrapped when no inbox automation_outputs row matches.
	ErrOutputNotFound = errors.New("inbox card not found")
	// ErrOutputClosed refuses a press on a card that is done or dismissed.
	ErrOutputClosed = errors.New("inbox card is done or dismissed")
	// ErrNotAReplyAction refuses a press of an index that is not a Reply action.
	ErrNotAReplyAction = errors.New("not a reply action of the card")
	// ErrOutputAutomationNotRunnable refuses a press while the card's
	// automation cannot run (off, unconfirmed, unreadable or removed).
	ErrOutputAutomationNotRunnable = errors.New("the card's automation cannot run")
)

// AlreadyPressedError refuses a second press of a card: it carries the run
// the first press queued.
type AlreadyPressedError struct{ RunID int64 }

func (e *AlreadyPressedError) Error() string { return fmt.Sprintf("Sent — run #%d", e.RunID) }

// ReplyPayload is the event_json of a trigger='reply' run.
type ReplyPayload struct {
	Reply ReplyTrigger `json:"reply"`
}

// ReplyTrigger is what the script sees as trigger.reply. Data is the pressed
// action's stored data (JSON null when it has none), never the caller's.
type ReplyTrigger struct {
	OutputID int64           `json:"output_id"`
	Action   int             `json:"action"`
	Value    string          `json:"value"`
	Data     json.RawMessage `json:"data"`
	Card     ReplyCard       `json:"card"`
}

// ReplyCard is the pressed card's title and link.
type ReplyCard struct {
	Title string `json:"title"`
	Link  string `json:"link"`
}

// decodeInboxActions decodes a stored actions_json; a decode error is an
// error, never an empty list.
func decodeInboxActions(s string) ([]InboxAction, error) {
	actions := []InboxAction{}
	if err := json.Unmarshal([]byte(s), &actions); err != nil {
		return nil, fmt.Errorf("decoding actions_json: %w", err)
	}
	if actions == nil { // a stored JSON null
		actions = []InboxAction{}
	}
	return actions, nil
}

// pressTarget is what a press reads of the card and its automation.
type pressTarget struct {
	automationID     int64
	title, link      string
	actions          string
	closed, runnable bool
	pressedRunID     sql.NullInt64
	pressed          bool
}

func readPressTargetTx(tx *sql.Tx, outputID int64) (pressTarget, error) {
	var p pressTarget
	err := tx.QueryRow(`SELECT o.automation_id, o.title, o.link, o.actions_json,
			o.done_at IS NOT NULL OR o.dismissed_at IS NOT NULL,
			a.parse_error = '' AND a.enabled = 1 AND a.removed_at IS NULL
				AND a.confirmed_hash != '' AND a.confirmed_hash = a.approval_hash,
			o.pressed_at IS NOT NULL, o.pressed_run_id
		FROM automation_outputs o JOIN automations a ON a.id = o.automation_id
		WHERE o.id = ? AND o.kind = 'inbox'`, outputID).Scan(&p.automationID, &p.title, &p.link, &p.actions,
		&p.closed, &p.runnable, &p.pressed, &p.pressedRunID)
	if errors.Is(err, sql.ErrNoRows) {
		return p, fmt.Errorf("inbox card %d: %w", outputID, ErrOutputNotFound)
	}
	if err != nil {
		return p, fmt.Errorf("reading inbox card %d: %w", outputID, err)
	}
	return p, nil
}

// replyActionAt returns the Reply action at index of the stored actions.
func replyActionAt(p pressTarget, outputID int64, index int) (InboxAction, error) {
	actions, err := decodeInboxActions(p.actions)
	if err != nil {
		return InboxAction{}, fmt.Errorf("inbox card %d: %w", outputID, err)
	}
	if index < 0 || index >= len(actions) || actions[index].Kind != InboxActionReply {
		return InboxAction{}, fmt.Errorf("inbox card %d action %d: %w", outputID, index, ErrNotAReplyAction)
	}
	return actions[index], nil
}

// PressInboxOutputAction records the owner's one press of the Reply action
// at actionIndex of inbox card outputID and queues its trigger='reply' run,
// in one transaction. Refusals, checked in this order, write nothing:
// ErrOutputNotFound, ErrOutputClosed (done or dismissed), ErrNotAReplyAction,
// ErrOutputAutomationNotRunnable, and *AlreadyPressedError for a card
// already pressed. The run's ReplyPayload is built from the stored row.
func (db *DB) PressInboxOutputAction(outputID int64, actionIndex int, now time.Time) (runID int64, err error) {
	if err := requireRunTime(now, fmt.Sprintf("pressing inbox card %d", outputID)); err != nil {
		return 0, err
	}
	tx, err := db.Begin()
	if err != nil {
		return 0, fmt.Errorf("pressing inbox card %d: %w", outputID, err)
	}
	defer func() { _ = tx.Rollback() }()

	p, err := readPressTargetTx(tx, outputID)
	if err != nil {
		return 0, err
	}
	if err := pressRefusal(p, outputID); err != nil {
		return 0, err
	}
	action, err := replyActionAt(p, outputID, actionIndex)
	if err != nil {
		return 0, err
	}
	if !p.runnable {
		return 0, fmt.Errorf("inbox card %d: %w", outputID, ErrOutputAutomationNotRunnable)
	}
	if p.pressed {
		return 0, &AlreadyPressedError{RunID: p.pressedRunID.Int64}
	}

	data := action.Data
	if len(data) == 0 {
		data = json.RawMessage(`null`)
	}
	payload, err := json.Marshal(ReplyPayload{Reply: ReplyTrigger{OutputID: outputID, Action: actionIndex,
		Value: action.Reply, Data: data, Card: ReplyCard{Title: p.title, Link: p.link}}})
	if err != nil {
		return 0, fmt.Errorf("pressing inbox card %d: encoding the reply: %w", outputID, err)
	}
	runID, _, err = enqueueRunTx(tx, EnqueueRequest{AutomationID: p.automationID, Trigger: TriggerReply,
		EventJSON: string(payload), Now: now})
	if err != nil {
		return 0, err
	}
	res, err := tx.Exec(`UPDATE automation_outputs SET pressed_action = ?, pressed_run_id = ?, pressed_at = ?
		WHERE id = ? AND pressed_at IS NULL AND done_at IS NULL AND dismissed_at IS NULL`,
		actionIndex, runID, formatAutomationTime(now), outputID)
	if err != nil {
		return 0, fmt.Errorf("recording the press of inbox card %d: %w", outputID, err)
	}
	if n, err := res.RowsAffected(); err != nil || n != 1 {
		// Unreachable inside one BEGIN IMMEDIATE transaction, kept as a guard:
		// roll back and name what changed.
		_ = tx.Rollback()
		return 0, db.pressRaceError(outputID, err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("pressing inbox card %d: %w", outputID, err)
	}
	return runID, nil
}

// pressRefusal returns ErrOutputClosed for a done or dismissed card.
func pressRefusal(p pressTarget, outputID int64) error {
	if p.closed {
		return fmt.Errorf("inbox card %d: %w", outputID, ErrOutputClosed)
	}
	return nil
}

// pressRaceError re-reads a card whose press update matched no row and
// returns the precise refusal.
func (db *DB) pressRaceError(outputID int64, cause error) error {
	if cause != nil {
		return fmt.Errorf("recording the press of inbox card %d: %w", outputID, cause)
	}
	tx, err := db.BeginTx(context.Background(), &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return fmt.Errorf("re-reading inbox card %d: %w", outputID, err)
	}
	defer func() { _ = tx.Rollback() }()
	p, err := readPressTargetTx(tx, outputID)
	if err != nil {
		return err
	}
	if err := pressRefusal(p, outputID); err != nil {
		return err
	}
	if p.pressed {
		return &AlreadyPressedError{RunID: p.pressedRunID.Int64}
	}
	return fmt.Errorf("recording the press of inbox card %d: no row updated", outputID)
}

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
	// ErrOutputChanged refuses a press made on a drawn version of the card
	// whose content_hash is no longer the row's: a living card was rewritten
	// between drawing and pressing.
	ErrOutputChanged = errors.New("This card changed — look again") //nolint:staticcheck // ST1005: shown to the owner as is
)

// AlreadyPressedError refuses a second press of a card: it carries the run
// the first press queued, 0 when that run was since deleted
// (pressed_run_id ON DELETE SET NULL).
type AlreadyPressedError struct{ RunID int64 }

func (e *AlreadyPressedError) Error() string {
	if e.RunID == 0 {
		return "Sent — its run was since deleted"
	}
	return fmt.Sprintf("Sent — run #%d", e.RunID)
}

// ReplyPayload is the event_json of a trigger='reply' run.
type ReplyPayload struct {
	Reply ReplyTrigger `json:"reply"`
}

// ReplyTrigger is what the script sees as trigger.reply. Data is the pressed
// action's stored data (JSON null when it has none), never the caller's.
// ContentHash is the card's content_hash the press resolved against (empty on
// a card from before content hashes, and in a payload from before this
// field): the executor cancels the run when the card no longer has it.
type ReplyTrigger struct {
	OutputID    int64           `json:"output_id"`
	Action      int             `json:"action"`
	Value       string          `json:"value"`
	Data        json.RawMessage `json:"data"`
	Card        ReplyCard       `json:"card"`
	ContentHash string          `json:"content_hash,omitempty"`
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

// FlattenStoredInboxActions is the card's flattened action list — the press
// address of the Inbox builder A spec — read from a stored row: the card's
// own actions, then each block action of blocksJSON in document order (a
// list's row actions in row order, an actions block's actions in order).
// It mirrors blocks.FlattenActions over the stored document (blocks imports
// db, so db cannot call it); the blocks fixture test pins the two to the same
// list. A document that does not decode, or of a version other than 1, is an
// error, never a shorter list.
func FlattenStoredInboxActions(card []InboxAction, blocksJSON string) ([]InboxAction, error) {
	out := append([]InboxAction{}, card...)
	if blocksJSON == "" {
		return out, nil
	}
	var doc struct {
		V      *int `json:"v"`
		Blocks []struct {
			Type    string          `json:"type"`
			Rows    json.RawMessage `json:"rows"`
			Actions json.RawMessage `json:"actions"`
		} `json:"blocks"`
	}
	if err := json.Unmarshal([]byte(blocksJSON), &doc); err != nil {
		return nil, fmt.Errorf("decoding blocks_json: %w", err)
	}
	if doc.V == nil || *doc.V != 1 {
		return nil, errors.New("decoding blocks_json: not a version 1 document")
	}
	for i, b := range doc.Blocks {
		switch b.Type {
		case "list":
			var rows []struct {
				Actions []InboxAction `json:"actions"`
			}
			if err := json.Unmarshal(b.Rows, &rows); err != nil {
				return nil, fmt.Errorf("decoding blocks_json: block %d rows: %w", i, err)
			}
			for _, r := range rows {
				out = append(out, r.Actions...)
			}
		case "actions":
			var actions []InboxAction
			if err := json.Unmarshal(b.Actions, &actions); err != nil {
				return nil, fmt.Errorf("decoding blocks_json: block %d actions: %w", i, err)
			}
			out = append(out, actions...)
		}
	}
	return out, nil
}

// pressTarget is what a press reads of the card and its automation.
type pressTarget struct {
	automationID     int64
	title, link      string
	actions          string
	blocks           string
	contentHash      string
	closed, runnable bool
	pressedRunID     sql.NullInt64
	pressed          bool
}

func readPressTargetTx(tx *sql.Tx, outputID int64) (pressTarget, error) {
	var p pressTarget
	// runnableAutomationSQL's columns are unqualified; none of them is an
	// automation_outputs column, so they resolve to a.
	err := tx.QueryRow(`SELECT o.automation_id, o.title, o.link, o.actions_json, o.blocks_json, o.content_hash,
			o.done_at IS NOT NULL OR o.dismissed_at IS NOT NULL,
			`+runnableAutomationSQL+`,
			o.pressed_at IS NOT NULL, o.pressed_run_id
		FROM automation_outputs o JOIN automations a ON a.id = o.automation_id
		WHERE o.id = ? AND o.kind = 'inbox'`, outputID).Scan(&p.automationID, &p.title, &p.link, &p.actions,
		&p.blocks, &p.contentHash, &p.closed, &p.runnable, &p.pressed, &p.pressedRunID)
	if errors.Is(err, sql.ErrNoRows) {
		return p, fmt.Errorf("inbox card %d: %w", outputID, ErrOutputNotFound)
	}
	if err != nil {
		return p, fmt.Errorf("reading inbox card %d: %w", outputID, err)
	}
	return p, nil
}

// replyActionAt returns the Reply action at index of the card's flattened
// action list (FlattenStoredInboxActions).
func replyActionAt(p pressTarget, outputID int64, index int) (InboxAction, error) {
	card, err := decodeInboxActions(p.actions)
	if err != nil {
		return InboxAction{}, fmt.Errorf("inbox card %d: %w", outputID, err)
	}
	actions, err := FlattenStoredInboxActions(card, p.blocks)
	if err != nil {
		return InboxAction{}, fmt.Errorf("inbox card %d: %w", outputID, err)
	}
	if index < 0 || index >= len(actions) || actions[index].Kind != InboxActionReply {
		return InboxAction{}, fmt.Errorf("inbox card %d action %d: %w", outputID, index, ErrNotAReplyAction)
	}
	return actions[index], nil
}

// PressInboxOutputAction records the owner's one press of the Reply action
// at actionIndex of inbox card outputID's flattened action list and queues
// its trigger='reply' run, in one transaction. contentHash is the hash of
// the card the owner pressed on (empty skips the check: the CLI by hand, an
// older Desktop). Refusals, checked in this order, write nothing:
// ErrOutputNotFound, ErrOutputChanged (contentHash is not the row's),
// ErrOutputClosed (done or dismissed), ErrNotAReplyAction,
// *AlreadyPressedError for a card already pressed, and
// ErrOutputAutomationNotRunnable. The run's ReplyPayload is built from the
// stored row and carries the row's content_hash.
func (db *DB) PressInboxOutputAction(outputID int64, actionIndex int, contentHash string, now time.Time) (runID int64, err error) {
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
	if contentHash != "" && contentHash != p.contentHash {
		return 0, fmt.Errorf("inbox card %d: %w", outputID, ErrOutputChanged)
	}
	if err := pressRefusal(p, outputID); err != nil {
		return 0, err
	}
	action, err := replyActionAt(p, outputID, actionIndex)
	if err != nil {
		return 0, err
	}
	// Already pressed before not runnable: a pressed card whose automation
	// was later turned off or edited still reports its sent state.
	if p.pressed {
		return 0, &AlreadyPressedError{RunID: p.pressedRunID.Int64}
	}
	if !p.runnable {
		return 0, fmt.Errorf("inbox card %d: %w", outputID, ErrOutputAutomationNotRunnable)
	}

	data := action.Data
	if len(data) == 0 {
		data = json.RawMessage(`null`)
	}
	payload, err := json.Marshal(ReplyPayload{Reply: ReplyTrigger{OutputID: outputID, Action: actionIndex,
		Value: action.Reply, Data: data, Card: ReplyCard{Title: p.title, Link: p.link}, ContentHash: p.contentHash}})
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

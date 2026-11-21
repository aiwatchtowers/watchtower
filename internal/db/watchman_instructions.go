package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Watchman instructions (00211, tuning spec §2): the owner's own words for a
// handed session or target, kept apart from watchman_arming so Take back
// keeps them (D7). Written only by `watchman arm --instructions-file` and
// `watchman instruct`; the last write wins. The twin reads them only for an
// armed scope (WATCHMAN-04), and they never lift a hard limit (WATCHMAN-01).

// WatchmanInstructionMaxRunes caps a stored instruction (after the trim).
const WatchmanInstructionMaxRunes = 2000

// WatchmanInstruction is one stored instruction.
type WatchmanInstruction struct {
	Scope     string // session | target
	RefID     int64
	Text      string
	UpdatedAt string // RFC 3339 UTC
}

// ClipWatchmanInstruction trims text and clips it to
// WatchmanInstructionMaxRunes runes (trimmed again after the clip).
func ClipWatchmanInstruction(text string) string {
	text = strings.TrimSpace(text)
	if r := []rune(text); len(r) > WatchmanInstructionMaxRunes {
		text = strings.TrimSpace(string(r[:WatchmanInstructionMaxRunes]))
	}
	return text
}

// SetWatchmanInstruction stores the scope's text, trimmed and clipped; an
// empty text deletes the row.
func (db *DB) SetWatchmanInstruction(scope string, refID int64, text string) error {
	return db.WithTx(func(tx *sql.Tx) error { return SetWatchmanInstructionTx(tx, scope, refID, text) })
}

// SetWatchmanInstructionTx is SetWatchmanInstruction inside tx (`watchman
// arm` writes it with the arming row).
func SetWatchmanInstructionTx(tx *sql.Tx, scope string, refID int64, text string) error {
	text = ClipWatchmanInstruction(text)
	var err error
	if text == "" {
		_, err = tx.Exec(`DELETE FROM watchman_instructions WHERE scope = ? AND ref_id = ?`, scope, refID)
	} else {
		_, err = tx.Exec(`INSERT INTO watchman_instructions (scope, ref_id, text, updated_at) VALUES (?, ?, ?, ?)
			ON CONFLICT(scope, ref_id) DO UPDATE SET text = excluded.text, updated_at = excluded.updated_at`,
			scope, refID, text, time.Now().UTC().Format(time.RFC3339))
	}
	if err != nil {
		return fmt.Errorf("setting watchman instruction of %s %d: %w", scope, refID, err)
	}
	return nil
}

// WatchmanInstruction is the scope's stored text; "" when there is none.
func (db *DB) WatchmanInstruction(scope string, refID int64) (string, error) {
	var text string
	err := db.QueryRow(`SELECT text FROM watchman_instructions WHERE scope = ? AND ref_id = ?`, scope, refID).Scan(&text)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("reading watchman instruction of %s %d: %w", scope, refID, err)
	}
	return text, nil
}

// WatchmanSessionInstructions is the text of the armed target covering
// sessionID (the oldest-armed one whose subtree holds the session's ticket,
// as WatchmanSessionsUnderArmedTargets picks; "" when none covers it or it
// has no text) and the session's own text.
func (db *DB) WatchmanSessionInstructions(sessionID int64) (target, session string, err error) {
	err = db.QueryRow(`
		WITH RECURSIVE sub(root, id) AS (
			SELECT ref_id, ref_id FROM watchman_arming WHERE scope = 'target'
			UNION
			SELECT sub.root, t.id FROM targets t JOIN sub ON t.parent_id = sub.id
		),
		cover AS (
			SELECT sub.root AS root FROM terminal_sessions ts
			JOIN sub ON ts.target_id = sub.id
			JOIN watchman_arming a ON a.scope = 'target' AND a.ref_id = sub.root
			WHERE ts.id = ?1
			ORDER BY a.armed_at, sub.root LIMIT 1
		)
		SELECT
			COALESCE((SELECT i.text FROM watchman_instructions i JOIN cover ON i.scope = 'target' AND i.ref_id = cover.root), ''),
			COALESCE((SELECT text FROM watchman_instructions WHERE scope = 'session' AND ref_id = ?1), '')`,
		sessionID).Scan(&target, &session)
	if err != nil {
		return "", "", fmt.Errorf("reading watchman instructions of session %d: %w", sessionID, err)
	}
	return target, session, nil
}

// PruneWatchmanInstructions removes the instructions whose session or
// target is gone (a session being deleted counts as gone); n is how many
// went. A finished session keeps its text until its row goes.
func (db *DB) PruneWatchmanInstructions() (n int64, err error) {
	res, err := db.Exec(`DELETE FROM watchman_instructions WHERE
		(scope = 'session' AND NOT EXISTS (SELECT 1 FROM terminal_sessions ts
			WHERE ts.id = watchman_instructions.ref_id AND ts.` + NotDeletingSQL + `))
		OR (scope = 'target' AND NOT EXISTS (SELECT 1 FROM targets t WHERE t.id = watchman_instructions.ref_id))`)
	if err != nil {
		return 0, fmt.Errorf("pruning watchman instructions: %w", err)
	}
	return res.RowsAffected()
}

// ArmWatchmanInstructed is ArmWatchman and SetWatchmanInstruction on the
// same (scope, ref_id) in one transaction, so an arm never lands without
// the text the owner gave with it, nor the text without the arm.
func (db *DB) ArmWatchmanInstructed(a WatchmanArming, text string) (inserted bool, err error) {
	err = db.WithTx(func(tx *sql.Tx) error {
		res, err := tx.Exec(`INSERT INTO watchman_arming (scope, ref_id, armed_at, armed_by) VALUES (?, ?, ?, ?)
			ON CONFLICT(scope, ref_id) DO NOTHING`, a.Scope, a.RefID, wmArmTime(a.ArmedAt), a.ArmedBy)
		if err != nil {
			return fmt.Errorf("arming watchman %s %d: %w", a.Scope, a.RefID, err)
		}
		n, err := res.RowsAffected()
		if err != nil {
			return err
		}
		inserted = n > 0
		return SetWatchmanInstructionTx(tx, a.Scope, a.RefID, text)
	})
	return inserted, err
}

package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// InstructionField names one of the two owner-written instruction texts.
type InstructionField string

const (
	InstructionSession   InstructionField = "session"
	InstructionProcedure InstructionField = "procedure"
)

// OwnerInstructions holds both texts of one scope (global or one workbench);
// "" means none.
type OwnerInstructions struct{ Session, Procedure string }

func (f InstructionField) valid() bool { return f == InstructionSession || f == InstructionProcedure }

func instructionStamp(t time.Time) string { return t.UTC().Format(time.RFC3339) }

// GetOwnerInstructions returns the global instructions; a missing row is "".
func (db *DB) GetOwnerInstructions() (OwnerInstructions, error) {
	rows, err := db.Query(`SELECT scope, body FROM owner_instructions`)
	if err != nil {
		return OwnerInstructions{}, fmt.Errorf("reading owner instructions: %w", err)
	}
	defer rows.Close()
	var out OwnerInstructions
	for rows.Next() {
		var scope, body string
		if err := rows.Scan(&scope, &body); err != nil {
			return OwnerInstructions{}, fmt.Errorf("scanning owner instructions: %w", err)
		}
		switch InstructionField(scope) {
		case InstructionSession:
			out.Session = body
		case InstructionProcedure:
			out.Procedure = body
		}
	}
	if err := rows.Err(); err != nil {
		return OwnerInstructions{}, fmt.Errorf("reading owner instructions: %w", err)
	}
	return out, nil
}

// SetOwnerInstruction writes the global text of field f; "" deletes the row.
func (db *DB) SetOwnerInstruction(f InstructionField, body string) error {
	return db.WithTx(func(tx *sql.Tx) error { return setOwnerInstructionTx(tx, f, body) })
}

func setOwnerInstructionTx(tx *sql.Tx, f InstructionField, body string) error {
	if !f.valid() {
		return fmt.Errorf("unknown instruction field %q", f)
	}
	var err error
	if body == "" {
		_, err = tx.Exec(`DELETE FROM owner_instructions WHERE scope = ?`, string(f))
	} else {
		_, err = tx.Exec(`INSERT INTO owner_instructions (scope, body, updated_at)
			VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now'))
			ON CONFLICT(scope) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at`, string(f), body)
	}
	if err != nil {
		return fmt.Errorf("setting owner %s instruction: %w", f, err)
	}
	return nil
}

// GetWorkbenchInstructions returns workbench id's texts (NULL = ""), or
// ErrWorkbenchNotFound.
func (db *DB) GetWorkbenchInstructions(id int64) (OwnerInstructions, error) {
	var s, p sql.NullString
	err := db.QueryRow(`SELECT session_instructions, target_procedure FROM projects WHERE id = ?`, id).Scan(&s, &p)
	if errors.Is(err, sql.ErrNoRows) {
		return OwnerInstructions{}, fmt.Errorf("workbench %d: %w", id, ErrWorkbenchNotFound)
	}
	if err != nil {
		return OwnerInstructions{}, fmt.Errorf("reading workbench %d instructions: %w", id, err)
	}
	return OwnerInstructions{Session: s.String, Procedure: p.String}, nil
}

// SetWorkbenchInstruction writes one text of workbench id; "" stores NULL.
func (db *DB) SetWorkbenchInstruction(id int64, f InstructionField, body string) error {
	return db.WithTx(func(tx *sql.Tx) error { return setWorkbenchInstructionTx(tx, id, f, body) })
}

func setWorkbenchInstructionTx(tx *sql.Tx, id int64, f InstructionField, body string) error {
	if !f.valid() {
		return fmt.Errorf("unknown instruction field %q", f)
	}
	query := `UPDATE projects SET target_procedure = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`
	if f == InstructionSession {
		query = `UPDATE projects SET session_instructions = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`
	}
	res, err := tx.Exec(query, methodologyValue(body), id)
	if err != nil {
		return fmt.Errorf("setting workbench %d %s instruction: %w", id, f, err)
	}
	return requireAffected(res, fmt.Errorf("workbench %d: %w", id, ErrWorkbenchNotFound))
}

// InstructionSuggestion is one mined repeat the owner can add to the
// instructions or dismiss. WorkbenchID is NULL for a global suggestion.
type InstructionSuggestion struct {
	ID                           int64
	Text                         string
	Field                        InstructionField
	WorkbenchID                  sql.NullInt64
	SessionCount, WorkbenchCount int
	FirstSeenAt, LastSeenAt      string
	Status, Fingerprint          string
}

const instructionSuggestionCols = `id, text, field, workbench_id, session_count, workbench_count,
	first_seen_at, last_seen_at, status, fingerprint`

func scanInstructionSuggestion(sc interface{ Scan(...any) error }) (InstructionSuggestion, error) {
	var s InstructionSuggestion
	var field string
	err := sc.Scan(&s.ID, &s.Text, &field, &s.WorkbenchID, &s.SessionCount, &s.WorkbenchCount,
		&s.FirstSeenAt, &s.LastSeenAt, &s.Status, &s.Fingerprint)
	s.Field = InstructionField(field)
	return s, err
}

// UpsertInstructionSuggestion inserts s as open, or refreshes the text, counts
// and last_seen_at of the open row with the same fingerprint. An added or
// dismissed row is left untouched.
func (db *DB) UpsertInstructionSuggestion(s InstructionSuggestion, now time.Time) error {
	if !s.Field.valid() {
		return fmt.Errorf("unknown instruction field %q", s.Field)
	}
	ts := instructionStamp(now)
	_, err := db.Exec(`INSERT INTO instruction_suggestions
		(text, field, workbench_id, session_count, workbench_count, first_seen_at, last_seen_at, status, fingerprint)
		VALUES (?, ?, ?, ?, ?, ?, ?, 'open', ?)
		ON CONFLICT(fingerprint) DO UPDATE SET text = excluded.text,
			session_count = excluded.session_count, workbench_count = excluded.workbench_count,
			last_seen_at = excluded.last_seen_at
		WHERE instruction_suggestions.status = 'open'`,
		s.Text, string(s.Field), s.WorkbenchID, s.SessionCount, s.WorkbenchCount, ts, ts, s.Fingerprint)
	if err != nil {
		return fmt.Errorf("upserting instruction suggestion: %w", err)
	}
	return nil
}

// ListOpenInstructionSuggestions returns the open suggestions, newest first.
func (db *DB) ListOpenInstructionSuggestions() ([]InstructionSuggestion, error) {
	rows, err := db.Query(`SELECT ` + instructionSuggestionCols + ` FROM instruction_suggestions
		WHERE status = 'open' ORDER BY first_seen_at DESC, id DESC`)
	if err != nil {
		return nil, fmt.Errorf("listing instruction suggestions: %w", err)
	}
	defer rows.Close()
	var out []InstructionSuggestion
	for rows.Next() {
		s, err := scanInstructionSuggestion(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning instruction suggestion: %w", err)
		}
		out = append(out, s)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing instruction suggestions: %w", err)
	}
	return out, nil
}

// ListInstructionSuggestionFingerprints maps every stored fingerprint to its
// status, whatever the status.
func (db *DB) ListInstructionSuggestionFingerprints() (map[string]string, error) {
	rows, err := db.Query(`SELECT fingerprint, status FROM instruction_suggestions`)
	if err != nil {
		return nil, fmt.Errorf("listing suggestion fingerprints: %w", err)
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var fp, st string
		if err := rows.Scan(&fp, &st); err != nil {
			return nil, fmt.Errorf("scanning suggestion fingerprint: %w", err)
		}
		out[fp] = st
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing suggestion fingerprints: %w", err)
	}
	return out, nil
}

// GetInstructionSuggestion returns suggestion id or an error wrapping
// sql.ErrNoRows.
func (db *DB) GetInstructionSuggestion(id int64) (InstructionSuggestion, error) {
	s, err := scanInstructionSuggestion(db.QueryRow(`SELECT `+instructionSuggestionCols+
		` FROM instruction_suggestions WHERE id = ?`, id))
	if err != nil {
		return InstructionSuggestion{}, fmt.Errorf("instruction suggestion %d: %w", id, err)
	}
	return s, nil
}

// DecideInstructionSuggestion marks an open suggestion "added" or "dismissed".
func (db *DB) DecideInstructionSuggestion(id int64, status string, now time.Time) error {
	return db.WithTx(func(tx *sql.Tx) error { return decideInstructionSuggestionTx(tx, id, status, now) })
}

func decideInstructionSuggestionTx(tx *sql.Tx, id int64, status string, now time.Time) error {
	if status != "added" && status != "dismissed" {
		return fmt.Errorf("instruction suggestion status must be added or dismissed, got %q", status)
	}
	res, err := tx.Exec(`UPDATE instruction_suggestions SET status = ?, decided_at = ?
		WHERE id = ? AND status = 'open'`, status, instructionStamp(now), id)
	if err != nil {
		return fmt.Errorf("deciding instruction suggestion %d: %w", id, err)
	}
	return requireAffected(res, fmt.Errorf("instruction suggestion %d is not open or does not exist", id))
}

// AddInstructionSuggestion writes newBody to the suggestion's field in its scope
// (global or its workbench) and marks it added, in one transaction. It errors
// when the suggestion is not open.
func (db *DB) AddInstructionSuggestion(id int64, newBody string, now time.Time) error {
	return db.WithTx(func(tx *sql.Tx) error {
		var field string
		var wb sql.NullInt64
		err := tx.QueryRow(`SELECT field, workbench_id FROM instruction_suggestions
			WHERE id = ? AND status = 'open'`, id).Scan(&field, &wb)
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("instruction suggestion %d is not open or does not exist", id)
		}
		if err != nil {
			return fmt.Errorf("reading instruction suggestion %d: %w", id, err)
		}
		if wb.Valid {
			err = setWorkbenchInstructionTx(tx, wb.Int64, InstructionField(field), newBody)
		} else {
			err = setOwnerInstructionTx(tx, InstructionField(field), newBody)
		}
		if err != nil {
			return err
		}
		return decideInstructionSuggestionTx(tx, id, "added", now)
	})
}

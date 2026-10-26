package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"
)

// InstructionField names one of the two owner-written instruction texts.
type InstructionField string

const (
	InstructionSession   InstructionField = "session"
	InstructionProcedure InstructionField = "procedure"
	InstructionChat      InstructionField = "chat"
)

// OwnerInstructions holds the texts of one scope (global or one workbench);
// "" means none. Chat exists only globally.
type OwnerInstructions struct{ Session, Procedure, Chat string }

func (f InstructionField) valid() bool {
	return f == InstructionSession || f == InstructionProcedure || f == InstructionChat
}

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
		case InstructionChat:
			out.Chat = body
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
	if !f.valid() || f == InstructionChat {
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

// SwapOwnerInstruction sets the global text of field f to body only while it
// is still before ("" = no row), in one statement; false when it was not.
func (db *DB) SwapOwnerInstruction(f InstructionField, before, body string) (bool, error) {
	if !f.valid() {
		return false, fmt.Errorf("unknown instruction field %q", f)
	}
	var res sql.Result
	var err error
	switch {
	case before == body:
		var same bool
		err = db.QueryRow(`SELECT COALESCE((SELECT body FROM owner_instructions WHERE scope = ?), '') = ?`,
			string(f), before).Scan(&same)
		if err != nil {
			return false, fmt.Errorf("reading owner %s instruction: %w", f, err)
		}
		return same, nil
	case before == "":
		res, err = db.Exec(`INSERT INTO owner_instructions (scope, body, updated_at)
			VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now'))
			ON CONFLICT(scope) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at
			WHERE owner_instructions.body = ''`, string(f), body)
	case body == "":
		res, err = db.Exec(`DELETE FROM owner_instructions WHERE scope = ? AND body = ?`, string(f), before)
	default:
		res, err = db.Exec(`UPDATE owner_instructions SET body = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
			WHERE scope = ? AND body = ?`, body, string(f), before)
	}
	return swapped(res, err, fmt.Sprintf("setting owner %s instruction", f))
}

// SwapWorkbenchInstruction sets one text of workbench id to body only while
// it is still before ("" = NULL), in one statement; false when it was not.
func (db *DB) SwapWorkbenchInstruction(id int64, f InstructionField, before, body string) (bool, error) {
	if !f.valid() || f == InstructionChat {
		return false, fmt.Errorf("unknown instruction field %q", f)
	}
	col := "target_procedure"
	if f == InstructionSession {
		col = "session_instructions"
	}
	res, err := db.Exec(`UPDATE projects SET `+col+` = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ? AND COALESCE(`+col+`, '') = ?`, methodologyValue(body), id, before)
	return swapped(res, err, fmt.Sprintf("setting workbench %d %s instruction", id, f))
}

func swapped(res sql.Result, err error, what string) (bool, error) {
	if err != nil {
		return false, fmt.Errorf("%s: %w", what, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("%s: %w", what, err)
	}
	return n > 0, nil
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

// UpsertInstructionSuggestion inserts s as open, or refreshes the text, field,
// scope (workbench_id), counts and last_seen_at of the open row with the same
// fingerprint. An added or
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
			field = excluded.field, workbench_id = excluded.workbench_id,
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

// ListInstructionSuggestionTexts returns the texts of the suggestions in
// status, oldest first.
func (db *DB) ListInstructionSuggestionTexts(status string) ([]string, error) {
	rows, err := db.Query(`SELECT text FROM instruction_suggestions WHERE status = ? ORDER BY id`, status)
	if err != nil {
		return nil, fmt.Errorf("listing %s suggestion texts: %w", status, err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return nil, fmt.Errorf("scanning %s suggestion text: %w", status, err)
		}
		out = append(out, s)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing %s suggestion texts: %w", status, err)
	}
	return out, nil
}

// InstructionChatLine is one line a "remember:" chat message appended to the
// chat instructions. ConversationID and MessageID are NULL-able: the chat rows
// they name may be deleted later.
type InstructionChatLine struct {
	ID                        int64
	Line                      string
	ConversationID, MessageID sql.NullInt64
	AddedAt                   string
}

// RememberOutcome is the result of RememberChatLine.
type RememberOutcome string

const (
	RememberAdded          RememberOutcome = "added"
	RememberAlreadyPresent RememberOutcome = "already_present"
	RememberTooLong        RememberOutcome = "too_long"
)

const chatLineCols = `id, line, conversation_id, message_id, added_at`

func scanChatLine(sc interface{ Scan(...any) error }) (InstructionChatLine, error) {
	var l InstructionChatLine
	err := sc.Scan(&l.ID, &l.Line, &l.ConversationID, &l.MessageID, &l.AddedAt)
	return l, err
}

func readChatTextTx(tx *sql.Tx) (string, error) {
	var body string
	err := tx.QueryRow(`SELECT body FROM owner_instructions WHERE scope = 'chat'`).Scan(&body)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("reading chat instructions: %w", err)
	}
	return body, nil
}

func hasChatLine(text, line string) bool {
	want := strings.TrimSpace(line)
	for _, l := range strings.Split(text, "\n") {
		if strings.TrimSpace(l) == want {
			return true
		}
	}
	return false
}

// RememberChatLine appends line to the chat instructions and records it in the
// ledger, in one transaction. A line already present (trimmed) is not written;
// an append that would leave the text over limit runes (surrounding space not
// counted) is refused. limit is passed in because internal/instructions
// imports internal/db.
func (db *DB) RememberChatLine(line string, conversationID, messageID int64, now time.Time, limit int) (InstructionChatLine, RememberOutcome, error) {
	var row InstructionChatLine
	outcome := RememberAdded
	err := db.WithTx(func(tx *sql.Tx) error {
		text, err := readChatTextTx(tx)
		if err != nil {
			return err
		}
		if hasChatLine(text, line) {
			outcome = RememberAlreadyPresent
			return nil
		}
		next := strings.TrimSpace(line)
		if strings.TrimSpace(text) != "" {
			next = strings.TrimSpace(text) + "\n" + next
		}
		if utf8.RuneCountInString(next) > limit {
			outcome = RememberTooLong
			return nil
		}
		if err := setOwnerInstructionTx(tx, InstructionChat, next); err != nil {
			return err
		}
		stamp := instructionStamp(now)
		res, err := tx.Exec(`INSERT INTO instruction_chat_lines (line, conversation_id, message_id, added_at)
			VALUES (?, ?, ?, ?)`, strings.TrimSpace(line), conversationID, messageID, stamp)
		if err != nil {
			return fmt.Errorf("recording chat line: %w", err)
		}
		id, err := res.LastInsertId()
		if err != nil {
			return fmt.Errorf("recording chat line: %w", err)
		}
		row = InstructionChatLine{ID: id, Line: strings.TrimSpace(line),
			ConversationID: sql.NullInt64{Int64: conversationID, Valid: true},
			MessageID:      sql.NullInt64{Int64: messageID, Valid: true}, AddedAt: stamp}
		return nil
	})
	if err != nil {
		return InstructionChatLine{}, "", err
	}
	return row, outcome, nil
}

// ForgetChatLine deletes ledger row id and removes the first trimmed line equal
// to its line from the chat instructions. removed is false when the owner
// already edited the line away. An unknown id wraps sql.ErrNoRows.
func (db *DB) ForgetChatLine(id int64, now time.Time) (removed bool, err error) {
	_ = now
	err = db.WithTx(func(tx *sql.Tx) error {
		var line string
		if err := tx.QueryRow(`SELECT line FROM instruction_chat_lines WHERE id = ?`, id).Scan(&line); err != nil {
			return fmt.Errorf("chat line %d: %w", id, err)
		}
		if _, err := tx.Exec(`DELETE FROM instruction_chat_lines WHERE id = ?`, id); err != nil {
			return fmt.Errorf("deleting chat line %d: %w", id, err)
		}
		text, err := readChatTextTx(tx)
		if err != nil {
			return err
		}
		lines := strings.Split(text, "\n")
		want := strings.TrimSpace(line)
		for i, l := range lines {
			if strings.TrimSpace(l) == want {
				rest := append(append([]string{}, lines[:i]...), lines[i+1:]...)
				removed = true
				return setOwnerInstructionTx(tx, InstructionChat, strings.TrimSpace(strings.Join(rest, "\n")))
			}
		}
		return nil
	})
	if err != nil {
		return false, err
	}
	return removed, nil
}

// ListPresentChatLines returns the ledger rows whose line is still a trimmed
// line of the chat instructions, newest first.
func (db *DB) ListPresentChatLines() ([]InstructionChatLine, error) {
	var text string
	err := db.QueryRow(`SELECT body FROM owner_instructions WHERE scope = 'chat'`).Scan(&text)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("reading chat instructions: %w", err)
	}
	rows, err := db.Query(`SELECT ` + chatLineCols + ` FROM instruction_chat_lines ORDER BY id DESC`)
	if err != nil {
		return nil, fmt.Errorf("listing chat lines: %w", err)
	}
	defer rows.Close()
	var out []InstructionChatLine
	for rows.Next() {
		l, err := scanChatLine(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning chat line: %w", err)
		}
		if hasChatLine(text, l.Line) {
			out = append(out, l)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing chat lines: %w", err)
	}
	return out, nil
}

// ChatLinesForMessages returns the ledger rows recorded for the given chat
// message ids, oldest first.
func (db *DB) ChatLinesForMessages(ids []int64) ([]InstructionChatLine, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	args := make([]any, len(ids))
	for i, id := range ids {
		args[i] = id
	}
	rows, err := db.Query(`SELECT `+chatLineCols+` FROM instruction_chat_lines
		WHERE message_id IN (?`+strings.Repeat(",?", len(ids)-1)+`) ORDER BY id`, args...)
	if err != nil {
		return nil, fmt.Errorf("listing chat lines for messages: %w", err)
	}
	defer rows.Close()
	var out []InstructionChatLine
	for rows.Next() {
		l, err := scanChatLine(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning chat line: %w", err)
		}
		out = append(out, l)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing chat lines for messages: %w", err)
	}
	return out, nil
}

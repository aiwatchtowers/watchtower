package db

import (
	"database/sql"
	"errors"
	"fmt"
)

var ErrTerminalSessionNotFound = errors.New("terminal session not found")

// TerminalSession is the slice of a terminal_sessions row Go reads; the
// Desktop owns every other column.
type TerminalSession struct {
	ID              int64
	ProjectID       sql.NullInt64
	Kind            string
	Title           string
	TitleSource     string
	FolderPath      string
	ClaudeSessionID sql.NullString
}

func (db *DB) GetTerminalSession(id int64) (*TerminalSession, error) {
	var s TerminalSession
	err := db.QueryRow(`SELECT id, project_id, kind, title, title_source, folder_path, claude_session_id
		FROM terminal_sessions WHERE id = ?`, id).
		Scan(&s.ID, &s.ProjectID, &s.Kind, &s.Title, &s.TitleSource, &s.FolderPath, &s.ClaudeSessionID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrTerminalSessionNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("reading terminal session %d: %w", id, err)
	}
	return &s, nil
}

// SetTerminalSessionAITitle stores an AI title only over a provisional one:
// an owner rename ('user') and an earlier AI title ('ai') are kept.
func (db *DB) SetTerminalSessionAITitle(id int64, title string) (bool, error) {
	res, err := db.Exec(`UPDATE terminal_sessions SET title = ?, title_source = 'ai'
		WHERE id = ? AND title_source = 'auto'`, title, id)
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d title: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d title: %w", id, err)
	}
	return n > 0, nil
}

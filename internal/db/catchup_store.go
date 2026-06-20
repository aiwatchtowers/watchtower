package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// CatchupSession represents one Catch-Up v2 review run.
type CatchupSession struct {
	ID            int64
	CreatedAt     string
	Status        string
	OldestUnread  string
	TotalThemes   int
	ReviewedCount int
}

// CatchupRef points at a single unread source item driving a theme's cascade.
type CatchupRef struct {
	Area  string `json:"area"`
	ID    int    `json:"id"`
	Label string `json:"label"`
}

// CatchupTheme is one cross-source theme, persisted incrementally as fan-out
// expansion completes.
type CatchupTheme struct {
	ID, SessionID                                                 int64
	OrderIdx                                                      int
	Title, Narrative, Priority                                    string
	NeedsYou                                                      bool
	SuggestedAction, RefsJSON, GenState, ReviewState, SnoozeUntil string
	TaskID                                                        int64
	CreatedAt, UpdatedAt                                          string
}

// CreateCatchupSession inserts a new session in status='building' and returns its id.
func (db *DB) CreateCatchupSession(oldestUnread string) (int64, error) {
	now := time.Now().UTC().Format(time.RFC3339)
	res, err := db.Exec(`
		INSERT INTO catchup_sessions (created_at, status, oldest_unread)
		VALUES (?, 'building', ?)
	`, now, oldestUnread)
	if err != nil {
		return 0, fmt.Errorf("creating catchup session: %w", err)
	}
	return res.LastInsertId()
}

// SetCatchupSessionStatus updates a session's status.
func (db *DB) SetCatchupSessionStatus(id int64, status string) error {
	_, err := db.Exec(`UPDATE catchup_sessions SET status=? WHERE id=?`, status, id)
	if err != nil {
		return fmt.Errorf("setting catchup session status: %w", err)
	}
	return nil
}

// SetCatchupSessionTotals records the theme count produced by the outline phase.
func (db *DB) SetCatchupSessionTotals(id int64, totalThemes int) error {
	_, err := db.Exec(`UPDATE catchup_sessions SET total_themes=? WHERE id=?`, totalThemes, id)
	if err != nil {
		return fmt.Errorf("setting catchup session totals: %w", err)
	}
	return nil
}

// IncrementReviewed bumps the session's reviewed_count by one.
func (db *DB) IncrementReviewed(sessionID int64) error {
	_, err := db.Exec(`UPDATE catchup_sessions SET reviewed_count = reviewed_count + 1 WHERE id=?`, sessionID)
	if err != nil {
		return fmt.Errorf("incrementing reviewed count: %w", err)
	}
	return nil
}

// GetActiveCatchupSession returns the newest session that is not done/failed,
// or nil when there is none.
func (db *DB) GetActiveCatchupSession() (*CatchupSession, error) {
	var s CatchupSession
	err := db.QueryRow(`
		SELECT id, created_at, status, oldest_unread, total_themes, reviewed_count
		FROM catchup_sessions
		WHERE status NOT IN ('done','failed')
		ORDER BY id DESC LIMIT 1
	`).Scan(&s.ID, &s.CreatedAt, &s.Status, &s.OldestUnread, &s.TotalThemes, &s.ReviewedCount)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("getting active catchup session: %w", err)
	}
	return &s, nil
}

// InsertCatchupTheme inserts a skeleton theme row and returns its id. Defaults
// are applied for empty priority/gen_state so callers may pass partial rows.
func (db *DB) InsertCatchupTheme(t CatchupTheme) (int64, error) {
	now := time.Now().UTC().Format(time.RFC3339)
	priority := t.Priority
	if priority == "" {
		priority = "medium"
	}
	genState := t.GenState
	if genState == "" {
		genState = "skeleton"
	}
	refs := t.RefsJSON
	if refs == "" {
		refs = "[]"
	}
	res, err := db.Exec(`
		INSERT INTO catchup_themes
			(session_id, order_idx, title, narrative, priority, needs_you,
			 suggested_action, refs, gen_state, review_state, snooze_until,
			 task_id, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', '', 0, ?, ?)
	`, t.SessionID, t.OrderIdx, t.Title, t.Narrative, priority, boolToInt(t.NeedsYou),
		t.SuggestedAction, refs, genState, now, now)
	if err != nil {
		return 0, fmt.Errorf("inserting catchup theme: %w", err)
	}
	return res.LastInsertId()
}

// UpdateCatchupThemeExpansion writes the expand-phase output for one theme.
func (db *DB) UpdateCatchupThemeExpansion(id int64, narrative, priority string, needsYou bool, suggestedAction, genState string) error {
	now := time.Now().UTC().Format(time.RFC3339)
	_, err := db.Exec(`
		UPDATE catchup_themes
		SET narrative=?, priority=?, needs_you=?, suggested_action=?, gen_state=?, updated_at=?
		WHERE id=?
	`, narrative, priority, boolToInt(needsYou), suggestedAction, genState, now, id)
	if err != nil {
		return fmt.Errorf("updating catchup theme expansion: %w", err)
	}
	return nil
}

// GetCatchupTheme returns a single theme by id.
func (db *DB) GetCatchupTheme(id int64) (*CatchupTheme, error) {
	var t CatchupTheme
	var needsYou int
	err := db.QueryRow(`
		SELECT id, session_id, order_idx, title, narrative, priority, needs_you,
		       suggested_action, refs, gen_state, review_state, snooze_until,
		       task_id, created_at, updated_at
		FROM catchup_themes WHERE id=?
	`, id).Scan(&t.ID, &t.SessionID, &t.OrderIdx, &t.Title, &t.Narrative, &t.Priority,
		&needsYou, &t.SuggestedAction, &t.RefsJSON, &t.GenState, &t.ReviewState,
		&t.SnoozeUntil, &t.TaskID, &t.CreatedAt, &t.UpdatedAt)
	if err != nil {
		return nil, fmt.Errorf("getting catchup theme: %w", err)
	}
	t.NeedsYou = needsYou != 0
	return &t, nil
}

// ListCatchupThemes returns all themes for a session ordered by order_idx.
func (db *DB) ListCatchupThemes(sessionID int64) ([]CatchupTheme, error) {
	rows, err := db.Query(`
		SELECT id, session_id, order_idx, title, narrative, priority, needs_you,
		       suggested_action, refs, gen_state, review_state, snooze_until,
		       task_id, created_at, updated_at
		FROM catchup_themes WHERE session_id=?
		ORDER BY order_idx, id
	`, sessionID)
	if err != nil {
		return nil, fmt.Errorf("listing catchup themes: %w", err)
	}
	defer rows.Close()
	var out []CatchupTheme
	for rows.Next() {
		var t CatchupTheme
		var needsYou int
		if err := rows.Scan(&t.ID, &t.SessionID, &t.OrderIdx, &t.Title, &t.Narrative,
			&t.Priority, &needsYou, &t.SuggestedAction, &t.RefsJSON, &t.GenState,
			&t.ReviewState, &t.SnoozeUntil, &t.TaskID, &t.CreatedAt, &t.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scanning catchup theme: %w", err)
		}
		t.NeedsYou = needsYou != 0
		out = append(out, t)
	}
	return out, rows.Err()
}

// SetCatchupThemeReview updates a theme's review_state and snooze_until.
func (db *DB) SetCatchupThemeReview(id int64, reviewState, snoozeUntil string) error {
	now := time.Now().UTC().Format(time.RFC3339)
	_, err := db.Exec(`
		UPDATE catchup_themes SET review_state=?, snooze_until=?, updated_at=? WHERE id=?
	`, reviewState, snoozeUntil, now, id)
	if err != nil {
		return fmt.Errorf("setting catchup theme review: %w", err)
	}
	return nil
}

// SetCatchupThemeTask links a theme to a created target.
func (db *DB) SetCatchupThemeTask(id int64, taskID int64) error {
	now := time.Now().UTC().Format(time.RFC3339)
	_, err := db.Exec(`UPDATE catchup_themes SET task_id=?, updated_at=? WHERE id=?`, taskID, now, id)
	if err != nil {
		return fmt.Errorf("setting catchup theme task: %w", err)
	}
	return nil
}

// CloseOpenCatchupSessions marks any building/active session as done. Called
// before starting a new run so only one session is ever active at a time.
func (db *DB) CloseOpenCatchupSessions() error {
	_, err := db.Exec(`UPDATE catchup_sessions SET status='done' WHERE status IN ('building','active')`)
	if err != nil {
		return fmt.Errorf("closing open catchup sessions: %w", err)
	}
	return nil
}

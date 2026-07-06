package db

import "fmt"

// situationSelectCols is the standard SELECT column list for situations.
const situationSelectCols = `id, title, kind, status, snooze_until, priority, rank,
	ai_reason, summary, why_matters, chronology, card_status, COALESCE(card_generated_at,''),
	target_id, track_id, converted_target_id, converted_track_id,
	last_signal_at, resolved_reason, created_at, updated_at`

// scanSituation scans a Situation from a row with situationSelectCols.
func scanSituation(row interface{ Scan(...any) error }) (*DashboardSituation, error) {
	var s DashboardSituation
	if err := row.Scan(
		&s.ID, &s.Title, &s.Kind, &s.Status, &s.SnoozeUntil, &s.Priority, &s.Rank,
		&s.AIReason, &s.Summary, &s.WhyMatters, &s.Chronology, &s.CardStatus, &s.CardGeneratedAt,
		&s.TargetID, &s.TrackID, &s.ConvertedTargetID, &s.ConvertedTrackID,
		&s.LastSignalAt, &s.ResolvedReason, &s.CreatedAt, &s.UpdatedAt,
	); err != nil {
		return nil, err
	}
	return &s, nil
}

// CreateSituation inserts a new situation and returns its ID.
func (db *DB) CreateSituation(s DashboardSituation) (int64, error) {
	if s.Status == "" {
		s.Status = "open"
	}
	if s.Priority == "" {
		s.Priority = "medium"
	}
	if s.Kind == "" {
		s.Kind = "external"
	}
	if s.CardStatus == "" {
		s.CardStatus = "none"
	}
	now := "strftime('%Y-%m-%dT%H:%M:%SZ', 'now')"
	res, err := db.Exec(`INSERT INTO situations (title, kind, status, priority, rank, ai_reason,
		summary, why_matters, chronology, card_status, target_id, track_id, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, `+now+`, `+now+`)`,
		s.Title, s.Kind, s.Status, s.Priority, s.Rank, s.AIReason,
		s.Summary, s.WhyMatters, s.Chronology, s.CardStatus, s.TargetID, s.TrackID,
	)
	if err != nil {
		return 0, fmt.Errorf("inserting situation: %w", err)
	}
	return res.LastInsertId()
}

// GetSituation returns a single situation by ID.
func (db *DB) GetSituation(id int) (DashboardSituation, error) {
	row := db.QueryRow(`SELECT `+situationSelectCols+` FROM situations WHERE id = ?`, id)
	s, err := scanSituation(row)
	if err != nil {
		return DashboardSituation{}, fmt.Errorf("getting situation %d: %w", id, err)
	}
	return *s, nil
}

// ListOpenSituations returns all open situations, highest rank first.
func (db *DB) ListOpenSituations() ([]DashboardSituation, error) {
	rows, err := db.Query(`SELECT ` + situationSelectCols + ` FROM situations
		WHERE status = 'open' ORDER BY rank DESC, updated_at DESC`)
	if err != nil {
		return nil, fmt.Errorf("listing open situations: %w", err)
	}
	defer rows.Close()

	var out []DashboardSituation
	for rows.Next() {
		s, err := scanSituation(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning situation: %w", err)
		}
		out = append(out, *s)
	}
	return out, rows.Err()
}

// AddSituationSignals attaches inbox items to a situation as signals
// (INSERT OR IGNORE, so re-adding an already-attached item is a no-op) and
// bumps the situation's last_signal_at/updated_at timestamps.
func (db *DB) AddSituationSignals(situationID int, inboxItemIDs []int) error {
	if len(inboxItemIDs) == 0 {
		return nil
	}
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("beginning tx for situation signals: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck

	for _, itemID := range inboxItemIDs {
		if _, err := tx.Exec(`INSERT OR IGNORE INTO situation_signals (situation_id, inbox_item_id) VALUES (?, ?)`,
			situationID, itemID); err != nil {
			return fmt.Errorf("adding signal %d to situation %d: %w", itemID, situationID, err)
		}
	}
	if _, err := tx.Exec(`UPDATE situations SET
		last_signal_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE id = ?`, situationID); err != nil {
		return fmt.Errorf("touching situation %d: %w", situationID, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing situation signals: %w", err)
	}
	return nil
}

// ListSituationSignals returns the inbox items attached to a situation,
// ordered chronologically (oldest first) for chronology rendering.
func (db *DB) ListSituationSignals(situationID int) ([]InboxItem, error) {
	rows, err := db.Query(`SELECT `+inboxSelectCols+` FROM inbox_items
		JOIN situation_signals ss ON ss.inbox_item_id = inbox_items.id
		WHERE ss.situation_id = ?
		ORDER BY inbox_items.message_ts ASC`, situationID)
	if err != nil {
		return nil, fmt.Errorf("listing situation %d signals: %w", situationID, err)
	}
	defer rows.Close()
	return scanInboxItems(rows)
}

package db

import (
	"database/sql"
	"fmt"
	"time"
)

// situationsExecer is the subset of *sql.DB / *sql.Tx used by the situation
// mutation helpers below, so the same statement logic can run auto-committed
// against the pool (the existing single-call methods) or as part of a
// caller-supplied transaction (the compose apply loop in internal/inbox,
// which needs the whole post-parse mutation block to commit atomically —
// DASH-02).
type situationsExecer interface {
	Exec(query string, args ...any) (sql.Result, error)
}

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
	return createSituationOn(db, s)
}

// CreateSituationTx is the transactional variant of CreateSituation, for
// callers (the compose apply loop) that need it to commit atomically with
// other mutations from the same pass.
func (db *DB) CreateSituationTx(tx *sql.Tx, s DashboardSituation) (int64, error) {
	return createSituationOn(tx, s)
}

func createSituationOn(q situationsExecer, s DashboardSituation) (int64, error) {
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
	res, err := q.Exec(`INSERT INTO situations (title, kind, status, priority, rank, ai_reason,
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

	if err := addSituationSignalsOn(tx, situationID, inboxItemIDs); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing situation signals: %w", err)
	}
	return nil
}

// AddSituationSignalsTx is the transactional variant of AddSituationSignals,
// for callers (the compose apply loop) that already hold an open tx spanning
// multiple mutations from the same pass.
func (db *DB) AddSituationSignalsTx(tx *sql.Tx, situationID int, inboxItemIDs []int) error {
	return addSituationSignalsOn(tx, situationID, inboxItemIDs)
}

func addSituationSignalsOn(q situationsExecer, situationID int, inboxItemIDs []int) error {
	if len(inboxItemIDs) == 0 {
		return nil
	}
	for _, itemID := range inboxItemIDs {
		if _, err := q.Exec(`INSERT OR IGNORE INTO situation_signals (situation_id, inbox_item_id) VALUES (?, ?)`,
			situationID, itemID); err != nil {
			return fmt.Errorf("adding signal %d to situation %d: %w", itemID, situationID, err)
		}
	}
	if _, err := q.Exec(`UPDATE situations SET
		last_signal_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE id = ?`, situationID); err != nil {
		return fmt.Errorf("touching situation %d: %w", situationID, err)
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

// ---- Compose inputs (Task 4's composer feeds off these) ----

// ListUncomposedSignals returns pending inbox items not yet folded into a
// situation by the composer, oldest first, capped at limit.
func (db *DB) ListUncomposedSignals(limit int) ([]InboxItem, error) {
	if limit <= 0 {
		limit = 100
	}
	rows, err := db.Query(`SELECT `+inboxSelectCols+` FROM inbox_items
		WHERE status = 'pending' AND composed_at IS NULL
		ORDER BY created_at ASC LIMIT ?`, limit)
	if err != nil {
		return nil, fmt.Errorf("listing uncomposed signals: %w", err)
	}
	defer rows.Close()
	return scanInboxItems(rows)
}

// MarkSignalsComposed sets composed_at on the given inbox items so the
// composer doesn't reprocess them on the next run.
func (db *DB) MarkSignalsComposed(ids []int) error {
	return markSignalsComposedOn(db, ids)
}

// MarkSignalsComposedTx is the transactional variant of MarkSignalsComposed,
// for callers (the compose apply loop) that need it to commit atomically
// with the rest of that pass's mutations.
func (db *DB) MarkSignalsComposedTx(tx *sql.Tx, ids []int) error {
	return markSignalsComposedOn(tx, ids)
}

func markSignalsComposedOn(q situationsExecer, ids []int) error {
	if len(ids) == 0 {
		return nil
	}
	args := append([]any{}, intArgs(ids)...)
	_, err := q.Exec(`UPDATE inbox_items SET composed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE id IN (`+placeholders(len(ids))+`)`, args...)
	if err != nil {
		return fmt.Errorf("marking signals composed: %w", err)
	}
	return nil
}

// ListTrackEventsSince returns track_events created strictly after ts
// (ISO8601 string compare), restricted to non-dismissed tracks, oldest first.
func (db *DB) ListTrackEventsSince(ts string) ([]TrackEvent, error) {
	rows, err := db.Query(`SELECT te.id, te.track_id, te.summary, te.detail, te.source_type, te.source_id,
		te.source_refs, te.decision, te.proposed_action, te.action_status, COALESCE(te.read_at,''), te.created_at
		FROM track_events te
		JOIN tracks t ON t.id = te.track_id
		WHERE te.created_at > ? AND t.dismissed_at = ''
		ORDER BY te.created_at ASC`, ts)
	if err != nil {
		return nil, fmt.Errorf("listing track events since %q: %w", ts, err)
	}
	defer rows.Close()

	var out []TrackEvent
	for rows.Next() {
		e, err := scanTrackEvent(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning track event: %w", err)
		}
		out = append(out, *e)
	}
	return out, rows.Err()
}

// ListTargetsUpdatedSince returns active targets (todo|in_progress|blocked|snoozed)
// whose updated_at is strictly after ts (ISO8601 string compare), excluding
// targets that are the conversion product of a situation converted within
// the same window. Creating a target from a situation bumps the target's
// updated_at, but that creation is not "subsequent activity" on the target —
// composing it right back into a target_update situation about its own birth
// would read as duplication. A later, genuine update to the target still
// surfaces normally, because the owning situation's updated_at doesn't move
// again after the conversion.
func (db *DB) ListTargetsUpdatedSince(ts string) ([]Target, error) {
	rows, err := db.Query(`SELECT `+targetSelectCols+` FROM targets t
		WHERE t.status IN ('todo','in_progress','blocked','snoozed') AND t.updated_at > ?
		  AND t.id NOT IN (
		      SELECT converted_target_id FROM situations
		      WHERE status = 'converted' AND converted_target_id IS NOT NULL
		        AND updated_at > ?
		  )
		ORDER BY t.updated_at ASC`, ts, ts)
	if err != nil {
		return nil, fmt.Errorf("listing targets updated since %q: %w", ts, err)
	}
	defer rows.Close()

	var out []Target
	for rows.Next() {
		t, err := scanTarget(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning target: %w", err)
		}
		out = append(out, *t)
	}
	return out, rows.Err()
}

// ---- Situation mutations ----

// UpdateSituationRank updates a situation's ranking score, priority, and AI reason.
func (db *DB) UpdateSituationRank(id int, rank float64, priority, reason string) error {
	return updateSituationRankOn(db, id, rank, priority, reason)
}

// UpdateSituationRankTx is the transactional variant of UpdateSituationRank,
// for callers (the compose apply loop) that need it to commit atomically
// with the rest of that pass's mutations.
func (db *DB) UpdateSituationRankTx(tx *sql.Tx, id int, rank float64, priority, reason string) error {
	return updateSituationRankOn(tx, id, rank, priority, reason)
}

func updateSituationRankOn(q situationsExecer, id int, rank float64, priority, reason string) error {
	_, err := q.Exec(`UPDATE situations SET rank = ?, priority = ?, ai_reason = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`, rank, priority, reason, id)
	if err != nil {
		return fmt.Errorf("updating situation %d rank: %w", id, err)
	}
	return nil
}

// SetSituationCard stores the AI-generated card content and marks card_status ready.
func (db *DB) SetSituationCard(id int, summary, whyMatters, chronology string) error {
	_, err := db.Exec(`UPDATE situations SET summary = ?, why_matters = ?, chronology = ?,
		card_status = 'ready', card_generated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`,
		summary, whyMatters, chronology, id)
	if err != nil {
		return fmt.Errorf("setting situation %d card: %w", id, err)
	}
	return nil
}

// MarkSituationCardFailed marks a situation's card generation as failed.
func (db *DB) MarkSituationCardFailed(id int) error {
	_, err := db.Exec(`UPDATE situations SET card_status = 'failed',
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("marking situation %d card failed: %w", id, err)
	}
	return nil
}

// ResetSituationCard resets card_status to 'none', e.g. when a situation is
// merged with new signals and needs its card regenerated.
func (db *DB) ResetSituationCard(id int) error {
	return resetSituationCardOn(db, id)
}

// ResetSituationCardTx is the transactional variant of ResetSituationCard,
// for callers (the compose apply loop) that need it to commit atomically
// with the rest of that pass's mutations.
func (db *DB) ResetSituationCardTx(tx *sql.Tx, id int) error {
	return resetSituationCardOn(tx, id)
}

func resetSituationCardOn(q situationsExecer, id int) error {
	_, err := q.Exec(`UPDATE situations SET card_status = 'none',
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("resetting situation %d card: %w", id, err)
	}
	return nil
}

// ListSituationsNeedingCards returns open situations whose card hasn't been
// generated yet or whose last generation attempt failed.
func (db *DB) ListSituationsNeedingCards() ([]DashboardSituation, error) {
	rows, err := db.Query(`SELECT ` + situationSelectCols + ` FROM situations
		WHERE status = 'open' AND card_status IN ('none','failed')
		ORDER BY rank DESC, updated_at DESC`)
	if err != nil {
		return nil, fmt.Errorf("listing situations needing cards: %w", err)
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

// ---- Lifecycle ----

// SetSituationStatus changes a situation's status and records the reason.
func (db *DB) SetSituationStatus(id int, status, reason string) error {
	_, err := db.Exec(`UPDATE situations SET status = ?, resolved_reason = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`, status, reason, id)
	if err != nil {
		return fmt.Errorf("setting situation %d status: %w", id, err)
	}
	return nil
}

// SnoozeSituation moves a situation to status='snoozed' until the given ISO8601 timestamp.
func (db *DB) SnoozeSituation(id int, until string) error {
	_, err := db.Exec(`UPDATE situations SET status = 'snoozed', snooze_until = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`, until, id)
	if err != nil {
		return fmt.Errorf("snoozing situation %d: %w", id, err)
	}
	return nil
}

// UnsnoozeExpiredSituations moves snoozed situations with an expired
// snooze_until back to open, and returns the number of rows affected.
func (db *DB) UnsnoozeExpiredSituations() (int, error) {
	now := time.Now().UTC().Format("2006-01-02T15:04:05Z")
	res, err := db.Exec(`UPDATE situations SET status = 'open', snooze_until = '',
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE status = 'snoozed' AND snooze_until != '' AND snooze_until <= ?`, now)
	if err != nil {
		return 0, fmt.Errorf("unsnoozing situations: %w", err)
	}
	n, _ := res.RowsAffected()
	return int(n), nil
}

// MarkStaleSituations moves open situations whose last_signal_at is older
// than threshold to status='stale'. Situations with an empty last_signal_at
// (no signal ever attached) are skipped. Returns the number of rows affected.
func (db *DB) MarkStaleSituations(threshold time.Duration) (int, error) {
	cutoff := time.Now().UTC().Add(-threshold).Format("2006-01-02T15:04:05Z")
	res, err := db.Exec(`UPDATE situations SET status = 'stale',
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE status = 'open' AND last_signal_at != '' AND last_signal_at < ?`, cutoff)
	if err != nil {
		return 0, fmt.Errorf("marking stale situations: %w", err)
	}
	n, _ := res.RowsAffected()
	return int(n), nil
}

// AutoCloseResolvedSituations closes open situations that have at least one
// member signal and zero pending member signals (every attached inbox item
// has moved past pending), setting resolved_reason='signals_resolved'.
// Returns the number of rows affected.
func (db *DB) AutoCloseResolvedSituations() (int, error) {
	res, err := db.Exec(`UPDATE situations SET status='done', resolved_reason='signals_resolved',
		       updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE status='open'
		  AND EXISTS (SELECT 1 FROM situation_signals ss WHERE ss.situation_id = situations.id)
		  AND NOT EXISTS (
		      SELECT 1 FROM situation_signals ss
		      JOIN inbox_items i ON i.id = ss.inbox_item_id
		      WHERE ss.situation_id = situations.id AND i.status = 'pending')`)
	if err != nil {
		return 0, fmt.Errorf("auto-closing resolved situations: %w", err)
	}
	n, _ := res.RowsAffected()
	return int(n), nil
}

// MarkSituationConverted marks a situation as converted into a target and/or
// track. A zero targetID/trackID is stored as NULL (not converted to that kind).
func (db *DB) MarkSituationConverted(id int, targetID, trackID int) error {
	var convertedTarget, convertedTrack any
	if targetID != 0 {
		convertedTarget = targetID
	}
	if trackID != 0 {
		convertedTrack = trackID
	}
	_, err := db.Exec(`UPDATE situations SET status = 'converted',
		converted_target_id = ?, converted_track_id = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`,
		convertedTarget, convertedTrack, id)
	if err != nil {
		return fmt.Errorf("marking situation %d converted: %w", id, err)
	}
	return nil
}

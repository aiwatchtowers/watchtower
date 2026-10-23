package db

import (
	"database/sql"
	"errors"
	"fmt"
)

// ErrWatchAlreadyBound is returned when a watch recipe or a custom track is
// already bound to another track or recipe.
var ErrWatchAlreadyBound = errors.New("watch track already bound")

// ErrNotCustomTrack is returned when a watch recipe is bound to a track that
// is not a custom (origin='custom') track.
var ErrNotCustomTrack = errors.New("track is not a custom track")

// BindWatchTrack binds custom track trackID to watch recipe automationID and
// sets the track's enabled to the recipe's (the enabled trigger mirrors it
// from then on). Binding a pair that is already bound is a no-op. It refuses
// a track that is not custom (ErrNotCustomTrack) and returns
// ErrWatchAlreadyBound when the track or the recipe is bound elsewhere.
func (db *DB) BindWatchTrack(trackID int, automationID int64) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("binding track %d to automation %d: %w", trackID, automationID, err)
	}
	defer func() { _ = tx.Rollback() }()
	if err := bindWatchTrackTx(tx, trackID, automationID); err != nil {
		return fmt.Errorf("binding track %d to automation %d: %w", trackID, automationID, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("binding track %d to automation %d: %w", trackID, automationID, err)
	}
	return nil
}

func bindWatchTrackTx(tx *sql.Tx, trackID int, automationID int64) error {
	enabled, err := automationEnabledTx(tx, automationID)
	if err != nil {
		return err
	}
	var (
		origin string
		bound  sql.NullInt64
	)
	err = tx.QueryRow(`SELECT origin, automation_id FROM tracks WHERE id = ?`, trackID).Scan(&origin, &bound)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("track %d not found", trackID)
	}
	if err != nil {
		return err
	}
	if origin != "custom" {
		return ErrNotCustomTrack
	}
	if bound.Valid {
		if bound.Int64 == automationID {
			return nil
		}
		return ErrWatchAlreadyBound
	}
	var other int
	err = tx.QueryRow(`SELECT id FROM tracks WHERE automation_id = ?`, automationID).Scan(&other)
	if err == nil {
		return ErrWatchAlreadyBound
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	_, err = tx.Exec(`UPDATE tracks SET automation_id = ?, enabled = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`, automationID, enabled, trackID)
	return err
}

// automationEnabledTx reads automation id's enabled inside tx;
// ErrAutomationNotFound when there is no such row.
func automationEnabledTx(tx *sql.Tx, id int64) (bool, error) {
	var enabled bool
	err := tx.QueryRow(`SELECT enabled FROM automations WHERE id = ?`, id).Scan(&enabled)
	if errors.Is(err, sql.ErrNoRows) {
		return false, fmt.Errorf("automation %d: %w", id, ErrAutomationNotFound)
	}
	return enabled, err
}

// GetWatchTrack returns the track bound to watch recipe automationID, or nil
// when none is.
func (db *DB) GetWatchTrack(automationID int64) (*Track, error) {
	t, err := scanTrack(db.QueryRow(`SELECT `+trackSelectCols+` FROM tracks WHERE automation_id = ?`, automationID))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading the watch track of automation %d: %w", automationID, err)
	}
	return t, nil
}

// EnsureWatchTrack returns the id of the track bound to watch recipe
// automationID, or creates a custom track for it (owned by ownerID, text =
// name, the given instruction, enabled = the recipe's enabled) and binds it,
// in one transaction. A missing automation is an error.
func (db *DB) EnsureWatchTrack(automationID int64, ownerID, name, instruction string) (int, error) {
	tx, err := db.Begin()
	if err != nil {
		return 0, fmt.Errorf("ensuring the watch track of automation %d: %w", automationID, err)
	}
	defer func() { _ = tx.Rollback() }()
	enabled, err := automationEnabledTx(tx, automationID)
	if err != nil {
		return 0, fmt.Errorf("ensuring the watch track of automation %d: %w", automationID, err)
	}
	var id int
	err = tx.QueryRow(`SELECT id FROM tracks WHERE automation_id = ?`, automationID).Scan(&id)
	if err == nil {
		return id, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return 0, fmt.Errorf("ensuring the watch track of automation %d: %w", automationID, err)
	}
	// The defaults match CreateCustomTrack's.
	err = tx.QueryRow(`INSERT INTO tracks
		(assignee_user_id, text, category, ownership, priority, fingerprint,
		 source_refs, channel_ids, related_digest_ids,
		 origin, instruction, enabled, automation_id)
		VALUES (?, ?, 'task', 'watching', 'medium', '[]', '[]', '[]', '[]', 'custom', ?, ?, ?)
		RETURNING id`, ownerID, name, instruction, enabled, automationID).Scan(&id)
	if err != nil {
		return 0, fmt.Errorf("creating the watch track of automation %d: %w", automationID, err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("ensuring the watch track of automation %d: %w", automationID, err)
	}
	return id, nil
}

// SetWatchInstruction sets custom track trackID's instruction, writing (and
// bumping updated_at) only when the value differs.
func (db *DB) SetWatchInstruction(trackID int, instruction string) error {
	res, err := db.Exec(`UPDATE tracks SET instruction = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ? AND origin = 'custom' AND instruction <> ?`, instruction, trackID, instruction)
	if err != nil {
		return fmt.Errorf("setting the instruction of track %d: %w", trackID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("setting the instruction of track %d: %w", trackID, err)
	}
	if n > 0 {
		return nil
	}
	var exists bool
	if err := db.QueryRow(`SELECT EXISTS (SELECT 1 FROM tracks WHERE id = ? AND origin = 'custom')`, trackID).Scan(&exists); err != nil {
		return fmt.Errorf("setting the instruction of track %d: %w", trackID, err)
	}
	if !exists {
		return fmt.Errorf("setting the instruction of track %d: custom track not found", trackID)
	}
	return nil
}

// ListSlotRecipes returns the owner's personal recipes that run at the given
// sync slot (trigger_kind 'sync', trigger_spec {"sync": slot}), not removed,
// in id order. Built-in rows are left out.
func (db *DB) ListSlotRecipes(slot string) ([]Automation, error) {
	rows, err := db.Query(`SELECT `+automationCols+` FROM automations
		WHERE origin = 'owner' AND scope = 'personal' AND trigger_kind = 'sync'
		  AND json_extract(trigger_spec, '$.sync') = ? AND removed_at IS NULL
		ORDER BY id`, slot)
	if err != nil {
		return nil, fmt.Errorf("listing the recipes of slot %s: %w", slot, err)
	}
	defer rows.Close()
	out := []Automation{}
	for rows.Next() {
		a, err := scanAutomation(rows)
		if err != nil {
			return nil, fmt.Errorf("listing the recipes of slot %s: %w", slot, err)
		}
		out = append(out, *a)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing the recipes of slot %s: %w", slot, err)
	}
	return out, nil
}

// HasScanActivity reports whether GetScanActivity(since, until, …) would
// return any row, without loading one: the same per-source predicates as one
// EXISTS each.
func (db *DB) HasScanActivity(since, until string) (bool, error) {
	var has bool
	err := db.QueryRow(`SELECT
		EXISTS (SELECT 1 FROM digests WHERE type = 'channel' AND created_at > ?1 AND created_at <= ?2)
		OR EXISTS (SELECT 1 FROM tracks WHERE dismissed_at = '' AND origin = 'auto' AND updated_at > ?1 AND updated_at <= ?2)
		OR EXISTS (SELECT 1 FROM inbox_items WHERE created_at > ?1 AND created_at <= ?2)`, since, until).Scan(&has)
	if err != nil {
		return false, fmt.Errorf("probing scan activity: %w", err)
	}
	return has, nil
}

// ListUnboundCustomTracks returns the active custom tracks bound to no watch
// recipe, in created order.
func (db *DB) ListUnboundCustomTracks() ([]Track, error) {
	return db.queryCustomTracks(`SELECT ` + trackSelectCols + `
		FROM tracks WHERE origin = 'custom' AND automation_id IS NULL AND dismissed_at = ''
		ORDER BY created_at, id`)
}

// UnbindRemovedWatchTracks unbinds and pauses every track bound to a watch
// recipe the indexer marked removed (removed_at set: its file is gone), as
// the delete trigger does for a deleted row: automation_id = NULL, enabled =
// 0, the track and its events kept. It returns how many tracks it unbound. A
// recipe whose file comes back is indexed again and gets a new track.
func (db *DB) UnbindRemovedWatchTracks() (int, error) {
	res, err := db.Exec(`UPDATE tracks SET automation_id = NULL, enabled = 0,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE automation_id IN (SELECT id FROM automations WHERE removed_at IS NOT NULL)`)
	if err != nil {
		return 0, fmt.Errorf("unbinding the tracks of removed watch recipes: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("unbinding the tracks of removed watch recipes: %w", err)
	}
	return int(n), nil
}

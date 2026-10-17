package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

const insertReactionEventSQL = `INSERT OR IGNORE INTO reaction_events
	(account_id, channel_id, message_ts, emoji, seen_at) VALUES (?, ?, ?, ?, ?)`

// InsertReactionEvent records r in the reaction_events ledger (migration
// 00136). inserted is false when the key was already there, so the caller
// publishes the automation event exactly once per reaction.
func (db *DB) InsertReactionEvent(r OwnerReaction) (inserted bool, err error) {
	res, err := db.Exec(insertReactionEventSQL, r.AccountID, r.ChannelID, r.MessageTS, r.Emoji,
		time.Now().UTC().Format(time.RFC3339))
	if err != nil {
		return false, fmt.Errorf("recording reaction event: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("recording reaction event: %w", err)
	}
	return n > 0, nil
}

// FilterUnseenReactionEvents returns the reactions of rs that accountID's
// reaction_events ledger has not recorded, in their order. Read-only, so a
// steady-state poll takes no write lock.
func (db *DB) FilterUnseenReactionEvents(accountID int64, rs []OwnerReaction) ([]OwnerReaction, error) {
	if len(rs) == 0 {
		return nil, nil
	}
	rows, err := db.Query(`SELECT channel_id, message_ts, emoji FROM reaction_events
		WHERE account_id = ?`, accountID)
	if err != nil {
		return nil, fmt.Errorf("loading reaction events ledger: %w", err)
	}
	defer rows.Close()

	seen := map[string]bool{}
	for rows.Next() {
		var ch, ts, emoji string
		if err := rows.Scan(&ch, &ts, &emoji); err != nil {
			return nil, fmt.Errorf("scanning reaction event key: %w", err)
		}
		seen[ch+"\x00"+ts+"\x00"+emoji] = true
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterating reaction events ledger: %w", err)
	}

	var out []OwnerReaction
	for _, r := range rs {
		if !seen[r.ChannelID+"\x00"+r.MessageTS+"\x00"+r.Emoji] {
			out = append(out, r)
		}
	}
	return out, nil
}

// SeedReactionEvents records rs as seen without firing and stamps
// accountID's reaction_events_seeded_at, in one transaction. It errors when
// the account row is missing.
func (db *DB) SeedReactionEvents(accountID int64, rs []OwnerReaction) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("seeding reaction events: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	now := time.Now().UTC().Format(time.RFC3339)
	for _, r := range rs {
		if _, err := tx.Exec(insertReactionEventSQL, r.AccountID, r.ChannelID, r.MessageTS, r.Emoji, now); err != nil {
			return fmt.Errorf("seeding reaction events: %w", err)
		}
	}
	res, err := tx.Exec(`UPDATE slack_accounts SET reaction_events_seeded_at = ? WHERE id = ?`, now, accountID)
	if err != nil {
		return fmt.Errorf("stamping reaction events seed for slack account %d: %w", accountID, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("stamping reaction events seed: no slack_accounts row %d", accountID)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("seeding reaction events: %w", err)
	}
	return nil
}

// ReactionEventsSeeded reports whether accountID's existing reactions have
// been recorded into reaction_events. A missing row reads as NOT seeded.
func (db *DB) ReactionEventsSeeded(accountID int64) (bool, error) {
	var stamp string
	err := db.QueryRow(`SELECT reaction_events_seeded_at FROM slack_accounts WHERE id = ?`, accountID).Scan(&stamp)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return false, nil
		}
		return false, fmt.Errorf("reading reaction events seed stamp for slack account %d: %w", accountID, err)
	}
	return stamp != "", nil
}

// ResetReactionEventsSeeded clears every account's seed stamp (rows are
// kept), so the next wanted poll reseeds instead of firing for reactions
// placed while nobody listened. It reads first and writes only when some
// stamp is set, so a poll nobody listens to takes no write lock.
func (db *DB) ResetReactionEventsSeeded() error {
	var anySet bool
	if err := db.QueryRow(`SELECT EXISTS (SELECT 1 FROM slack_accounts WHERE reaction_events_seeded_at != '')`).Scan(&anySet); err != nil {
		return fmt.Errorf("reading reaction events seed stamps: %w", err)
	}
	if !anySet {
		return nil
	}
	if _, err := db.Exec(`UPDATE slack_accounts SET reaction_events_seeded_at = '' WHERE reaction_events_seeded_at != ''`); err != nil {
		return fmt.Errorf("resetting reaction events seed stamps: %w", err)
	}
	return nil
}

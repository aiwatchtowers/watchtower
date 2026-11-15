package db

import (
	"database/sql"
	"fmt"
	"time"
)

// ToggleMuteForLLM toggles the is_muted_for_llm flag for a channel.
// Returns the new value of the flag. Like SetMuteForLLM it is a manual mute
// change: muted_at is set when the mute turns on and cleared when it turns
// off, and the mute is the user's from now on (muted_by_exclusion = 0).
func (db *DB) ToggleMuteForLLM(channelID string) (bool, error) {
	_, err := db.Exec(`
		INSERT INTO channel_settings (channel_id, is_muted_for_llm, muted_at, updated_at)
		VALUES (?, 1, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		ON CONFLICT(channel_id) DO UPDATE SET
			is_muted_for_llm = 1 - channel_settings.is_muted_for_llm,
			muted_at = CASE WHEN channel_settings.is_muted_for_llm = 0
				THEN strftime('%Y-%m-%dT%H:%M:%SZ', 'now') ELSE '' END,
			muted_by_exclusion = 0,
			updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')`,
		channelID)
	if err != nil {
		return false, fmt.Errorf("toggling mute for %s: %w", channelID, err)
	}
	var val bool
	err = db.QueryRow(`SELECT is_muted_for_llm FROM channel_settings WHERE channel_id = ?`, channelID).Scan(&val)
	if err != nil {
		return false, fmt.Errorf("reading mute state for %s: %w", channelID, err)
	}
	return val, nil
}

// ToggleFavorite toggles the is_favorite flag for a channel.
// Returns the new value of the flag.
func (db *DB) ToggleFavorite(channelID string) (bool, error) {
	_, err := db.Exec(`
		INSERT INTO channel_settings (channel_id, is_favorite, updated_at)
		VALUES (?, 1, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		ON CONFLICT(channel_id) DO UPDATE SET
			is_favorite = 1 - channel_settings.is_favorite,
			updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')`,
		channelID)
	if err != nil {
		return false, fmt.Errorf("toggling favorite for %s: %w", channelID, err)
	}
	var val bool
	err = db.QueryRow(`SELECT is_favorite FROM channel_settings WHERE channel_id = ?`, channelID).Scan(&val)
	if err != nil {
		return false, fmt.Errorf("reading favorite state for %s: %w", channelID, err)
	}
	return val, nil
}

// SetMuteForLLM sets the is_muted_for_llm flag explicitly. muted_at is set
// when the mute turns on (kept when it was already on) and cleared when it
// turns off; any manual change makes the mute the user's own
// (muted_by_exclusion = 0), so Sync again never lifts it. The Swift twin
// ChannelStatsQueries.toggleMuteForLLM follows the same rule
// (testdata/channel_mute_cases.json).
func (db *DB) SetMuteForLLM(channelID string, muted bool) error {
	val := 0
	if muted {
		val = 1
	}
	_, err := db.Exec(`
		INSERT INTO channel_settings (channel_id, is_muted_for_llm, muted_at, updated_at)
		VALUES (?, ?, CASE WHEN ? = 1 THEN strftime('%Y-%m-%dT%H:%M:%SZ', 'now') ELSE '' END,
			strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		ON CONFLICT(channel_id) DO UPDATE SET
			is_muted_for_llm = excluded.is_muted_for_llm,
			muted_at = CASE
				WHEN excluded.is_muted_for_llm = 0 THEN ''
				WHEN channel_settings.is_muted_for_llm = 1 THEN channel_settings.muted_at
				ELSE excluded.muted_at END,
			muted_by_exclusion = 0,
			updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')`,
		channelID, val, val)
	if err != nil {
		return fmt.Errorf("setting mute for %s: %w", channelID, err)
	}
	return nil
}

// SetFavorite sets the is_favorite flag explicitly.
func (db *DB) SetFavorite(channelID string, favorite bool) error {
	val := 0
	if favorite {
		val = 1
	}
	_, err := db.Exec(`
		INSERT INTO channel_settings (channel_id, is_favorite, updated_at)
		VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		ON CONFLICT(channel_id) DO UPDATE SET
			is_favorite = excluded.is_favorite,
			updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')`,
		channelID, val)
	if err != nil {
		return fmt.Errorf("setting favorite for %s: %w", channelID, err)
	}
	return nil
}

// GetChannelSettings returns settings for a channel. Returns nil if no settings exist.
func (db *DB) GetChannelSettings(channelID string) (*ChannelSettings, error) {
	var cs ChannelSettings
	err := db.QueryRow(`SELECT channel_id, is_muted_for_llm, is_favorite, updated_at,
		sync_excluded, excluded_at, catchup_from, catchup_to, muted_by_exclusion, muted_at
		FROM channel_settings WHERE channel_id = ?`, channelID).
		Scan(channelSettingsDest(&cs)...)
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, fmt.Errorf("getting channel settings for %s: %w", channelID, err)
	}
	return &cs, nil
}

// GetAllChannelSettings returns settings for all channels that have custom settings.
func (db *DB) GetAllChannelSettings() ([]ChannelSettings, error) {
	rows, err := db.Query(`SELECT channel_id, is_muted_for_llm, is_favorite, updated_at,
		sync_excluded, excluded_at, catchup_from, catchup_to, muted_by_exclusion, muted_at FROM channel_settings`)
	if err != nil {
		return nil, fmt.Errorf("querying channel settings: %w", err)
	}
	defer rows.Close()

	var settings []ChannelSettings
	for rows.Next() {
		var cs ChannelSettings
		if err := rows.Scan(channelSettingsDest(&cs)...); err != nil {
			return nil, fmt.Errorf("scanning channel settings: %w", err)
		}
		settings = append(settings, cs)
	}
	return settings, rows.Err()
}

// GetMutedChannelIDs returns the list of channel IDs that are muted for LLM processing.
func (db *DB) GetMutedChannelIDs() ([]string, error) {
	rows, err := db.Query(`SELECT channel_id FROM channel_settings WHERE is_muted_for_llm = 1`)
	if err != nil {
		return nil, fmt.Errorf("querying muted channels: %w", err)
	}
	defer rows.Close()

	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning muted channel id: %w", err)
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

func channelSettingsDest(cs *ChannelSettings) []any {
	return []any{&cs.ChannelID, &cs.IsMutedForLLM, &cs.IsFavorite, &cs.UpdatedAt,
		&cs.SyncExcluded, &cs.ExcludedAt, &cs.CatchupFrom, &cs.CatchupTo, &cs.MutedByExclusion, &cs.MutedAt}
}

// SyncAgainOverlap is how far before excluded_at a Sync again catch-up
// starts: the forward search's own overlap (its window starts two days
// before the last watermark, for Slack's indexing delay).
const SyncAgainOverlap = 48 * time.Hour

const syncAgainOverlapSeconds = int64(SyncAgainOverlap / time.Second)

// SetSyncExcluded is Stop syncing (excluded) or Sync again (!excluded) for a
// channel, in one write; the only writer of the exclusion columns besides the
// sync's catch-up (AdvanceCatchup, FinishCatchup). SYNCEX-01.
//
// Stop syncing sets sync_excluded and excluded_at = now. During an unfinished
// catch-up excluded_at is the exclusion that catch-up started from instead
// (catchup_from + SyncAgainOverlap, the earliest point not yet known to be
// covered), so the next Sync again covers that window too; the catch-up is
// cleared. A channel that was not muted for AI is muted with
// muted_by_exclusion = 1. Excluding an excluded channel changes nothing.
//
// Sync again clears sync_excluded and starts a catch-up of
// [excluded_at − SyncAgainOverlap, now): from now on the forward search
// covers the channel. The overlap takes back what was posted just before
// Stop syncing but not stored yet (the forward search dropped it); the rows
// already stored upsert. It lifts the mute only when Stop syncing set it.
// Including a channel that is not excluded changes nothing.
func (db *DB) SetSyncExcluded(channelID string, excluded bool, now time.Time) error {
	stamp := now.UTC().Format(time.RFC3339)
	var err error
	if excluded {
		_, err = db.Exec(`
			INSERT INTO channel_settings (channel_id, sync_excluded, excluded_at,
				is_muted_for_llm, muted_by_exclusion, muted_at, updated_at)
			VALUES (?, 1, ?, 1, 1, ?, ?)
			ON CONFLICT(channel_id) DO UPDATE SET
				excluded_at = CASE
					WHEN channel_settings.sync_excluded = 1 THEN channel_settings.excluded_at
					WHEN channel_settings.catchup_from IS NOT NULL
						THEN strftime('%Y-%m-%dT%H:%M:%SZ', CAST(channel_settings.catchup_from AS INTEGER) + ?, 'unixepoch')
					ELSE excluded.excluded_at END,
				sync_excluded = 1,
				catchup_from = NULL,
				catchup_to = NULL,
				muted_by_exclusion = CASE WHEN channel_settings.is_muted_for_llm = 1
					THEN channel_settings.muted_by_exclusion ELSE 1 END,
				muted_at = CASE WHEN channel_settings.is_muted_for_llm = 1
					THEN channel_settings.muted_at ELSE excluded.muted_at END,
				is_muted_for_llm = 1,
				updated_at = excluded.updated_at`,
			channelID, stamp, stamp, stamp, syncAgainOverlapSeconds)
	} else {
		_, err = db.Exec(`
			UPDATE channel_settings SET
				sync_excluded = 0,
				catchup_from = CAST(strftime('%s', excluded_at) - ? AS REAL),
				catchup_to = CASE WHEN strftime('%s', excluded_at) IS NULL THEN NULL ELSE ? END,
				is_muted_for_llm = CASE WHEN muted_by_exclusion = 1 THEN 0 ELSE is_muted_for_llm END,
				muted_at = CASE WHEN muted_by_exclusion = 1 THEN '' ELSE muted_at END,
				muted_by_exclusion = 0,
				updated_at = ?
			WHERE channel_id = ? AND sync_excluded = 1`,
			syncAgainOverlapSeconds, float64(now.Unix()), stamp, channelID)
	}
	if err != nil {
		return fmt.Errorf("setting sync exclusion for %s: %w", channelID, err)
	}
	return nil
}

// accountChannelPattern is the LIKE pattern of an account's namespaced
// channel ids ("<accountID>:<raw>").
func accountChannelPattern(accountID int64) string {
	return fmt.Sprintf("%d:%%", accountID)
}

// SyncExcludedChannelIDs is the set of the account's channels with Stop
// syncing on (namespaced ids).
func (db *DB) SyncExcludedChannelIDs(accountID int64) (map[string]bool, error) {
	rows, err := db.Query(`SELECT channel_id FROM channel_settings
		WHERE sync_excluded = 1 AND channel_id LIKE ?`, accountChannelPattern(accountID))
	if err != nil {
		return nil, fmt.Errorf("querying sync-excluded channels: %w", err)
	}
	defer rows.Close()
	out := make(map[string]bool)
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning sync-excluded channel: %w", err)
		}
		out[id] = true
	}
	return out, rows.Err()
}

// Catchup is Sync again's pending fetch of a channel's excluded period:
// From is fixed, To moves down as pages are saved (unix seconds).
type Catchup struct {
	ChannelID string
	From, To  float64
}

// PendingCatchups lists the account's pending catch-ups, the one with the
// oldest start first.
func (db *DB) PendingCatchups(accountID int64) ([]Catchup, error) {
	rows, err := db.Query(`SELECT channel_id, catchup_from, catchup_to FROM channel_settings
		WHERE sync_excluded = 0 AND catchup_from IS NOT NULL AND catchup_to IS NOT NULL
			AND channel_id LIKE ?
		ORDER BY catchup_from, channel_id`, accountChannelPattern(accountID))
	if err != nil {
		return nil, fmt.Errorf("querying catch-ups: %w", err)
	}
	defer rows.Close()
	var out []Catchup
	for rows.Next() {
		var c Catchup
		if err := rows.Scan(&c.ChannelID, &c.From, &c.To); err != nil {
			return nil, fmt.Errorf("scanning catch-up: %w", err)
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// AdvanceCatchup moves the catch-up c of a channel down to `to` after a
// saved page. It is a compare-and-set on the bounds the walker read (c.From,
// c.To): it applies only while the channel is not excluded, the catch-up is
// still that one at that bound, and `to` is below it. applied is false
// otherwise, and the walker stops: a Stop syncing (and a later Sync again,
// which may start a catch-up with the same From) made its walk stale.
func (db *DB) AdvanceCatchup(c Catchup, to float64) (applied bool, err error) {
	res, err := db.Exec(`UPDATE channel_settings SET catchup_to = ?
		WHERE channel_id = ? AND sync_excluded = 0 AND catchup_from = ? AND catchup_to = ? AND catchup_to > ?`,
		to, c.ChannelID, c.From, c.To, to)
	if err != nil {
		return false, fmt.Errorf("advancing catch-up of %s: %w", c.ChannelID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("advancing catch-up of %s: %w", c.ChannelID, err)
	}
	return n > 0, nil
}

// FinishCatchup clears the catch-up c of a channel, compare-and-set on its
// bounds like AdvanceCatchup: a catch-up started or cleared since the walker
// read c is left alone (applied = false).
func (db *DB) FinishCatchup(c Catchup) (applied bool, err error) {
	res, err := db.Exec(`UPDATE channel_settings SET catchup_from = NULL, catchup_to = NULL
		WHERE channel_id = ? AND catchup_from = ? AND catchup_to = ?`, c.ChannelID, c.From, c.To)
	if err != nil {
		return false, fmt.Errorf("finishing catch-up of %s: %w", c.ChannelID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("finishing catch-up of %s: %w", c.ChannelID, err)
	}
	return n > 0, nil
}

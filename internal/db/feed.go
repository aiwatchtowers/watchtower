package db

import (
	"database/sql"
	"fmt"
)

const feedItemSelectCols = `id, item_type, source_id, event_ts, importance,
	COALESCE(hidden_at,''), COALESCE(seen_at,''), created_at, updated_at`

func scanFeedItem(row interface{ Scan(...any) error }) (*FeedItem, error) {
	var f FeedItem
	err := row.Scan(&f.ID, &f.ItemType, &f.SourceID, &f.EventTS, &f.Importance,
		&f.HiddenAt, &f.SeenAt, &f.CreatedAt, &f.UpdatedAt)
	if err != nil {
		return nil, err
	}
	return &f, nil
}

// GetFeedItem returns the feed index row for (itemType, sourceID), or nil
// when the item has not been published.
func (db *DB) GetFeedItem(itemType, sourceID string) (*FeedItem, error) {
	row := db.QueryRow(`SELECT `+feedItemSelectCols+` FROM feed_items
		WHERE item_type = ? AND source_id = ?`, itemType, sourceID)
	item, err := scanFeedItem(row)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("getting feed item %s/%s: %w", itemType, sourceID, err)
	}
	return item, nil
}

// CountFeedItems returns the total number of feed index rows.
func (db *DB) CountFeedItems() (int, error) {
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM feed_items`).Scan(&n); err != nil {
		return 0, fmt.Errorf("counting feed items: %w", err)
	}
	return n, nil
}

// GetFeedBootstrapCutoff returns the timestamp seeded by migration 00014 —
// briefings/recaps/day-plans created before it are never published, so the
// pre-feature backlog doesn't flood the feed.
func (db *DB) GetFeedBootstrapCutoff() (string, error) {
	var cutoff string
	if err := db.QueryRow(`SELECT bootstrap_cutoff FROM feed_state WHERE id = 1`).Scan(&cutoff); err != nil {
		return "", fmt.Errorf("getting feed bootstrap cutoff: %w", err)
	}
	return cutoff, nil
}

// feedUpsert runs one publish statement and reports rows inserted/updated.
func (db *DB) feedUpsert(name, query string, args ...any) (int, error) {
	res, err := db.Exec(query, args...)
	if err != nil {
		return 0, fmt.Errorf("publishing %s feed items: %w", name, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("publishing %s feed items: %w", name, err)
	}
	return int(n), nil
}

// PublishSituationFeedItems mirrors every open situation into the feed index.
// event_ts follows the situation's updated_at (a compose merge bumps it, so
// the feed item resurfaces); importance maps from priority. The conditional
// DO UPDATE keeps a steady-state publish at zero touched rows, and never
// writes hidden_at/seen_at (DASH-05).
func (db *DB) PublishSituationFeedItems() (int, error) {
	return db.feedUpsert("situation", `
		INSERT INTO feed_items (item_type, source_id, event_ts, importance)
		SELECT 'situation', CAST(s.id AS TEXT), s.updated_at,
		       CASE s.priority WHEN 'high' THEN 90 WHEN 'medium' THEN 60 ELSE 30 END
		FROM situations s
		WHERE s.status = 'open'
		ON CONFLICT(item_type, source_id) DO UPDATE SET
		    event_ts   = excluded.event_ts,
		    importance = excluded.importance,
		    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE feed_items.event_ts != excluded.event_ts
		   OR feed_items.importance != excluded.importance`)
}

// PublishMeetingFeedItems publishes confirmed, non-all-day meetings whose
// start_time falls inside (nowTS, windowEndTS]. event_ts = start_time, so an
// upcoming meeting sits at the top of the DESC feed and slides down naturally
// once its time passes; a reschedule inside the window updates event_ts.
// A reschedule OUT of the window (e.g. pushed past windowEndTS) falls out of
// the SELECT entirely, so its feed_items row keeps its stale event_ts until
// the meeting re-enters a future window — an accepted trade-off (DASH-05).
func (db *DB) PublishMeetingFeedItems(nowTS, windowEndTS string) (int, error) {
	return db.feedUpsert("meeting", `
		INSERT INTO feed_items (item_type, source_id, event_ts, importance)
		SELECT 'meeting', e.id, e.start_time, 70
		FROM calendar_events e
		WHERE e.is_all_day = 0
		  AND e.event_status = 'confirmed'
		  AND e.start_time > ?
		  AND e.start_time <= ?
		ON CONFLICT(item_type, source_id) DO UPDATE SET
		    event_ts   = excluded.event_ts,
		    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE feed_items.event_ts != excluded.event_ts`, nowTS, windowEndTS)
}

// PublishBriefingFeedItems publishes briefings created after the bootstrap
// cutoff. Insert-once: a briefing never changes identity after creation.
func (db *DB) PublishBriefingFeedItems(cutoff string) (int, error) {
	return db.feedUpsert("briefing", `
		INSERT INTO feed_items (item_type, source_id, event_ts, importance)
		SELECT 'briefing', CAST(b.id AS TEXT), b.created_at, 60
		FROM briefings b
		WHERE b.created_at > ?
		ON CONFLICT(item_type, source_id) DO NOTHING`, cutoff)
}

// PublishRecapFeedItems publishes meeting recaps created after the bootstrap
// cutoff, keyed by their calendar event id.
func (db *DB) PublishRecapFeedItems(cutoff string) (int, error) {
	return db.feedUpsert("meeting_recap", `
		INSERT INTO feed_items (item_type, source_id, event_ts, importance)
		SELECT 'meeting_recap', r.event_id, r.created_at, 60
		FROM meeting_recaps r
		WHERE r.created_at > ?
		ON CONFLICT(item_type, source_id) DO NOTHING`, cutoff)
}

// PublishDayPlanFeedItems publishes active day plans created after the
// bootstrap cutoff. event_ts tracks the latest (re)generation, so a
// regenerated plan resurfaces at its new position.
func (db *DB) PublishDayPlanFeedItems(cutoff string) (int, error) {
	return db.feedUpsert("day_plan", `
		INSERT INTO feed_items (item_type, source_id, event_ts, importance)
		SELECT 'day_plan', CAST(p.id AS TEXT), COALESCE(p.last_regenerated_at, p.generated_at), 60
		FROM day_plans p
		WHERE p.status = 'active'
		  AND p.created_at > ?
		ON CONFLICT(item_type, source_id) DO UPDATE SET
		    event_ts   = excluded.event_ts,
		    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE feed_items.event_ts != excluded.event_ts`, cutoff)
}

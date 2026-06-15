package db

import "fmt"

// UnreadItem is a compact representation of one unread row for the catch-up rollup.
type UnreadItem struct {
	ID       int
	Title    string
	Snippet  string
	Priority string // "" when the area has no priority concept
}

// GetUnreadDigests returns up to limit unread digests (read_at IS NULL),
// newest first, plus the uncapped total count.
func (db *DB) GetUnreadDigests(limit int) ([]UnreadItem, int, error) {
	var total int
	if err := db.QueryRow(`SELECT COUNT(*) FROM digests WHERE read_at IS NULL`).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("counting unread digests: %w", err)
	}
	rows, err := db.Query(`
		SELECT id, type, channel_id, substr(summary, 1, 280)
		FROM digests WHERE read_at IS NULL
		ORDER BY period_to DESC LIMIT ?`, limit)
	if err != nil {
		return nil, 0, fmt.Errorf("querying unread digests: %w", err)
	}
	defer rows.Close()
	var items []UnreadItem
	for rows.Next() {
		var it UnreadItem
		var dtype, channel string
		if err := rows.Scan(&it.ID, &dtype, &channel, &it.Snippet); err != nil {
			return nil, 0, fmt.Errorf("scanning digest: %w", err)
		}
		it.Title = dtype + " digest " + channel
		items = append(items, it)
	}
	return items, total, rows.Err()
}

// GetUnreadTracks returns up to limit tracks with pending updates
// (has_updates=1, not dismissed), ranked by priority then recency.
func (db *DB) GetUnreadTracks(limit int) ([]UnreadItem, int, error) {
	var total int
	if err := db.QueryRow(`SELECT COUNT(*) FROM tracks WHERE has_updates = 1 AND dismissed_at = ''`).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("counting unread tracks: %w", err)
	}
	rows, err := db.Query(`
		SELECT id, text, substr(context, 1, 280), priority
		FROM tracks WHERE has_updates = 1 AND dismissed_at = ''
		ORDER BY CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, updated_at DESC
		LIMIT ?`, limit)
	if err != nil {
		return nil, 0, fmt.Errorf("querying unread tracks: %w", err)
	}
	defer rows.Close()
	var items []UnreadItem
	for rows.Next() {
		var it UnreadItem
		if err := rows.Scan(&it.ID, &it.Title, &it.Snippet, &it.Priority); err != nil {
			return nil, 0, fmt.Errorf("scanning track: %w", err)
		}
		items = append(items, it)
	}
	return items, total, rows.Err()
}

// GetUnreadInboxItems returns up to limit pending, unarchived, unread inbox
// items, ranked by priority then recency.
func (db *DB) GetUnreadInboxItems(limit int) ([]UnreadItem, int, error) {
	const where = `status = 'pending' AND archived_at IS NULL AND (read_at IS NULL OR read_at = '')`
	var total int
	if err := db.QueryRow(`SELECT COUNT(*) FROM inbox_items WHERE ` + where).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("counting unread inbox: %w", err)
	}
	rows, err := db.Query(`
		SELECT id, trigger_type, substr(snippet, 1, 280), priority
		FROM inbox_items WHERE `+where+`
		ORDER BY CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, updated_at DESC
		LIMIT ?`, limit)
	if err != nil {
		return nil, 0, fmt.Errorf("querying unread inbox: %w", err)
	}
	defer rows.Close()
	var items []UnreadItem
	for rows.Next() {
		var it UnreadItem
		var trigger string
		if err := rows.Scan(&it.ID, &trigger, &it.Snippet, &it.Priority); err != nil {
			return nil, 0, fmt.Errorf("scanning inbox item: %w", err)
		}
		it.Title = trigger
		items = append(items, it)
	}
	return items, total, rows.Err()
}

// GetUnreadBriefings returns up to limit unread briefings (read_at IS NULL),
// newest first, plus the uncapped total.
func (db *DB) GetUnreadBriefings(limit int) ([]UnreadItem, int, error) {
	var total int
	if err := db.QueryRow(`SELECT COUNT(*) FROM briefings WHERE read_at IS NULL`).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("counting unread briefings: %w", err)
	}
	rows, err := db.Query(`
		SELECT id, date FROM briefings WHERE read_at IS NULL
		ORDER BY date DESC LIMIT ?`, limit)
	if err != nil {
		return nil, 0, fmt.Errorf("querying unread briefings: %w", err)
	}
	defer rows.Close()
	var items []UnreadItem
	for rows.Next() {
		var it UnreadItem
		var date string
		if err := rows.Scan(&it.ID, &date); err != nil {
			return nil, 0, fmt.Errorf("scanning briefing: %w", err)
		}
		it.Title = "Briefing " + date
		items = append(items, it)
	}
	return items, total, rows.Err()
}

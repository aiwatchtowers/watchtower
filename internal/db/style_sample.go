package db

import "fmt"

// StyleSampleMessage is one of the owner's own messages, sampled for the
// communication-style distillation.
type StyleSampleMessage struct {
	ChannelID   string
	ChannelName string
	ChannelType string // public | private | dm | group_dm
	Text        string
	TS          string
}

// ListStyleSampleMessages returns the owner's most recent qualifying messages
// (not deleted, no subtype, non-trivial length), newest first, up to fetchCap.
// Per-channel/total capping happens in the caller.
func (db *DB) ListStyleSampleMessages(userID string, fetchCap int) ([]StyleSampleMessage, error) {
	rows, err := db.Query(`
		SELECT m.channel_id, c.name, c.type, m.text, m.ts
		FROM messages m
		JOIN channels c ON c.id = m.channel_id
		WHERE m.user_id = ? AND m.is_deleted = 0 AND m.subtype = ''
		  AND LENGTH(TRIM(m.text)) >= 8
		ORDER BY m.ts_unix DESC
		LIMIT ?`, userID, fetchCap)
	if err != nil {
		return nil, fmt.Errorf("listing style sample messages: %w", err)
	}
	defer rows.Close()
	var out []StyleSampleMessage
	for rows.Next() {
		var m StyleSampleMessage
		if err := rows.Scan(&m.ChannelID, &m.ChannelName, &m.ChannelType, &m.Text, &m.TS); err != nil {
			return nil, fmt.Errorf("scanning style sample message: %w", err)
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

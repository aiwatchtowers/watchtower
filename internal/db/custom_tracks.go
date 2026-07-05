package db

import "fmt"

// CreateCustomTrack inserts a user-authored (origin='custom') track. The
// narrative (text/context) and instruction are set at creation; the scan
// pipeline appends track_events over time.
func (db *DB) CreateCustomTrack(t Track) (int64, error) {
	if t.Priority == "" {
		t.Priority = "medium"
	}
	if t.Category == "" {
		t.Category = "task"
	}
	if t.Ownership == "" {
		t.Ownership = "watching"
	}
	if t.Fingerprint == "" {
		t.Fingerprint = "[]"
	}
	var linked any
	if t.LinkedTargetID > 0 {
		linked = t.LinkedTargetID
	}
	res, err := db.Exec(`INSERT INTO tracks
		(assignee_user_id, text, context, category, ownership, priority,
		 fingerprint, source_refs, channel_ids, related_digest_ids,
		 origin, instruction, enabled, linked_target_id)
		VALUES (?, ?, ?, ?, ?, ?, ?,
		        COALESCE(NULLIF(?, ''), '[]'), COALESCE(NULLIF(?, ''), '[]'), COALESCE(NULLIF(?, ''), '[]'),
		        'custom', ?, 1, ?)`,
		t.AssigneeUserID, t.Text, t.Context, t.Category, t.Ownership, t.Priority,
		t.Fingerprint, t.SourceRefs, t.ChannelIDs, t.RelatedDigestIDs,
		t.Instruction, linked)
	if err != nil {
		return 0, fmt.Errorf("inserting custom track: %w", err)
	}
	return res.LastInsertId()
}

// GetEnabledCustomTracks returns active, enabled custom tracks for scanning.
func (db *DB) GetEnabledCustomTracks() ([]Track, error) {
	rows, err := db.Query(`SELECT ` + trackSelectCols + `
		FROM tracks WHERE origin = 'custom' AND enabled = 1 AND dismissed_at = ''
		ORDER BY created_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Track
	for rows.Next() {
		t, err := scanTrack(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *t)
	}
	return out, rows.Err()
}

// SetTrackLastRun advances a custom track's scan watermark.
func (db *DB) SetTrackLastRun(id int, at string) error {
	_, err := db.Exec(`UPDATE tracks SET last_run_at = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`, at, id)
	return err
}

// SetTrackEnabled toggles a custom track's scanning.
func (db *DB) SetTrackEnabled(id int, enabled bool) error {
	_, err := db.Exec(`UPDATE tracks SET enabled = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`, enabled, id)
	return err
}

// UpdateCustomTrackInstruction edits a custom track's narrative + instruction.
func (db *DB) UpdateCustomTrackInstruction(id int, text, instruction string) error {
	_, err := db.Exec(`UPDATE tracks SET text = ?, instruction = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ? AND origin = 'custom'`, text, instruction, id)
	return err
}

// FoldSourceRefsIntoTrack folds matching auto-extracted content into a custom
// track: it merges channel_ids/related_digest_ids and flags an update, WITHOUT
// touching the custom track's text/context/instruction/priority (custom is
// authoritative — see the design's fold rule).
func (db *DB) FoldSourceRefsIntoTrack(id int, sourceRefs, channelIDs, relatedDigestIDs string) error {
	existing, err := db.GetTrackByID(id)
	if err != nil {
		return fmt.Errorf("loading track %d for fold: %w", id, err)
	}
	mergedChannels := mergeJSONArrays(existing.ChannelIDs, channelIDs)
	mergedDigests := mergeJSONArrays(existing.RelatedDigestIDs, relatedDigestIDs)
	// A fold is always news → flag has_updates unconditionally (unlike
	// UpdateTrackFromExtraction, which guards on read_at; here the custom
	// track's narrative is untouched, so the flag is the only signal).
	_, err = db.Exec(`UPDATE tracks SET
		channel_ids = ?, related_digest_ids = ?,
		has_updates = 1,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ?`, mergedChannels, mergedDigests, id)
	_ = sourceRefs // reserved: appending quote-level refs is out of scope for v1
	return err
}

package db

import (
	"database/sql"
	"fmt"
	"sort"
)

// TrackEvent is one entry in a custom track's timeline (ported from the
// observer_events model; keyed on track_id, not observer/entity).
type TrackEvent struct {
	ID             int    `json:"id"`
	TrackID        int    `json:"track_id"`
	Summary        string `json:"summary"`
	Detail         string `json:"detail"`
	SourceType     string `json:"source_type"`
	SourceID       string `json:"source_id"`
	SourceRefs     string `json:"source_refs"`     // JSON array
	Decision       string `json:"decision"`        // JSON object or ""
	ProposedAction string `json:"proposed_action"` // JSON object or ""
	ActionStatus   string `json:"action_status"`
	ReadAt         string `json:"read_at"`
	CreatedAt      string `json:"created_at"`
}

const trackEventCols = `id, track_id, summary, detail, source_type, source_id,
	source_refs, decision, proposed_action, action_status, COALESCE(read_at,''), created_at`

func scanTrackEvent(row interface{ Scan(...any) error }) (*TrackEvent, error) {
	var e TrackEvent
	if err := row.Scan(&e.ID, &e.TrackID, &e.Summary, &e.Detail, &e.SourceType, &e.SourceID,
		&e.SourceRefs, &e.Decision, &e.ProposedAction, &e.ActionStatus, &e.ReadAt, &e.CreatedAt); err != nil {
		return nil, err
	}
	return &e, nil
}

// InsertTrackEvent appends one event to a custom track's timeline.
func (db *DB) InsertTrackEvent(e TrackEvent) (int, error) {
	if e.SourceRefs == "" {
		e.SourceRefs = "[]"
	}
	if e.ActionStatus == "" {
		e.ActionStatus = "none"
	}
	res, err := db.Exec(`INSERT INTO track_events
		(track_id, summary, detail, source_type, source_id, source_refs, decision, proposed_action, action_status)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		e.TrackID, e.Summary, e.Detail, e.SourceType, e.SourceID, e.SourceRefs, e.Decision, e.ProposedAction, e.ActionStatus)
	if err != nil {
		return 0, fmt.Errorf("inserting track event: %w", err)
	}
	id, err := res.LastInsertId()
	return int(id), err
}

// GetTrackEvents returns a custom track's timeline, newest first.
func (db *DB) GetTrackEvents(trackID, limit int) ([]TrackEvent, error) {
	if limit <= 0 {
		limit = 100
	}
	rows, err := db.Query(`SELECT `+trackEventCols+`
		FROM track_events WHERE track_id = ? ORDER BY created_at DESC, id DESC LIMIT ?`, trackID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []TrackEvent
	for rows.Next() {
		e, err := scanTrackEvent(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *e)
	}
	return out, rows.Err()
}

// GetTrackEventSummaries returns the most recent event summaries for one custom
// track, newest first. Used to dedup a scan against events already produced for
// an overlapping window.
func (db *DB) GetTrackEventSummaries(trackID, limit int) ([]string, error) {
	if limit <= 0 {
		limit = 400
	}
	rows, err := db.Query(`SELECT summary FROM track_events
		WHERE track_id = ? ORDER BY created_at DESC LIMIT ?`, trackID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// MarkTrackEventRead sets read_at.
func (db *DB) MarkTrackEventRead(id int, at string) error {
	_, err := db.Exec(`UPDATE track_events SET read_at = ? WHERE id = ?`, at, id)
	return err
}

// SetTrackEventActionStatus updates the proposed-action lifecycle.
func (db *DB) SetTrackEventActionStatus(id int, status string) error {
	_, err := db.Exec(`UPDATE track_events SET action_status = ? WHERE id = ?`, status, id)
	return err
}

// ---- Scan-activity gather (cross-source feed for the custom-track scan) ----

// ScanActivity is the bundle of recent cross-source activity fed to a custom
// track's scan (ported from ObserverActivity; reuses the shared Activity*
// row structs declared alongside the observer engine).
type ScanActivity struct {
	Digests []ActivityDigest
	Tracks  []ActivityTrack
	Inbox   []ActivityInbox
	// CappedAt is the safe watermark when any source hit the per-source row cap:
	// the smallest max-timestamp among capped sources. Rows newer than it were
	// NOT loaded, so the caller must not advance its watermark past this point.
	// Empty when no source was capped (the whole window was consumed).
	CappedAt string
}

// GetScanActivity returns recent activity created/updated strictly after the
// `since` ISO8601 watermark, capped at `limit` rows per source. These three
// already-summarized sources together cover Slack (digests), action items
// (auto tracks), and Jira/Calendar/decision signals (inbox items). The tracks
// sub-query is restricted to origin='auto' so a custom track's feed excludes
// other custom tracks.
//
// Rows come oldest-first ((timestamp, id) order) so a capped window is consumed
// incrementally: when a source hits the cap, CappedAt records how far the
// window was actually read and the caller advances its watermark to that point,
// not to now. Timestamps are second-resolution, so a capped fetch additionally
// drains every remaining row tied at the boundary second — the caller reopens
// the next window with a strict `>`, and any tie left behind would be skipped
// forever (realistic: inbox_items batch-inserted 100-in-one-second on a cold
// start).
func (db *DB) GetScanActivity(since string, limit int) (ScanActivity, error) {
	if limit <= 0 {
		limit = 40
	}
	var act ScanActivity

	// cappedAt folds one source's coverage into act.CappedAt (min across sources).
	cappedAt := func(maxTS string) {
		if act.CappedAt == "" || maxTS < act.CappedAt {
			act.CappedAt = maxTS
		}
	}

	scanDigest := func(r *sql.Rows) error {
		var a ActivityDigest
		if err := r.Scan(&a.ID, &a.ChannelID, &a.Summary, &a.Decisions, &a.CreatedAt); err != nil {
			return err
		}
		act.Digests = append(act.Digests, a)
		return nil
	}
	if err := db.forEachRow(scanDigest, `SELECT id, channel_id, summary, decisions, created_at
		FROM digests WHERE type = 'channel' AND created_at > ?
		ORDER BY created_at ASC, id ASC LIMIT ?`, since, limit); err != nil {
		return act, err
	}
	if len(act.Digests) == limit {
		last := act.Digests[limit-1]
		if err := db.forEachRow(scanDigest, `SELECT id, channel_id, summary, decisions, created_at
			FROM digests WHERE type = 'channel' AND created_at = ? AND id > ?
			ORDER BY id ASC`, last.CreatedAt, last.ID); err != nil {
			return act, err
		}
		cappedAt(last.CreatedAt)
	}

	scanTrack := func(r *sql.Rows) error {
		var a ActivityTrack
		if err := r.Scan(&a.ID, &a.Text, &a.Context, &a.UpdatedAt); err != nil {
			return err
		}
		act.Tracks = append(act.Tracks, a)
		return nil
	}
	if err := db.forEachRow(scanTrack, `SELECT id, text, context, updated_at
		FROM tracks WHERE dismissed_at = '' AND origin = 'auto' AND updated_at > ?
		ORDER BY updated_at ASC, id ASC LIMIT ?`, since, limit); err != nil {
		return act, err
	}
	if len(act.Tracks) == limit {
		last := act.Tracks[limit-1]
		if err := db.forEachRow(scanTrack, `SELECT id, text, context, updated_at
			FROM tracks WHERE dismissed_at = '' AND origin = 'auto' AND updated_at = ? AND id > ?
			ORDER BY id ASC`, last.UpdatedAt, last.ID); err != nil {
			return act, err
		}
		cappedAt(last.UpdatedAt)
	}

	scanInbox := func(r *sql.Rows) error {
		var a ActivityInbox
		if err := r.Scan(&a.ID, &a.TriggerType, &a.Snippet, &a.Permalink, &a.CreatedAt); err != nil {
			return err
		}
		act.Inbox = append(act.Inbox, a)
		return nil
	}
	if err := db.forEachRow(scanInbox, `SELECT id, trigger_type, snippet, permalink, created_at
		FROM inbox_items WHERE created_at > ?
		ORDER BY created_at ASC, id ASC LIMIT ?`, since, limit); err != nil {
		return act, err
	}
	if len(act.Inbox) == limit {
		last := act.Inbox[limit-1]
		if err := db.forEachRow(scanInbox, `SELECT id, trigger_type, snippet, permalink, created_at
			FROM inbox_items WHERE created_at = ? AND id > ?
			ORDER BY id ASC`, last.CreatedAt, last.ID); err != nil {
			return act, err
		}
		cappedAt(last.CreatedAt)
	}

	return act, nil
}

// GetScanActivityTitles returns headline-only activity in the window after
// `since`, newest first, capped at `limit` items total. Titles are tiny, so a
// scan can shortlist far more of the window than it could feed in full. The
// tracks sub-query is restricted to origin='auto' (custom tracks are excluded
// from their own feed).
func (db *DB) GetScanActivityTitles(since string, limit int) ([]ActivityTitle, error) {
	if limit <= 0 {
		limit = 2000
	}
	var titles []ActivityTitle

	scan := func(q, kind string) error {
		rows, err := db.Query(q, since, limit)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			t := ActivityTitle{Kind: kind}
			if err := rows.Scan(&t.ID, &t.Title, &t.CreatedAt); err != nil {
				return err
			}
			titles = append(titles, t)
		}
		return rows.Err()
	}

	if err := scan(`SELECT id, summary, created_at FROM digests
		WHERE type = 'channel' AND created_at > ?
		ORDER BY created_at DESC LIMIT ?`, "digest"); err != nil {
		return nil, err
	}
	if err := scan(`SELECT id, text, updated_at FROM tracks
		WHERE dismissed_at = '' AND origin = 'auto' AND updated_at > ?
		ORDER BY updated_at DESC LIMIT ?`, "track"); err != nil {
		return nil, err
	}
	if err := scan(`SELECT id, snippet, created_at FROM inbox_items
		WHERE created_at > ?
		ORDER BY created_at DESC LIMIT ?`, "inbox"); err != nil {
		return nil, err
	}

	// Merge the three per-source streams newest-first and cap to the overall limit.
	sort.Slice(titles, func(i, j int) bool { return titles[i].CreatedAt > titles[j].CreatedAt })
	if len(titles) > limit {
		titles = titles[:limit]
	}
	return titles, nil
}

// GetScanActivityByIDs loads full activity content for the given per-source ids
// (the stage-1 shortlist), for the stage-2 extract pass. Empty id slices are
// skipped. Order within each source is newest first. The tracks sub-query is
// restricted to origin='auto'.
func (db *DB) GetScanActivityByIDs(digestIDs, trackIDs, inboxIDs []int) (ScanActivity, error) {
	var act ScanActivity

	if len(digestIDs) > 0 {
		if err := db.forEachRow(func(r *sql.Rows) error {
			var a ActivityDigest
			if err := r.Scan(&a.ID, &a.ChannelID, &a.Summary, &a.Decisions, &a.CreatedAt); err != nil {
				return err
			}
			act.Digests = append(act.Digests, a)
			return nil
		}, `SELECT id, channel_id, summary, decisions, created_at
			FROM digests WHERE id IN (`+placeholders(len(digestIDs))+`)
			ORDER BY created_at DESC`, intArgs(digestIDs)...); err != nil {
			return act, err
		}
	}

	if len(trackIDs) > 0 {
		if err := db.forEachRow(func(r *sql.Rows) error {
			var a ActivityTrack
			if err := r.Scan(&a.ID, &a.Text, &a.Context, &a.UpdatedAt); err != nil {
				return err
			}
			act.Tracks = append(act.Tracks, a)
			return nil
		}, `SELECT id, text, context, updated_at
			FROM tracks WHERE origin = 'auto' AND id IN (`+placeholders(len(trackIDs))+`)
			ORDER BY updated_at DESC`, intArgs(trackIDs)...); err != nil {
			return act, err
		}
	}

	if len(inboxIDs) > 0 {
		if err := db.forEachRow(func(r *sql.Rows) error {
			var a ActivityInbox
			if err := r.Scan(&a.ID, &a.TriggerType, &a.Snippet, &a.Permalink, &a.CreatedAt); err != nil {
				return err
			}
			act.Inbox = append(act.Inbox, a)
			return nil
		}, `SELECT id, trigger_type, snippet, permalink, created_at
			FROM inbox_items WHERE id IN (`+placeholders(len(inboxIDs))+`)
			ORDER BY created_at DESC`, intArgs(inboxIDs)...); err != nil {
			return act, err
		}
	}

	return act, nil
}

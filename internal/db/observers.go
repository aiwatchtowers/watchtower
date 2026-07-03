package db

import (
	"database/sql"
	"fmt"
	"sort"
	"strings"
)

// CreateObserver inserts a new observer and returns its id.
func (db *DB) CreateObserver(o Observer) (int, error) {
	if o.EntityType == "" {
		o.EntityType = "target"
	}
	res, err := db.Exec(`
		INSERT INTO observers (entity_type, entity_id, name, instruction, enabled)
		VALUES (?, ?, ?, ?, ?)`,
		o.EntityType, o.EntityID, o.Name, o.Instruction, boolToInt(o.Enabled))
	if err != nil {
		return 0, fmt.Errorf("create observer: %w", err)
	}
	id, err := res.LastInsertId()
	return int(id), err
}

func scanObserver(s interface{ Scan(...any) error }) (*Observer, error) {
	var o Observer
	var enabled int
	if err := s.Scan(&o.ID, &o.EntityType, &o.EntityID, &o.Name, &o.Instruction,
		&enabled, &o.LastRunAt, &o.CreatedAt, &o.UpdatedAt); err != nil {
		return nil, err
	}
	o.Enabled = enabled != 0
	return &o, nil
}

const observerCols = `id, entity_type, entity_id, name, instruction, enabled, last_run_at, created_at, updated_at`

// GetObserverByID loads one observer.
func (db *DB) GetObserverByID(id int) (*Observer, error) {
	row := db.QueryRow(`SELECT `+observerCols+` FROM observers WHERE id = ?`, id)
	o, err := scanObserver(row)
	if err == sql.ErrNoRows {
		return nil, fmt.Errorf("observer %d not found", id)
	}
	return o, err
}

// GetObserversForEntity returns all observers attached to an entity, oldest first.
func (db *DB) GetObserversForEntity(entityType string, entityID int) ([]Observer, error) {
	rows, err := db.Query(`SELECT `+observerCols+`
		FROM observers WHERE entity_type = ? AND entity_id = ? ORDER BY created_at`,
		entityType, entityID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return collectObservers(rows)
}

// GetEnabledObservers returns every enabled observer across all entities.
func (db *DB) GetEnabledObservers() ([]Observer, error) {
	rows, err := db.Query(`SELECT ` + observerCols + ` FROM observers WHERE enabled = 1 ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return collectObservers(rows)
}

func collectObservers(rows *sql.Rows) ([]Observer, error) {
	var out []Observer
	for rows.Next() {
		o, err := scanObserver(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *o)
	}
	return out, rows.Err()
}

// UpdateObserver edits the name and instruction and bumps updated_at.
func (db *DB) UpdateObserver(id int, name, instruction string) error {
	_, err := db.Exec(`UPDATE observers
		SET name = ?, instruction = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ?`, name, instruction, id)
	return err
}

// SetObserverEnabled toggles the enabled flag.
func (db *DB) SetObserverEnabled(id int, enabled bool) error {
	_, err := db.Exec(`UPDATE observers
		SET enabled = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ?`, boolToInt(enabled), id)
	return err
}

// SetObserverLastRun advances the per-observer watermark. It intentionally does
// not touch updated_at (a run is not a user edit).
func (db *DB) SetObserverLastRun(id int, at string) error {
	_, err := db.Exec(`UPDATE observers SET last_run_at = ? WHERE id = ?`, at, id)
	return err
}

// DeleteObserver removes an observer; its events cascade-delete.
func (db *DB) DeleteObserver(id int) error {
	_, err := db.Exec(`DELETE FROM observers WHERE id = ?`, id)
	return err
}

// CountObserversForEntity counts observers attached to an entity.
func (db *DB) CountObserversForEntity(entityType string, entityID int) (int, error) {
	var n int
	err := db.QueryRow(`SELECT COUNT(*) FROM observers WHERE entity_type = ? AND entity_id = ?`,
		entityType, entityID).Scan(&n)
	return n, err
}

// InsertObserverEvent appends one event to the timeline.
func (db *DB) InsertObserverEvent(e ObserverEvent) (int, error) {
	if e.EntityType == "" {
		e.EntityType = "target"
	}
	if e.SourceRefs == "" {
		e.SourceRefs = "[]"
	}
	if e.ActionStatus == "" {
		e.ActionStatus = "none"
	}
	res, err := db.Exec(`
		INSERT INTO observer_events
			(observer_id, entity_type, entity_id, summary, detail, source_type, source_id,
			 source_refs, decision, proposed_action, action_status)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		e.ObserverID, e.EntityType, e.EntityID, e.Summary, e.Detail, e.SourceType, e.SourceID,
		e.SourceRefs, e.Decision, e.ProposedAction, e.ActionStatus)
	if err != nil {
		return 0, fmt.Errorf("insert observer event: %w", err)
	}
	id, err := res.LastInsertId()
	return int(id), err
}

const observerEventCols = `id, observer_id, entity_type, entity_id, summary, detail,
	source_type, source_id, source_refs, decision, proposed_action, action_status,
	COALESCE(read_at, ''), created_at`

// GetObserverEventsForEntity returns the timeline for an entity, newest first.
func (db *DB) GetObserverEventsForEntity(entityType string, entityID, limit int) ([]ObserverEvent, error) {
	if limit <= 0 {
		limit = 100
	}
	rows, err := db.Query(`SELECT `+observerEventCols+`
		FROM observer_events WHERE entity_type = ? AND entity_id = ?
		ORDER BY created_at DESC, id DESC LIMIT ?`, entityType, entityID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ObserverEvent
	for rows.Next() {
		var e ObserverEvent
		if err := rows.Scan(&e.ID, &e.ObserverID, &e.EntityType, &e.EntityID, &e.Summary,
			&e.Detail, &e.SourceType, &e.SourceID, &e.SourceRefs, &e.Decision,
			&e.ProposedAction, &e.ActionStatus, &e.ReadAt, &e.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// GetObserverEventSummaries returns the most recent event summaries for one
// observer, newest first. Used to dedup a history backfill against events the
// observer already produced for an overlapping window.
func (db *DB) GetObserverEventSummaries(observerID, limit int) ([]string, error) {
	if limit <= 0 {
		limit = 200
	}
	rows, err := db.Query(`SELECT summary FROM observer_events
		WHERE observer_id = ? ORDER BY created_at DESC, id DESC LIMIT ?`, observerID, limit)
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

// MarkObserverEventRead sets read_at.
func (db *DB) MarkObserverEventRead(id int, at string) error {
	_, err := db.Exec(`UPDATE observer_events SET read_at = ? WHERE id = ?`, at, id)
	return err
}

// SetObserverEventActionStatus updates the proposed-action lifecycle.
func (db *DB) SetObserverEventActionStatus(id int, status string) error {
	_, err := db.Exec(`UPDATE observer_events SET action_status = ? WHERE id = ?`, status, id)
	return err
}

// ---- Activity gather (cross-source feed for the observer prompt) ----

// ActivityDigest is a compact recent channel digest for the observer prompt.
type ActivityDigest struct {
	ID        int
	ChannelID string
	Summary   string
	Decisions string // JSON array
	CreatedAt string
}

// ActivityTrack is a compact recent track.
type ActivityTrack struct {
	ID        int
	Text      string
	Context   string
	UpdatedAt string
}

// ActivityInbox is a compact recent inbox item (covers Jira/Calendar/decision triggers).
type ActivityInbox struct {
	ID          int
	TriggerType string
	Snippet     string
	Permalink   string
	CreatedAt   string
}

// ObserverActivity is the bundle of recent cross-source activity fed to observers.
type ObserverActivity struct {
	Digests []ActivityDigest
	Tracks  []ActivityTrack
	Inbox   []ActivityInbox
}

// GetObserverActivity returns recent activity created/updated strictly after the
// `since` ISO8601 watermark, capped at `limit` rows per source. These three
// already-summarized sources together cover Slack (digests), action items
// (tracks), and Jira/Calendar/decision signals (inbox items).
func (db *DB) GetObserverActivity(since string, limit int) (ObserverActivity, error) {
	if limit <= 0 {
		limit = 40
	}
	var act ObserverActivity

	dr, err := db.Query(`SELECT id, channel_id, summary, decisions, created_at
		FROM digests WHERE type = 'channel' AND created_at > ?
		ORDER BY created_at DESC LIMIT ?`, since, limit)
	if err != nil {
		return act, err
	}
	for dr.Next() {
		var a ActivityDigest
		if err := dr.Scan(&a.ID, &a.ChannelID, &a.Summary, &a.Decisions, &a.CreatedAt); err != nil {
			dr.Close()
			return act, err
		}
		act.Digests = append(act.Digests, a)
	}
	dr.Close()
	if err := dr.Err(); err != nil {
		return act, err
	}

	tr, err := db.Query(`SELECT id, text, context, updated_at
		FROM tracks WHERE dismissed_at = '' AND updated_at > ?
		ORDER BY updated_at DESC LIMIT ?`, since, limit)
	if err != nil {
		return act, err
	}
	for tr.Next() {
		var a ActivityTrack
		if err := tr.Scan(&a.ID, &a.Text, &a.Context, &a.UpdatedAt); err != nil {
			tr.Close()
			return act, err
		}
		act.Tracks = append(act.Tracks, a)
	}
	tr.Close()
	if err := tr.Err(); err != nil {
		return act, err
	}

	ir, err := db.Query(`SELECT id, trigger_type, snippet, permalink, created_at
		FROM inbox_items WHERE created_at > ?
		ORDER BY created_at DESC LIMIT ?`, since, limit)
	if err != nil {
		return act, err
	}
	for ir.Next() {
		var a ActivityInbox
		if err := ir.Scan(&a.ID, &a.TriggerType, &a.Snippet, &a.Permalink, &a.CreatedAt); err != nil {
			ir.Close()
			return act, err
		}
		act.Inbox = append(act.Inbox, a)
	}
	ir.Close()
	if err := ir.Err(); err != nil {
		return act, err
	}

	return act, nil
}

// ActivityTitle is a one-line headline for a single activity item, used by the
// cheap stage-1 "shortlist" pass of a history backfill. Kind is digest|track|inbox.
type ActivityTitle struct {
	Kind      string
	ID        int
	Title     string
	CreatedAt string
}

// GetObserverActivityTitles returns headline-only activity in the window after
// `since`, newest first, capped at `limit` items total. Titles are tiny, so a
// backfill can shortlist far more of the window than it could feed in full.
func (db *DB) GetObserverActivityTitles(since string, limit int) ([]ActivityTitle, error) {
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
		WHERE dismissed_at = '' AND updated_at > ?
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

// GetObserverActivityByIDs loads full activity content for the given per-source
// ids (the stage-1 shortlist), for the stage-2 extract pass. Empty id slices are
// skipped. Order within each source is newest first.
func (db *DB) GetObserverActivityByIDs(digestIDs, trackIDs, inboxIDs []int) (ObserverActivity, error) {
	var act ObserverActivity

	if len(digestIDs) > 0 {
		rows, err := db.Query(`SELECT id, channel_id, summary, decisions, created_at
			FROM digests WHERE id IN (`+placeholders(len(digestIDs))+`)
			ORDER BY created_at DESC`, intArgs(digestIDs)...)
		if err != nil {
			return act, err
		}
		for rows.Next() {
			var a ActivityDigest
			if err := rows.Scan(&a.ID, &a.ChannelID, &a.Summary, &a.Decisions, &a.CreatedAt); err != nil {
				rows.Close()
				return act, err
			}
			act.Digests = append(act.Digests, a)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return act, err
		}
	}

	if len(trackIDs) > 0 {
		rows, err := db.Query(`SELECT id, text, context, updated_at
			FROM tracks WHERE id IN (`+placeholders(len(trackIDs))+`)
			ORDER BY updated_at DESC`, intArgs(trackIDs)...)
		if err != nil {
			return act, err
		}
		for rows.Next() {
			var a ActivityTrack
			if err := rows.Scan(&a.ID, &a.Text, &a.Context, &a.UpdatedAt); err != nil {
				rows.Close()
				return act, err
			}
			act.Tracks = append(act.Tracks, a)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return act, err
		}
	}

	if len(inboxIDs) > 0 {
		rows, err := db.Query(`SELECT id, trigger_type, snippet, permalink, created_at
			FROM inbox_items WHERE id IN (`+placeholders(len(inboxIDs))+`)
			ORDER BY created_at DESC`, intArgs(inboxIDs)...)
		if err != nil {
			return act, err
		}
		for rows.Next() {
			var a ActivityInbox
			if err := rows.Scan(&a.ID, &a.TriggerType, &a.Snippet, &a.Permalink, &a.CreatedAt); err != nil {
				rows.Close()
				return act, err
			}
			act.Inbox = append(act.Inbox, a)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return act, err
		}
	}

	return act, nil
}

// placeholders returns "?,?,…" with n entries for an IN clause.
func placeholders(n int) string {
	return strings.TrimSuffix(strings.Repeat("?,", n), ",")
}

// intArgs converts an int slice to []any for parameterized queries.
func intArgs(ids []int) []any {
	args := make([]any, len(ids))
	for i, v := range ids {
		args[i] = v
	}
	return args
}

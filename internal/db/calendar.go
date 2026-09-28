package db

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// UpsertCalendar inserts or updates a Google Calendar for accountID. accountID
// <= 0 writes a NULL account_id — the shape caldav/ics calendars need, since
// those rows must never enter the Google syncer's fetch/stale-delete loops
// (see dropNonGoogleCalendarIDs in internal/calendar).
//
// calendar_calendars.id is a shared keyspace: a public/shared Google calendar
// subscribed by two different accounts syncs to the SAME row. On conflict
// this never steals ownership — an already-claimed (non-NULL account_id) row
// keeps its original owner regardless of which account syncs it next; only a
// NULL account_id (unclaimed, a legacy row stamped by migration 00043, or a
// row a logout/remove kept and detached — see purgeGoogleAccountCalendarsTx)
// can be claimed, and a claim takes the incoming is_selected too, as a fresh
// insert would (a detached row was unselected by the detach, not by the
// owner). Combined with GetSelectedCalendarIDs filtering by account_id,
// a shared calendar is synced (and stale-cleaned) by whichever account
// connected it first — the other account simply never selects it, so it can
// neither duplicate nor cross-delete that calendar's events.
func (db *DB) UpsertCalendar(accountID int64, cal CalendarCalendar) error {
	var accountArg any
	if accountID > 0 {
		accountArg = accountID
	}
	_, err := db.Exec(`INSERT INTO calendar_calendars (id, name, is_primary, is_selected, color, synced_at, account_id)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET name=excluded.name, is_primary=excluded.is_primary, color=excluded.color, synced_at=excluded.synced_at,
			is_selected = CASE WHEN calendar_calendars.account_id IS NULL AND excluded.account_id IS NOT NULL
				THEN excluded.is_selected ELSE calendar_calendars.is_selected END,
			account_id = CASE WHEN calendar_calendars.account_id IS NULL THEN excluded.account_id ELSE calendar_calendars.account_id END`,
		cal.ID, cal.Name, cal.IsPrimary, cal.IsSelected, cal.Color, cal.SyncedAt, accountArg)
	if err != nil {
		return fmt.Errorf("upserting calendar %s: %w", cal.ID, err)
	}
	return nil
}

// GetCalendars returns all synced calendars.
func (db *DB) GetCalendars() ([]CalendarCalendar, error) {
	rows, err := db.Query(`SELECT id, name, is_primary, is_selected, color, synced_at FROM calendar_calendars ORDER BY is_primary DESC, name`)
	if err != nil {
		return nil, fmt.Errorf("querying calendars: %w", err)
	}
	defer rows.Close()

	var cals []CalendarCalendar
	for rows.Next() {
		var c CalendarCalendar
		if err := rows.Scan(&c.ID, &c.Name, &c.IsPrimary, &c.IsSelected, &c.Color, &c.SyncedAt); err != nil {
			return nil, fmt.Errorf("scanning calendar: %w", err)
		}
		cals = append(cals, c)
	}
	return cals, rows.Err()
}

// GetSelectedCalendarIDs returns IDs of accountID's calendars marked as
// selected. caldav:/ics: calendars carry a NULL account_id, so they never
// match here regardless of accountID.
func (db *DB) GetSelectedCalendarIDs(accountID int64) ([]string, error) {
	rows, err := db.Query(`SELECT id FROM calendar_calendars WHERE is_selected = 1 AND account_id = ?`, accountID)
	if err != nil {
		return nil, fmt.Errorf("querying selected calendars: %w", err)
	}
	defer rows.Close()

	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning calendar id: %w", err)
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// SetCalendarSelected updates the is_selected flag for a calendar.
func (db *DB) SetCalendarSelected(id string, selected bool) error {
	_, err := db.Exec(`UPDATE calendar_calendars SET is_selected = ? WHERE id = ?`, selected, id)
	if err != nil {
		return fmt.Errorf("setting calendar %s selected=%v: %w", id, selected, err)
	}
	return nil
}

// calendarEventUpdateSet is the ON CONFLICT(id) DO UPDATE clause shared by the
// single and batch event upserts — every column except the id.
// time_changed_at is stamped with the pass's synced_at only when start/end
// actually moved (a column qualified with the table name on the right-hand
// side is the row's pre-update value); a first insert leaves it empty.
// rsvp_changed is computed in Go before the write (mergeRSVPChanges), since it
// needs the stored and the new attendee lists side by side.
// The upserts must NEVER use INSERT OR REPLACE: with foreign_keys=ON, REPLACE
// resolves a PK conflict as DELETE+INSERT, firing the FK actions on the children — it
// NULLs meeting_transcripts.event_id (ON DELETE SET NULL) and deletes the
// event's meeting_recaps row (ON DELETE CASCADE) on every sync cycle.
const calendarEventUpdateSet = `ON CONFLICT(id) DO UPDATE SET
		calendar_id=excluded.calendar_id, title=excluded.title, description=excluded.description,
		location=excluded.location, start_time=excluded.start_time, end_time=excluded.end_time,
		organizer_email=excluded.organizer_email, attendees=excluded.attendees,
		is_recurring=excluded.is_recurring, is_all_day=excluded.is_all_day,
		event_status=excluded.event_status, event_type=excluded.event_type,
		html_link=excluded.html_link, conference_url=excluded.conference_url,
		raw_json=excluded.raw_json, ical_uid=excluded.ical_uid,
		synced_at=excluded.synced_at, updated_at=excluded.updated_at,
		time_changed_at=CASE
			WHEN calendar_events.start_time <> excluded.start_time
			  OR calendar_events.end_time <> excluded.end_time
			THEN excluded.synced_at ELSE calendar_events.time_changed_at END,
		rsvp_changed=excluded.rsvp_changed`

// UpsertCalendarEvent inserts or updates a calendar event (never REPLACE —
// see calendarEventUpdateSet for why that would wipe FK children).
// syncedAt is an ISO8601 timestamp used to track when the event was last synced.
// If empty, the current UTC time is used.
func (db *DB) UpsertCalendarEvent(ev CalendarEvent, syncedAt ...string) error {
	sa := ""
	if len(syncedAt) > 0 {
		sa = syncedAt[0]
	}
	return db.upsertCalendarEventsTx([]CalendarEvent{ev}, sa)
}

// UpsertCalendarEvents inserts or updates multiple calendar events in a single
// transaction (never REPLACE — see calendarEventUpdateSet for why that would
// wipe FK children), all stamped with the current UTC time as synced_at.
func (db *DB) UpsertCalendarEvents(events []CalendarEvent) error {
	if len(events) == 0 {
		return nil
	}
	return db.upsertCalendarEventsTx(events, "")
}

// upsertCalendarEventsTx writes events in one transaction. Each event's
// stored row is read first so rsvp_changed can be carried forward: an
// attendee whose response_status differs from the stored one gets this
// pass's synced_at (see mergeRSVPChanges).
func (db *DB) upsertCalendarEventsTx(events []CalendarEvent, syncedAt string) error {
	if syncedAt == "" {
		syncedAt = time.Now().UTC().Format(time.RFC3339)
	}
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("beginning calendar events tx: %w", err)
	}
	defer tx.Rollback()

	for _, ev := range events {
		var prevAttendees, prevChanges string
		err := tx.QueryRow(`SELECT attendees, rsvp_changed FROM calendar_events WHERE id = ?`, ev.ID).
			Scan(&prevAttendees, &prevChanges)
		existed := err == nil
		if err != nil && err != sql.ErrNoRows {
			return fmt.Errorf("reading calendar event %s: %w", ev.ID, err)
		}
		rsvpChanged := "{}"
		if existed {
			rsvpChanged = mergeRSVPChanges(prevAttendees, prevChanges, ev.Attendees, syncedAt)
		}
		_, err = tx.Exec(`INSERT INTO calendar_events
			(id, calendar_id, title, description, location, start_time, end_time,
			 organizer_email, attendees, is_recurring, is_all_day, event_status,
			 event_type, html_link, conference_url, raw_json, ical_uid, synced_at, updated_at,
			 rsvp_changed)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
			`+calendarEventUpdateSet,
			ev.ID, ev.CalendarID, ev.Title, ev.Description, ev.Location,
			ev.StartTime, ev.EndTime, ev.OrganizerEmail, ev.Attendees,
			ev.IsRecurring, ev.IsAllDay, ev.EventStatus, ev.EventType,
			ev.HTMLLink, ev.ConferenceURL, ev.RawJSON, ev.ICalUID, syncedAt, ev.UpdatedAt,
			rsvpChanged)
		if err != nil {
			return fmt.Errorf("upserting calendar event %s: %w", ev.ID, err)
		}
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing calendar events tx: %w", err)
	}
	return nil
}

// calendarRSVP is the slice of one attendees-JSON element rsvp tracking reads
// (the calendar.Attendee wire keys).
type calendarRSVP struct {
	Email          string `json:"email"`
	ResponseStatus string `json:"response_status"`
}

// mergeRSVPChanges returns the rsvp_changed JSON object (lower-cased
// attendee email → the synced_at of the pass that last saw that attendee's
// response_status change) for a re-sync: the stored stamps, plus stamp for
// every attendee present in both the stored and the new attendee list whose
// response differs. An attendee who only appears or disappears is not a
// response change. It is keyed per attendee rather than on one "owner"
// because the upsert does not know who the owner is — the inbox applies its
// own owner identity when it reads the map. Unparseable input degrades to
// "no change seen", never an error.
func mergeRSVPChanges(prevAttendees, prevChanges, newAttendees, stamp string) string {
	changes := map[string]string{}
	_ = json.Unmarshal([]byte(prevChanges), &changes)
	if changes == nil {
		changes = map[string]string{}
	}
	var prev, cur []calendarRSVP
	_ = json.Unmarshal([]byte(prevAttendees), &prev)
	_ = json.Unmarshal([]byte(newAttendees), &cur)
	before := make(map[string]string, len(prev))
	for _, a := range prev {
		before[strings.ToLower(a.Email)] = a.ResponseStatus
	}
	for _, a := range cur {
		email := strings.ToLower(a.Email)
		if old, ok := before[email]; ok && email != "" && old != a.ResponseStatus {
			changes[email] = stamp
		}
	}
	out, err := json.Marshal(changes)
	if err != nil {
		return "{}"
	}
	return string(out)
}

// CalendarRSVPChangedAt returns when the sync last saw email's
// response_status change on the event (the rsvp_changed stamp), "" when it
// never has. Email is matched case-insensitively.
func CalendarRSVPChangedAt(rsvpChanged, email string) string {
	changes := map[string]string{}
	_ = json.Unmarshal([]byte(rsvpChanged), &changes)
	return changes[strings.ToLower(email)]
}

// GetCalendarEvents returns events matching the filter.
func (db *DB) GetCalendarEvents(filter CalendarEventFilter) ([]CalendarEvent, error) {
	query := `SELECT id, calendar_id, title, description, location, start_time, end_time,
		organizer_email, attendees, is_recurring, is_all_day, event_status,
		event_type, html_link, conference_url, raw_json, ical_uid, synced_at, updated_at
		FROM calendar_events WHERE 1=1`
	var args []any

	if filter.CalendarID != "" {
		query += ` AND calendar_id = ?`
		args = append(args, filter.CalendarID)
	}
	if filter.FromTime != "" {
		query += ` AND end_time >= ?`
		args = append(args, filter.FromTime)
	}
	if filter.ToTime != "" {
		query += ` AND start_time <= ?`
		args = append(args, filter.ToTime)
	}
	query += ` ORDER BY start_time`
	if filter.Limit > 0 {
		query += fmt.Sprintf(` LIMIT %d`, filter.Limit)
	}

	return db.queryCalendarEvents(query, args...)
}

// GetCalendarEventsForDate returns all events on the local calendar day date
// (YYYY-MM-DD, interpreted in loc; nil = time.Local). A timed event matches
// when it overlaps [local midnight, next local midnight), both converted to
// UTC — the column format. An all-day event is stored as UTC midnight of its
// date with an EXCLUSIVE end (Google's End.Date, iCal DTEND;VALUE=DATE), so it
// matches by its own date: start before the next date's midnight and end
// strictly after this date's midnight — yesterday's all-day event, whose end
// is exactly today's midnight, does not leak into today.
func (db *DB) GetCalendarEventsForDate(date string, loc *time.Location) ([]CalendarEvent, error) {
	if loc == nil {
		loc = time.Local
	}
	day, err := time.ParseInLocation("2006-01-02", date, loc)
	if err != nil {
		return nil, fmt.Errorf("parsing calendar date %q: %w", date, err)
	}
	const layout = "2006-01-02T15:04:05Z"
	next := day.AddDate(0, 0, 1)
	allDayFrom := date + "T00:00:00Z"
	allDayTo := next.Format("2006-01-02") + "T00:00:00Z"
	timedFrom := day.UTC().Format(layout)
	timedTo := next.UTC().Format(layout)
	query := `SELECT id, calendar_id, title, description, location, start_time, end_time,
		organizer_email, attendees, is_recurring, is_all_day, event_status,
		event_type, html_link, conference_url, raw_json, ical_uid, synced_at, updated_at
		FROM calendar_events
		WHERE (is_all_day = 1 AND end_time > ? AND start_time < ?)
		   OR (is_all_day = 0 AND end_time > ? AND start_time < ?)
		ORDER BY start_time`
	return db.queryCalendarEvents(query, allDayFrom, allDayTo, timedFrom, timedTo)
}

// GetCalendarEventByID returns a single event by its Google ID.
func (db *DB) GetCalendarEventByID(id string) (*CalendarEvent, error) {
	query := `SELECT id, calendar_id, title, description, location, start_time, end_time,
		organizer_email, attendees, is_recurring, is_all_day, event_status,
		event_type, html_link, conference_url, raw_json, ical_uid, synced_at, updated_at
		FROM calendar_events WHERE id = ?`
	events, err := db.queryCalendarEvents(query, id)
	if err != nil {
		return nil, err
	}
	if len(events) == 0 {
		return nil, nil
	}
	return &events[0], nil
}

// GetNextEvent returns the next upcoming event from now.
func (db *DB) GetNextEvent() (*CalendarEvent, error) {
	now := time.Now().UTC().Format(time.RFC3339)
	query := `SELECT id, calendar_id, title, description, location, start_time, end_time,
		organizer_email, attendees, is_recurring, is_all_day, event_status,
		event_type, html_link, conference_url, raw_json, ical_uid, synced_at, updated_at
		FROM calendar_events WHERE end_time >= ? AND is_all_day = 0
		ORDER BY start_time LIMIT 1`
	events, err := db.queryCalendarEvents(query, now)
	if err != nil {
		return nil, err
	}
	if len(events) == 0 {
		return nil, nil
	}
	return &events[0], nil
}

// DeleteStaleCalendarEvents removes events for a calendar synced before the
// given timestamp — "not re-stamped in this sync pass", which covers both an
// event aging out of the history window and an event removed upstream (the
// two share this one delete branch, see internal/calendar/sync.go and
// internal/caldav/sync.go). An event still referenced by a meeting_transcripts
// or meeting_recaps row is spared even when stale, so a locally-recorded
// meeting keeps its event association (title/attendees/description) for
// recap/notes/chapters regeneration and the attendee-scoped voice-print pool
// (owner decision 14) — including a meeting later cancelled upstream, which
// therefore persists locally. A row already detached before this guard
// shipped (event_id already NULL) is not backfilled.
func (db *DB) DeleteStaleCalendarEvents(calendarID string, beforeSyncedAt string) (int, error) {
	result, err := db.Exec(`
		DELETE FROM calendar_events
		 WHERE calendar_id = ? AND synced_at < ?
		   AND NOT EXISTS (SELECT 1 FROM meeting_transcripts t WHERE t.event_id = calendar_events.id)
		   AND NOT EXISTS (SELECT 1 FROM meeting_recaps    r WHERE r.event_id = calendar_events.id)
	`, calendarID, beforeSyncedAt)
	if err != nil {
		return 0, fmt.Errorf("deleting stale calendar events: %w", err)
	}
	n, _ := result.RowsAffected()
	return int(n), nil
}

// ClearGoogleAccountCalendarData removes one Google account's calendar data —
// the `calendar logout` purge. Only calendars whose account_id is accountID
// and their events are touched: other Google accounts, CalDAV/ICS calendars
// (NULL account_id) and the shared calendar_attendee_map cache stay. An event
// still referenced by a meeting_transcripts or meeting_recaps row is spared,
// the same NOT EXISTS guard as DeleteStaleCalendarEvents (owner decision 14 —
// deleting it would SET NULL the recording's event link for good), and so is
// the calendar row that still holds such an event (calendar_events.calendar_id
// is a foreign key) — detached from the account (account_id NULL,
// is_selected 0), so another Google account sharing that calendar id can
// claim it on UpsertCalendar. Returns the number of events deleted.
func (db *DB) ClearGoogleAccountCalendarData(accountID int64) (int, error) {
	tx, err := db.Begin()
	if err != nil {
		return 0, fmt.Errorf("clearing calendar data for google account %d: %w", accountID, err)
	}
	defer tx.Rollback()

	n, err := purgeGoogleAccountCalendarsTx(tx, accountID)
	if err != nil {
		return 0, fmt.Errorf("clearing calendar data for google account %d: %w", accountID, err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("clearing calendar data for google account %d: %w", accountID, err)
	}
	return int(n), nil
}

// purgeGoogleAccountCalendarsTx deletes accountID's calendar events and
// calendar rows inside tx, except that an event a meeting_transcripts or
// meeting_recaps row references is spared (the DeleteStaleCalendarEvents
// guard, owner decision 14), and so is the calendar row still holding such an
// event (calendar_events.calendar_id is a foreign key). A spared calendar row
// is detached — account_id NULL, is_selected 0 — so it no longer names the
// account (whose row may be deleted next) and is never synced for it; a later
// account sharing that calendar id claims it on UpsertCalendar. Returns the
// number of events deleted.
func purgeGoogleAccountCalendarsTx(tx *sql.Tx, accountID int64) (int64, error) {
	result, err := tx.Exec(`
		DELETE FROM calendar_events
		 WHERE calendar_id IN (SELECT id FROM calendar_calendars WHERE account_id = ?)
		   AND NOT EXISTS (SELECT 1 FROM meeting_transcripts t WHERE t.event_id = calendar_events.id)
		   AND NOT EXISTS (SELECT 1 FROM meeting_recaps    r WHERE r.event_id = calendar_events.id)
	`, accountID)
	if err != nil {
		return 0, fmt.Errorf("deleting calendar events of google account %d: %w", accountID, err)
	}
	n, err := result.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("counting deleted calendar events of google account %d: %w", accountID, err)
	}
	if _, err := tx.Exec(`
		DELETE FROM calendar_calendars
		 WHERE account_id = ?
		   AND NOT EXISTS (SELECT 1 FROM calendar_events e WHERE e.calendar_id = calendar_calendars.id)
	`, accountID); err != nil {
		return 0, fmt.Errorf("deleting calendars of google account %d: %w", accountID, err)
	}
	if _, err := tx.Exec(`UPDATE calendar_calendars SET account_id = NULL, is_selected = 0 WHERE account_id = ?`,
		accountID); err != nil {
		return 0, fmt.Errorf("detaching kept calendars of google account %d: %w", accountID, err)
	}
	return n, nil
}

// UpsertAttendeeMap caches an email to slack_user_id mapping.
func (db *DB) UpsertAttendeeMap(email, slackUserID string) error {
	_, err := db.Exec(`INSERT OR REPLACE INTO calendar_attendee_map (email, slack_user_id, resolved_at)
		VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now'))`, email, slackUserID)
	if err != nil {
		return fmt.Errorf("upserting attendee map for %s: %w", email, err)
	}
	return nil
}

// GetAttendeeMap returns the full email to slack_user_id cache.
func (db *DB) GetAttendeeMap() (map[string]string, error) {
	rows, err := db.Query(`SELECT email, slack_user_id FROM calendar_attendee_map WHERE slack_user_id != ''`)
	if err != nil {
		return nil, fmt.Errorf("querying attendee map: %w", err)
	}
	defer rows.Close()

	m := make(map[string]string)
	for rows.Next() {
		var email, uid string
		if err := rows.Scan(&email, &uid); err != nil {
			return nil, fmt.Errorf("scanning attendee map: %w", err)
		}
		m[email] = uid
	}
	return m, rows.Err()
}

// GetSlackUserIDByEmail looks up a cached Slack user ID for an email.
func (db *DB) GetSlackUserIDByEmail(email string) (string, error) {
	var uid string
	err := db.QueryRow(`SELECT slack_user_id FROM calendar_attendee_map WHERE email = ?`, email).Scan(&uid)
	if err != nil {
		return "", err
	}
	return uid, nil
}

// GetMeetingPrepCache returns a cached meeting prep result for the given event.
func (db *DB) GetMeetingPrepCache(eventID string) (*MeetingPrepCache, error) {
	var c MeetingPrepCache
	err := db.QueryRow(`SELECT event_id, result_json, user_notes, generated_at FROM meeting_prep_cache WHERE event_id = ?`, eventID).
		Scan(&c.EventID, &c.ResultJSON, &c.UserNotes, &c.GeneratedAt)
	if err != nil {
		return nil, err
	}
	return &c, nil
}

// SaveMeetingPrepCache upserts a meeting prep result for the given event.
func (db *DB) SaveMeetingPrepCache(c MeetingPrepCache) error {
	_, err := db.Exec(`INSERT OR REPLACE INTO meeting_prep_cache (event_id, result_json, user_notes, generated_at)
		VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now'))`,
		c.EventID, c.ResultJSON, c.UserNotes)
	if err != nil {
		return fmt.Errorf("saving meeting prep cache for %s: %w", c.EventID, err)
	}
	return nil
}

// DeleteMeetingPrepCache removes a cached meeting prep result.
func (db *DB) DeleteMeetingPrepCache(eventID string) error {
	_, err := db.Exec(`DELETE FROM meeting_prep_cache WHERE event_id = ?`, eventID)
	if err != nil {
		return fmt.Errorf("deleting meeting prep cache for %s: %w", eventID, err)
	}
	return nil
}

func (db *DB) queryCalendarEvents(query string, args ...any) ([]CalendarEvent, error) {
	rows, err := db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("querying calendar events: %w", err)
	}
	defer rows.Close()

	var events []CalendarEvent
	for rows.Next() {
		var e CalendarEvent
		if err := rows.Scan(&e.ID, &e.CalendarID, &e.Title, &e.Description, &e.Location,
			&e.StartTime, &e.EndTime, &e.OrganizerEmail, &e.Attendees,
			&e.IsRecurring, &e.IsAllDay, &e.EventStatus, &e.EventType,
			&e.HTMLLink, &e.ConferenceURL, &e.RawJSON, &e.ICalUID, &e.SyncedAt, &e.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scanning calendar event: %w", err)
		}
		events = append(events, e)
	}
	return events, rows.Err()
}

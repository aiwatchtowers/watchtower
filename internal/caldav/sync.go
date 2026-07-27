package caldav

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"

	"github.com/emersion/go-ical"
)

// Syncer fetches calendar events for one connected calendar source
// (calendar_accounts row) and stores them. One Syncer per account — mirrors
// imap.Syncer's per-account shape, but with the Google calendar.Syncer's
// window-replace discipline instead of a watermark: every cycle re-fetches
// the whole [now-24h, now+SyncDaysAhead] window, upserts with a single
// syncedAt stamp, and stale-deletes per calendar_id so events removed
// upstream disappear while other sources' events stay untouched.
type Syncer struct {
	account   db.CalendarAccount
	creds     *Credentials
	db        *db.DB
	appConfig *config.Config
	logger    *log.Logger

	// now returns the current time. Defaults to time.Now — tests override it
	// to give consecutive syncs distinct syncedAt stamps, since the
	// stale-delete comparison (synced_at < syncedAt) works at RFC3339 second
	// resolution and two same-second syncs would tie.
	now func() time.Time
}

// NewSyncer creates a Syncer for one connected calendar source.
// If logger is nil, a no-op logger is used.
func NewSyncer(account db.CalendarAccount, creds *Credentials, database *db.DB, appConfig *config.Config, logger *log.Logger) *Syncer {
	if logger == nil {
		logger = log.New(io.Discard, "", 0)
	}
	return &Syncer{account: account, creds: creds, db: database, appConfig: appConfig, logger: logger, now: time.Now}
}

// CalendarID returns the calendar_calendars/calendar_events scope for this
// account: "caldav:<id>" / "ics:<id>".
func (s *Syncer) CalendarID() string {
	return db.CalendarAccountCalendarID(s.account.Provider, s.account.ID)
}

// Sync fetches the account's events for the sync window, upserts them, and
// removes events that disappeared upstream. Returns the count of stored events.
func (s *Syncer) Sync(ctx context.Context) (int, error) {
	now := s.now().UTC()
	syncedAt := now.Format(time.RFC3339)
	winStart := now.Add(-24 * time.Hour) // past 1 day, mirroring the Google syncer

	daysAhead := s.appConfig.Calendar.SyncDaysAhead
	if daysAhead <= 0 {
		daysAhead = config.DefaultCalendarSyncDaysAhead
	}
	winEnd := now.Add(time.Duration(daysAhead) * 24 * time.Hour)

	rawEvents, err := s.fetchWindow(ctx, winStart, winEnd)
	if err != nil {
		s.recordAuthResult(err)
		return 0, fmt.Errorf("fetching calendar account %d: %w", s.account.ID, err)
	}
	s.recordAuthResult(nil)

	events := expandEvents(rawEvents, winStart, winEnd, s.logger)

	calID := s.CalendarID()
	// Register the account's calendar_calendars row (calendar_events.calendar_id
	// FK). IsSelected stays false: calendar_calendars.is_selected drives the
	// GOOGLE syncer's calendar selection, and a caldav:/ics: id must never end
	// up in its fetch/stale-delete loops. The upsert's conflict clause doesn't
	// touch is_selected, so this only applies on first insert.
	if err := s.db.UpsertCalendar(db.CalendarCalendar{
		ID:       calID,
		Name:     s.calendarName(),
		SyncedAt: syncedAt,
	}); err != nil {
		return 0, fmt.Errorf("registering calendar %s: %w", calID, err)
	}

	count := 0
	for _, ev := range events {
		if ctx.Err() != nil {
			break
		}
		s.resolveAttendees(ev.Attendees)
		attendeesJSON, err := json.Marshal(ev.Attendees)
		if err != nil {
			attendeesJSON = []byte("[]")
		}
		row := toDBEvent(ev, calID, string(attendeesJSON))
		if err := s.db.UpsertCalendarEvent(row, syncedAt); err != nil {
			s.logger.Printf("caldav account %d: upsert event %s: %v", s.account.ID, row.ID, err)
			continue
		}
		count++
	}

	// Window-replace cleanup, scoped to this account's calendar_id: events no
	// longer present upstream (or that left the window) were not re-stamped
	// this cycle and get removed. A cancelled sync must not wipe the rows it
	// never got to re-stamp, so skip the cleanup on context error.
	if ctx.Err() == nil {
		if n, err := s.db.DeleteStaleCalendarEvents(calID, syncedAt); err != nil {
			s.logger.Printf("caldav account %d: cleanup stale events: %v", s.account.ID, err)
		} else if n > 0 {
			s.logger.Printf("caldav account %d: removed %d stale events", s.account.ID, n)
		}
	}
	return count, nil
}

// fetchWindow fetches raw window-relevant VEVENTs for the account's provider.
func (s *Syncer) fetchWindow(ctx context.Context, winStart, winEnd time.Time) ([]ical.Event, error) {
	switch s.account.Provider {
	case "caldav":
		client, err := DialCalDAV(s.account.URL, s.account.Username, s.creds.Password)
		if err != nil {
			return nil, err
		}
		return client.FetchEvents(ctx, winStart, winEnd)
	case "ics":
		cal, err := FetchICS(ctx, s.creds.FeedURL)
		if err != nil {
			return nil, err
		}
		// The ICS feed is one calendar document; window filtering happens in
		// expandEvents (feeds have no server-side time-range query).
		return cal.Events(), nil
	default:
		return nil, fmt.Errorf("unknown calendar account provider %q", s.account.Provider)
	}
}

// calendarName is the display name for the account's calendar_calendars row:
// label > username > provider.
func (s *Syncer) calendarName() string {
	if s.account.Label != "" {
		return s.account.Label
	}
	if s.account.Username != "" {
		return s.account.Username
	}
	if s.account.Provider == "ics" {
		return "ICS feed"
	}
	return "CalDAV"
}

// recordAuthResult persists the account's connect/auth state. Pass err=nil to
// mark it healthy. Errors writing to the DB are logged but not returned —
// auth state is best-effort telemetry, mirroring imap.Syncer.recordAuthResult.
func (s *Syncer) recordAuthResult(err error) {
	if err == nil {
		if dbErr := s.db.SetCalendarAccountAuthState(s.account.ID, "ok", ""); dbErr != nil {
			s.logger.Printf("caldav account %d: clear auth state: %v", s.account.ID, dbErr)
		}
		return
	}
	if dbErr := s.db.SetCalendarAccountAuthState(s.account.ID, "error", err.Error()); dbErr != nil {
		s.logger.Printf("caldav account %d: record auth state: %v", s.account.ID, dbErr)
	}
}

// resolveAttendees matches attendee emails to Slack user IDs via the users
// table, caching the mapping in calendar_attendee_map — the same enrichment
// the Google syncer does (calendar.Syncer.ResolveAttendees), so downstream
// consumers see identical attendee JSON regardless of source.
func (s *Syncer) resolveAttendees(attendees []Attendee) {
	for i, a := range attendees {
		if a.Email == "" || a.SlackUserID != "" {
			continue
		}
		if uid, err := s.db.GetSlackUserIDByEmail(a.Email); err == nil && uid != "" {
			attendees[i].SlackUserID = uid
			continue
		}
		user, err := s.db.GetUserByEmail(a.Email)
		if err == nil && user != nil {
			attendees[i].SlackUserID = user.ID
			_ = s.db.UpsertAttendeeMap(a.Email, user.ID)
		}
	}
}

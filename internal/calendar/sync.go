package calendar

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"strings"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// Syncer fetches calendar events and stores them in the database.
type Syncer struct {
	client    *Client
	db        *db.DB
	cfg       *config.Config
	logger    *log.Logger
	accountID int64
}

// NewSyncer creates a calendar syncer for the connected google_accounts row
// accountID.
// If logger is nil, a no-op logger is used.
func NewSyncer(client *Client, database *db.DB, cfg *config.Config, logger *log.Logger, accountID int64) *Syncer {
	if logger == nil {
		logger = log.New(io.Discard, "", 0)
	}
	return &Syncer{
		client:    client,
		db:        database,
		cfg:       cfg,
		logger:    logger,
		accountID: accountID,
	}
}

// Sync fetches calendars and events, upserts them to DB, and cleans up stale data.
// Returns the count of new/updated events.
func (s *Syncer) Sync(ctx context.Context) (int, error) {
	now := time.Now().UTC()
	syncedAt := now.Format(time.RFC3339)
	timeMin := now.Add(-24 * time.Hour) // past 1 day

	daysAhead := s.cfg.Calendar.SyncDaysAhead
	if daysAhead <= 0 {
		daysAhead = config.DefaultCalendarSyncDaysAhead
	}
	timeMax := now.Add(time.Duration(daysAhead) * 24 * time.Hour)

	// Sync calendar list first. realPrimaryID captures this account's actual
	// primary calendar id (its own email) so a later "primary" fallback can
	// resolve to a per-account-unique id instead of the literal string
	// "primary", which every account would otherwise collide on.
	calInfos, err := s.client.FetchCalendars(ctx)
	var realPrimaryID string
	if err != nil {
		s.recordAuthResult(ctx, err)
		if errors.Is(err, ErrAuthRevoked) {
			return 0, err
		}
		s.logger.Printf("calendar: failed to fetch calendar list: %v", err)
		// Continue with selected calendars from config if available.
	} else {
		for _, ci := range calInfos {
			if ci.Primary {
				realPrimaryID = ci.ID
			}
			cal := db.CalendarCalendar{
				ID:         ci.ID,
				Name:       ci.Summary,
				IsPrimary:  ci.Primary,
				IsSelected: true,
				Color:      ci.Color,
				SyncedAt:   syncedAt,
			}
			if err := s.db.UpsertCalendar(s.accountID, cal); err != nil {
				s.logger.Printf("calendar: failed to upsert calendar %s: %v", ci.ID, err)
			}
		}
	}

	// Determine which calendars to sync. CalDAV/ICS accounts (internal/caldav)
	// register their own calendar_calendars rows scoped "caldav:<id>"/"ics:<id>";
	// those must never enter this Google syncer's fetch loop (the Google API
	// doesn't know them) nor its stale-delete loop (which would wipe another
	// source's freshly-synced events).
	//
	// The legacy cfg.Calendar.SelectedCalendars config path only ever applied
	// to the single pre-multi-account install (google_accounts id 1); every
	// other account goes straight to its own DB selection.
	var calendarIDs []string
	if s.accountID == 1 {
		calendarIDs = dropNonGoogleCalendarIDs(s.cfg.Calendar.SelectedCalendars)
	}
	// skipStaleDelete marks calendar ids in this run's calendarIDs that had to
	// fall back to the literal "primary" placeholder because realPrimaryID
	// couldn't be resolved this cycle (calendar-list fetch failed, or came
	// back with no calendar flagged primary). Every account falls back to the
	// same literal id in that case, so cleaning it up here could delete
	// another account's freshly-synced events under the same bucket —
	// skip the stale-delete pass for it instead; events still sync fine.
	skipStaleDelete := map[string]bool{}
	primaryFallback := func() string {
		if realPrimaryID != "" {
			return realPrimaryID
		}
		s.logger.Printf("calendar: real primary calendar id unresolved this cycle, using literal \"primary\" and skipping its stale-event cleanup")
		skipStaleDelete["primary"] = true
		return "primary"
	}
	if len(calendarIDs) == 0 {
		// Use selected calendars from DB.
		dbIDs, err := s.db.GetSelectedCalendarIDs(s.accountID)
		if err != nil {
			s.logger.Printf("calendar: failed to get selected calendars from DB, falling back to primary: %v", err)
			calendarIDs = []string{primaryFallback()}
		} else if dbIDs = dropNonGoogleCalendarIDs(dbIDs); len(dbIDs) == 0 {
			calendarIDs = []string{primaryFallback()}
		} else {
			calendarIDs = dbIDs
		}
	}

	events, err := s.client.FetchEvents(ctx, calendarIDs, timeMin, timeMax)
	if err != nil {
		s.recordAuthResult(ctx, err)
		return 0, fmt.Errorf("fetching calendar events: %w", err)
	}

	// Successful fetch — clear any previously recorded auth failure.
	s.recordAuthResult(ctx, nil)

	// Resolve attendee emails to Slack user IDs.
	events = s.ResolveAttendees(events)

	count := 0
	for _, e := range events {
		attendeesJSON, err := json.Marshal(e.Attendees)
		if err != nil {
			attendeesJSON = []byte("[]")
		}

		rawJSON := e.RawJSON
		if rawJSON == "" {
			rawJSON = "{}"
		}

		dbEvent := db.CalendarEvent{
			ID:             e.ID,
			CalendarID:     e.CalendarID,
			Title:          e.Title,
			Description:    e.Description,
			Location:       e.Location,
			StartTime:      e.StartTime.Format(time.RFC3339),
			EndTime:        e.EndTime.Format(time.RFC3339),
			OrganizerEmail: e.Organizer,
			Attendees:      string(attendeesJSON),
			IsRecurring:    e.Recurring,
			IsAllDay:       e.IsAllDay,
			EventStatus:    e.EventStatus,
			EventType:      e.EventType,
			HTMLLink:       e.HTMLLink,
			RawJSON:        rawJSON,
			ICalUID:        e.ICalUID,
			UpdatedAt:      e.UpdatedAt,
		}

		if err := s.db.UpsertCalendarEvent(dbEvent, syncedAt); err != nil {
			s.logger.Printf("calendar: failed to upsert event %s: %v", e.ID, err)
			continue
		}
		count++
	}

	// Cleanup stale events per calendar (synced before this run).
	for _, calID := range calendarIDs {
		if skipStaleDelete[calID] {
			continue
		}
		if n, err := s.db.DeleteStaleCalendarEvents(calID, syncedAt); err != nil {
			s.logger.Printf("calendar: failed to cleanup stale events for %s: %v", calID, err)
		} else if n > 0 {
			s.logger.Printf("calendar: removed %d stale events from %s", n, calID)
		}
	}

	return count, nil
}

// dropNonGoogleCalendarIDs filters out calendar ids owned by the CalDAV/ICS
// multi-account source ("caldav:<id>"/"ics:<id>" — db.CalendarAccountCalendarID),
// which share the calendar_calendars table but are synced by internal/caldav.
func dropNonGoogleCalendarIDs(ids []string) []string {
	out := ids[:0:0]
	for _, id := range ids {
		if strings.HasPrefix(id, "caldav:") || strings.HasPrefix(id, "ics:") {
			continue
		}
		out = append(out, id)
	}
	return out
}

// recordAuthResult persists the calendar auth state. Pass err=nil to mark auth as healthy.
// Errors writing to the DB are logged but not returned — auth state is best-effort telemetry.
// A cancelled ctx means daemon shutdown, not an auth problem, so the state is left untouched —
// the guard is ctx-based because Go's signal-cancel cause does not unwrap to context.Canceled.
func (s *Syncer) recordAuthResult(ctx context.Context, err error) {
	if s.db == nil {
		return
	}
	if err == nil {
		if dbErr := s.db.SetGoogleAccountAuthState(s.accountID, "ok", ""); dbErr != nil {
			s.logger.Printf("calendar: failed to clear auth state: %v", dbErr)
		}
		return
	}
	if ctx.Err() != nil {
		s.logger.Printf("calendar: sync cancelled, leaving auth state untouched: %v", err)
		return
	}
	status := "error"
	if errors.Is(err, ErrAuthRevoked) {
		status = "revoked"
	}
	if dbErr := s.db.SetGoogleAccountAuthState(s.accountID, status, err.Error()); dbErr != nil {
		s.logger.Printf("calendar: failed to record auth state: %v", dbErr)
	}
}

// ResolveAttendees matches attendee emails to Slack user_ids via the users table
// and caches the mapping in calendar_attendee_map.
func (s *Syncer) ResolveAttendees(events []CalendarEvent) []CalendarEvent {
	for i, e := range events {
		for j, a := range e.Attendees {
			if a.Email == "" {
				continue
			}
			// Check cache first.
			if uid, err := s.db.GetSlackUserIDByEmail(a.Email); err == nil && uid != "" {
				events[i].Attendees[j].SlackUserID = uid
				continue
			}
			// Look up in users table.
			user, err := s.db.GetUserByEmail(a.Email)
			if err == nil && user != nil {
				events[i].Attendees[j].SlackUserID = user.ID
				// Cache the mapping.
				_ = s.db.UpsertAttendeeMap(a.Email, user.ID)
			}
		}
	}
	return events
}

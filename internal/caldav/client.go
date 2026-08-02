package caldav

import (
	"context"
	"fmt"
	"net/http"
	"time"

	"github.com/emersion/go-ical"
	"github.com/emersion/go-webdav"
	webcaldav "github.com/emersion/go-webdav/caldav"
)

// httpTimeout bounds every CalDAV/ICS HTTP request so a hung server can't
// stall the daemon's sync cycle.
const httpTimeout = 30 * time.Second

// Client wraps a go-webdav CalDAV client authenticated with HTTP basic auth
// (username/password or app password — iCloud, Fastmail, Yandex, Nextcloud,
// corporate servers).
type Client struct {
	c *webcaldav.Client
}

// DialCalDAV creates a CalDAV client for the server at baseURL.
func DialCalDAV(baseURL, username, password string) (*Client, error) {
	httpClient := webdav.HTTPClientWithBasicAuth(&http.Client{Timeout: httpTimeout}, username, password)
	c, err := webcaldav.NewClient(httpClient, baseURL)
	if err != nil {
		return nil, fmt.Errorf("creating caldav client for %s: %w", baseURL, err)
	}
	return &Client{c: c}, nil
}

// FetchEvents discovers the account's calendars (current-user-principal →
// calendar-home-set → calendar collections) and fetches every VEVENT
// overlapping [winStart, winEnd) via a calendar-query time-range REPORT.
// The returned events are raw components — recurring masters are NOT
// expanded here; expandEvents does that client-side, since servers vary in
// whether they expand recurrences for time-range queries.
func (c *Client) FetchEvents(ctx context.Context, winStart, winEnd time.Time) ([]ical.Event, error) {
	principal, err := c.c.FindCurrentUserPrincipal(ctx)
	if err != nil {
		return nil, fmt.Errorf("finding current user principal: %w", err)
	}
	homeSet, err := c.c.FindCalendarHomeSet(ctx, principal)
	if err != nil {
		return nil, fmt.Errorf("finding calendar home set: %w", err)
	}
	calendars, err := c.c.FindCalendars(ctx, homeSet)
	if err != nil {
		return nil, fmt.Errorf("listing calendars: %w", err)
	}

	query := &webcaldav.CalendarQuery{
		CompRequest: webcaldav.CalendarCompRequest{
			Name:     ical.CompCalendar,
			AllProps: true,
			AllComps: true,
		},
		CompFilter: webcaldav.CompFilter{
			Name: ical.CompCalendar,
			Comps: []webcaldav.CompFilter{{
				Name:  ical.CompEvent,
				Start: winStart,
				End:   winEnd,
			}},
		},
	}

	var events []ical.Event
	for _, cal := range calendars {
		if !supportsEvents(cal) {
			continue
		}
		objects, err := c.c.QueryCalendar(ctx, cal.Path, query)
		if err != nil {
			return nil, fmt.Errorf("querying calendar %s: %w", cal.Path, err)
		}
		for _, obj := range objects {
			if obj.Data == nil {
				continue
			}
			events = append(events, obj.Data.Events()...)
		}
	}
	return events, nil
}

// supportsEvents reports whether a calendar collection can contain VEVENTs.
// An empty SupportedComponentSet means the server didn't advertise one, so
// assume events are allowed.
func supportsEvents(cal webcaldav.Calendar) bool {
	if len(cal.SupportedComponentSet) == 0 {
		return true
	}
	for _, comp := range cal.SupportedComponentSet {
		if comp == ical.CompEvent {
			return true
		}
	}
	return false
}

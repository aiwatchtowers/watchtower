package automations

import (
	"context"
	"fmt"
	"slices"
	"time"

	"watchtower/internal/db"
)

const (
	calendarEventChanged = "calendar.event_changed"
	calendarCancelled    = "cancelled"
)

// CalendarSource is the event source of phaseCalendarSync and
// phaseCalDAVSync together (Before ahead of the first, After behind the
// second): per event the phases changed, one calendar.event_changed —
// created (a new id), cancelled (event_status became cancelled, or a row gone
// whose end is still after clock's now), updated (updated_at, start or end
// moved). A row gone whose end has passed left the sync window: nothing. A
// calendar with no events before the phases (just connected) publishes
// nothing, and neither does a calendar that names no account any more (a
// logout or removal).
func CalendarSource(d *db.DB, clock Clock) EventSource {
	return calendarSource{d: d, clock: clock}
}

type calendarSource struct {
	d     *db.DB
	clock Clock
}

func (calendarSource) Type() string { return calendarEventChanged }

func (s calendarSource) Before(context.Context) (EventDiff, error) {
	marks, err := s.d.CalendarEventMarks()
	if err != nil {
		return nil, fmt.Errorf("snapshotting calendar events: %w", err)
	}
	calendars := map[string]bool{}
	for _, m := range marks {
		calendars[m.CalendarID] = true
	}
	return calendarDiff{calendarSource: s, before: marks, calendars: calendars}, nil
}

type calendarDiff struct {
	calendarSource
	before    map[string]db.CalendarEventMark
	calendars map[string]bool // calendars holding events before the phases
}

// calendarAccount is one calendar's event label; ok false when it names no
// account.
type calendarAccount struct {
	label string
	ok    bool
}

func (s calendarDiff) After(ctx context.Context) ([]Event, error) {
	after, err := s.d.CalendarEventMarks()
	if err != nil {
		return nil, fmt.Errorf("reading calendar events: %w", err)
	}
	now := s.clock.Now()
	accounts := map[string]calendarAccount{}
	var events []Event
	for _, id := range eventIDs(s.before, after) {
		if err := ctx.Err(); err != nil {
			return nil, fmt.Errorf("diffing calendar events: %w", err)
		}
		calendar, change := s.change(id, after, now)
		if change == "" {
			continue
		}
		acct, err := s.account(calendar, accounts)
		if err != nil {
			return nil, err
		}
		if acct.ok {
			events = append(events, Event{Type: calendarEventChanged, Fields: map[string]any{
				"account": acct.label, "event_id": id, "change": change,
			}})
		}
	}
	return events, nil
}

// change returns one event's calendar and change; "" is no change.
func (s calendarDiff) change(id string, after map[string]db.CalendarEventMark, now time.Time) (string, string) {
	b, wasThere := s.before[id]
	a, isThere := after[id]
	switch {
	case !wasThere:
		if s.calendars[a.CalendarID] && a.Status != calendarCancelled {
			return a.CalendarID, "created"
		}
	case !isThere:
		if b.Status != calendarCancelled && endsAfter(b.End, now) {
			return b.CalendarID, calendarCancelled
		}
	case b.Status == calendarCancelled:
		// Already announced; nothing more to say about a cancelled event.
	case a.Status == calendarCancelled:
		return a.CalendarID, calendarCancelled
	case a.UpdatedAt != b.UpdatedAt || a.Start != b.Start || a.End != b.End:
		return a.CalendarID, "updated"
	}
	return "", ""
}

// endsAfter reports whether an RFC 3339 end time is after now; an
// unparseable one is not.
func endsAfter(end string, now time.Time) bool {
	t, err := time.Parse(time.RFC3339, end)
	return err == nil && t.After(now)
}

// eventIDs returns, sorted, every event id in before or after.
func eventIDs(before, after map[string]db.CalendarEventMark) []string {
	ids := make([]string, 0, len(after))
	for id := range after {
		ids = append(ids, id)
	}
	for id := range before {
		if _, ok := after[id]; !ok {
			ids = append(ids, id)
		}
	}
	slices.Sort(ids)
	return ids
}

// account reads a calendar's account label once per diff.
func (s calendarDiff) account(calendar string, cache map[string]calendarAccount) (calendarAccount, error) {
	if a, ok := cache[calendar]; ok {
		return a, nil
	}
	label, ok, err := s.d.CalendarEventLabel(calendar)
	if err != nil {
		return calendarAccount{}, fmt.Errorf("labelling calendar events: %w", err)
	}
	a := calendarAccount{label: label, ok: ok}
	cache[calendar] = a
	return a, nil
}

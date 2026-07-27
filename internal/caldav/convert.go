package caldav

import (
	"fmt"
	"log"
	"strings"
	"time"

	"watchtower/internal/db"

	"github.com/emersion/go-ical"
)

// instanceTimeFormat stamps a recurring occurrence's start into its instance
// UID ("<uid>:20260727T090000Z") — UIDs are only unique per base event, so
// expanded instances need the occurrence start to stay distinct.
const instanceTimeFormat = "20060102T150405Z"

// expandEvents converts raw iCalendar VEVENTs into window-relevant Events,
// expanding recurring events into concrete occurrences.
//
// Recurrence handling: events with an RRULE are expanded via go-ical's
// RecurrenceSet (rrule-go) into every occurrence overlapping
// [winStart, winEnd), each with the occurrence start appended to its UID.
// Override components (same UID + RECURRENCE-ID) replace their base
// occurrence: the base expansion skips overridden starts and the override is
// emitted as its own instance (or dropped entirely when STATUS:CANCELLED,
// which also covers plain cancelled events — mirroring the Google syncer's
// skip of status="cancelled" items). EXDATE/RDATE are honored by rrule-go.
//
// Unparseable events are logged and skipped rather than failing the batch.
func expandEvents(events []ical.Event, winStart, winEnd time.Time, logger *log.Logger) []Event {
	// Overridden occurrence starts per UID (unix seconds), so base expansion
	// can skip occurrences that a RECURRENCE-ID component replaces.
	overridden := make(map[string]map[int64]bool)
	for _, e := range events {
		rid, ok, err := recurrenceID(e)
		if err != nil || !ok {
			continue
		}
		uid, _ := propText(e, ical.PropUID)
		if overridden[uid] == nil {
			overridden[uid] = make(map[int64]bool)
		}
		overridden[uid][rid.Unix()] = true
	}

	var out []Event
	for _, e := range events {
		uid, _ := propText(e, ical.PropUID)
		if uid == "" {
			logger.Printf("caldav: skipping event without UID (summary %q)", titleOf(e))
			continue
		}
		base, err := parseEvent(e)
		if err != nil {
			logger.Printf("caldav: skipping unparseable event %s: %v", uid, err)
			continue
		}
		if base.Status == "cancelled" {
			continue // mirrors the Google syncer's skip of cancelled items
		}

		if rid, ok, err := recurrenceID(e); err == nil && ok {
			// Override of one recurring occurrence: emit as its own instance,
			// scoped by the *original* occurrence start so it replaces the base
			// occurrence's row instead of duplicating it.
			base.UID = uid + ":" + rid.UTC().Format(instanceTimeFormat)
			base.Recurring = true
			if overlapsWindow(base.Start, base.End, winStart, winEnd) {
				out = append(out, base)
			}
			continue
		} else if err != nil {
			logger.Printf("caldav: skipping event %s with bad RECURRENCE-ID: %v", uid, err)
			continue
		}

		rset, err := e.RecurrenceSet(time.UTC)
		if err != nil {
			logger.Printf("caldav: skipping event %s with bad recurrence rule: %v", uid, err)
			continue
		}
		if rset == nil {
			// Plain single event.
			if overlapsWindow(base.Start, base.End, winStart, winEnd) {
				out = append(out, base)
			}
			continue
		}

		// Recurring: occurrences starting up to one event-duration before the
		// window still overlap it, so widen the Between() lower bound by dur.
		dur := base.End.Sub(base.Start)
		from := winStart
		if dur > 0 {
			from = winStart.Add(-dur)
		}
		for _, occ := range rset.Between(from, winEnd, true) {
			if overridden[uid][occ.Unix()] {
				continue
			}
			start := occ.UTC()
			end := start.Add(dur)
			if !overlapsWindow(start, end, winStart, winEnd) {
				continue
			}
			inst := base
			inst.UID = uid + ":" + start.Format(instanceTimeFormat)
			inst.Start, inst.End = start, end
			inst.Recurring = true
			out = append(out, inst)
		}
	}
	return out
}

// overlapsWindow reports whether [start, end) intersects [winStart, winEnd) —
// the same overlap semantics as Google's timeMin/timeMax event listing.
// Zero-duration events count as overlapping when their start is in-window.
func overlapsWindow(start, end, winStart, winEnd time.Time) bool {
	if !start.Before(winEnd) {
		return false
	}
	if end.After(winStart) {
		return true
	}
	return end.Equal(start) && !start.Before(winStart)
}

// parseEvent converts one VEVENT into the intermediate Event model.
// Times are normalized to UTC; TZID-parameterized values are resolved by
// go-ical, floating times are interpreted as UTC.
func parseEvent(e ical.Event) (Event, error) {
	start, err := e.DateTimeStart(time.UTC)
	if err != nil {
		return Event{}, fmt.Errorf("parsing DTSTART: %w", err)
	}
	end, err := e.DateTimeEnd(time.UTC)
	if err != nil {
		return Event{}, fmt.Errorf("parsing DTEND: %w", err)
	}

	uid, _ := propText(e, ical.PropUID)
	title, _ := propText(e, ical.PropSummary)
	description, _ := propText(e, ical.PropDescription)
	location, _ := propText(e, ical.PropLocation)

	ev := Event{
		UID:         uid,
		Title:       strings.TrimSpace(title),
		Description: description,
		Location:    location,
		Start:       start.UTC(),
		End:         end.UTC(),
		Status:      eventStatus(e),
		UpdatedAt:   lastModified(e),
	}

	if p := e.Props.Get(ical.PropDateTimeStart); p != nil && p.ValueType() == ical.ValueDate {
		ev.IsAllDay = true
	}

	if p := e.Props.Get(ical.PropOrganizer); p != nil {
		ev.Organizer = stripMailto(p.Value)
	}
	for _, p := range e.Props[ical.PropAttendee] {
		email := stripMailto(p.Value)
		if email == "" {
			continue
		}
		ev.Attendees = append(ev.Attendees, Attendee{
			Email:          email,
			DisplayName:    p.Params.Get(ical.ParamCommonName),
			ResponseStatus: mapPartStat(p.Params.Get(ical.ParamParticipationStatus)),
		})
	}
	return ev, nil
}

// toDBEvent converts an expanded Event into a db.CalendarEvent row matching
// the Google syncer's row conventions exactly (internal/calendar/sync.go):
// RFC3339 UTC times, attendees as a JSON array, and calendar_id scoping.
// The row id is account-scoped ("caldav:<accountID>:<uid>") because
// iCalendar UIDs are only unique within one calendar, not across accounts —
// the same lesson as imap_messages' account_id scoping.
func toDBEvent(ev Event, calendarID, attendeesJSON string) db.CalendarEvent {
	return db.CalendarEvent{
		ID:             calendarID + ":" + ev.UID,
		CalendarID:     calendarID,
		Title:          ev.Title,
		Description:    ev.Description,
		Location:       ev.Location,
		StartTime:      ev.Start.Format(time.RFC3339),
		EndTime:        ev.End.Format(time.RFC3339),
		OrganizerEmail: ev.Organizer,
		Attendees:      attendeesJSON,
		IsRecurring:    ev.Recurring,
		IsAllDay:       ev.IsAllDay,
		EventStatus:    ev.Status,
		EventType:      "default",
		HTMLLink:       "",   // no universal deep-link scheme for CalDAV/ICS events
		RawJSON:        "{}", // mirrors the Google syncer's empty-raw fallback
		UpdatedAt:      ev.UpdatedAt,
	}
}

// recurrenceID returns the event's RECURRENCE-ID time when present.
func recurrenceID(e ical.Event) (time.Time, bool, error) {
	p := e.Props.Get(ical.PropRecurrenceID)
	if p == nil {
		return time.Time{}, false, nil
	}
	t, err := p.DateTime(time.UTC)
	if err != nil {
		return time.Time{}, true, err
	}
	return t, true, nil
}

// eventStatus maps the iCal STATUS onto the calendar_events.event_status
// vocabulary used by the Google syncer: confirmed | tentative | cancelled.
func eventStatus(e ical.Event) string {
	s, err := e.Status()
	if err != nil || s == "" {
		return "confirmed"
	}
	return strings.ToLower(string(s))
}

// lastModified returns LAST-MODIFIED (falling back to DTSTAMP) as ISO8601,
// or "" — matching calendar_events.updated_at's empty default.
func lastModified(e ical.Event) string {
	for _, name := range []string{ical.PropLastModified, ical.PropDateTimeStamp} {
		if p := e.Props.Get(name); p != nil {
			if t, err := p.DateTime(time.UTC); err == nil {
				return t.UTC().Format(time.RFC3339)
			}
		}
	}
	return ""
}

// mapPartStat maps an iCal PARTSTAT onto Google's response_status
// vocabulary, which the shared attendees JSON uses.
func mapPartStat(partStat string) string {
	switch strings.ToUpper(partStat) {
	case "ACCEPTED":
		return "accepted"
	case "DECLINED":
		return "declined"
	case "TENTATIVE":
		return "tentative"
	default:
		return "needsAction"
	}
}

// stripMailto normalizes a calendar-address value ("mailto:a@b") to a bare email.
func stripMailto(v string) string {
	if len(v) >= 7 && strings.EqualFold(v[:7], "mailto:") {
		return v[7:]
	}
	return v
}

// propText returns a component's text property value, or "" when absent.
func propText(e ical.Event, name string) (string, error) {
	p := e.Props.Get(name)
	if p == nil {
		return "", nil
	}
	return p.Text()
}

// titleOf is a best-effort SUMMARY for log lines about broken events.
func titleOf(e ical.Event) string {
	t, _ := propText(e, ical.PropSummary)
	return t
}

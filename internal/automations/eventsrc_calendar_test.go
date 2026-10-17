package automations

import (
	"context"
	"reflect"
	"testing"
	"time"

	"watchtower/internal/db"
)

// calendarNow is the fixtures' "now": events end before or after it.
var calendarNow = time.Date(2026, 10, 17, 12, 0, 0, 0, time.UTC)

const workCalendar = "primary@example.com"

// calEvent is an event on calendar cal; title, description and location carry
// contentMarker.
func calEvent(id, cal, start, end string) db.CalendarEvent {
	return db.CalendarEvent{ID: id, CalendarID: cal, Title: contentMarker, Description: contentMarker,
		Location: contentMarker, StartTime: start, EndTime: end, EventStatus: "confirmed",
		UpdatedAt: "2026-10-01T00:00:00Z"}
}

// calendarFixture seeds Google account "work" with calendar workCalendar
// holding a future event (e-future) and one that ended (e-past).
func calendarFixture(t *testing.T) *db.DB {
	t.Helper()
	d := openEventDB(t)
	g, err := d.CreateGoogleAccount(db.GoogleAccount{Email: "owner@example.com", Label: "work", CalendarEnabled: true})
	must(t, err)
	must(t, d.UpsertCalendar(g, db.CalendarCalendar{ID: workCalendar, Name: contentMarker, IsSelected: true}))
	must(t, d.UpsertCalendarEvent(calEvent("e-future", workCalendar, "2026-10-20T09:00:00Z", "2026-10-20T10:00:00Z")))
	must(t, d.UpsertCalendarEvent(calEvent("e-past", workCalendar, "2026-10-16T09:00:00Z", "2026-10-16T10:00:00Z")))
	return d
}

// calendarEvents runs the calendar source around phase at calendarNow.
func calendarEvents(t *testing.T, d *db.DB, phase func()) []Event {
	t.Helper()
	ctx := context.Background()
	src := CalendarSource(d, &indexerClock{now: calendarNow})
	if src.Type() != "calendar.event_changed" {
		t.Errorf("Type() = %q", src.Type())
	}
	diff, err := src.Before(ctx)
	must(t, err)
	phase()
	events, err := diff.After(ctx)
	must(t, err)
	return events
}

func calChange(account, id, change string) Event {
	return Event{Type: "calendar.event_changed", Fields: map[string]any{"account": account, "event_id": id, "change": change}}
}

func deleteCalEvent(t *testing.T, d *db.DB, id string) {
	t.Helper()
	_, err := d.Exec(`DELETE FROM calendar_events WHERE id = ?`, id)
	must(t, err)
}

func TestCalendarEvents_CreatedUpdatedCancelled(t *testing.T) {
	d := calendarFixture(t)
	must(t, d.UpsertCalendarEvent(calEvent("e-later", workCalendar, "2026-10-21T09:00:00Z", "2026-10-21T10:00:00Z")))
	must(t, d.UpsertCalendarEvent(calEvent("e-same", workCalendar, "2026-10-22T09:00:00Z", "2026-10-22T10:00:00Z")))
	got := calendarEvents(t, d, func() {
		must(t, d.UpsertCalendarEvent(calEvent("e-new", workCalendar, "2026-10-23T09:00:00Z", "2026-10-23T10:00:00Z")))
		must(t, d.UpsertCalendarEvent(calEvent("e-future", workCalendar, "2026-10-20T11:00:00Z", "2026-10-20T12:00:00Z")))
		off := calEvent("e-later", workCalendar, "2026-10-21T09:00:00Z", "2026-10-21T10:00:00Z")
		off.EventStatus, off.UpdatedAt = "cancelled", "2026-10-02T00:00:00Z"
		must(t, d.UpsertCalendarEvent(off))
		must(t, d.UpsertCalendarEvent(calEvent("e-same", workCalendar, "2026-10-22T09:00:00Z", "2026-10-22T10:00:00Z")))
	})
	want := []Event{
		calChange("work", "e-future", "updated"),
		calChange("work", "e-later", "cancelled"),
		calChange("work", "e-new", "created"),
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("events = %+v\nwant %+v", got, want)
	}
}

func TestCalendarEvents_DeletedFutureEventIsCancelled(t *testing.T) {
	d := calendarFixture(t)
	got := calendarEvents(t, d, func() { deleteCalEvent(t, d, "e-future") })
	if want := []Event{calChange("work", "e-future", "cancelled")}; !reflect.DeepEqual(got, want) {
		t.Errorf("events = %+v, want %+v", got, want)
	}
}

func TestCalendarEvents_PastEventLeavingWindowIsNotCancelled(t *testing.T) {
	d := calendarFixture(t)
	got := calendarEvents(t, d, func() { deleteCalEvent(t, d, "e-past") })
	if len(got) != 0 {
		t.Errorf("past event leaving the window published %+v", got)
	}
}

func TestCalendarEvents_CalDAVAccountLabel(t *testing.T) {
	d := calendarFixture(t)
	_, err := d.CreateCalendarAccount(db.CalendarAccount{Provider: "ics", Label: "feed"})
	must(t, err)
	dav, err := d.CreateCalendarAccount(db.CalendarAccount{Provider: "caldav", URL: "https://dav.example.com", Username: "owner", Label: "home"})
	must(t, err)
	cal := db.CalendarAccountCalendarID("caldav", dav)
	if cal != "caldav:2" {
		t.Fatalf("calendar id %q, want caldav:2", cal)
	}
	must(t, d.UpsertCalendar(0, db.CalendarCalendar{ID: cal, Name: contentMarker, IsSelected: true}))
	must(t, d.UpsertCalendarEvent(calEvent("d-1", cal, "2026-10-20T09:00:00Z", "2026-10-20T10:00:00Z")))
	got := calendarEvents(t, d, func() {
		must(t, d.UpsertCalendarEvent(calEvent("d-2", cal, "2026-10-24T09:00:00Z", "2026-10-24T10:00:00Z")))
	})
	if want := []Event{calChange("home", "d-2", "created")}; !reflect.DeepEqual(got, want) {
		t.Errorf("events = %+v, want %+v", got, want)
	}
}

func TestCalendarEvents_NewAccountBackfillPublishesNothing(t *testing.T) {
	d := calendarFixture(t)
	g, err := d.CreateGoogleAccount(db.GoogleAccount{Email: "home@example.com", Label: "home", CalendarEnabled: true})
	must(t, err)
	got := calendarEvents(t, d, func() {
		must(t, d.UpsertCalendar(g, db.CalendarCalendar{ID: "home@example.com", Name: "home", IsSelected: true}))
		must(t, d.UpsertCalendarEvent(calEvent("h-1", "home@example.com", "2026-10-20T09:00:00Z", "2026-10-20T10:00:00Z")))
		must(t, d.UpsertCalendarEvent(calEvent("h-2", "home@example.com", "2026-10-21T09:00:00Z", "2026-10-21T10:00:00Z")))
	})
	if len(got) != 0 {
		t.Errorf("new account's backfill published %+v", got)
	}
}

func TestCalendarEvents_RemovedAccountPublishesNothing(t *testing.T) {
	d := calendarFixture(t)
	got := calendarEvents(t, d, func() {
		_, err := d.ClearGoogleAccountCalendarData(1)
		must(t, err)
	})
	if len(got) != 0 {
		t.Errorf("logout purge published %+v", got)
	}
}

// calendarContentEvents builds calendar events from the contentMarker
// fixtures for TestBus_EventsCarryNoContent.
func calendarContentEvents(t *testing.T) []Event {
	d := calendarFixture(t)
	events := calendarEvents(t, d, func() {
		must(t, d.UpsertCalendarEvent(calEvent("e-new", workCalendar, "2026-10-23T09:00:00Z", "2026-10-23T10:00:00Z")))
		moved := calEvent("e-past", workCalendar, "2026-10-16T09:00:00Z", "2026-10-16T11:00:00Z")
		moved.Title = contentMarker + " moved"
		must(t, d.UpsertCalendarEvent(moved))
		deleteCalEvent(t, d, "e-future")
	})
	if len(events) != 3 {
		t.Fatalf("calendar content fixture built %d events, want 3", len(events))
	}
	return events
}

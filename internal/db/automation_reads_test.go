package db

import (
	"context"
	"testing"
)

// The automation read helpers refuse a non-positive limit (the tools always
// clamp it first) and return an empty, non-nil slice on an empty store.
func TestAutomationReads_LimitAndEmptyResults(t *testing.T) {
	d := OpenTestDB(t)
	ctx := context.Background()
	calls := map[string]func(limit int) (int, error){
		"inbox": func(n int) (int, error) {
			r, err := d.ListInboxForAutomation(ctx, InboxReadQuery{Limit: n})
			return len(r), err
		},
		"calendar": func(n int) (int, error) {
			r, err := d.ListCalendarEventsRange(ctx, CalendarRangeQuery{From: "2026-01-01T00:00:00Z", To: "2027-01-01T00:00:00Z", Limit: n})
			return checkNotNil(r == nil, len(r)), err
		},
		"calendar filtered to nothing": func(n int) (int, error) {
			r, err := d.ListCalendarEventsRange(ctx, CalendarRangeQuery{From: "2026-01-01T00:00:00Z", To: "2027-01-01T00:00:00Z", Filtered: true, Limit: n})
			return checkNotNil(r == nil, len(r)), err
		},
		"recaps": func(n int) (int, error) {
			r, err := d.ListMeetingRecaps(ctx, "", "", n)
			return checkNotNil(r == nil, len(r)), err
		},
		"notes": func(n int) (int, error) {
			r, err := d.ListMeetingNotes(ctx, "ev", "", n)
			return checkNotNil(r == nil, len(r)), err
		},
		"day plans": func(n int) (int, error) {
			r, err := d.ListDayPlanSummaries(ctx, "u", "", n)
			return checkNotNil(r == nil, len(r)), err
		},
		"reminders": func(n int) (int, error) {
			r, err := d.ListReminders(ctx, "", "", n)
			return checkNotNil(r == nil, len(r)), err
		},
		"sprints": func(n int) (int, error) {
			r, err := d.ListJiraSprints(ctx, JiraSprintQuery{Limit: n})
			return checkNotNil(r == nil, len(r)), err
		},
		"releases": func(n int) (int, error) {
			r, err := d.ListJiraReleases(ctx, JiraReleaseQuery{Limit: n})
			return checkNotNil(r == nil, len(r)), err
		},
	}
	for name, call := range calls {
		if _, err := call(0); err == nil {
			t.Errorf("%s: limit 0 accepted", name)
		}
		got, err := call(10)
		if err != nil || got != 0 {
			t.Errorf("%s on an empty store = %d, %v; want an empty non-nil result", name, got, err)
		}
	}
}

// checkNotNil turns a nil slice into -1 so the caller's "want 0" fails.
func checkNotNil(isNil bool, n int) int {
	if isNil {
		return -1
	}
	return n
}

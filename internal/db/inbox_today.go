package db

import (
	"sort"
	"time"
)

// The "from today" rule of the Inbox and the Waiting for me sections. This is
// the Go twin of the Desktop's InboxToday (WatchtowerCore); the shared fixture
// internal/inbox/testdata/from_today.json pins that both agree.

// StartOfToday returns the first instant, in now's location, whose local date
// is now's date: local midnight, or — when a DST gap swallows midnight — the
// first instant after the gap (Foundation's Calendar.startOfDay semantics).
func StartOfToday(now time.Time) time.Time {
	loc := now.Location()
	y, m, d := now.Date()
	want := dayKey(y, m, d)
	onDate := func(t time.Time) bool { return dayKey(t.Date()) >= want }

	c := time.Date(y, m, d, 0, 0, 0, 0, loc)
	if dayKey(c.Date()) == want && !onDate(c.Add(-time.Second)) {
		return c
	}
	// Midnight does not exist on this date and time.Date normalized it to a
	// neighbouring instant: find the first second on the date. Zone
	// transitions fall on whole seconds.
	lo := c.Add(-48 * time.Hour)
	span := int((96 * time.Hour) / time.Second)
	n := sort.Search(span, func(i int) bool {
		return onDate(lo.Add(time.Duration(i) * time.Second))
	})
	return lo.Add(time.Duration(n) * time.Second).In(loc)
}

func dayKey(y int, m time.Month, d int) int { return y*10000 + int(m)*100 + d }

// IsFromToday reports whether an item counts as from today: the later of
// createdAt and mentionedAt (zero = no mention) is at or after StartOfToday(now).
func IsFromToday(createdAt, mentionedAt, now time.Time) bool {
	at := createdAt
	if !mentionedAt.IsZero() && mentionedAt.After(at) {
		at = mentionedAt
	}
	return !at.Before(StartOfToday(now))
}

// WaitingSection is the section of Waiting for me / Mail waiting an item
// falls into by its time (the later of created_at and mentioned_at).
type WaitingSection string

const (
	SectionToday WaitingSection = "today"
	SectionWeek  WaitingSection = "week"
	SectionOlder WaitingSection = "older"
)

// WaitingOlderAfter is the age from which an item belongs to Older.
const WaitingOlderAfter = 7 * 24 * time.Hour

// WaitingSectionOf places an item time: Today from StartOfToday(now), Week
// while younger than WaitingOlderAfter, else Older. A zero time is Older,
// matching the SQL cutoff compare.
func WaitingSectionOf(at, now time.Time) WaitingSection {
	switch {
	case at.IsZero():
		return SectionOlder
	case !at.Before(StartOfToday(now)):
		return SectionToday
	case now.Sub(at) < WaitingOlderAfter:
		return SectionWeek
	default:
		return SectionOlder
	}
}

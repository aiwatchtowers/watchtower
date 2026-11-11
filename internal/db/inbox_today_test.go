package db

import (
	"encoding/json"
	"os"
	"testing"
	"time"
)

const fromTodayFixture = "../inbox/testdata/from_today.json"

type fromTodayCase struct {
	Name        string  `json:"name"`
	Now         string  `json:"now"`
	TZ          string  `json:"tz"`
	CreatedAt   string  `json:"created_at"`
	MentionedAt *string `json:"mentioned_at"`
	Expected    bool    `json:"expected"`
}

func mustRFC3339(t *testing.T, s string) time.Time {
	t.Helper()
	v, err := time.Parse(time.RFC3339, s)
	if err != nil {
		t.Fatalf("parse %q: %v", s, err)
	}
	return v
}

// TestInboxToday_SharedFixture pins the Go twin of the Swift InboxToday rule
// to the fixture both sides read.
func TestInboxToday_SharedFixture(t *testing.T) {
	raw, err := os.ReadFile(fromTodayFixture)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var fx struct {
		Cases []fromTodayCase `json:"cases"`
	}
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	if len(fx.Cases) < 10 {
		t.Fatalf("fixture has %d cases, want at least 10", len(fx.Cases))
	}
	for i, c := range fx.Cases {
		loc, err := time.LoadLocation(c.TZ)
		if err != nil {
			t.Fatalf("case %d (%s): load tz %q: %v", i, c.Name, c.TZ, err)
		}
		now := mustRFC3339(t, c.Now).In(loc)
		created := mustRFC3339(t, c.CreatedAt)
		var mentioned time.Time
		if c.MentionedAt != nil && *c.MentionedAt != "" {
			mentioned = mustRFC3339(t, *c.MentionedAt)
		}
		if got := IsFromToday(created, mentioned, now); got != c.Expected {
			t.Errorf("case %d (%s): IsFromToday = %v, want %v", i, c.Name, got, c.Expected)
		}
	}
}

func TestStartOfToday(t *testing.T) {
	cases := []struct {
		tz, now, want string
	}{
		{"Europe/Kyiv", "2026-11-11T08:00:00Z", "2026-11-10T22:00:00Z"},
		// Midnight falls in the DST gap: the day starts at 01:00 local.
		{"America/Santiago", "2026-09-06T15:00:00Z", "2026-09-06T04:00:00Z"},
		{"America/New_York", "2026-03-08T15:00:00Z", "2026-03-08T05:00:00Z"},
		{"UTC", "2026-11-11T00:00:00Z", "2026-11-11T00:00:00Z"},
	}
	for _, c := range cases {
		loc, err := time.LoadLocation(c.tz)
		if err != nil {
			t.Fatalf("load tz %q: %v", c.tz, err)
		}
		got := StartOfToday(mustRFC3339(t, c.now).In(loc))
		if want := mustRFC3339(t, c.want); !got.Equal(want) {
			t.Errorf("%s at %s: StartOfToday = %s, want %s", c.tz, c.now, got.UTC().Format(time.RFC3339), c.want)
		}
		if got.Location() != loc {
			t.Errorf("%s: StartOfToday location = %v, want %v", c.tz, got.Location(), loc)
		}
	}
}

func TestWaitingSectionOf(t *testing.T) {
	loc, err := time.LoadLocation("Europe/Kyiv")
	if err != nil {
		t.Fatalf("load tz: %v", err)
	}
	now := mustRFC3339(t, "2026-11-11T08:00:00Z").In(loc)
	start := StartOfToday(now)
	cases := []struct {
		name string
		at   time.Time
		want WaitingSection
	}{
		{"start of today", start, SectionToday},
		{"now", now, SectionToday},
		{"one second before today", start.Add(-time.Second), SectionWeek},
		{"exactly seven days", now.Add(-WaitingOlderAfter), SectionOlder},
		{"one second inside seven days", now.Add(-WaitingOlderAfter + time.Second), SectionWeek},
		{"zero", time.Time{}, SectionOlder},
	}
	for _, c := range cases {
		if got := WaitingSectionOf(c.at, now); got != c.want {
			t.Errorf("%s: WaitingSectionOf = %q, want %q", c.name, got, c.want)
		}
	}
}

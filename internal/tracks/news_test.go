package tracks

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/db"
)

type trackNewsCase struct {
	Name          string  `json:"name"`
	Now           string  `json:"now"`
	ReadAt        *string `json:"read_at"`
	HasUpdates    bool    `json:"has_updates"`
	UpdatedAt     string  `json:"updated_at"`
	NewestEventAt *string `json:"newest_event_at"`
	HasNews       bool    `json:"has_news"`
	Quiet         bool    `json:"quiet"`
}

type trackNewsFixture struct {
	Note      string          `json:"note"`
	QuietDays int             `json:"quiet_days"`
	Cases     []trackNewsCase `json:"cases"`
}

func loadTrackNewsFixture(t *testing.T) trackNewsFixture {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "track_news.json"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var f trackNewsFixture
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	if len(f.Cases) == 0 {
		t.Fatal("fixture has no cases")
	}
	return f
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func TestTrackNews_Fixture(t *testing.T) {
	f := loadTrackNewsFixture(t)
	if f.QuietDays != QuietDays {
		t.Errorf("fixture quiet_days = %d, QuietDays = %d", f.QuietDays, QuietDays)
	}
	for _, c := range f.Cases {
		now, err := time.Parse(time.RFC3339Nano, c.Now)
		if err != nil {
			t.Fatalf("%s: bad now %q: %v", c.Name, c.Now, err)
		}
		in := NewsInput{
			ReadAt:        deref(c.ReadAt),
			HasUpdates:    c.HasUpdates,
			UpdatedAt:     c.UpdatedAt,
			NewestEventAt: deref(c.NewestEventAt),
		}
		if got := HasNews(in, now); got != c.HasNews {
			t.Errorf("%s: HasNews = %v, want %v", c.Name, got, c.HasNews)
		}
		if got := IsQuiet(in, now, f.QuietDays); got != c.Quiet {
			t.Errorf("%s: IsQuiet = %v, want %v", c.Name, got, c.Quiet)
		}
	}
}

func TestTrackNews_FixtureCoversBoundaries(t *testing.T) {
	f := loadTrackNewsFixture(t)
	have := make(map[string]bool, len(f.Cases))
	for _, c := range f.Cases {
		if have[c.Name] {
			t.Errorf("duplicate case name %q", c.Name)
		}
		have[c.Name] = true
	}
	for _, name := range []string{
		"has_updates_old",
		"never_read_2d",
		"never_read_exactly_72h",
		"never_read_72h_plus_1s",
		"never_read_empty_string",
		"read_10d",
		"read_exactly_30d",
		"read_40d",
		"never_read_40d",
		"event_newer_than_updated",
		"fractional_seconds",
		"unparseable_time",
		"future_event_never_read",
	} {
		if !have[name] {
			t.Errorf("fixture lost boundary case %q", name)
		}
	}
}

func TestLastEventAt_ZeroWhenNeitherParses(t *testing.T) {
	if got := LastEventAt("garbage", ""); !got.IsZero() {
		t.Errorf("LastEventAt(garbage, \"\") = %v, want zero", got)
	}
	if got := LastEventAt("", "not-a-time"); !got.IsZero() {
		t.Errorf("LastEventAt(\"\", not-a-time) = %v, want zero", got)
	}
	want := time.Date(2026, 11, 9, 12, 0, 0, 0, time.UTC)
	if got := LastEventAt("garbage", "2026-11-09T12:00:00Z"); !got.Equal(want) {
		t.Errorf("LastEventAt picks the parsable side: got %v, want %v", got, want)
	}
	if got := LastEventAt("2026-11-09T12:00:00Z", "2026-10-01T12:00:00Z"); !got.Equal(want) {
		t.Errorf("LastEventAt picks the later: got %v, want %v", got, want)
	}
}

func TestQuietTrackIDs_KeepsQuietInOrder(t *testing.T) {
	now := time.Now().UTC()
	at := func(d time.Duration) string { return now.Add(-d).Format(time.RFC3339) }
	day := 24 * time.Hour
	rows := []db.TrackNewsRow{
		{ID: 1, ReadAt: at(50 * day), UpdatedAt: at(40 * day)},                   // quiet
		{ID: 2, ReadAt: at(50 * day), UpdatedAt: at(10 * day)},                   // read recently active
		{ID: 3, HasUpdates: true, ReadAt: at(50 * day), UpdatedAt: at(40 * day)}, // news
		{ID: 4, ReadAt: at(50 * day), UpdatedAt: "garbage"},                      // unknown last event
		{ID: 5, ReadAt: at(50 * day), UpdatedAt: at(40 * day), NewestEventAt: at(5 * day)},
		{ID: 6, UpdatedAt: at(31 * day)}, // never read, old: no news, quiet
	}
	assert.Equal(t, []int{1, 6}, QuietTrackIDs(rows, now, QuietDays))
	assert.Empty(t, QuietTrackIDs(nil, now, QuietDays))
}

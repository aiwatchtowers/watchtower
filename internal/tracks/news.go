package tracks

import (
	"time"

	"watchtower/internal/db"
)

// NewsWindow is how long a never-read track counts as news after its last
// event (inclusive).
const NewsWindow = 72 * time.Hour

// QuietDays is the default number of days without an event after which a
// track with no news counts as quiet (inclusive).
const QuietDays = 30

// NewsInput is the part of a track the "with news" rule reads. The Swift twin
// reads the same rule from testdata/track_news.json.
type NewsInput struct {
	ReadAt        string // "" = never read
	HasUpdates    bool
	UpdatedAt     string // tracks.updated_at
	NewestEventAt string // newest track_events.created_at; "" = no event
}

// LastEventAt returns the later of updatedAt and newestEventAt, parsed as
// RFC 3339 (fractional seconds optional). A side that does not parse is
// ignored; the zero time means neither parsed.
func LastEventAt(updatedAt, newestEventAt string) time.Time {
	var last time.Time
	for _, s := range []string{updatedAt, newestEventAt} {
		t, err := time.Parse(time.RFC3339Nano, s)
		if err == nil && t.After(last) {
			last = t
		}
	}
	return last
}

// HasNews reports whether a track has news: has_updates is set, or it was
// never read and its last event is within NewsWindow of now (inclusive; an
// event after now counts). An unknown last event is never news by time.
func HasNews(in NewsInput, now time.Time) bool {
	if in.HasUpdates {
		return true
	}
	if in.ReadAt != "" {
		return false
	}
	last := LastEventAt(in.UpdatedAt, in.NewestEventAt)
	return !last.IsZero() && !last.Before(now.Add(-NewsWindow))
}

// IsQuiet reports whether a track without news has had no event for
// quietDays days (inclusive). An unknown last event is never quiet.
func IsQuiet(in NewsInput, now time.Time, quietDays int) bool {
	if HasNews(in, now) {
		return false
	}
	last := LastEventAt(in.UpdatedAt, in.NewestEventAt)
	return !last.IsZero() && !last.After(now.Add(-time.Duration(quietDays)*24*time.Hour))
}

// QuietTrackIDs returns, in rows' order, the ids of the tracks that are quiet
// for the given number of days (IsQuiet) — what `tracks dismiss --quiet-days N --dry-run`
// lists.
func QuietTrackIDs(rows []db.TrackNewsRow, now time.Time, days int) []int {
	ids := []int{}
	for _, r := range rows {
		in := NewsInput{ReadAt: r.ReadAt, HasUpdates: r.HasUpdates, UpdatedAt: r.UpdatedAt, NewestEventAt: r.NewestEventAt}
		if IsQuiet(in, now, days) {
			ids = append(ids, r.ID)
		}
	}
	return ids
}

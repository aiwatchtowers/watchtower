package slackbackfill

import (
	"errors"
	"fmt"
	"time"
)

// MaxDays bounds one `slack backfill` run: Slack's search recall gets
// unreliable further back (maxSearchCatchUpDays in internal/sync), and a
// longer range belongs to several runs.
const MaxDays = 31

// ParseRange parses the inclusive local day range --from..--to into the
// chunk convention's [floor, upper) (internal/historybackfill/chunk.go).
func ParseRange(fromArg, toArg string, now time.Time) (floor, upper time.Time, err error) {
	from, err := time.ParseInLocation("2006-01-02", fromArg, time.Local)
	if err != nil {
		return time.Time{}, time.Time{}, fmt.Errorf("--from must be YYYY-MM-DD: %w", err)
	}
	to, err := time.ParseInLocation("2006-01-02", toArg, time.Local)
	if err != nil {
		return time.Time{}, time.Time{}, fmt.Errorf("--to must be YYYY-MM-DD: %w", err)
	}
	if to.Before(from) {
		return time.Time{}, time.Time{}, errors.New("--to is before --from")
	}
	if to.After(now) {
		return time.Time{}, time.Time{}, errors.New("--to is in the future")
	}
	upper = to.AddDate(0, 0, 1)
	if from.AddDate(0, 0, MaxDays).Before(upper) {
		return time.Time{}, time.Time{}, fmt.Errorf("at most %d days at a time", MaxDays)
	}
	return from, upper, nil
}

// span is the interval (from, to] of Unix seconds — the digest period and
// chunk convention.
type span struct{ from, to float64 }

func spanOf(from, to time.Time) span { return span{float64(from.Unix()), float64(to.Unix())} }

// utcDaysNewestFirst splits [from, to) into the UTC days the daily rollups
// and the ledger use, each clipped to the range, newest first: a backfill
// digest of a channel with no forward mark becomes its mark, and an older
// day digested after it stays below it (Run.digestDay's cap).
func utcDaysNewestFirst(from, to time.Time) [][2]time.Time {
	var out [][2]time.Time
	for d := from.UTC().Truncate(24 * time.Hour); d.Before(to); d = d.Add(24 * time.Hour) {
		out = append([][2]time.Time{{maxTime(d, from), minTime(d.Add(24*time.Hour), to)}}, out...)
	}
	return out
}

func maxTime(a, b time.Time) time.Time {
	if a.After(b) {
		return a
	}
	return b
}

func minTime(a, b time.Time) time.Time {
	if a.Before(b) {
		return a
	}
	return b
}

func utcDayKey(t time.Time) string { return t.UTC().Format("2006-01-02") }

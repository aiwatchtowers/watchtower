package slackbackfill

import (
	"cmp"
	"slices"
	"sort"

	"watchtower/internal/db"
)

// Coverage rule (#914 review, ask #454): a channel's message is already
// digested when it lies inside the period (period_from, period_to] of one of
// the channel's digests, except a digest the ledger excluded for the day.
// The backfill digests every other message of the day — so a day partly
// covered still gets its uncovered messages digested, and nothing is
// digested twice. uncovered is the one place the rule lives: the earlier
// whole-day rule ("any covering digest overlaps the day → skip the channel
// day") would be `if len(covering) > 0 { return nil }` before the cut.

// uncovered returns the parts of window, cut at limit, that lie outside
// every covering period and hold at least one of times (ascending).
func uncovered(window span, limit float64, covering []span, times []float64) []span {
	hi := min(window.to, limit)
	if hi <= window.from {
		return nil
	}
	covering = slices.Clone(covering)
	slices.SortFunc(covering, func(a, b span) int { return cmp.Compare(a.from, b.from) })
	var pieces []span
	cur := window.from
	for _, c := range covering {
		if cur >= hi {
			break
		}
		if c.from > cur {
			pieces = append(pieces, span{cur, min(c.from, hi)})
		}
		cur = max(cur, c.to)
	}
	if cur < hi {
		pieces = append(pieces, span{cur, hi})
	}
	var out []span
	for _, p := range pieces {
		if holdsTime(p, times) {
			out = append(out, p)
		}
	}
	return out
}

// holdsTime reports whether some t of times (ascending) has s.from < t <= s.to.
func holdsTime(s span, times []float64) bool {
	i := sort.Search(len(times), func(i int) bool { return times[i] > s.from })
	return i < len(times) && times[i] <= s.to
}

// excludedDigests returns the ids of the channel digests overlapping day
// whose period held none of the channel's messages in the day (times, per
// channel, as stored before the first fetch): the first forward digest after
// a sync gap starts at the previous digest's end, so its period spans gap
// days it never saw a message of.
func excludedDigests(day span, digests []db.ChannelDigestPeriod, times map[string][]float64) []int64 {
	excluded := []int64{}
	for _, d := range digests {
		if !holdsTime(span{max(d.From, day.from), min(d.To, day.to)}, times[d.ChannelID]) {
			excluded = append(excluded, d.ID)
		}
	}
	return excluded
}

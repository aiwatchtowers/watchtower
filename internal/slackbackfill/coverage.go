package slackbackfill

import (
	"cmp"
	"slices"
	"sort"

	"watchtower/internal/db"
)

// Coverage rule (#914 review, owner decision in ask #454): per channel and
// UTC day. A channel's day is covered when one of the channel's digests
// overlapping the day existed when the day was decided (id at most the
// ledger's digest_id_max) and saw one of the day's messages stored before
// the first fetch (the ledger did not exclude it). A covered day is not
// digested: its refetched messages are stored and searchable, but not
// digested — the accepted limit for a partly covered day. An uncovered day
// is digested up to the channel's forward mark, outside the periods of the
// digests written since the decision (by the daemon, or by an earlier run of
// this command): they may not have seen the refetched messages, so they
// never cover the day, but what they digested is not digested again.
// RunBackfillWindowChannels re-reads the start under the digest lock for a
// digest committed after this cut.

// coveredChannels returns the channels whose day one of digests (the
// account's channel digests overlapping the whole UTC day) covers.
func coveredChannels(digests []db.ChannelDigestPeriod, day *ledgerDay) map[string]bool {
	covered := map[string]bool{}
	for _, d := range digests {
		if d.ID <= day.DigestIDMax && !slices.Contains(day.Excluded, d.ID) {
			covered[d.ChannelID] = true
		}
	}
	return covered
}

// laterPeriods returns, per channel, the periods of digests written after
// the day was decided (id above digest_id_max).
func laterPeriods(digests []db.ChannelDigestPeriod, day *ledgerDay) map[string][]span {
	later := map[string][]span{}
	for _, d := range digests {
		if d.ID > day.DigestIDMax {
			later[d.ChannelID] = append(later[d.ChannelID], span{d.From, d.To})
		}
	}
	return later
}

// uncovered returns the parts of window, cut at limit, that lie outside
// every period of later and hold at least one of times (ascending).
func uncovered(window span, limit float64, later []span, times []float64) []span {
	hi := min(window.to, limit)
	if hi <= window.from {
		return nil
	}
	later = slices.Clone(later)
	slices.SortFunc(later, func(a, b span) int { return cmp.Compare(a.from, b.from) })
	var pieces []span
	cur := window.from
	for _, c := range later {
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
		if countTimes(p, times) > 0 {
			out = append(out, p)
		}
	}
	return out
}

// countTimes counts the t of times (ascending) with s.from < t <= s.to.
func countTimes(s span, times []float64) int {
	if s.to <= s.from {
		return 0
	}
	lo := sort.Search(len(times), func(i int) bool { return times[i] > s.from })
	hi := sort.Search(len(times), func(i int) bool { return times[i] > s.to })
	return hi - lo
}

// holdsTime reports whether some t of times (ascending) has s.from < t <= s.to.
func holdsTime(s span, times []float64) bool { return countTimes(s, times) > 0 }

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

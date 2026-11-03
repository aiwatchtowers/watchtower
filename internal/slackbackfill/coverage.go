package slackbackfill

import (
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
// is digested in full up to the channel's forward mark;
// RunBackfillWindowChannels still starts after any digest written since the
// decision, so nothing is digested twice.

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

// uncovered returns window cut at limit (the channel's forward mark), and
// whether it holds one of times (ascending).
func uncovered(window span, limit float64, times []float64) (span, bool) {
	s := span{window.from, min(window.to, limit)}
	return s, s.to > s.from && holdsTime(s, times)
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

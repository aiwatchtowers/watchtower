package slackmode

import (
	"sort"

	"watchtower/internal/db"
)

// NewestBatches returns one verdict row per provider, by provider name:
// the provider's newest check. A probe writes one slack_live_status row per
// team (and team ”) at one instant, and that batch is the provider's
// verdict — its first ok row by team when any row in it is ok, else its
// first row by team. An older ok row never outlives a newer failed check
// (SLACKMODE-01, ask #1525). Swift twin: SlackModePresentation.newestBatches.
func NewestBatches(rows []db.SlackLiveStatus) []db.SlackLiveStatus {
	best := map[string]db.SlackLiveStatus{}
	for _, r := range rows {
		cur, seen := best[r.Provider]
		if !seen || r.CheckedAt.After(cur.CheckedAt) || r.CheckedAt.Equal(cur.CheckedAt) && better(r, cur) {
			best[r.Provider] = r
		}
	}
	out := make([]db.SlackLiveStatus, 0, len(best))
	for _, r := range best {
		out = append(out, r)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Provider < out[j].Provider })
	return out
}

// better orders two rows of one batch: ok before not ok, then by team.
func better(r, cur db.SlackLiveStatus) bool {
	if (r.Status == StatusOK) != (cur.Status == StatusOK) {
		return r.Status == StatusOK
	}
	return r.TeamID < cur.TeamID
}

// LiveVerdicts is the status of each provider's newest batch, the Live
// input of Derive.
func LiveVerdicts(rows []db.SlackLiveStatus) []string {
	batches := NewestBatches(rows)
	out := make([]string, 0, len(batches))
	for _, r := range batches {
		out = append(out, r.Status)
	}
	return out
}

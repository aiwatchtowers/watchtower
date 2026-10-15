package planusage

import (
	"encoding/json"

	"watchtower/internal/db"
)

// NearLimit reports whether background AI work should wait: the 5-hour or the
// weekly (all models) limit is projected to be hit, or is hit. Anything it
// cannot read — no row, a status other than ok, malformed limits — does not
// block: the per-step budgets still hold (docs/features/history-backfill.md).
func NearLimit(st *db.PlanUsageStatus) bool {
	if st == nil || st.State != "ok" {
		return false
	}
	var limits []Limit
	if err := json.Unmarshal([]byte(st.LimitsJSON), &limits); err != nil {
		return false
	}
	for _, l := range limits {
		if l.Key != "session" && l.Key != "weekly_all" {
			continue
		}
		if l.Projection.State == "will_hit" || l.Projection.State == "hit" {
			return true
		}
	}
	return false
}

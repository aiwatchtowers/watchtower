package planusage

import (
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/db"
)

func TestNearLimit(t *testing.T) {
	lim := func(key, state string) string {
		return fmt.Sprintf(`{"key":%q,"group":"x","percent":50,"projection":{"state":%q}}`, key, state)
	}
	cases := []struct {
		name string
		st   *db.PlanUsageStatus
		want bool
	}{
		{"no row", nil, false},
		{"status not ok", &db.PlanUsageStatus{State: "stale", LimitsJSON: "[" + lim("session", "hit") + "]"}, false},
		{"session will_hit", &db.PlanUsageStatus{State: "ok", LimitsJSON: "[" + lim("session", "will_hit") + "]"}, true},
		{"weekly_all hit", &db.PlanUsageStatus{State: "ok", LimitsJSON: "[" + lim("weekly_all", "hit") + "]"}, true},
		{"scoped weekly ignored", &db.PlanUsageStatus{State: "ok", LimitsJSON: "[" + lim("weekly_scoped:fable", "hit") + "]"}, false},
		{"safe", &db.PlanUsageStatus{State: "ok", LimitsJSON: "[" + lim("session", "safe") + "]"}, false},
		{"bad json", &db.PlanUsageStatus{State: "ok", LimitsJSON: "{"}, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { assert.Equal(t, c.want, NearLimit(c.st)) })
	}
}

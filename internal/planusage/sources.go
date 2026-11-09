package planusage

import (
	"time"

	"watchtower/internal/db"
)

// Subscription sources describe published quota data, independently of the AI
// transport configuration. A source owns its storage, identity and history
// policy; aggregation applies the same freshness and projection gates to all.
type subscriptionRow struct {
	status               *db.PlanUsageStatus
	scope                string
	identityKnown        bool
	ordinaryUsageAllowed *bool
}
type subscriptionSource struct {
	identityRequired bool
	load             func(ReadStore) (subscriptionRow, error)
	normalize        func(WindowLimit) WindowLimit
	history          func(ReadStore, subscriptionRow, string, time.Time, time.Time, time.Time) ([]db.PlanUsageSample, error)
}

var subscriptionSourceOrder = []string{"claude", "codex"}
var subscriptionSources = map[string]subscriptionSource{
	"claude": {
		load: func(store ReadStore) (subscriptionRow, error) {
			status, err := store.GetPlanUsageStatus()
			return subscriptionRow{status: status, identityKnown: true}, err
		},
		normalize: func(l WindowLimit) WindowLimit {
			return ClaudeWindowLimit(Limit{Key: l.Key, Label: l.Label, Group: l.Group, Percent: l.Percent, ResetsAt: l.ResetsAt, Projection: l.Projection})
		},
		history: func(store ReadStore, _ subscriptionRow, key string, since, fetched, reset time.Time) ([]db.PlanUsageSample, error) {
			return store.PlanUsageHistory(key, since, fetched, reset)
		},
	},
	"codex": {
		identityRequired: true,
		load: func(store ReadStore) (subscriptionRow, error) {
			row, err := store.GetCodexPlanUsageStatus()
			if err != nil || row == nil {
				return subscriptionRow{}, err
			}
			return subscriptionRow{status: &row.PlanUsageStatus, scope: row.Scope, identityKnown: row.IdentityKnown, ordinaryUsageAllowed: row.OrdinaryUsageAllowed}, nil
		},
		normalize: func(l WindowLimit) WindowLimit { return l },
		history: func(store ReadStore, row subscriptionRow, key string, since, fetched, reset time.Time) ([]db.PlanUsageSample, error) {
			return store.CodexPlanUsageHistory(row.scope, key, since, fetched, reset)
		},
	},
}

// Sources returns the stable public subscription order, without exposing the registry.
func Sources() []string { return append([]string(nil), subscriptionSourceOrder...) }

// HasSource validates a subscription product, not an AI transport.
func HasSource(name string) bool { _, ok := subscriptionSources[name]; return ok }

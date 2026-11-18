package claude

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"
	"time"
)

// usageWindowWire is one rate-limit window of the get_usage answer. A null
// utilization is absent, never 0 %.
type usageWindowWire struct {
	Utilization *float64 `json:"utilization"`
	ResetsAt    *string  `json:"resets_at"`
}

type usageAnswerWire struct {
	SubscriptionType *string `json:"subscription_type"`
	Available        *bool   `json:"rate_limits_available"`
	RateLimits       *struct {
		FiveHour *usageWindowWire `json:"five_hour"`
		SevenDay *usageWindowWire `json:"seven_day"`
		Opus     *usageWindowWire `json:"seven_day_opus"`
		Sonnet   *usageWindowWire `json:"seven_day_sonnet"`
		// ModelScoped is nil when absent (or null) and empty when the
		// endpoint listed no per-model window.
		ModelScoped []struct {
			DisplayName string `json:"display_name"`
			usageWindowWire
		} `json:"model_scoped"`
		// Breakdown is not in the CLI's schema: it is the usage endpoint's
		// surface split, passed through when the endpoint sends it.
		Breakdown *struct {
			Rows []struct {
				Key         string  `json:"key"`
				DisplayName string  `json:"display_name"`
				Percent     float64 `json:"percent"`
			} `json:"rows"`
		} `json:"seven_day_breakdown"`
	} `json:"rate_limits"`
}

var errUsageAvailabilityMissing = errors.New("claude usage: rate_limits_available missing")

// parseClaudeUsage decodes the payload of a successful get_usage
// control_response. available is rate_limits_available; limitsNull reports
// an available answer whose rate_limits is null. Unknown fields are ignored;
// a window that is null or has a null utilization is left out.
func parseClaudeUsage(payload []byte) (snap UsageSnapshot, available bool, limitsNull bool, err error) {
	var w usageAnswerWire
	if err := json.Unmarshal(payload, &w); err != nil {
		return UsageSnapshot{}, false, false, fmt.Errorf("claude usage: decode: %w", err)
	}
	if w.Available == nil {
		return UsageSnapshot{}, false, false, errUsageAvailabilityMissing
	}
	if w.SubscriptionType != nil {
		snap.Plan = *w.SubscriptionType
	}
	if !*w.Available {
		return snap, false, false, nil
	}
	rl := w.RateLimits
	if rl == nil {
		return snap, true, true, nil
	}
	add := func(key, label, group string, win *usageWindowWire) {
		if win == nil || win.Utilization == nil {
			return
		}
		snap.Windows = append(snap.Windows, UsageWindow{Key: key, Label: label, Group: group,
			Percent: clampUsagePercent(*win.Utilization), ResetsAt: parseUsageReset(win.ResetsAt)})
	}
	add("session", "5-hour", "session", rl.FiveHour)
	add("weekly_all", "Weekly", "weekly", rl.SevenDay)
	if rl.ModelScoped != nil {
		for i := range rl.ModelScoped {
			m := &rl.ModelScoped[i]
			add("weekly_scoped:"+usageSlug(m.DisplayName), "Weekly · "+m.DisplayName, "weekly", &m.usageWindowWire)
		}
	} else {
		add("weekly_scoped:opus", "Weekly · Opus", "weekly", rl.Opus)
		add("weekly_scoped:sonnet", "Weekly · Sonnet", "weekly", rl.Sonnet)
	}
	if rl.Breakdown != nil {
		for _, row := range rl.Breakdown.Rows {
			snap.Breakdown = append(snap.Breakdown, BreakdownRow{Key: row.Key, Label: row.DisplayName, Percent: row.Percent})
		}
	}
	return snap, true, false, nil
}

// usageSlug is the scoped key's suffix: lower case, trimmed, spaces → "-".
func usageSlug(s string) string {
	return strings.ReplaceAll(strings.ToLower(strings.TrimSpace(s)), " ", "-")
}

func clampUsagePercent(p float64) float64 { return math.Max(0, math.Min(100, p)) }

// parseUsageReset reads an ISO 8601 reset time; null, empty or unreadable is
// nil (the window has not started).
func parseUsageReset(s *string) *time.Time {
	if s == nil || *s == "" {
		return nil
	}
	t, err := time.Parse(time.RFC3339Nano, *s)
	if err != nil {
		return nil
	}
	t = t.UTC()
	return &t
}

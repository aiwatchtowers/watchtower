package claude

import "time"

// UsageError is ReadUsage's failure: Code is one of cli_missing,
// unsupported_cli, unsupported_auth, cloud_bedrock, cloud_vertex,
// cloud_foundry, no_credentials, network, parse, timeout, cancelled. It
// never carries the child's output.
type UsageError struct{ Code string }

func (e *UsageError) Error() string { return "claude usage: " + e.Code }

// UsageWindow is one plan-limit window under the stored limit keys:
// session "5-hour", weekly_all "Weekly", weekly_scoped:<slug> "Weekly · <name>".
type UsageWindow struct {
	Key, Label, Group string
	Percent           float64
	ResetsAt          *time.Time
}

// BreakdownRow is one surface's share of the weekly usage.
type BreakdownRow struct {
	Key, Label string
	Percent    float64
}

// UsageSnapshot is one get_usage answer: the plan name (empty when the CLI
// reports none), the windows, and the surface breakdown (nil when absent).
type UsageSnapshot struct {
	Plan      string
	Windows   []UsageWindow
	Breakdown []BreakdownRow
}

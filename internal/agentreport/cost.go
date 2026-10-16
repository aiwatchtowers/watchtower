package agentreport

import (
	"cmp"
	"slices"

	"watchtower/internal/db"
)

// ModelRow is one model's spend, main agent vs subagents, as stored.
type ModelRow struct {
	Model          string  `json:"model"`
	MainCostUSD    float64 `json:"main_cost_usd"`
	SubCostUSD     float64 `json:"sub_cost_usd"`
	Tokens         int64   `json:"tokens"`
	CacheReadShare float64 `json:"cache_read_share"`
}

// CommandRow aggregates the tool calls of one verb: the shell verb for Bash,
// else the tool name. A pending call is a run with no time; AvgMS is over the
// timed runs.
type CommandRow struct {
	Verb    string `json:"verb"`
	Class   string `json:"class"`
	Runs    int    `json:"runs"`
	Errors  int    `json:"errors"`
	TotalMS int64  `json:"total_ms"`
	AvgMS   int64  `json:"avg_ms"`
}

// cacheReadShare is cache_read / all input (fresh, cache read, cache writes), 0 without input.
func cacheReadShare(in, read, w5m, w1h int64) float64 {
	all := in + read + w5m + w1h
	if all == 0 {
		return 0
	}
	return float64(read) / float64(all)
}

// Models sums the api_call events by model, most expensive first.
func Models(events []db.AgentReportEvent) []ModelRow {
	type acc struct {
		row                ModelRow
		in, read, w5m, w1h int64
	}
	by := map[string]*acc{}
	for _, e := range events {
		if e.Kind != "api_call" {
			continue
		}
		a := by[e.Model]
		if a == nil {
			a = &acc{row: ModelRow{Model: e.Model}}
			by[e.Model] = a
		}
		if isMain(e) {
			a.row.MainCostUSD += e.CostUSD
		} else {
			a.row.SubCostUSD += e.CostUSD
		}
		a.row.Tokens += e.InputTokens + e.OutputTokens + e.CacheReadTokens + e.CacheWrite5mTokens + e.CacheWrite1hTokens
		a.in += e.InputTokens
		a.read += e.CacheReadTokens
		a.w5m += e.CacheWrite5mTokens
		a.w1h += e.CacheWrite1hTokens
	}
	out := make([]ModelRow, 0, len(by))
	for _, a := range by {
		a.row.CacheReadShare = cacheReadShare(a.in, a.read, a.w5m, a.w1h)
		out = append(out, a.row)
	}
	slices.SortFunc(out, func(a, b ModelRow) int {
		return cmp.Or(cmp.Compare(b.MainCostUSD+b.SubCostUSD, a.MainCostUSD+a.SubCostUSD), cmp.Compare(a.Model, b.Model))
	})
	return out
}

// Commands sums the tool calls by verb, most total time first.
func Commands(events []db.AgentReportEvent) []CommandRow {
	by := map[string]*CommandRow{}
	timed := map[string]int64{}
	for _, e := range events {
		if e.Kind != "tool" {
			continue
		}
		v := verb(e)
		r := by[v]
		if r == nil {
			r = &CommandRow{Verb: v, Class: ToolClass(e.Name, e.Target)}
			by[v] = r
		}
		r.Runs++
		if e.Outcome == "error" {
			r.Errors++
		}
		if e.DurationMS != nil {
			r.TotalMS += max(*e.DurationMS, 0)
			timed[v]++
		}
	}
	out := make([]CommandRow, 0, len(by))
	for v, r := range by {
		if n := timed[v]; n > 0 {
			r.AvgMS = r.TotalMS / n
		}
		out = append(out, *r)
	}
	slices.SortFunc(out, func(a, b CommandRow) int {
		return cmp.Or(cmp.Compare(b.TotalMS, a.TotalMS), cmp.Compare(a.Verb, b.Verb))
	})
	return out
}

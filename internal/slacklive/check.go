package slacklive

import (
	"context"
	"fmt"
	"time"

	"watchtower/internal/db"
)

// Check probes provider ("claude" or "codex") with bin and env, then records
// the verdict: one slack_live_status row per covered team. A cancelled ctx
// returns its error and writes nothing.
//
// A verdict that names its teams (an ok probe that saw them) is written for
// those; any other verdict (including every failure) is written for team ”
// and for every connected Slack account, so a stale ok never outlives it.
func Check(ctx context.Context, d *db.DB, provider, bin string, env []string, now time.Time) (Result, error) {
	var r Result
	switch provider {
	case "claude":
		r = ProbeClaude(ctx, bin, env)
	case "codex":
		r = ProbeCodex(ctx, bin, env)
	default:
		return Result{}, fmt.Errorf("unknown provider %q", provider)
	}
	if err := ctx.Err(); err != nil {
		return Result{}, err
	}
	accounts, err := d.ListSlackAccounts()
	if err != nil {
		return Result{}, err
	}
	var teams []string
	if r.Status == StatusOK {
		for _, t := range r.Teams {
			if provider == "claude" { // a permalink label, matched to its account
				t = teamIDForDomain(accounts, t)
			}
			if t != "" {
				teams = append(teams, t)
			}
		}
	} else {
		for _, a := range accounts {
			if a.TeamID != "" {
				teams = append(teams, a.TeamID)
			}
		}
	}
	teams = append(teams, "")
	r.Teams = dedupe(teams)
	for _, t := range r.Teams {
		if err := d.UpsertSlackLiveStatus(db.SlackLiveStatus{TeamID: t, Provider: provider,
			Status: r.Status, ErrorClass: r.ErrorClass, ConnectorID: r.ConnectorID, CheckedAt: now}); err != nil {
			return Result{}, err
		}
	}
	return r, nil
}

func teamIDForDomain(accounts []db.SlackAccount, domain string) string {
	for _, a := range accounts {
		if a.TeamDomain != "" && a.TeamDomain == domain {
			return a.TeamID
		}
	}
	return ""
}

func dedupe(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range in {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

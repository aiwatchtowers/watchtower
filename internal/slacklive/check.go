package slacklive

import (
	"context"
	"slices"
	"time"

	"watchtower/internal/db"
)

// Check runs probe with bin and env, then records the verdict under the
// probe's provider: one slack_live_status row per covered team. A cancelled
// ctx returns its error and writes nothing.
//
// A verdict that names its teams (an ok probe that saw them) is written for
// those; any other verdict (including every failure) is written for team ”
// and for every connected Slack account, so a stale ok never outlives it.
func Check(ctx context.Context, d *db.DB, probe Probe, bin string, env []string, now time.Time) (Result, error) {
	r := probe(ctx, bin, env)
	provider := r.Provider
	if err := ctx.Err(); err != nil {
		return Result{}, err
	}
	accounts, err := d.ListSlackAccounts()
	if err != nil {
		return Result{}, err
	}
	var teams, absent []string
	if r.Status == StatusOK {
		teams = append(teams, r.Teams...)
		for _, domain := range r.TeamDomains { // a permalink label, matched to its account
			if t := teamIDForDomain(accounts, domain); t != "" {
				teams = append(teams, t)
			}
		}
		teams = slices.DeleteFunc(teams, func(t string) bool { return t == "" })
		// A connected account that the provider did not list cannot be read
		// through it: record that, so an earlier ok for it does not linger.
		if len(teams) > 0 {
			for _, a := range accounts {
				if a.TeamID != "" && !slices.Contains(teams, a.TeamID) {
					absent = append(absent, a.TeamID)
				}
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
	r.Teams, r.TeamDomains = dedupe(teams), nil
	for _, t := range r.Teams {
		if err := d.UpsertSlackLiveStatus(db.SlackLiveStatus{TeamID: t, Provider: provider,
			Status: r.Status, ErrorClass: r.ErrorClass, ConnectorID: r.ConnectorID, CheckedAt: now}); err != nil {
			return Result{}, err
		}
	}
	for _, t := range dedupe(absent) {
		if err := d.UpsertSlackLiveStatus(db.SlackLiveStatus{TeamID: t, Provider: provider,
			Status: StatusNotConnected, ErrorClass: "workspace_not_connected", CheckedAt: now}); err != nil {
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

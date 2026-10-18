package automations

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strings"

	"watchtower/internal/db"
)

// linearTeamUnits is the scope of one Linear issue key: the current team key
// of every non-deleted issue the key resolves to (a moved issue is scoped by
// the team it lives in now, never by an old prefix); a key absent from the
// mirror falls back to its own prefix. Empty when the key has no prefix.
func linearTeamUnits(d *db.DB, key string) ([]string, error) {
	key = strings.ToUpper(strings.TrimSpace(key))
	if d == nil {
		return nil, errNoDB
	}
	issues, err := d.GetLinearIssueByKey(key)
	if err != nil {
		return nil, fmt.Errorf("scope lookup: %w", err)
	}
	var teams []string
	for _, i := range issues {
		team := strings.ToUpper(i.TeamKey)
		if !i.IsDeleted && team != "" && !slices.Contains(teams, team) {
			teams = append(teams, team)
		}
	}
	if len(teams) == 0 {
		if p := issueProject(key); p != "" {
			teams = []string{p}
		}
	}
	return teams, nil
}

// linearIssueScope scopes a call by its issue key's current team (the "key" arg).
func linearIssueScope(_ context.Context, d *db.DB, args json.RawMessage) ([]CallScope, error) {
	a, err := decodeScopeArgs(args)
	if err != nil {
		return nil, err
	}
	teams, err := linearTeamUnits(d, argString(a, "key"))
	if err != nil {
		return nil, err
	}
	var out []CallScope
	for _, t := range teams {
		out = addProjectUnit(out, t)
	}
	return out, nil
}

// linearStatusHistoryScope: one unit per key's current team; a key without a
// team makes the whole call's scope absent.
func linearStatusHistoryScope(_ context.Context, d *db.DB, args json.RawMessage) ([]CallScope, error) {
	a, err := decodeScopeArgs(args)
	if err != nil {
		return nil, err
	}
	var out []CallScope
	for _, k := range argStrings(a, "keys") {
		teams, err := linearTeamUnits(d, k)
		if err != nil {
			return nil, err
		}
		if len(teams) == 0 {
			return nil, nil
		}
		for _, t := range teams {
			out = addProjectUnit(out, t)
		}
	}
	return out, nil
}

package automations

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"

	"watchtower/internal/db"
)

// errNoDB is a scope lookup with no database handle.
var errNoDB = errors.New("scope lookup needs the database")

// scopeArgNames are every argument a ScopeOf reads. Precondition of the
// scope check: the tools decode their args with encoding/json, which matches
// struct fields case-insensitively, so {"project":"PAY","PROJECT":"OPS"}
// could check PAY while the tool reads OPS. decodeScopeArgs refuses any key
// that equals one of these names ignoring case without being byte-equal.
var scopeArgNames = []string{
	"project", "project_key", "team", "key", "keys", "issue_keys", "board_id", "account", "account_id",
}

// decodeArgs decodes a call's args as an object; empty or null is {}.
func decodeArgs(args json.RawMessage) (map[string]json.RawMessage, error) {
	a := map[string]json.RawMessage{}
	trimmed := strings.TrimSpace(string(args))
	if trimmed == "" || trimmed == "null" {
		return a, nil
	}
	if err := json.Unmarshal(args, &a); err != nil {
		return nil, fmt.Errorf("decoding tool args: %w", err)
	}
	return a, nil
}

// decodeScopeArgs is decodeArgs plus the case-variant key refusal (see
// scopeArgNames).
func decodeScopeArgs(args json.RawMessage) (map[string]json.RawMessage, error) {
	a, err := decodeArgs(args)
	if err != nil {
		return nil, err
	}
	for k := range a {
		for _, name := range scopeArgNames {
			if k != name && strings.EqualFold(k, name) {
				return nil, fmt.Errorf("argument %q is a case variant of %q", k, name)
			}
		}
	}
	return a, nil
}

// argString returns args[key] as a trimmed string; "" when absent or not a
// string.
func argString(a map[string]json.RawMessage, key string) string {
	var s string
	if raw, ok := a[key]; ok && json.Unmarshal(raw, &s) == nil {
		return strings.TrimSpace(s)
	}
	return ""
}

// argStrings returns args[key] as a list of strings; nil when absent or not
// a list of strings.
func argStrings(a map[string]json.RawMessage, key string) []string {
	var s []string
	if raw, ok := a[key]; ok && json.Unmarshal(raw, &s) == nil {
		return s
	}
	return nil
}

// argInt returns args[key] as an integer; 0 when absent or not a number.
func argInt(a map[string]json.RawMessage, key string) int64 {
	var n float64
	if raw, ok := a[key]; ok && json.Unmarshal(raw, &n) == nil {
		return int64(n)
	}
	return 0
}

// unit is one scope unit of the non-empty values; no unit when all are empty.
func unit(values ...string) []CallScope {
	var vs []string
	for _, v := range values {
		if v != "" && !slices.Contains(vs, v) {
			vs = append(vs, v)
		}
	}
	if len(vs) == 0 {
		return nil
	}
	return []CallScope{{Values: vs}}
}

func upperArgScope(key string) func(context.Context, *db.DB, json.RawMessage) ([]CallScope, error) {
	return func(_ context.Context, _ *db.DB, args json.RawMessage) ([]CallScope, error) {
		a, err := decodeScopeArgs(args)
		if err != nil {
			return nil, err
		}
		return unit(strings.ToUpper(argString(a, key))), nil
	}
}

// issueProject is the project prefix of an issue key ("ABC-123" → "ABC");
// "" for a key without one.
func issueProject(key string) string {
	prefix, _, ok := strings.Cut(strings.TrimSpace(key), "-")
	if !ok {
		return ""
	}
	return strings.ToUpper(prefix)
}

// issueKeyScope scopes a call by its issue key's project (the "key" arg).
func issueKeyScope(_ context.Context, _ *db.DB, args json.RawMessage) ([]CallScope, error) {
	a, err := decodeScopeArgs(args)
	if err != nil {
		return nil, err
	}
	return unit(issueProject(argString(a, "key"))), nil
}

// projectsOfKeys is one unit per distinct project prefix; a key without a
// prefix (or no key) makes the whole call's scope absent.
func projectsOfKeys(keys []string) []CallScope {
	var out []CallScope
	for _, k := range keys {
		p := issueProject(k)
		if p == "" {
			return nil
		}
		out = addProjectUnit(out, p)
	}
	return out
}

func addProjectUnit(units []CallScope, project string) []CallScope {
	if slices.ContainsFunc(units, func(u CallScope) bool { return u.Values[0] == project }) {
		return units
	}
	return append(units, CallScope{Values: []string{project}})
}

// statusHistoryScope: one unit per key's project.
func statusHistoryScope(_ context.Context, _ *db.DB, args json.RawMessage) ([]CallScope, error) {
	a, err := decodeScopeArgs(args)
	if err != nil {
		return nil, err
	}
	return projectsOfKeys(argStrings(a, "keys")), nil
}

// timeInStatusScope: project when given, else the issue_keys prefixes, else
// absent (board_id alone is absent). Linked issues the tool adds are covered
// by the project grant (owner, ask #287).
func timeInStatusScope(_ context.Context, _ *db.DB, args json.RawMessage) ([]CallScope, error) {
	a, err := decodeScopeArgs(args)
	if err != nil {
		return nil, err
	}
	if p := argString(a, "project"); p != "" {
		return unit(strings.ToUpper(p)), nil
	}
	return projectsOfKeys(argStrings(a, "issue_keys")), nil
}

// sprintScope: upper(project) when given, else the project of board_id's
// board(s); an unknown board or one with no project key is absent. Sprint
// rows carry only sprint metadata, never issues of other projects.
func sprintScope(ctx context.Context, d *db.DB, args json.RawMessage) ([]CallScope, error) {
	a, err := decodeScopeArgs(args)
	if err != nil {
		return nil, err
	}
	if p := argString(a, "project"); p != "" {
		return unit(strings.ToUpper(p)), nil
	}
	board := argInt(a, "board_id")
	if board == 0 {
		return nil, nil
	}
	if d == nil {
		return nil, errNoDB
	}
	keys, err := queryStrings(ctx, d, `SELECT project_key FROM jira_boards WHERE id = ?1`, board)
	if err != nil {
		return nil, err
	}
	var out []CallScope
	for _, k := range keys {
		k = strings.ToUpper(strings.TrimSpace(k))
		if k == "" {
			return nil, nil
		}
		out = addProjectUnit(out, k)
	}
	return out, nil
}

func queryStrings(ctx context.Context, d *db.DB, q string, args ...any) ([]string, error) {
	rows, err := d.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("scope lookup: %w", err)
	}
	defer func() { _ = rows.Close() }()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return nil, fmt.Errorf("scope lookup: %w", err)
		}
		out = append(out, s)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("scope lookup: %w", err)
	}
	return out, nil
}

// accountUnits runs a two-column (label, address) lookup and returns one
// unit per matching account.
func accountUnits(ctx context.Context, d *db.DB, q string, args ...any) ([]CallScope, error) {
	rows, err := d.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("account lookup: %w", err)
	}
	defer func() { _ = rows.Close() }()
	var out []CallScope
	for rows.Next() {
		var label, address string
		if err := rows.Scan(&label, &address); err != nil {
			return nil, fmt.Errorf("account lookup: %w", err)
		}
		out = append(out, unit(strings.ToLower(label), strings.ToLower(address))...)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("account lookup: %w", err)
	}
	return out, nil
}

// accountArgScope resolves args.account through the label/address lookups,
// each taking the account as ?1; no account or an unknown one is absent (the
// tool itself refuses an unknown account).
func accountArgScope(ctx context.Context, d *db.DB, args json.RawMessage, queries ...string) ([]CallScope, error) {
	a, err := decodeScopeArgs(args)
	if err != nil {
		return nil, err
	}
	acct := argString(a, "account")
	if acct == "" {
		return nil, nil
	}
	if d == nil {
		return nil, errNoDB
	}
	var out []CallScope
	for _, q := range queries {
		units, err := accountUnits(ctx, d, q, acct)
		if err != nil {
			return nil, err
		}
		out = append(out, units...)
	}
	return out, nil
}

const googleAccountByNameSQL = `SELECT label, email FROM google_accounts WHERE label = ?1 COLLATE NOCASE OR email = ?1 COLLATE NOCASE`

// emailAccountScope: a Google or IMAP account by label or address.
func emailAccountScope(ctx context.Context, d *db.DB, args json.RawMessage) ([]CallScope, error) {
	return accountArgScope(ctx, d, args, googleAccountByNameSQL,
		`SELECT label, email_address FROM email_accounts WHERE label = ?1 COLLATE NOCASE OR email_address = ?1 COLLATE NOCASE`)
}

// calendarAccountScope: a Google account by label or address, or a
// calendar_accounts row by label — db.MatchCalendarAccounts, the same
// predicate list_calendar_events resolves its account with. No account or an
// unknown one is absent.
func calendarAccountScope(ctx context.Context, d *db.DB, args json.RawMessage) ([]CallScope, error) {
	a, err := decodeScopeArgs(args)
	if err != nil {
		return nil, err
	}
	acct := argString(a, "account")
	if acct == "" {
		return nil, nil
	}
	if d == nil {
		return nil, errNoDB
	}
	matches, err := d.MatchCalendarAccounts(ctx, acct)
	if err != nil {
		return nil, err
	}
	var out []CallScope
	for _, m := range matches {
		out = append(out, unit(strings.ToLower(m.Label), strings.ToLower(m.Address))...)
	}
	return out, nil
}

// slackAccountScope: account_id resolved to {label, team_domain}; with no
// account_id, the only enabled Slack account when exactly one exists, else
// absent. An account_id of no account is an error (denied as slack:write@*).
func slackAccountScope(ctx context.Context, d *db.DB, args json.RawMessage) ([]CallScope, error) {
	a, err := decodeScopeArgs(args)
	if err != nil {
		return nil, err
	}
	if d == nil {
		return nil, errNoDB
	}
	if id := argInt(a, "account_id"); id != 0 {
		units, err := accountUnits(ctx, d, `SELECT label, team_domain FROM slack_accounts WHERE id = ?1`, id)
		if err != nil {
			return nil, err
		}
		if len(units) == 0 {
			return nil, fmt.Errorf("slack account %d: %w", id, sql.ErrNoRows)
		}
		return units, nil
	}
	units, err := accountUnits(ctx, d, `SELECT label, team_domain FROM slack_accounts WHERE enabled = 1 AND status != 'removed'`)
	if err != nil || len(units) != 1 {
		return nil, err
	}
	return units, nil
}

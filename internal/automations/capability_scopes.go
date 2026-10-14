package automations

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
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
	"project", "project_key", "key", "keys", "issue_keys", "board_id", "include_linked", "account", "account_id",
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

// argFalse reports whether args[key] is explicitly the boolean false.
func argFalse(a map[string]json.RawMessage, key string) bool {
	var b bool
	raw, ok := a[key]
	return ok && json.Unmarshal(raw, &b) == nil && !b
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

// issueKeyScope scopes a write by its issue key's project.
func issueKeyScope(key string) func(context.Context, *db.DB, json.RawMessage) ([]CallScope, error) {
	return func(_ context.Context, _ *db.DB, args json.RawMessage) ([]CallScope, error) {
		a, err := decodeScopeArgs(args)
		if err != nil {
			return nil, err
		}
		return unit(issueProject(argString(a, key))), nil
	}
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

// statusHistoryScope: get_jira_status_history returns exactly the issues of
// its keys (never their links), so one unit per key's project.
func statusHistoryScope(_ context.Context, _ *db.DB, args json.RawMessage) ([]CallScope, error) {
	a, err := decodeScopeArgs(args)
	if err != nil {
		return nil, err
	}
	return projectsOfKeys(argStrings(a, "keys")), nil
}

// timeInStatusScope: get_jira_time_in_status adds the issues the selected
// ones link to, on any project, unless include_linked is explicitly false —
// so its scope is absent unless include_linked:false. Then the filters AND
// together: project when given, else the issue_keys prefixes, else absent.
func timeInStatusScope(_ context.Context, _ *db.DB, args json.RawMessage) ([]CallScope, error) {
	a, err := decodeScopeArgs(args)
	if err != nil {
		return nil, err
	}
	if !argFalse(a, "include_linked") {
		return nil, nil
	}
	if p := argString(a, "project"); p != "" {
		return unit(strings.ToUpper(p)), nil
	}
	return projectsOfKeys(argStrings(a, "issue_keys")), nil
}

// jiraIssueRefs is the part of jira.Issue (as the sync marshals it into
// jira_issues.raw_json) that names other issues: links both ways, epic and
// parent.
type jiraIssueRefs struct {
	Fields struct {
		IssueLinks []struct {
			InwardIssue  *struct{ Key string } `json:"inwardIssue"`
			OutwardIssue *struct{ Key string } `json:"outwardIssue"`
		} `json:"issuelinks"`
		Epic   *struct{ Key string } `json:"epic"`
		Parent *struct{ Key string } `json:"parent"`
	} `json:"fields"`
}

func (r jiraIssueRefs) keys() []string {
	var out []string
	for _, l := range r.Fields.IssueLinks {
		if l.InwardIssue != nil {
			out = append(out, l.InwardIssue.Key)
		}
		if l.OutwardIssue != nil {
			out = append(out, l.OutwardIssue.Key)
		}
	}
	if r.Fields.Epic != nil {
		out = append(out, r.Fields.Epic.Key)
	}
	if r.Fields.Parent != nil {
		out = append(out, r.Fields.Parent.Key)
	}
	return out
}

// issueKeyPattern finds issue keys in custom_fields_json, whose shape is
// whatever the board's mapped custom fields hold.
var issueKeyPattern = regexp.MustCompile(`\b[A-Z][A-Z0-9_]+-[0-9]+\b`)

// referencedIssueKeys lists the issue keys one row references: its raw
// JSON's links, epic and parent, the epic_key column, and every issue key in
// custom_fields_json. ok is false when the raw JSON is empty or unreadable:
// such an issue could carry any project's data, so the caller fails closed.
func referencedIssueKeys(raw, custom, epic string) (keys []string, ok bool) {
	var refs jiraIssueRefs
	if json.Unmarshal([]byte(raw), &refs) != nil {
		return nil, false
	}
	keys = append(refs.keys(), epic)
	return append(keys, issueKeyPattern.FindAllString(custom, -1)...), true
}

// withReferencedProjects adds a unit per project the selected issues
// reference (list_jira_issues and get_jira_issue return raw_json and the
// custom fields, so a linked issue's key, summary and status ride along), in
// key order so a denial names the same project every time. filter is the
// row filter on ?1 and must use an index (exact match on the upper-cased
// value). A row with unreadable raw JSON, or a referenced key without a
// project prefix, makes the scope absent (fail closed).
func withReferencedProjects(ctx context.Context, d *db.DB, units []CallScope, filter string, arg any) ([]CallScope, error) {
	if d == nil {
		return nil, errNoDB
	}
	rows, err := d.QueryContext(ctx, `SELECT raw_json, custom_fields_json, epic_key FROM jira_issues WHERE `+filter, arg)
	if err != nil {
		return nil, fmt.Errorf("scope lookup: %w", err)
	}
	defer func() { _ = rows.Close() }()
	var keys []string
	for rows.Next() {
		var raw, custom, epic sql.NullString
		if err := rows.Scan(&raw, &custom, &epic); err != nil {
			return nil, fmt.Errorf("scope lookup: %w", err)
		}
		k, ok := referencedIssueKeys(raw.String, custom.String, epic.String)
		if !ok {
			return nil, nil // absent: only @* admits
		}
		keys = append(keys, k...)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("scope lookup: %w", err)
	}
	return addReferencedProjects(units, keys), nil
}

// addReferencedProjects adds the projects of keys (blank keys skipped) in
// key order; a non-blank key without a project prefix makes the scope absent.
func addReferencedProjects(units []CallScope, keys []string) []CallScope {
	slices.Sort(keys)
	for _, k := range keys {
		if strings.TrimSpace(k) == "" {
			continue
		}
		p := issueProject(k)
		if p == "" {
			return nil
		}
		units = addProjectUnit(units, p)
	}
	return units
}

// listJiraIssuesScope: the project plus every project its issues reference;
// no project → absent.
func listJiraIssuesScope(ctx context.Context, d *db.DB, args json.RawMessage) ([]CallScope, error) {
	a, err := decodeScopeArgs(args)
	if err != nil {
		return nil, err
	}
	p := strings.ToUpper(argString(a, "project"))
	if p == "" {
		return nil, nil
	}
	return withReferencedProjects(ctx, d, unit(p), "project_key = ?1", p)
}

// getJiraIssueScope: the key's project plus every project the issue
// references; a key without a project prefix → absent.
func getJiraIssueScope(ctx context.Context, d *db.DB, args json.RawMessage) ([]CallScope, error) {
	a, err := decodeScopeArgs(args)
	if err != nil {
		return nil, err
	}
	key := argString(a, "key")
	p := issueProject(key)
	if p == "" {
		return nil, nil
	}
	return withReferencedProjects(ctx, d, unit(p), "key = ?1", strings.ToUpper(key))
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
// calendar_accounts row by label.
func calendarAccountScope(ctx context.Context, d *db.DB, args json.RawMessage) ([]CallScope, error) {
	return accountArgScope(ctx, d, args, googleAccountByNameSQL,
		`SELECT label, '' FROM calendar_accounts WHERE label = ?1 COLLATE NOCASE`)
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

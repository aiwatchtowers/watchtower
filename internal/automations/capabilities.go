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
	"watchtower/internal/tools"
)

// CallScope is one scope unit a tool call touches. It is covered when any of
// Values matches an entry's scope; Values[0] is the canonical form named in
// PermissionDenied.Needed.
type CallScope struct {
	Values []string
}

// ToolCapability maps a registry tool to the capability row that admits it
// (spec §3.2). ScopeOf == nil reads args[ScopeArg] verbatim as one unit. A
// scoped tool returning no unit has an absent scope, admitted only by @* or
// tool:<name>.
type ToolCapability struct {
	Capability, Verb, ScopeArg string
	ScopeOf                    func(ctx context.Context, d *db.DB, args json.RawMessage) ([]CallScope, error)
}

func (c ToolCapability) scopes(ctx context.Context, d *db.DB, args json.RawMessage) ([]CallScope, error) {
	if c.ScopeOf != nil {
		return c.ScopeOf(ctx, d, args)
	}
	if c.ScopeArg == "" {
		return nil, nil
	}
	a, err := decodeArgs(args)
	if err != nil {
		return nil, err
	}
	return unit(argString(a, c.ScopeArg)), nil
}

// errNoDB is a scope lookup with no database handle.
var errNoDB = errors.New("scope lookup needs the database")

// ToolCapabilities is the tool → capability table (spec §3.2, §6.1, §20.1
// D21–D23). Tools missing from it — the broad knowledge tools, list_inbox,
// the memory tools and get_writing_style among them — are admitted only by
// tool:<name>.
var ToolCapabilities = map[string]ToolCapability{
	// Jira reads.
	"list_jira_issues":        {Capability: "jira", Verb: "read", ScopeArg: "project", ScopeOf: upperArgScope("project")},
	"get_jira_issue":          {Capability: "jira", Verb: "read", ScopeArg: "key", ScopeOf: issueKeyScope("key")},
	"get_jira_status_history": {Capability: "jira", Verb: "read", ScopeArg: "keys", ScopeOf: issueKeysScope("keys")},
	"get_jira_time_in_status": {Capability: "jira", Verb: "read", ScopeArg: "project", ScopeOf: timeInStatusScope},
	"list_jira_projects":      {Capability: "jira", Verb: "read"},
	"list_jira_sprints":       {Capability: "jira", Verb: "read", ScopeArg: "project", ScopeOf: sprintScope},
	"list_jira_releases":      {Capability: "jira", Verb: "read", ScopeArg: "project", ScopeOf: upperArgScope("project")},

	// Account-scoped reads. list_messages and list_upcoming_events read every
	// connected workspace/calendar: their scope is always absent (D22).
	"list_emails":          {Capability: "gmail", Verb: "read", ScopeArg: "account", ScopeOf: emailAccountScope},
	"get_email":            {Capability: "gmail", Verb: "read", ScopeArg: "account", ScopeOf: emailAccountScope},
	"list_calendar_events": {Capability: "calendar", Verb: "read", ScopeArg: "account", ScopeOf: calendarAccountScope},
	"list_messages":        {Capability: "slack", Verb: "read"},
	"list_upcoming_events": {Capability: "calendar", Verb: "read"},

	// Local reads, no scope.
	"list_targets":        {Capability: "targets", Verb: "read"},
	"get_target":          {Capability: "targets", Verb: "read"},
	"list_reminders":      {Capability: "targets", Verb: "read"},
	"list_tracks":         {Capability: "tracks", Verb: "read"},
	"get_track":           {Capability: "tracks", Verb: "read"},
	"get_track_counts":    {Capability: "tracks", Verb: "read"},
	"list_ideas":          {Capability: "ideas", Verb: "read"},
	"get_idea":            {Capability: "ideas", Verb: "read"},
	"list_digests":        {Capability: "digests", Verb: "read"},
	"get_digest":          {Capability: "digests", Verb: "read"},
	"get_today_briefing":  {Capability: "digests", Verb: "read"},
	"list_people":         {Capability: "people", Verb: "read"},
	"get_person":          {Capability: "people", Verb: "read"},
	"find_experts":        {Capability: "people", Verb: "read"},
	"list_transcripts":    {Capability: "transcripts", Verb: "read"},
	"get_transcript":      {Capability: "transcripts", Verb: "read"},
	"list_meeting_recaps": {Capability: "meetings", Verb: "read"},
	"get_meeting_recap":   {Capability: "meetings", Verb: "read"},
	"list_meeting_notes":  {Capability: "meetings", Verb: "read"},
	"list_day_plans":      {Capability: "dayplan", Verb: "read"},
	"get_day_plan":        {Capability: "dayplan", Verb: "read"},

	// Write tools (spec §6.1, consumed by P2).
	"create_target":         {Capability: "targets", Verb: "write"},
	"remind_me":             {Capability: "targets", Verb: "write"},
	"create_idea":           {Capability: "ideas", Verb: "write"},
	"create_track":          {Capability: "tracks", Verb: "write"},
	"create_jira_issue":     {Capability: "jira", Verb: "write", ScopeArg: "project_key", ScopeOf: upperArgScope("project_key")},
	"add_jira_comment":      {Capability: "jira", Verb: "write", ScopeArg: "key", ScopeOf: issueKeyScope("key")},
	"transition_jira_issue": {Capability: "jira", Verb: "write", ScopeArg: "key", ScopeOf: issueKeyScope("key")},
	"assign_jira_issue":     {Capability: "jira", Verb: "write", ScopeArg: "key", ScopeOf: issueKeyScope("key")},
	"update_jira_issue":     {Capability: "jira", Verb: "write", ScopeArg: "key", ScopeOf: issueKeyScope("key")},
	"send_slack_message":    {Capability: "slack", Verb: "write", ScopeArg: "account_id", ScopeOf: slackAccountScope},
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
		a, err := decodeArgs(args)
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

func issueKeyScope(key string) func(context.Context, *db.DB, json.RawMessage) ([]CallScope, error) {
	return func(_ context.Context, _ *db.DB, args json.RawMessage) ([]CallScope, error) {
		a, err := decodeArgs(args)
		if err != nil {
			return nil, err
		}
		return unit(issueProject(argString(a, key))), nil
	}
}

// projectsOfKeys is one unit per distinct project prefix; a key without a
// prefix makes the whole call's scope absent (only @* admits it).
func projectsOfKeys(keys []string) []CallScope {
	var out []CallScope
	var seen []string
	for _, k := range keys {
		p := issueProject(k)
		if p == "" {
			return nil
		}
		if !slices.Contains(seen, p) {
			seen = append(seen, p)
			out = append(out, CallScope{Values: []string{p}})
		}
	}
	return out
}

func issueKeysScope(key string) func(context.Context, *db.DB, json.RawMessage) ([]CallScope, error) {
	return func(_ context.Context, _ *db.DB, args json.RawMessage) ([]CallScope, error) {
		a, err := decodeArgs(args)
		if err != nil {
			return nil, err
		}
		return projectsOfKeys(argStrings(a, key)), nil
	}
}

// timeInStatusScope: project when given, else the issue_keys prefixes, else
// absent (board_id alone is absent).
func timeInStatusScope(_ context.Context, _ *db.DB, args json.RawMessage) ([]CallScope, error) {
	a, err := decodeArgs(args)
	if err != nil {
		return nil, err
	}
	if p := argString(a, "project"); p != "" {
		return unit(strings.ToUpper(p)), nil
	}
	return projectsOfKeys(argStrings(a, "issue_keys")), nil
}

// sprintScope: upper(project) when given, else the project of board_id's
// board(s); an unknown board or one with no project key is absent.
func sprintScope(ctx context.Context, d *db.DB, args json.RawMessage) ([]CallScope, error) {
	a, err := decodeArgs(args)
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
	keys, err := queryStrings(ctx, d, `SELECT project_key FROM jira_boards WHERE id = ?`, board)
	if err != nil {
		return nil, err
	}
	var out []CallScope
	for _, k := range keys {
		k = strings.ToUpper(strings.TrimSpace(k))
		if k == "" {
			return nil, nil
		}
		if !slices.ContainsFunc(out, func(u CallScope) bool { return u.Values[0] == k }) {
			out = append(out, CallScope{Values: []string{k}})
		}
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

// accountArgScope resolves args.account through the label/address lookups
// (each with two "?" for the account); no account or an unknown one is
// absent (the tool itself refuses an unknown account).
func accountArgScope(ctx context.Context, d *db.DB, args json.RawMessage, queries ...string) ([]CallScope, error) {
	a, err := decodeArgs(args)
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
		units, err := accountUnits(ctx, d, q, acct, acct)
		if err != nil {
			return nil, err
		}
		out = append(out, units...)
	}
	return out, nil
}

// emailAccountScope: a Google or IMAP account by label or address.
func emailAccountScope(ctx context.Context, d *db.DB, args json.RawMessage) ([]CallScope, error) {
	return accountArgScope(ctx, d, args,
		`SELECT label, email FROM google_accounts WHERE label = ? COLLATE NOCASE OR email = ? COLLATE NOCASE`,
		`SELECT label, email_address FROM email_accounts WHERE label = ? COLLATE NOCASE OR email_address = ? COLLATE NOCASE`)
}

// calendarAccountScope: a Google account by label or address, or a
// calendar_accounts row by label.
func calendarAccountScope(ctx context.Context, d *db.DB, args json.RawMessage) ([]CallScope, error) {
	return accountArgScope(ctx, d, args,
		`SELECT label, email FROM google_accounts WHERE label = ? COLLATE NOCASE OR email = ? COLLATE NOCASE`,
		`SELECT label, '' FROM calendar_accounts WHERE label = ? COLLATE NOCASE AND label = ? COLLATE NOCASE`)
}

// slackAccountScope: account_id resolved to {label, team_domain}; with no
// account_id, the only enabled Slack account when exactly one exists, else
// absent. An account_id of no account is an error (denied as slack:write@*).
func slackAccountScope(ctx context.Context, d *db.DB, args json.RawMessage) ([]CallScope, error) {
	a, err := decodeArgs(args)
	if err != nil {
		return nil, err
	}
	if d == nil {
		return nil, errNoDB
	}
	if id := argInt(a, "account_id"); id != 0 {
		units, err := accountUnits(ctx, d, `SELECT label, team_domain FROM slack_accounts WHERE id = ?`, id)
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

// ClampListLimit applies the list-tool limit (S9) to a call of a tool whose
// input schema has a "limit" property: absent or ≤ 0 → DefaultListLimit,
// above MaxListLimit → MaxListLimit. Every other call's args are returned
// unchanged, as are args that are not an object (schema validation refuses
// them later) or whose limit is not a number.
func ClampListLimit(t *tools.Tool, args json.RawMessage) json.RawMessage {
	if t.InputSchema == nil || t.InputSchema.Properties["limit"] == nil {
		return args
	}
	a, err := decodeArgs(args)
	if err != nil {
		return args
	}
	var n float64
	if raw, ok := a["limit"]; ok {
		if json.Unmarshal(raw, &n) != nil {
			return args
		}
	}
	switch {
	case n <= 0:
		n = DefaultListLimit
	case n > MaxListLimit:
		n = MaxListLimit
	default:
		return args
	}
	a["limit"] = json.RawMessage(fmt.Sprintf("%d", int(n)))
	out, err := json.Marshal(a)
	if err != nil {
		return args
	}
	return out
}

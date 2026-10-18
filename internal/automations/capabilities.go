package automations

import (
	"context"
	"encoding/json"
	"fmt"

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
//
// A Jira project grant covers the data the tool returns with that project's
// issues (linked issues, epic, parent): the scope is the call's own project
// or key prefixes (owner, ask #287).
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
	a, err := decodeScopeArgs(args)
	if err != nil {
		return nil, err
	}
	return unit(argString(a, c.ScopeArg)), nil
}

// ToolCapabilities is the tool → capability table (spec §3.2, §6.1, §20.1
// D21–D23). Tools missing from it — the broad knowledge tools, list_inbox,
// the memory tools and get_writing_style — are admitted only by
// tool:<name>.
var ToolCapabilities = map[string]ToolCapability{
	// Jira reads.
	"list_jira_issues":        {Capability: "jira", Verb: "read", ScopeArg: "project", ScopeOf: upperArgScope("project")},
	"get_jira_issue":          {Capability: "jira", Verb: "read", ScopeArg: "key", ScopeOf: issueKeyScope},
	"get_jira_status_history": {Capability: "jira", Verb: "read", ScopeArg: "keys", ScopeOf: statusHistoryScope},
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
	"add_jira_comment":      {Capability: "jira", Verb: "write", ScopeArg: "key", ScopeOf: issueKeyScope},
	"transition_jira_issue": {Capability: "jira", Verb: "write", ScopeArg: "key", ScopeOf: issueKeyScope},
	"assign_jira_issue":     {Capability: "jira", Verb: "write", ScopeArg: "key", ScopeOf: issueKeyScope},
	"update_jira_issue":     {Capability: "jira", Verb: "write", ScopeArg: "key", ScopeOf: issueKeyScope},
	"send_slack_message":    {Capability: "slack", Verb: "write", ScopeArg: "account_id", ScopeOf: slackAccountScope},
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

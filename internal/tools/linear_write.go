package tools

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"math"
	"slices"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/linear"
)

// LinearWriteClient is what the five Linear write tools need: the name
// lookups, the three mutations, the syncer's one-issue refresh and the
// lookup by id a create retry makes — a seam so tests inject a fake.
type LinearWriteClient interface {
	FetchTeamStates(ctx context.Context, teamID string) ([]linear.WorkflowState, error)
	FetchLabels(ctx context.Context, teamID string) ([]linear.Label, error)
	FetchUsers(ctx context.Context) ([]linear.User, error)
	CreateIssue(ctx context.Context, in linear.IssueCreateInput) (linear.IssueRef, error)
	UpdateIssue(ctx context.Context, issueID string, in linear.IssueUpdateInput) error
	CreateComment(ctx context.Context, issueID, body string) (string, error)
	RefreshIssue(ctx context.Context, issueID string) error
	FetchIssueRef(ctx context.Context, id string) (linear.IssueRef, bool, error)
}

// LinearWriteClientFactory builds a write client for one connected account.
type LinearWriteClientFactory func(account db.LinearAccount) (LinearWriteClient, error)

// LinearWriteTools returns the five Linear write tools in registration
// order. All are External (AGENT-03): each leaves the machine.
func LinearWriteTools(f LinearWriteClientFactory) []*Tool {
	return []*Tool{NewCreateLinearIssue(f), NewAddLinearComment(f), NewTransitionLinearIssue(f),
		NewAssignLinearIssue(f), NewUpdateLinearIssue(f)}
}

// linearTransitionStateTypes are the state types transition_linear_issue
// takes (triage is not a place an issue is moved to).
var linearTransitionStateTypes = []string{"backlog", "unstarted", "started", "completed", "canceled"}

// linearPriorities maps priority names to Linear's 0-4 scale.
var linearPriorities = map[string]int{"none": 0, "urgent": 1, "high": 2, "medium": 3, "normal": 3, "low": 4}

// linearPriority maps a priority name to Linear's 0-4 value.
func linearPriority(name string) (int, error) {
	if p, ok := linearPriorities[strings.ToLower(strings.TrimSpace(name))]; ok {
		return p, nil
	}
	return 0, &ValidationError{Msg: fmt.Sprintf("unknown priority %q: use none, urgent, high, medium (or normal) or low", name)}
}

// linearTeamTarget resolves a team key to its account and team: explicit
// account_id → that account; else the one enabled account whose mirror has
// the team. A key on several workspaces needs account_id; an unknown key
// lists the known ones.
func linearTeamTarget(d *db.DB, accountID int64, rawTeam string) (db.LinearAccount, db.LinearTeam, error) {
	team := strings.ToUpper(strings.TrimSpace(rawTeam))
	if team == "" {
		return db.LinearAccount{}, db.LinearTeam{}, &ValidationError{Msg: "team is required (see list_linear_teams)"}
	}
	accounts, err := linearReadAccounts(d, accountID)
	if err != nil {
		return db.LinearAccount{}, db.LinearTeam{}, err
	}
	if len(accounts) == 0 {
		return db.LinearAccount{}, db.LinearTeam{}, &ValidationError{Msg: noLinearAccountMsg}
	}
	type match struct {
		account db.LinearAccount
		team    db.LinearTeam
	}
	var matches []match
	var known []string
	for _, a := range accounts {
		teams, err := d.ListLinearTeams(a.ID)
		if err != nil {
			return db.LinearAccount{}, db.LinearTeam{}, err
		}
		for _, t := range teams {
			known = append(known, t.Key)
			if t.Key == team {
				matches = append(matches, match{a, t})
			}
		}
	}
	switch len(matches) {
	case 1:
		return matches[0].account, matches[0].team, nil
	case 0:
		slices.Sort(known)
		return db.LinearAccount{}, db.LinearTeam{}, &ValidationError{Msg: fmt.Sprintf(
			"no Linear team %s; known team keys: %s (see list_linear_teams)", team, strings.Join(slices.Compact(known), ", "))}
	default:
		return db.LinearAccount{}, db.LinearTeam{}, &ValidationError{Msg: fmt.Sprintf(
			"team %s exists on several Linear workspaces — pass account_id (see list_linear_teams)", team)}
	}
}

// linearIssueTarget resolves an issue key to the mirrored issue and its
// account. The writes need the issue's Linear id, so an issue missing from
// the mirror is the model's to fix.
func linearIssueTarget(d *db.DB, accountID int64, rawKey string) (db.LinearAccount, db.LinearIssue, error) {
	issue, err := linearIssuesByKey(d, accountID, rawKey)
	if errors.Is(err, errLinearIssueNotFound) {
		return db.LinearAccount{}, db.LinearIssue{}, &ValidationError{Msg: fmt.Sprintf(
			"%s is not a synced Linear issue; check the key with list_linear_issues", strings.ToUpper(strings.TrimSpace(rawKey)))}
	}
	if err != nil {
		return db.LinearAccount{}, db.LinearIssue{}, err
	}
	account, err := enabledLinearAccount(d, issue.AccountID)
	if err != nil {
		return db.LinearAccount{}, db.LinearIssue{}, err
	}
	return account, issue, nil
}

// openLinearIssue resolves the issue target and builds its client.
func openLinearIssue(d *db.DB, factory LinearWriteClientFactory, accountID int64, rawKey string) (db.LinearAccount, db.LinearIssue, LinearWriteClient, error) {
	account, issue, err := linearIssueTarget(d, accountID, rawKey)
	if err != nil {
		return db.LinearAccount{}, db.LinearIssue{}, nil, err
	}
	client, err := factory(account)
	if err != nil {
		return db.LinearAccount{}, db.LinearIssue{}, nil, err
	}
	return account, issue, client, nil
}

// pinnedLinearClient re-resolves the account Normalize pinned (refused once
// removed or disabled) and builds its client. Execute never re-resolves a
// key, team or name: a missing pin means Normalize never ran (a direct call
// or a row predating the pinning), and re-deriving would apply something the
// owner did not approve.
func pinnedLinearClient(d *db.DB, factory LinearWriteClientFactory, tool string, accountID int64, pins ...string) (db.LinearAccount, LinearWriteClient, error) {
	if accountID <= 0 || slices.Contains(pins, "") {
		return db.LinearAccount{}, nil, fmt.Errorf("%s: the target was not resolved when this was proposed; re-propose the action", tool)
	}
	account, err := enabledLinearAccount(d, accountID)
	if err != nil {
		return db.LinearAccount{}, nil, err
	}
	client, err := factory(account)
	if err != nil {
		return db.LinearAccount{}, nil, err
	}
	return account, client, nil
}

// linearWriteFailed marks the account revoked on ErrAuthRevoked (Execute only
// — Validate never writes) and folds a failed marking into the error.
func linearWriteFailed(d *db.DB, accountID int64, err error) error {
	if !errors.Is(err, linear.ErrAuthRevoked) {
		return err
	}
	if dbErr := d.SetLinearAccountAuthState(accountID, "revoked", err.Error()); dbErr != nil {
		return fmt.Errorf("%w (and recording the revoked state failed: %v)", err, dbErr)
	}
	return err
}

func linearIssueURL(account db.LinearAccount, key string) string {
	if account.URLKey == "" {
		return ""
	}
	return "https://linear.app/" + account.URLKey + "/issue/" + key
}

// linearIssueResult is the {key, url, label} shape of every issue write. The
// write already happened in Linear, so a failed mirror refresh only warns;
// the next sync repairs the mirror.
func linearIssueResult(ctx context.Context, client LinearWriteClient, issueID, key, url, label string) map[string]any {
	result := map[string]any{"key": key, "url": url, "label": label}
	if err := client.RefreshIssue(ctx, issueID); err != nil {
		result["warning"] = "applied, but the local mirror was not updated (it refreshes on the next sync): " + err.Error()
	}
	return result
}

// resolveLinearState picks one workflow state of a team: by name
// (case-insensitive) or, given stateType, the lowest-position state of that
// type. The mirror answers first; a miss refetches the team's states once (a
// state created since the last sync). A miss in both lists the states.
func resolveLinearState(ctx context.Context, d *db.DB, c LinearWriteClient, acct db.LinearAccount, teamID, name, stateType string) (linear.WorkflowState, error) {
	mirrored, err := d.ListLinearTeamStates(acct.ID, teamID)
	if err != nil {
		return linear.WorkflowState{}, err
	}
	states := make([]linear.WorkflowState, 0, len(mirrored))
	for _, s := range mirrored {
		states = append(states, linear.WorkflowState{ID: s.ID, Name: s.Name, Type: s.Type, Position: s.Position})
	}
	if s, ok := pickLinearState(states, name, stateType); ok {
		return s, nil
	}
	states, err = c.FetchTeamStates(ctx, teamID)
	if err != nil {
		return linear.WorkflowState{}, fmt.Errorf("reading the team's workflow states: %w", err)
	}
	if s, ok := pickLinearState(states, name, stateType); ok {
		return s, nil
	}
	listed := make([]string, 0, len(states))
	for _, s := range states {
		listed = append(listed, fmt.Sprintf("%s (%s)", s.Name, s.Type))
	}
	want := fmt.Sprintf("state %q", strings.TrimSpace(name))
	if name == "" {
		want = "state of type " + stateType
	}
	return linear.WorkflowState{}, &ValidationError{Msg: fmt.Sprintf("the team has no %s; its states: %s", want, strings.Join(listed, ", "))}
}

func pickLinearState(states []linear.WorkflowState, name, stateType string) (linear.WorkflowState, bool) {
	var best linear.WorkflowState
	found := false
	for _, s := range states {
		if name != "" {
			if strings.EqualFold(s.Name, strings.TrimSpace(name)) {
				return s, true
			}
			continue
		}
		if s.Type == stateType && (!found || s.Position < best.Position) {
			best, found = s, true
		}
	}
	return best, found
}

// resolveLinearLabels maps label names (case-insensitive) to ids among the
// team's and the workspace's labels; a team label wins over a workspace
// label of the same name. Any miss refetches the labels once; a label that
// still does not exist is refused, never created.
func resolveLinearLabels(ctx context.Context, d *db.DB, c LinearWriteClient, acct db.LinearAccount, teamID string, names []string) ([]string, error) {
	if len(names) == 0 {
		return []string{}, nil
	}
	mirrored, err := d.ListLinearLabels(acct.ID, teamID)
	if err != nil {
		return nil, err
	}
	labels := make([]linear.Label, 0, len(mirrored))
	for _, l := range mirrored {
		labels = append(labels, linear.Label{ID: l.ID, Name: l.Name, TeamID: l.TeamID})
	}
	ids, missing := matchLinearLabels(labels, names)
	if len(missing) == 0 {
		return ids, nil
	}
	if labels, err = c.FetchLabels(ctx, teamID); err != nil {
		return nil, fmt.Errorf("reading the team's labels: %w", err)
	}
	if ids, missing = matchLinearLabels(labels, names); len(missing) == 0 {
		return ids, nil
	}
	known := make([]string, 0, len(labels))
	for _, l := range labels {
		known = append(known, l.Name)
	}
	slices.Sort(known)
	return nil, &ValidationError{Msg: fmt.Sprintf("unknown label(s) %s (labels are never created); the team's labels: %s",
		strings.Join(missing, ", "), strings.Join(slices.Compact(known), ", "))}
}

func matchLinearLabels(labels []linear.Label, names []string) (ids, missing []string) {
	ids = []string{}
	for _, name := range names {
		id := ""
		for _, l := range labels {
			if strings.EqualFold(l.Name, name) && (id == "" || l.TeamID != "") {
				id = l.ID
			}
		}
		switch {
		case id == "":
			missing = append(missing, name)
		case !slices.Contains(ids, id):
			ids = append(ids, id)
		}
	}
	return ids, missing
}

type linearAssignee struct{ ID, Name string }

// resolveLinearAssignee maps "me" (the account's owner_user_id), "none"
// (unassign, ID "") or an email / exact display name to a Linear user:
// linear_user_map first, then one live workspace-users fetch. An ambiguous
// match is refused with the candidates.
func resolveLinearAssignee(ctx context.Context, d *db.DB, c LinearWriteClient, acct db.LinearAccount, who string) (linearAssignee, error) {
	who = strings.TrimSpace(who)
	switch {
	case who == "":
		return linearAssignee{}, &ValidationError{Msg: "assignee is required"}
	case strings.EqualFold(who, "none"):
		return linearAssignee{ID: "", Name: "nobody"}, nil
	case strings.EqualFold(who, "me"):
		if acct.OwnerUserID == "" {
			return linearAssignee{}, &ValidationError{Msg: fmt.Sprintf(
				"the owner's Linear user is not known yet; ask the owner to run 'watchtower linear sync --account %d', or pass their email", acct.ID)}
		}
		return linearAssignee{acct.OwnerUserID, firstNonEmpty(acct.OwnerDisplayName, "you")}, nil
	}
	if a, found, err := localLinearAssignee(d, who); err != nil || found {
		return a, err
	}
	users, err := c.FetchUsers(ctx)
	if err != nil {
		return linearAssignee{}, fmt.Errorf("reading the workspace's Linear users: %w", err)
	}
	byEmail := strings.Contains(who, "@")
	var hits []db.LinearUser
	for _, u := range users {
		if (byEmail && strings.EqualFold(u.Email, who)) ||
			(!byEmail && (strings.EqualFold(u.DisplayName, who) || strings.EqualFold(u.Name, who))) {
			hits = append(hits, db.LinearUser{ID: u.ID, Email: u.Email, DisplayName: firstNonEmpty(u.Name, u.DisplayName)})
		}
	}
	if len(hits) == 0 {
		return linearAssignee{}, &ValidationError{Msg: fmt.Sprintf("no Linear user matches %q; ask the owner for the person's email", who)}
	}
	return pickLinearAssignee(who, hits)
}

// localLinearAssignee answers from linear_user_map. The map has no account
// column, so with more than one Linear workspace on record it could name a
// user of another workspace; then only the live fetch is trusted.
func localLinearAssignee(d *db.DB, who string) (linearAssignee, bool, error) {
	accounts, err := d.ListLinearAccounts()
	if err != nil {
		return linearAssignee{}, false, fmt.Errorf("listing linear accounts: %w", err)
	}
	if len(accounts) != 1 {
		return linearAssignee{}, false, nil
	}
	hits, err := d.FindLinearUsers(who)
	if err != nil || len(hits) == 0 {
		return linearAssignee{}, false, err
	}
	a, err := pickLinearAssignee(who, hits)
	return a, true, err
}

func pickLinearAssignee(who string, hits []db.LinearUser) (linearAssignee, error) {
	if len(hits) == 1 {
		return linearAssignee{hits[0].ID, firstNonEmpty(hits[0].DisplayName, hits[0].Email)}, nil
	}
	names := make([]string, 0, len(hits))
	for _, h := range hits {
		names = append(names, strings.TrimSpace(h.DisplayName+" <"+h.Email+">"))
	}
	return linearAssignee{}, &ValidationError{Msg: fmt.Sprintf("%q matches several Linear users (%s); pass an email", who, strings.Join(names, ", "))}
}

// ---- create_linear_issue -----------------------------------------------------

type createLinearIssueArgs struct {
	AccountID   int64    `json:"account_id,omitempty" jsonschema:"connected Linear account id; needed only when the team key exists on several workspaces (see list_linear_teams)"`
	Team        string   `json:"team" jsonschema:"team key, e.g. ENG (see list_linear_teams)"`
	Title       string   `json:"title" jsonschema:"issue title"`
	Description string   `json:"description,omitempty" jsonschema:"markdown body"`
	Labels      []string `json:"labels,omitempty" jsonschema:"existing label names of the team or the workspace; an unknown label is refused, never created"`
	Priority    string   `json:"priority,omitempty" jsonschema:"none, urgent, high, medium (or normal) or low"`
	Assignee    string   `json:"assignee,omitempty" jsonschema:"me (the owner), a person's email, or their exact display name"`
	State       string   `json:"state,omitempty" jsonschema:"workflow state name, e.g. Todo; the team's default when omitted"`
	Reason      string   `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
	// Filled in by Normalize from the fields above when the proposal is
	// recorded — never by the model; Execute uses only these.
	TeamID        string   `json:"team_id,omitempty" jsonschema:"do not set; filled in automatically when the proposal is recorded"`
	LabelIDs      []string `json:"label_ids,omitempty" jsonschema:"do not set; filled in automatically when the proposal is recorded"`
	PriorityValue *int     `json:"priority_value,omitempty" jsonschema:"do not set; filled in automatically when the proposal is recorded"`
	AssigneeID    string   `json:"assignee_id,omitempty" jsonschema:"do not set; filled in automatically when the proposal is recorded"`
	StateID       string   `json:"state_id,omitempty" jsonschema:"do not set; filled in automatically when the proposal is recorded"`
	IssueUUID     string   `json:"issue_uuid,omitempty" jsonschema:"do not set; filled in automatically when the proposal is recorded"`
}

// newUUIDv4 is a random RFC 4122 version-4 UUID, the form Linear accepts as
// a client-chosen issue id.
func newUUIDv4() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", fmt.Errorf("generating an issue id: %w", err)
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]), nil
}

// resolveCreateLinearIssue checks the args and resolves every name to the
// ids Normalize pins (Validate runs it and discards the pins).
func resolveCreateLinearIssue(ctx context.Context, d *db.DB, factory LinearWriteClientFactory, a createLinearIssueArgs) (map[string]any, error) {
	if strings.TrimSpace(a.Title) == "" {
		return nil, &ValidationError{Msg: "title is required"}
	}
	var priority any // JSON null when omitted, overwriting any model guess
	if strings.TrimSpace(a.Priority) != "" {
		p, err := linearPriority(a.Priority)
		if err != nil {
			return nil, err
		}
		priority = p
	}
	account, team, err := linearTeamTarget(d, a.AccountID, a.Team)
	if err != nil {
		return nil, err
	}
	client, err := factory(account)
	if err != nil {
		return nil, err
	}
	labelIDs, err := resolveLinearLabels(ctx, d, client, account, team.ID, trimmedLabels(a.Labels))
	if err != nil {
		return nil, err
	}
	assigneeID := ""
	if strings.TrimSpace(a.Assignee) != "" {
		who, err := resolveLinearAssignee(ctx, d, client, account, a.Assignee)
		if err != nil {
			return nil, err
		}
		assigneeID = who.ID
	}
	stateID := ""
	if strings.TrimSpace(a.State) != "" {
		s, err := resolveLinearState(ctx, d, client, account, team.ID, a.State, "")
		if err != nil {
			return nil, err
		}
		stateID = s.ID
	}
	return map[string]any{
		"account_id": account.ID, "team": team.Key, "team_id": team.ID, "label_ids": labelIDs,
		"priority_value": priority, "assignee_id": assigneeID, "state_id": stateID,
	}, nil
}

// NewCreateLinearIssue builds the create_linear_issue write tool.
func NewCreateLinearIssue(factory LinearWriteClientFactory) *Tool {
	return &Tool{
		Name: "create_linear_issue",
		Description: "Propose creating a Linear issue in a team. Call list_linear_teams first for the team key, its " +
			"state names and labels; an unknown label is refused, never created. The owner approves it in the chat " +
			"before anything is sent to Linear.",
		InputSchema: mustWriteSchema[createLinearIssueArgs]("create_linear_issue"),
		Access:      AccessWrite,
		External:    true,
		Surfaces:    []string{"main", "target", AutomationSurface},
		Validate: func(ctx context.Context, d *db.DB, raw json.RawMessage) error {
			var a createLinearIssueArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			_, err := resolveCreateLinearIssue(ctx, d, factory, a)
			return err
		},
		Normalize: func(ctx context.Context, d *db.DB, raw json.RawMessage) (json.RawMessage, error) {
			var a createLinearIssueArgs
			if err := decodeStrict(raw, &a); err != nil {
				return nil, err
			}
			pins, err := resolveCreateLinearIssue(ctx, d, factory, a)
			if err != nil {
				return nil, err
			}
			// A fresh id per proposal, whatever the model sent: Linear
			// creates the issue under it, so a retry can find it.
			id, err := newUUIDv4()
			if err != nil {
				return nil, err
			}
			pins["issue_uuid"] = id
			return mergeJSON(raw, pins)
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a createLinearIssueArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding create_linear_issue args: %w", err)
			}
			account, client, err := pinnedLinearClient(d, factory, "create_linear_issue", a.AccountID, a.TeamID, a.IssueUUID)
			if err != nil {
				return nil, err
			}
			if call.Retry {
				// The failed attempt may have created the issue anyway (a
				// timeout or a lost response after Linear stored it). A
				// lookup that cannot tell fails the retry rather than
				// risking a duplicate.
				ref, found, err := client.FetchIssueRef(ctx, a.IssueUUID)
				if err != nil {
					return nil, linearWriteFailed(d, account.ID, err)
				}
				if found {
					result := linearIssueResult(ctx, client, ref.ID, ref.Identifier, ref.URL, "Created "+ref.Identifier)
					result["reused"] = true
					return result, nil
				}
			}
			ref, err := client.CreateIssue(ctx, linear.IssueCreateInput{
				ID: a.IssueUUID, TeamID: a.TeamID, Title: strings.TrimSpace(a.Title), Description: a.Description,
				StateID: a.StateID, AssigneeID: a.AssigneeID, Priority: a.PriorityValue, LabelIDs: a.LabelIDs,
			})
			if err != nil {
				return nil, linearWriteFailed(d, account.ID, err)
			}
			return linearIssueResult(ctx, client, ref.ID, ref.Identifier, ref.URL, "Created "+ref.Identifier), nil
		},
	}
}

// ---- add_linear_comment ------------------------------------------------------

type addLinearCommentArgs struct {
	AccountID int64  `json:"account_id,omitempty" jsonschema:"connected Linear account id; needed only when the key exists on several workspaces (see list_linear_teams)"`
	Key       string `json:"key" jsonschema:"issue key, e.g. ENG-123"`
	Body      string `json:"body" jsonschema:"markdown comment, at most 32000 characters"`
	Reason    string `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
	IssueID   string `json:"issue_id,omitempty" jsonschema:"do not set; filled in automatically when the proposal is recorded"`
}

// pinLinearIssue resolves the issue now and bakes the choice into the
// persisted args (account_id, the canonical key, issue_id) plus extra.
func pinLinearIssue(raw json.RawMessage, issue db.LinearIssue, extra map[string]any) (json.RawMessage, error) {
	patch := map[string]any{"account_id": issue.AccountID, "key": issue.Key, "issue_id": issue.ID}
	maps.Copy(patch, extra)
	return mergeJSON(raw, patch)
}

// NewAddLinearComment builds the add_linear_comment write tool.
func NewAddLinearComment(factory LinearWriteClientFactory) *Tool {
	return &Tool{
		Name: "add_linear_comment",
		Description: "Propose a comment on an existing Linear issue. The owner approves it in the chat before " +
			"anything is sent to Linear.",
		InputSchema: mustWriteSchema[addLinearCommentArgs]("add_linear_comment"),
		Access:      AccessWrite,
		External:    true,
		Surfaces:    []string{"main", "target", AutomationSurface},
		Validate: func(_ context.Context, d *db.DB, raw json.RawMessage) error {
			var a addLinearCommentArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			switch body := strings.TrimSpace(a.Body); {
			case body == "":
				return &ValidationError{Msg: "body is required"}
			case len([]rune(body)) > 32000:
				return &ValidationError{Msg: "body must be at most 32000 characters"}
			}
			_, _, err := linearIssueTarget(d, a.AccountID, a.Key)
			return err
		},
		Normalize: func(_ context.Context, d *db.DB, raw json.RawMessage) (json.RawMessage, error) {
			var a addLinearCommentArgs
			if err := decodeStrict(raw, &a); err != nil {
				return nil, err
			}
			_, issue, err := linearIssueTarget(d, a.AccountID, a.Key)
			if err != nil {
				return nil, err
			}
			return pinLinearIssue(raw, issue, nil)
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a addLinearCommentArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding add_linear_comment args: %w", err)
			}
			account, client, err := pinnedLinearClient(d, factory, "add_linear_comment", a.AccountID, a.IssueID)
			if err != nil {
				return nil, err
			}
			// Validate checked the cap on the trimmed body; send that one.
			if _, err := client.CreateComment(ctx, a.IssueID, strings.TrimSpace(a.Body)); err != nil {
				return nil, linearWriteFailed(d, account.ID, err)
			}
			return linearIssueResult(ctx, client, a.IssueID, a.Key, linearIssueURL(account, a.Key), "Comment on "+a.Key), nil
		},
	}
}

// ---- transition_linear_issue -------------------------------------------------

type transitionLinearIssueArgs struct {
	AccountID int64  `json:"account_id,omitempty" jsonschema:"connected Linear account id; needed only when the key exists on several workspaces (see list_linear_teams)"`
	Key       string `json:"key" jsonschema:"issue key, e.g. ENG-123"`
	State     string `json:"state,omitempty" jsonschema:"the workflow state to move the issue to, e.g. In Review; pass this or state_type"`
	StateType string `json:"state_type,omitempty" jsonschema:"backlog, unstarted, started, completed or canceled: the team's first state of that type; pass this or state"`
	Reason    string `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
	IssueID   string `json:"issue_id,omitempty" jsonschema:"do not set; filled in automatically when the proposal is recorded"`
	StateID   string `json:"state_id,omitempty" jsonschema:"do not set; filled in automatically when the proposal is recorded"`
	StateName string `json:"state_name,omitempty" jsonschema:"do not set; filled in automatically when the proposal is recorded"`
}

// resolveLinearTransition checks the args and resolves the issue and state.
func resolveLinearTransition(ctx context.Context, d *db.DB, factory LinearWriteClientFactory, a transitionLinearIssueArgs) (db.LinearIssue, linear.WorkflowState, error) {
	hasState, hasType := strings.TrimSpace(a.State) != "", a.StateType != ""
	if hasState == hasType {
		return db.LinearIssue{}, linear.WorkflowState{}, &ValidationError{Msg: "pass exactly one of state or state_type"}
	}
	if err := validateEnum("state_type", a.StateType, linearTransitionStateTypes...); err != nil {
		return db.LinearIssue{}, linear.WorkflowState{}, err
	}
	account, issue, client, err := openLinearIssue(d, factory, a.AccountID, a.Key)
	if err != nil {
		return db.LinearIssue{}, linear.WorkflowState{}, err
	}
	state, err := resolveLinearState(ctx, d, client, account, issue.TeamID, a.State, a.StateType)
	return issue, state, err
}

// NewTransitionLinearIssue builds the transition_linear_issue write tool.
func NewTransitionLinearIssue(factory LinearWriteClientFactory) *Tool {
	return &Tool{
		Name: "transition_linear_issue",
		Description: "Propose moving an existing Linear issue to another workflow state of its team: pass the state " +
			"name, or a state_type for the team's first state of that type. A state the team does not have is " +
			"rejected with the team's states. The owner approves it in the chat before anything is sent to Linear.",
		InputSchema: mustWriteSchema[transitionLinearIssueArgs]("transition_linear_issue"),
		Access:      AccessWrite,
		External:    true,
		Surfaces:    []string{"main", "target", AutomationSurface},
		Validate: func(ctx context.Context, d *db.DB, raw json.RawMessage) error {
			var a transitionLinearIssueArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			_, _, err := resolveLinearTransition(ctx, d, factory, a)
			return err
		},
		Normalize: func(ctx context.Context, d *db.DB, raw json.RawMessage) (json.RawMessage, error) {
			var a transitionLinearIssueArgs
			if err := decodeStrict(raw, &a); err != nil {
				return nil, err
			}
			issue, state, err := resolveLinearTransition(ctx, d, factory, a)
			if err != nil {
				return nil, err
			}
			return pinLinearIssue(raw, issue, map[string]any{"state_id": state.ID, "state_name": state.Name})
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a transitionLinearIssueArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding transition_linear_issue args: %w", err)
			}
			account, client, err := pinnedLinearClient(d, factory, "transition_linear_issue", a.AccountID, a.IssueID, a.StateID)
			if err != nil {
				return nil, err
			}
			if err := client.UpdateIssue(ctx, a.IssueID, linear.IssueUpdateInput{StateID: &a.StateID}); err != nil {
				return nil, linearWriteFailed(d, account.ID, err)
			}
			label := a.Key + " → " + firstNonEmpty(a.StateName, a.State, a.StateType)
			return linearIssueResult(ctx, client, a.IssueID, a.Key, linearIssueURL(account, a.Key), label), nil
		},
	}
}

// ---- assign_linear_issue -----------------------------------------------------

type assignLinearIssueArgs struct {
	AccountID    int64  `json:"account_id,omitempty" jsonschema:"connected Linear account id; needed only when the key exists on several workspaces (see list_linear_teams)"`
	Key          string `json:"key" jsonschema:"issue key, e.g. ENG-123"`
	Assignee     string `json:"assignee" jsonschema:"me (the owner), a person's email, their exact display name, or none to unassign"`
	Reason       string `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
	IssueID      string `json:"issue_id,omitempty" jsonschema:"do not set; filled in automatically when the proposal is recorded"`
	AssigneeID   string `json:"assignee_id,omitempty" jsonschema:"do not set; filled in automatically when the proposal is recorded"`
	AssigneeName string `json:"assignee_name,omitempty" jsonschema:"do not set; filled in automatically when the proposal is recorded"`
}

func resolveLinearAssign(ctx context.Context, d *db.DB, factory LinearWriteClientFactory, a assignLinearIssueArgs) (db.LinearIssue, linearAssignee, error) {
	if strings.TrimSpace(a.Assignee) == "" {
		return db.LinearIssue{}, linearAssignee{}, &ValidationError{Msg: "assignee is required"}
	}
	account, issue, client, err := openLinearIssue(d, factory, a.AccountID, a.Key)
	if err != nil {
		return db.LinearIssue{}, linearAssignee{}, err
	}
	who, err := resolveLinearAssignee(ctx, d, client, account, a.Assignee)
	return issue, who, err
}

// NewAssignLinearIssue builds the assign_linear_issue write tool.
func NewAssignLinearIssue(factory LinearWriteClientFactory) *Tool {
	return &Tool{
		Name: "assign_linear_issue",
		Description: "Propose assigning an existing Linear issue. assignee is \"me\" (the owner), a person's email, " +
			"their exact display name, or \"none\" to unassign; an ambiguous name is rejected with the candidates. " +
			"The owner approves it in the chat before anything is sent to Linear.",
		InputSchema: mustWriteSchema[assignLinearIssueArgs]("assign_linear_issue"),
		Access:      AccessWrite,
		External:    true,
		Surfaces:    []string{"main", "target", AutomationSurface},
		Validate: func(ctx context.Context, d *db.DB, raw json.RawMessage) error {
			var a assignLinearIssueArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			_, _, err := resolveLinearAssign(ctx, d, factory, a)
			return err
		},
		Normalize: func(ctx context.Context, d *db.DB, raw json.RawMessage) (json.RawMessage, error) {
			var a assignLinearIssueArgs
			if err := decodeStrict(raw, &a); err != nil {
				return nil, err
			}
			issue, who, err := resolveLinearAssign(ctx, d, factory, a)
			if err != nil {
				return nil, err
			}
			return pinLinearIssue(raw, issue, map[string]any{"assignee_id": who.ID, "assignee_name": who.Name})
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a assignLinearIssueArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding assign_linear_issue args: %w", err)
			}
			// assignee_id "" is a pinned unassign, so only issue_id proves
			// Normalize ran (it pins both together).
			account, client, err := pinnedLinearClient(d, factory, "assign_linear_issue", a.AccountID, a.IssueID)
			if err != nil {
				return nil, err
			}
			if err := client.UpdateIssue(ctx, a.IssueID, linear.IssueUpdateInput{AssigneeID: &a.AssigneeID}); err != nil {
				return nil, linearWriteFailed(d, account.ID, err)
			}
			label := a.Key + " → " + firstNonEmpty(a.AssigneeName, a.AssigneeID, "nobody")
			return linearIssueResult(ctx, client, a.IssueID, a.Key, linearIssueURL(account, a.Key), label), nil
		},
	}
}

// ---- update_linear_issue -----------------------------------------------------

type updateLinearIssueArgs struct {
	AccountID    int64    `json:"account_id,omitempty" jsonschema:"connected Linear account id; needed only when the key exists on several workspaces (see list_linear_teams)"`
	Key          string   `json:"key" jsonschema:"issue key, e.g. ENG-123"`
	Title        string   `json:"title,omitempty" jsonschema:"new title"`
	Priority     string   `json:"priority,omitempty" jsonschema:"none, urgent, high, medium (or normal) or low"`
	LabelsAdd    []string `json:"labels_add,omitempty" jsonschema:"existing label names to add; an unknown label is refused, never created"`
	LabelsRemove []string `json:"labels_remove,omitempty" jsonschema:"label names to remove"`
	DueDate      string   `json:"due_date,omitempty" jsonschema:"new due date, YYYY-MM-DD"`
	Estimate     *float64 `json:"estimate,omitempty" jsonschema:"new estimate, a whole number on the team's scale"`
	Reason       string   `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
	// Filled in by Normalize; Execute uses these, never the names.
	IssueID        string   `json:"issue_id,omitempty" jsonschema:"do not set; filled in automatically when the proposal is recorded"`
	LabelIDsAdd    []string `json:"label_ids_add,omitempty" jsonschema:"do not set; filled in automatically when the proposal is recorded"`
	LabelIDsRemove []string `json:"label_ids_remove,omitempty" jsonschema:"do not set; filled in automatically when the proposal is recorded"`
	PriorityValue  *int     `json:"priority_value,omitempty" jsonschema:"do not set; filled in automatically when the proposal is recorded"`
}

// checkLinearUpdate applies the validateIssueUpdate rules: at least one
// field, a well-formed due date, a whole non-negative estimate, no label in
// both lists. Clearing a field is not supported.
func checkLinearUpdate(a updateLinearIssueArgs) error {
	add, remove := trimmedLabels(a.LabelsAdd), trimmedLabels(a.LabelsRemove)
	title, due := strings.TrimSpace(a.Title), strings.TrimSpace(a.DueDate)
	if title == "" && strings.TrimSpace(a.Priority) == "" && len(add) == 0 && len(remove) == 0 && due == "" && a.Estimate == nil {
		return &ValidationError{Msg: "pass at least one of title, priority, labels_add, labels_remove, due_date, estimate"}
	}
	if due != "" {
		if _, err := time.Parse("2006-01-02", due); err != nil {
			return &ValidationError{Msg: fmt.Sprintf("due_date %q must be YYYY-MM-DD", due)}
		}
	}
	if e := a.Estimate; e != nil && (*e < 0 || *e != math.Trunc(*e)) {
		return &ValidationError{Msg: fmt.Sprintf("estimate %v must be a whole number of at least 0", *e)}
	}
	for _, l := range add {
		if slices.ContainsFunc(remove, func(r string) bool { return strings.EqualFold(r, l) }) {
			return &ValidationError{Msg: fmt.Sprintf("label %q is in both labels_add and labels_remove", l)}
		}
	}
	if strings.TrimSpace(a.Priority) != "" {
		if _, err := linearPriority(a.Priority); err != nil {
			return err
		}
	}
	return nil
}

// resolveLinearUpdate checks the args and returns the issue and the pins.
func resolveLinearUpdate(ctx context.Context, d *db.DB, factory LinearWriteClientFactory, a updateLinearIssueArgs) (db.LinearIssue, map[string]any, error) {
	if err := checkLinearUpdate(a); err != nil {
		return db.LinearIssue{}, nil, err
	}
	account, issue, client, err := openLinearIssue(d, factory, a.AccountID, a.Key)
	if err != nil {
		return db.LinearIssue{}, nil, err
	}
	add, err := resolveLinearLabels(ctx, d, client, account, issue.TeamID, trimmedLabels(a.LabelsAdd))
	if err != nil {
		return db.LinearIssue{}, nil, err
	}
	remove, err := resolveLinearLabels(ctx, d, client, account, issue.TeamID, trimmedLabels(a.LabelsRemove))
	if err != nil {
		return db.LinearIssue{}, nil, err
	}
	var priority any // JSON null when omitted, overwriting any model guess
	if strings.TrimSpace(a.Priority) != "" {
		priority, _ = linearPriority(a.Priority) // checked above
	}
	return issue, map[string]any{"label_ids_add": add, "label_ids_remove": remove, "priority_value": priority}, nil
}

// NewUpdateLinearIssue builds the update_linear_issue write tool.
func NewUpdateLinearIssue(factory LinearWriteClientFactory) *Tool {
	return &Tool{
		Name: "update_linear_issue",
		Description: "Propose editing an existing Linear issue: any of title, priority (none, urgent, high, medium, " +
			"low), labels to add or remove, due date (YYYY-MM-DD) and estimate (a whole number). Clearing a field is " +
			"not supported. The owner approves it in the chat before anything is sent to Linear.",
		InputSchema: mustWriteSchema[updateLinearIssueArgs]("update_linear_issue"),
		Access:      AccessWrite,
		External:    true,
		Surfaces:    []string{"main", "target", AutomationSurface},
		Validate: func(ctx context.Context, d *db.DB, raw json.RawMessage) error {
			var a updateLinearIssueArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			_, _, err := resolveLinearUpdate(ctx, d, factory, a)
			return err
		},
		Normalize: func(ctx context.Context, d *db.DB, raw json.RawMessage) (json.RawMessage, error) {
			var a updateLinearIssueArgs
			if err := decodeStrict(raw, &a); err != nil {
				return nil, err
			}
			issue, pins, err := resolveLinearUpdate(ctx, d, factory, a)
			if err != nil {
				return nil, err
			}
			return pinLinearIssue(raw, issue, pins)
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a updateLinearIssueArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding update_linear_issue args: %w", err)
			}
			account, client, err := pinnedLinearClient(d, factory, "update_linear_issue", a.AccountID, a.IssueID)
			if err != nil {
				return nil, err
			}
			in := linear.IssueUpdateInput{Priority: a.PriorityValue, Estimate: a.Estimate,
				AddedLabelIDs: a.LabelIDsAdd, RemovedLabelIDs: a.LabelIDsRemove}
			if title := strings.TrimSpace(a.Title); title != "" {
				in.Title = &title
			}
			if due := strings.TrimSpace(a.DueDate); due != "" {
				in.DueDate = &due
			}
			if err := client.UpdateIssue(ctx, a.IssueID, in); err != nil {
				return nil, linearWriteFailed(d, account.ID, err)
			}
			return linearIssueResult(ctx, client, a.IssueID, a.Key, linearIssueURL(account, a.Key), a.Key+" updated"), nil
		},
	}
}

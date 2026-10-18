package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"watchtower/internal/db"
)

// maxLinearHistoryKeys caps get_linear_status_history, as the spec's "≤ 20".
const maxLinearHistoryKeys = 20

// linearStateTypes are Linear's workflow state types.
var linearStateTypes = []string{"triage", "backlog", "unstarted", "started", "completed", "canceled"}

var linearKeyRE = regexp.MustCompile(`^[A-Z][A-Z0-9]*-\d+$`)

const noLinearAccountMsg = "no Linear workspace is connected; the owner must run 'watchtower linear add' first"

// enabledLinearAccount returns the account for an explicit id, refusing a
// removed or disabled one (the ResolveJiraAccount rule).
func enabledLinearAccount(d *db.DB, id int64) (db.LinearAccount, error) {
	a, err := d.GetLinearAccount(id)
	if errors.Is(err, db.ErrLinearAccountNotFound) {
		return db.LinearAccount{}, &ValidationError{Msg: fmt.Sprintf("no Linear account #%d", id)}
	}
	if err != nil {
		return db.LinearAccount{}, fmt.Errorf("looking up Linear account #%d: %w", id, err)
	}
	if a.Status == "removed" || !a.Enabled {
		return db.LinearAccount{}, &ValidationError{Msg: fmt.Sprintf("Linear account #%d is not enabled", id)}
	}
	return a, nil
}

// linearReadAccounts is the account set a list read covers: the explicit
// account, else every enabled one.
func linearReadAccounts(d *db.DB, accountID int64) ([]db.LinearAccount, error) {
	if accountID > 0 {
		a, err := enabledLinearAccount(d, accountID)
		if err != nil {
			return nil, err
		}
		return []db.LinearAccount{a}, nil
	}
	accounts, err := d.ListEnabledLinearAccounts()
	if err != nil {
		return nil, fmt.Errorf("listing linear accounts: %w", err)
	}
	if len(accounts) == 0 {
		return nil, &ValidationError{Msg: noLinearAccountMsg}
	}
	return accounts, nil
}

// linearIssuesByKey resolves an issue key (current or previous, any case) to
// one non-deleted issue of an enabled account. accountID > 0 narrows to that
// account; several accounts holding the key without it is a ValidationError.
// Task 5's writes reuse it.
func linearIssuesByKey(d *db.DB, accountID int64, rawKey string) (db.LinearIssue, error) {
	key := strings.ToUpper(strings.TrimSpace(rawKey))
	if !linearKeyRE.MatchString(key) {
		return db.LinearIssue{}, &ValidationError{Msg: fmt.Sprintf("invalid issue key %q: expected e.g. ENG-123", rawKey)}
	}
	if accountID > 0 {
		if _, err := enabledLinearAccount(d, accountID); err != nil {
			return db.LinearIssue{}, err
		}
	}
	enabled, err := d.ListEnabledLinearAccounts()
	if err != nil {
		return db.LinearIssue{}, fmt.Errorf("listing linear accounts: %w", err)
	}
	if len(enabled) == 0 {
		return db.LinearIssue{}, &ValidationError{Msg: noLinearAccountMsg}
	}
	isEnabled := map[int64]bool{}
	for _, a := range enabled {
		isEnabled[a.ID] = true
	}
	rows, err := d.GetLinearIssueByKey(key)
	if err != nil {
		return db.LinearIssue{}, fmt.Errorf("getting linear issue: %w", err)
	}
	byAccount := map[int64]db.LinearIssue{}
	var order []int64
	for _, r := range rows {
		if r.IsDeleted || !isEnabled[r.AccountID] || (accountID > 0 && r.AccountID != accountID) {
			continue
		}
		cur, seen := byAccount[r.AccountID]
		if !seen {
			order = append(order, r.AccountID)
		}
		// Within an account the issue that holds the key now beats one that
		// only held it before a move.
		if !seen || (cur.Key != key && r.Key == key) {
			byAccount[r.AccountID] = r
		}
	}
	switch len(order) {
	case 0:
		return db.LinearIssue{}, fmt.Errorf("no linear issue with key %s", key)
	case 1:
		return byAccount[order[0]], nil
	default:
		return db.LinearIssue{}, &ValidationError{Msg: fmt.Sprintf(
			"issue %s exists on several Linear workspaces — pass account_id (see list_linear_teams)", key)}
	}
}

// ── list_linear_teams ────────────────────────────────────────────────────────

type listLinearTeamsArgs struct{}

type linearStateView struct {
	Name     string  `json:"name"`
	Type     string  `json:"type"`
	Position float64 `json:"position"`
}

type linearTeamView struct {
	Key      string            `json:"key"`
	Name     string            `json:"name"`
	Selected bool              `json:"selected"`
	States   []linearStateView `json:"states"`
	Labels   []string          `json:"labels"`
}

type linearAccountView struct {
	AccountID       int64            `json:"account_id"`
	Label           string           `json:"label,omitempty"`
	OrgName         string           `json:"org_name,omitempty"`
	URLKey          string           `json:"url_key,omitempty"`
	Teams           []linearTeamView `json:"teams"`
	WorkspaceLabels []string         `json:"workspace_labels"`
}

// NewListLinearTeams lists the connected Linear workspaces with their teams,
// workflow states and labels (the mirror only).
func NewListLinearTeams() *Tool {
	return &Tool{
		Name: "list_linear_teams",
		Description: "List the connected Linear workspaces and their teams (key, name, whether Watchtower syncs it), " +
			"with each team's workflow states (name, type, position) and labels — the account_id, team key and " +
			"state names the other Linear tools take.",
		InputSchema: mustSchema[listLinearTeamsArgs]("list_linear_teams"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, _ Call) (any, error) {
			accounts, err := d.ListEnabledLinearAccounts()
			if err != nil {
				return nil, fmt.Errorf("listing linear accounts: %w", err)
			}
			out := make([]linearAccountView, 0, len(accounts))
			for _, a := range accounts {
				view := linearAccountView{AccountID: a.ID, Label: a.Label, OrgName: a.OrgName, URLKey: a.URLKey,
					Teams: []linearTeamView{}, WorkspaceLabels: []string{}}
				teams, err := d.ListLinearTeams(a.ID)
				if err != nil {
					return nil, err
				}
				seenWS := map[string]bool{}
				for _, t := range teams {
					tv := linearTeamView{Key: t.Key, Name: t.Name, Selected: t.IsSelected,
						States: []linearStateView{}, Labels: []string{}}
					states, err := d.ListLinearTeamStates(a.ID, t.ID)
					if err != nil {
						return nil, err
					}
					for _, s := range states {
						tv.States = append(tv.States, linearStateView{Name: s.Name, Type: s.Type, Position: s.Position})
					}
					labels, err := d.ListLinearLabels(a.ID, t.ID)
					if err != nil {
						return nil, err
					}
					for _, l := range labels {
						switch {
						case l.TeamID == "" && !seenWS[l.ID]:
							seenWS[l.ID] = true
							view.WorkspaceLabels = append(view.WorkspaceLabels, l.Name)
						case l.TeamID != "":
							tv.Labels = append(tv.Labels, l.Name)
						}
					}
					view.Teams = append(view.Teams, tv)
				}
				out = append(out, view)
			}
			return out, nil
		},
	}
}

// ── list_linear_issues ───────────────────────────────────────────────────────

type listLinearIssuesArgs struct {
	AccountID    int64  `json:"account_id,omitempty" jsonschema:"connected Linear account id; needed only to narrow to one workspace (see list_linear_teams)"`
	Team         string `json:"team,omitempty" jsonschema:"team key, e.g. ENG"`
	State        string `json:"state,omitempty" jsonschema:"exact workflow state name, e.g. 'In Progress'"`
	StateType    string `json:"state_type,omitempty" jsonschema:"state type: triage, backlog, unstarted, started, completed or canceled"`
	Assignee     string `json:"assignee,omitempty" jsonschema:"'me' (the owner), an assignee email, or a Linear user id"`
	CreatedAfter string `json:"created_after,omitempty" jsonschema:"only issues created at or after this RFC 3339 time or YYYY-MM-DD date (UTC)"`
	Limit        int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

// linearIssueListItem is one list_linear_issues row: the issue without
// raw_json and with the description clipped.
type linearIssueListItem struct {
	AccountID            int64    `json:"account_id"`
	Key                  string   `json:"key"`
	Title                string   `json:"title"`
	Description          string   `json:"description,omitempty"`
	DescriptionTruncated bool     `json:"description_truncated,omitempty"`
	TeamKey              string   `json:"team_key"`
	State                string   `json:"state"`
	StateType            string   `json:"state_type"`
	Assignee             string   `json:"assignee,omitempty"`
	AssigneeID           string   `json:"assignee_id,omitempty"`
	AssigneeEmail        string   `json:"assignee_email,omitempty"`
	Priority             int      `json:"priority"`
	PriorityName         string   `json:"priority_name"`
	Estimate             *float64 `json:"estimate,omitempty"`
	Labels               []string `json:"labels"`
	DueDate              string   `json:"due_date,omitempty"`
	URL                  string   `json:"url,omitempty"`
	CreatedAt            string   `json:"created_at"`
	UpdatedAt            string   `json:"updated_at"`
}

// linearPriorityName is Linear's 0-4 priority as a word.
func linearPriorityName(p int) string {
	switch p {
	case 1:
		return "urgent"
	case 2:
		return "high"
	case 3:
		return "medium"
	case 4:
		return "low"
	default:
		return "none"
	}
}

func listedLinearIssue(i db.LinearIssue) linearIssueListItem {
	desc, truncated := ClipUTF8Bytes(i.DescriptionText, maxListedDescriptionBytes)
	labels := i.Labels
	if labels == nil {
		labels = []string{}
	}
	return linearIssueListItem{
		AccountID: i.AccountID, Key: i.Key, Title: i.Title, Description: desc, DescriptionTruncated: truncated,
		TeamKey: i.TeamKey, State: i.StateName, StateType: i.StateType, Assignee: i.AssigneeDisplayName,
		AssigneeID: i.AssigneeID, AssigneeEmail: i.AssigneeEmail, Priority: i.Priority,
		PriorityName: linearPriorityName(i.Priority), Estimate: i.Estimate, Labels: labels, DueDate: i.DueDate,
		URL: i.URL, CreatedAt: i.CreatedAt, UpdatedAt: i.UpdatedAt,
	}
}

// linearCreatedAfter normalises an RFC 3339 time or a YYYY-MM-DD date (its
// midnight UTC) to the stored UTC layout; "" stays "".
func linearCreatedAfter(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", nil
	}
	if ts, err := time.Parse(time.RFC3339, raw); err == nil {
		return ts.UTC().Format(utcColumnLayout), nil
	}
	if ts, err := time.Parse(planDateLayout, raw); err == nil {
		return ts.UTC().Format(utcColumnLayout), nil
	}
	return "", &ValidationError{Msg: "created_after must be an RFC 3339 time or a YYYY-MM-DD date"}
}

// NewListLinearIssues lists synced Linear issues as lean rows, newest first.
func NewListLinearIssues() *Tool {
	return &Tool{
		Name: "list_linear_issues",
		Description: "List synced Linear issues, newest created first, optionally filtered by team key, workflow state " +
			"name or type (triage, backlog, unstarted, started, completed, canceled), assignee ('me', email or Linear " +
			"user id) and creation time. Each row has the issue's main fields and its description clipped at 512 bytes; " +
			"get_linear_issue returns one issue in full with its comments.",
		InputSchema: mustSchema[listLinearIssuesArgs]("list_linear_issues"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a listLinearIssuesArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			if err := validateEnum("state_type", a.StateType, linearStateTypes...); err != nil {
				return nil, err
			}
			createdAfter, err := linearCreatedAfter(a.CreatedAfter)
			if err != nil {
				return nil, err
			}
			accounts, err := linearReadAccounts(d, a.AccountID)
			if err != nil {
				return nil, err
			}
			f := db.LinearIssueFilter{
				TeamKey: strings.ToUpper(strings.TrimSpace(a.Team)), StateName: strings.TrimSpace(a.State),
				StateType: a.StateType, CreatedAfter: createdAfter, Limit: listLimit(a.Limit),
			}
			for _, acc := range accounts {
				f.AccountIDs = append(f.AccountIDs, acc.ID)
			}
			switch who := strings.TrimSpace(a.Assignee); {
			case who == "":
			case strings.EqualFold(who, "me"):
				for _, acc := range accounts {
					if acc.OwnerUserID != "" {
						f.AssigneeIDs = append(f.AssigneeIDs, acc.OwnerUserID)
					}
				}
				if len(f.AssigneeIDs) == 0 {
					return nil, &ValidationError{Msg: "the owner's Linear user is not known yet; run linear sync"}
				}
			case strings.Contains(who, "@"):
				f.AssigneeEmail = who
			default:
				f.AssigneeIDs = []string{who}
			}
			issues, err := d.ListLinearIssues(f)
			if err != nil {
				return nil, err
			}
			out := make([]linearIssueListItem, 0, len(issues))
			for _, i := range issues {
				out = append(out, listedLinearIssue(i))
			}
			return out, nil
		},
	}
}

// ── get_linear_issue ─────────────────────────────────────────────────────────

type getLinearIssueArgs struct {
	Key       string `json:"key" jsonschema:"Linear issue key, e.g. ENG-123; a key the issue had before moving teams works too"`
	AccountID int64  `json:"account_id,omitempty" jsonschema:"connected Linear account id; needed only when the key exists on several workspaces"`
}

type linearCommentView struct {
	ID        string `json:"id"`
	Author    string `json:"author,omitempty"`
	AuthorID  string `json:"author_id,omitempty"`
	Body      string `json:"body"`
	CreatedAt string `json:"created_at"`
	UpdatedAt string `json:"updated_at,omitempty"`
}

type linearIssueView struct {
	AccountID      int64               `json:"account_id"`
	Key            string              `json:"key"`
	PreviousKeys   []string            `json:"previous_keys,omitempty"`
	Title          string              `json:"title"`
	Description    string              `json:"description,omitempty"`
	TeamKey        string              `json:"team_key"`
	State          string              `json:"state"`
	StateType      string              `json:"state_type"`
	StateChangedAt string              `json:"state_changed_at,omitempty"`
	Assignee       string              `json:"assignee,omitempty"`
	AssigneeID     string              `json:"assignee_id,omitempty"`
	AssigneeEmail  string              `json:"assignee_email,omitempty"`
	Creator        string              `json:"creator,omitempty"`
	CreatorID      string              `json:"creator_id,omitempty"`
	CreatorEmail   string              `json:"creator_email,omitempty"`
	Priority       int                 `json:"priority"`
	PriorityName   string              `json:"priority_name"`
	Estimate       *float64            `json:"estimate,omitempty"`
	Labels         []string            `json:"labels"`
	DueDate        string              `json:"due_date,omitempty"`
	CycleID        string              `json:"cycle_id,omitempty"`
	ProjectID      string              `json:"project_id,omitempty"`
	ParentID       string              `json:"parent_id,omitempty"`
	URL            string              `json:"url,omitempty"`
	CreatedAt      string              `json:"created_at"`
	UpdatedAt      string              `json:"updated_at"`
	CompletedAt    string              `json:"completed_at,omitempty"`
	CanceledAt     string              `json:"canceled_at,omitempty"`
	Comments       []linearCommentView `json:"comments"`
}

// NewGetLinearIssue returns one Linear issue in full with its comments.
func NewGetLinearIssue() *Tool {
	return &Tool{
		Name:        "get_linear_issue",
		Description: "Get a single Linear issue by key with its full description and its comments, oldest first.",
		InputSchema: mustSchema[getLinearIssueArgs]("get_linear_issue"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a getLinearIssueArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			i, err := linearIssuesByKey(d, a.AccountID, a.Key)
			if err != nil {
				return nil, err
			}
			comments, err := d.ListLinearComments(i.AccountID, i.ID)
			if err != nil {
				return nil, err
			}
			labels := i.Labels
			if labels == nil {
				labels = []string{}
			}
			view := linearIssueView{
				AccountID: i.AccountID, Key: i.Key, PreviousKeys: i.PreviousKeys, Title: i.Title,
				Description: i.DescriptionText, TeamKey: i.TeamKey, State: i.StateName, StateType: i.StateType,
				StateChangedAt: i.StateChangedAt, Assignee: i.AssigneeDisplayName, AssigneeID: i.AssigneeID,
				AssigneeEmail: i.AssigneeEmail, Creator: i.CreatorDisplayName, CreatorID: i.CreatorID,
				CreatorEmail: i.CreatorEmail, Priority: i.Priority, PriorityName: linearPriorityName(i.Priority),
				Estimate: i.Estimate, Labels: labels, DueDate: i.DueDate, CycleID: i.CycleID, ProjectID: i.ProjectID,
				ParentID: i.ParentID, URL: i.URL, CreatedAt: i.CreatedAt, UpdatedAt: i.UpdatedAt,
				CompletedAt: i.CompletedAt, CanceledAt: i.CanceledAt, Comments: []linearCommentView{},
			}
			for _, c := range comments {
				view.Comments = append(view.Comments, linearCommentView{ID: c.ID, Author: c.AuthorDisplayName,
					AuthorID: c.AuthorID, Body: c.BodyText, CreatedAt: c.CreatedAt, UpdatedAt: c.UpdatedAt})
			}
			return view, nil
		},
	}
}

// ── get_linear_status_history ────────────────────────────────────────────────

type getLinearStatusHistoryArgs struct {
	Keys      []string `json:"keys" jsonschema:"Linear issue keys, e.g. ENG-1 (at most 20)"`
	AccountID int64    `json:"account_id,omitempty" jsonschema:"connected Linear account id; needed only when a key exists on several workspaces"`
}

type linearHistoryEvent struct {
	At    string `json:"at"`
	Field string `json:"field"`
	From  string `json:"from,omitempty"`
	To    string `json:"to,omitempty"`
	By    string `json:"by,omitempty"`
}

type linearIssueHistoryView struct {
	Key       string               `json:"key"`
	AccountID int64                `json:"account_id"`
	Title     string               `json:"title"`
	State     string               `json:"state"`
	StateType string               `json:"state_type"`
	Assignee  string               `json:"assignee,omitempty"`
	CreatedAt string               `json:"created_at"`
	Events    []linearHistoryEvent `json:"events"`
}

type linearHistoryResult struct {
	Issues   []linearIssueHistoryView `json:"issues"`
	NotFound []string                 `json:"not_found,omitempty"`
}

// NewGetLinearStatusHistory returns the state and assignee changes of issues.
func NewGetLinearStatusHistory() *Tool {
	return &Tool{
		Name: "get_linear_status_history",
		Description: "Get the state and assignee change history of Linear issues (who changed what, when), oldest first. " +
			"Keys that are not synced come back in not_found.",
		InputSchema: mustSchema[getLinearStatusHistoryArgs]("get_linear_status_history"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a getLinearStatusHistoryArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			keys := normalizeKeys(a.Keys)
			if len(keys) == 0 {
				return nil, &ValidationError{Msg: "keys is required"}
			}
			if len(keys) > maxLinearHistoryKeys {
				return nil, &ValidationError{Msg: fmt.Sprintf("at most %d keys per call", maxLinearHistoryKeys)}
			}
			res := linearHistoryResult{Issues: []linearIssueHistoryView{}}
			for _, k := range keys {
				i, err := linearIssuesByKey(d, a.AccountID, k)
				if err != nil {
					var ve *ValidationError
					if errors.As(err, &ve) {
						return nil, err
					}
					res.NotFound = append(res.NotFound, k)
					continue
				}
				entries, err := d.ListLinearHistory(i.AccountID, []string{i.ID})
				if err != nil {
					return nil, err
				}
				view := linearIssueHistoryView{Key: i.Key, AccountID: i.AccountID, Title: i.Title, State: i.StateName,
					StateType: i.StateType, Assignee: i.AssigneeDisplayName, CreatedAt: i.CreatedAt,
					Events: make([]linearHistoryEvent, 0, len(entries))}
				for _, e := range entries {
					view.Events = append(view.Events, linearHistoryEvent{At: e.ChangedAt, Field: e.Field,
						From: e.FromString, To: e.ToString, By: e.ActorDisplayName})
				}
				res.Issues = append(res.Issues, view)
			}
			return res, nil
		},
	}
}

// ── list_linear_cycles ───────────────────────────────────────────────────────

type listLinearCyclesArgs struct {
	Team      string `json:"team" jsonschema:"team key, e.g. ENG (see list_linear_teams)"`
	AccountID int64  `json:"account_id,omitempty" jsonschema:"connected Linear account id; needed only when the team key exists on several workspaces"`
	Limit     int    `json:"limit,omitempty" jsonschema:"max cycles per workspace, 0 = default (50), capped at 200"`
}

type linearCycleView struct {
	AccountID   int64   `json:"account_id"`
	ID          string  `json:"id"`
	TeamKey     string  `json:"team_key"`
	Number      int     `json:"number"`
	Name        string  `json:"name,omitempty"`
	State       string  `json:"state"`
	StartsAt    string  `json:"starts_at"`
	EndsAt      string  `json:"ends_at"`
	CompletedAt string  `json:"completed_at,omitempty"`
	Progress    float64 `json:"progress"`
}

// linearCycleState derives active/upcoming/past: a completed or ended cycle
// is past, one not started yet is upcoming. Unreadable times give "".
func linearCycleState(c db.LinearCycle, now time.Time) string {
	if c.CompletedAt != "" {
		return "past"
	}
	starts, err1 := time.Parse(time.RFC3339, c.StartsAt)
	ends, err2 := time.Parse(time.RFC3339, c.EndsAt)
	switch {
	case err1 != nil || err2 != nil:
		return ""
	case now.Before(starts):
		return "upcoming"
	case !now.Before(ends):
		return "past"
	default:
		return "active"
	}
}

// NewListLinearCycles lists a team's cycles with a derived state.
func NewListLinearCycles() *Tool {
	return &Tool{
		Name: "list_linear_cycles",
		Description: "List a Linear team's synced cycles (sprints), newest first, with a derived state " +
			"(active, upcoming or past) and progress.",
		InputSchema: mustSchema[listLinearCyclesArgs]("list_linear_cycles"),
		Access:      AccessRead,
		Surfaces:    automationSurfaceOnly(),
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			a, err := decodeAutomationArgs[listLinearCyclesArgs](call)
			if err != nil {
				return nil, err
			}
			team := strings.ToUpper(strings.TrimSpace(a.Team))
			if team == "" {
				return nil, &ValidationError{Msg: "team is required (see list_linear_teams)"}
			}
			accounts, err := linearReadAccounts(d, a.AccountID)
			if err != nil {
				return nil, err
			}
			now := time.Now().UTC()
			out := []linearCycleView{}
			for _, acc := range accounts {
				teams, err := d.ListLinearTeams(acc.ID)
				if err != nil {
					return nil, err
				}
				for _, t := range teams {
					if t.Key != team {
						continue
					}
					cycles, err := d.ListLinearCycles(acc.ID, t.ID)
					if err != nil {
						return nil, err
					}
					if limit := listLimit(a.Limit); len(cycles) > limit {
						cycles = cycles[:limit]
					}
					for _, c := range cycles {
						out = append(out, linearCycleView{AccountID: acc.ID, ID: c.ID, TeamKey: t.Key, Number: c.Number,
							Name: c.Name, State: linearCycleState(c, now), StartsAt: c.StartsAt, EndsAt: c.EndsAt,
							CompletedAt: c.CompletedAt, Progress: c.Progress})
					}
				}
			}
			return map[string]any{"cycles": out}, nil
		},
	}
}

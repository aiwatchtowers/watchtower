package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/db"
	"watchtower/internal/jira"
)

// JiraIssueClient is the slice of *jira.Client the tool needs — a seam so
// tests inject a fake and the CLI wiring injects a real per-account client.
type JiraIssueClient interface {
	CreateIssue(ctx context.Context, req jira.CreateIssueRequest) (jira.CreatedIssue, error)
	GetIssue(ctx context.Context, key string) (jira.Issue, error)
}

// JiraClientFactory builds a client for one connected account.
type JiraClientFactory func(account db.JiraAccount) (JiraIssueClient, error)

type createJiraIssueArgs struct {
	AccountID   int64    `json:"account_id,omitempty" jsonschema:"connected Jira account id; required only when more than one site is connected (see list_jira_projects)"`
	ProjectKey  string   `json:"project_key" jsonschema:"project key, e.g. ABC — must be a synced project (list_jira_projects)"`
	IssueType   string   `json:"issue_type" jsonschema:"issue type name, e.g. Task, Bug, Story"`
	Summary     string   `json:"summary" jsonschema:"issue title, at most 255 characters"`
	Description string   `json:"description,omitempty" jsonschema:"plain-text body; blank lines separate paragraphs"`
	Labels      []string `json:"labels,omitempty"`
	Priority    string   `json:"priority,omitempty" jsonschema:"Jira priority name, e.g. High"`
	Reason      string   `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
}

// ResolveJiraAccount mirrors cmd/jira.go's resolveJiraAccount: an explicit id
// must exist and not be removed; 0 means "the single enabled account".
func ResolveJiraAccount(d *db.DB, id int64) (db.JiraAccount, error) {
	if id > 0 {
		a, err := d.GetJiraAccount(id)
		// Only a genuine miss is the model's mistake. A failed lookup told as
		// "no Jira account #N" sends the model (and the owner reading the
		// failed row) after a typo that is not there.
		if errors.Is(err, db.ErrJiraAccountNotFound) {
			return db.JiraAccount{}, &ValidationError{Msg: fmt.Sprintf("no Jira account #%d", id)}
		}
		if err != nil {
			return db.JiraAccount{}, fmt.Errorf("looking up Jira account #%d: %w", id, err)
		}
		if a.Status == "removed" || !a.Enabled {
			return db.JiraAccount{}, &ValidationError{Msg: fmt.Sprintf("Jira account #%d is not enabled", id)}
		}
		return a, nil
	}
	accounts, err := d.ListEnabledJiraAccounts()
	if err != nil {
		return db.JiraAccount{}, err
	}
	switch len(accounts) {
	case 0:
		return db.JiraAccount{}, &ValidationError{Msg: "no Jira site is connected; the owner must run 'watchtower jira add' first"}
	case 1:
		return accounts[0], nil
	default:
		return db.JiraAccount{}, &ValidationError{Msg: "several Jira sites are connected — pass account_id (see list_jira_projects)"}
	}
}

func projectSynced(d *db.DB, accountID int64, projectKey string) (bool, error) {
	states, err := d.GetJiraSyncStates()
	if err != nil {
		return false, err
	}
	for _, s := range states {
		if s.AccountID == accountID && strings.EqualFold(s.ProjectKey, projectKey) {
			return true, nil
		}
	}
	return false, nil
}

// issueRow maps a fetched issue onto the synced-row shape without the
// syncer's user mapping; the next sync pass refreshes assignee/reporter and
// board fields.
func issueRow(accountID int64, issue jira.Issue) db.JiraIssue {
	f := issue.Fields
	now := time.Now().UTC().Format(time.RFC3339)
	projectKey := issue.Key
	if idx := strings.LastIndex(issue.Key, "-"); idx > 0 {
		projectKey = issue.Key[:idx]
	}
	labels, _ := json.Marshal(f.Labels)
	if f.Labels == nil {
		labels = []byte("[]")
	}
	priority := ""
	if f.Priority != nil {
		priority = f.Priority.Name
	}
	raw, _ := json.Marshal(issue)
	return db.JiraIssue{
		AccountID: accountID, Key: issue.Key, ID: issue.ID, ProjectKey: projectKey,
		Summary: f.Summary, DescriptionText: jira.DescriptionText(f.Description),
		IssueType: f.IssueType.Name, Status: f.Status.Name, StatusCategory: f.Status.StatusCategory.Key,
		Priority: priority, Labels: string(labels), Components: "[]", FixVersions: "[]",
		CreatedAt: f.Created, UpdatedAt: f.Updated, RawJSON: string(raw), SyncedAt: now,
	}
}

// mirrorCreatedIssue copies a freshly created issue into the local jira_issues
// mirror and returns the warning the result should carry, "" on success. The
// issue already exists in Jira by the time this runs, so nothing here may fail
// the action — but the owner still gets told the mirror is stale, and the next
// sync pass refreshes it either way.
func mirrorCreatedIssue(ctx context.Context, d *db.DB, client JiraIssueClient, accountID int64, key string) string {
	issue, err := client.GetIssue(ctx, key)
	if err != nil {
		return "created, but the local mirror was not updated: " + err.Error()
	}
	if err := d.UpsertJiraIssue(issueRow(accountID, issue)); err != nil {
		return "created, but the local mirror was not updated: " + err.Error()
	}
	return ""
}

// NewCreateJiraIssue builds the create_jira_issue write tool — the first
// action whose write leaves the machine, hence External (AGENT-03).
func NewCreateJiraIssue(factory JiraClientFactory) *Tool {
	schema, err := jsonschema.For[createJiraIssueArgs](nil)
	if err != nil {
		panic("create_jira_issue schema: " + err.Error())
	}
	return &Tool{
		Name: "create_jira_issue",
		Description: "Propose creating a Jira issue. The owner approves it in the chat before anything is sent to " +
			"Jira. Call list_jira_projects first to pick a synced project and a known issue type; when the " +
			"project or type is ambiguous, ask the owner instead of guessing.",
		InputSchema: schema,
		Access:      AccessWrite,
		External:    true,
		Surfaces:    []string{"main", "target"},
		Validate: func(_ context.Context, d *db.DB, raw json.RawMessage) error {
			var a createJiraIssueArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			switch {
			case strings.TrimSpace(a.ProjectKey) == "":
				return &ValidationError{Msg: "project_key is required"}
			case strings.TrimSpace(a.IssueType) == "":
				return &ValidationError{Msg: "issue_type is required"}
			case strings.TrimSpace(a.Summary) == "":
				return &ValidationError{Msg: "summary is required"}
			case len([]rune(a.Summary)) > 255:
				return &ValidationError{Msg: "summary must be at most 255 characters"}
			}
			account, err := ResolveJiraAccount(d, a.AccountID)
			if err != nil {
				return err
			}
			ok, err := projectSynced(d, account.ID, a.ProjectKey)
			if err != nil {
				return err
			}
			if !ok {
				return &ValidationError{Msg: fmt.Sprintf("project %s is not synced for this account; call list_jira_projects", a.ProjectKey)}
			}
			return nil
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a createJiraIssueArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding create_jira_issue args: %w", err)
			}
			account, err := ResolveJiraAccount(d, a.AccountID)
			if err != nil {
				return nil, err
			}
			client, err := factory(account)
			if err != nil {
				return nil, err
			}
			created, err := client.CreateIssue(ctx, jira.CreateIssueRequest{
				ProjectKey: strings.ToUpper(strings.TrimSpace(a.ProjectKey)), IssueType: strings.TrimSpace(a.IssueType),
				Summary: strings.TrimSpace(a.Summary), Description: a.Description, Labels: a.Labels, Priority: a.Priority,
			})
			if err != nil {
				// The package has no logger, so a failed side-write rides the
				// error it accompanies rather than vanishing (§9 swallowed
				// error): the owner must know the account was NOT marked.
				if errors.Is(err, jira.ErrAuthRevoked) {
					if dbErr := d.SetJiraAccountAuthState(account.ID, "revoked", err.Error()); dbErr != nil {
						return nil, fmt.Errorf("%w (and recording the revoked state failed: %v)", err, dbErr)
					}
				}
				return nil, err
			}
			url := strings.TrimRight(account.SiteURL, "/") + "/browse/" + created.Key
			result := map[string]any{"key": created.Key, "url": url}
			if warning := mirrorCreatedIssue(ctx, d, client, account.ID, created.Key); warning != "" {
				result["warning"] = warning
			}
			return result, nil
		},
	}
}

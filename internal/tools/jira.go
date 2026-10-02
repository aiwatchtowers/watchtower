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
	SearchIssues(ctx context.Context, jql string, maxResults int, nextPageToken string) (*jira.SearchResult, error)
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

// pinAccount resolves account_id right now and bakes the choice into the
// persisted args: an omitted id means "the single enabled account", and
// without the pin Execute would re-resolve it hours later — failing for good
// once a second site is connected, or writing to a different site than the
// owner approved (the pinSite rule for issue-key tools).
func pinAccount(d *db.DB, raw json.RawMessage, accountID int64) (json.RawMessage, error) {
	account, err := ResolveJiraAccount(d, accountID)
	if err != nil {
		return nil, err
	}
	return mergeJSON(raw, map[string]any{"account_id": account.ID})
}

// syncedProjectAccount resolves the account and checks projectKey is synced
// on it.
func syncedProjectAccount(d *db.DB, accountID int64, projectKey string) (db.JiraAccount, error) {
	account, err := ResolveJiraAccount(d, accountID)
	if err != nil {
		return db.JiraAccount{}, err
	}
	ok, err := projectSynced(d, account.ID, projectKey)
	if err != nil {
		return db.JiraAccount{}, err
	}
	if !ok {
		return db.JiraAccount{}, &ValidationError{Msg: fmt.Sprintf("project %s is not synced for this account; call list_jira_projects", projectKey)}
	}
	return account, nil
}

// projectSynced reports whether list_jira_projects lists projectKey for the
// account, so a listed project is always one create_jira_issue accepts.
func projectSynced(d *db.DB, accountID int64, projectKey string) (bool, error) {
	keys, err := syncedJiraProjects(d)
	if err != nil {
		return false, err
	}
	for k := range keys {
		if k.accountID == accountID && strings.EqualFold(k.projectKey, projectKey) {
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
	resolvedAt := ""
	if f.Resolved != nil {
		resolvedAt, _ = jira.NormalizeTimestamp(*f.Resolved)
	}
	statusCategoryChangedAt := ""
	if f.StatusCategoryChanged != nil {
		statusCategoryChangedAt, _ = jira.NormalizeTimestamp(*f.StatusCategoryChanged)
	}
	// The same UTC form the syncer stores, so the mirrored row
	// compares and sorts with the synced ones.
	createdAt, _ := jira.NormalizeTimestamp(f.Created)
	updatedAt, _ := jira.NormalizeTimestamp(f.Updated)
	raw, _ := json.Marshal(issue)
	return db.JiraIssue{
		AccountID: accountID, Key: issue.Key, ID: issue.ID, ProjectKey: projectKey,
		Summary: f.Summary, DescriptionText: jira.DescriptionText(f.Description),
		// StatusCategory uses the same normalizer the syncer writes
		// (jira.NormalizeStatusCategory: "todo"/"in_progress"/"done"), not the raw
		// Jira key — every reader that filters on status_category (briefing,
		// dashboards, memory) compares against the normalized form.
		IssueType: f.IssueType.Name, Status: f.Status.Name, StatusCategory: jira.NormalizeStatusCategory(f.Status.StatusCategory.Key),
		StatusCategoryChangedAt: statusCategoryChangedAt, Priority: priority,
		Labels: string(labels), Components: "[]", FixVersions: "[]",
		CreatedAt: createdAt, UpdatedAt: updatedAt, ResolvedAt: resolvedAt, RawJSON: string(raw), SyncedAt: now,
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

// landedIssueSearchLimit bounds the retry lookup: the owner's issues in one
// project since the proposal was recorded, newest first.
const landedIssueSearchLimit = 100

// findLandedIssue returns the key of an issue an earlier, failed attempt of
// action actionID created after all, "" when there is none: an issue the
// owner reported in req's project since the proposal was recorded, with the
// same summary and issue type. A failed lookup is an error — the caller must
// not re-send the request when it cannot tell whether the first one landed.
func findLandedIssue(ctx context.Context, d *db.DB, client JiraIssueClient, actionID int64, req jira.CreateIssueRequest) (string, error) {
	row, err := d.GetAgentAction(actionID)
	if err != nil {
		return "", err
	}
	if row == nil {
		return "", fmt.Errorf("action #%d not found", actionID)
	}
	proposed, err := time.Parse(time.RFC3339, row.CreatedAt)
	if err != nil {
		return "", fmt.Errorf("action #%d: parsing created_at %q: %w", actionID, row.CreatedAt, err)
	}
	// A relative window ("-90m") is free of the Jira profile's time zone,
	// which an absolute JQL date would be read in; the two extra minutes
	// cover the truncation and clock skew.
	minutes := int(time.Since(proposed).Minutes()) + 2
	jql := fmt.Sprintf(`project = "%s" AND reporter = currentUser() AND created >= -%dm ORDER BY created DESC`, req.ProjectKey, minutes)
	res, err := client.SearchIssues(ctx, jql, landedIssueSearchLimit, "")
	if err != nil {
		return "", fmt.Errorf("checking whether the failed attempt created the issue: %w", err)
	}
	for _, issue := range res.Issues {
		if issue.Fields.Summary == req.Summary && strings.EqualFold(issue.Fields.IssueType.Name, req.IssueType) {
			return issue.Key, nil
		}
	}
	if len(res.Issues) >= landedIssueSearchLimit || (!res.IsLast && res.NextPageToken != "") {
		// The window holds more than one page: no match on this one does not
		// prove the first attempt did not land.
		return "", fmt.Errorf("cannot tell whether the failed attempt created the issue: %s has more issues since the proposal than one search page", req.ProjectKey)
	}
	return "", nil
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
			_, err := syncedProjectAccount(d, a.AccountID, a.ProjectKey)
			return err
		},
		Normalize: func(_ context.Context, d *db.DB, raw json.RawMessage) (json.RawMessage, error) {
			var a createJiraIssueArgs
			if err := decodeStrict(raw, &a); err != nil {
				return nil, err
			}
			return pinAccount(d, raw, a.AccountID)
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a createJiraIssueArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding create_jira_issue args: %w", err)
			}
			// The account was pinned at propose time; the project is checked
			// again because it may have stopped syncing since.
			account, err := syncedProjectAccount(d, a.AccountID, a.ProjectKey)
			if err != nil {
				return nil, err
			}
			client, err := factory(account)
			if err != nil {
				return nil, err
			}
			req := jira.CreateIssueRequest{
				ProjectKey: strings.ToUpper(strings.TrimSpace(a.ProjectKey)), IssueType: strings.TrimSpace(a.IssueType),
				Summary: strings.TrimSpace(a.Summary), Description: a.Description, Labels: a.Labels, Priority: a.Priority,
			}
			key, reused := "", false
			if call.Retry {
				// The failed attempt may have created the issue anyway (a
				// timeout or a broken response after Jira stored it): look
				// for it before sending the request a second time.
				if key, err = findLandedIssue(ctx, d, client, call.ActionID, req); err != nil {
					return nil, jiraWriteFailed(d, account.ID, err)
				}
				reused = key != ""
			}
			if key == "" {
				created, err := client.CreateIssue(ctx, req)
				if err != nil {
					// The package has no logger, so a failed side-write rides
					// the error it accompanies rather than vanishing (§9
					// swallowed error): the owner must know the account was
					// NOT marked.
					return nil, jiraWriteFailed(d, account.ID, err)
				}
				key = created.Key
			}
			result := map[string]any{"key": key, "url": browseURL(account, key)}
			if reused {
				// Say which path ran: the issue is the earlier attempt's.
				result["reused"] = true
			}
			if warning := mirrorCreatedIssue(ctx, d, client, account.ID, key); warning != "" {
				result["warning"] = warning
			}
			return result, nil
		},
	}
}

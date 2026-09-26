package tools

import (
	"context"
	"encoding/json"
	"fmt"

	"watchtower/internal/db"
)

type listJiraIssuesArgs struct {
	Project  string `json:"project,omitempty" jsonschema:"Jira project key, e.g. ABC"`
	Status   string `json:"status,omitempty" jsonschema:"exact status name, e.g. 'In Progress'"`
	Assignee string `json:"assignee,omitempty" jsonschema:"assignee Jira account id"`
	Limit    int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

type getJiraIssueArgs struct {
	Key string `json:"key" jsonschema:"Jira issue key, e.g. ABC-123"`
}

// NewListJiraIssues lists synced Jira issues, optionally filtered by project,
// status, or assignee account id.
func NewListJiraIssues() *Tool {
	return &Tool{
		Name:        "list_jira_issues",
		Description: "List synced Jira issues, optionally filtered by project, status, or assignee account id.",
		InputSchema: mustSchema[listJiraIssuesArgs]("list_jira_issues"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a listJiraIssuesArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			issues, err := d.GetJiraIssues(db.JiraIssueFilter{
				ProjectKey: a.Project, Status: a.Status, AssigneeAccountID: a.Assignee, Limit: listLimit(a.Limit),
			})
			if err != nil {
				return nil, fmt.Errorf("listing jira issues: %w", err)
			}
			if issues == nil {
				issues = []db.JiraIssue{}
			}
			return issues, nil
		},
	}
}

type listJiraProjectsArgs struct{}

type jiraProjectsView struct {
	AccountID int64             `json:"account_id"`
	Label     string            `json:"label,omitempty"`
	SiteName  string            `json:"site_name,omitempty"`
	SiteURL   string            `json:"site_url,omitempty"`
	Projects  []jiraProjectView `json:"projects"`
}

type jiraProjectView struct {
	ProjectKey string   `json:"project_key"`
	IssueTypes []string `json:"issue_types"`
	IssueCount int      `json:"issue_count"`
}

type projectKeyID struct {
	accountID  int64
	projectKey string
}

type projectTypes struct {
	types []string
	count int
}

// jiraIssueTypesByProject aggregates the distinct issue types (and the issue
// count) per (account, project) from the synced issues.
func jiraIssueTypesByProject(d *db.DB) (map[projectKeyID]projectTypes, error) {
	rows, err := d.Query(`SELECT account_id, project_key, issue_type, COUNT(*)
		FROM jira_issues WHERE is_deleted = 0
		GROUP BY account_id, project_key, issue_type ORDER BY account_id, project_key, issue_type`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[projectKeyID]projectTypes{}
	for rows.Next() {
		var id projectKeyID
		var issueType string
		var n int
		if err := rows.Scan(&id.accountID, &id.projectKey, &issueType, &n); err != nil {
			return nil, err
		}
		pt := out[id]
		if issueType != "" {
			pt.types = append(pt.types, issueType)
		}
		pt.count += n
		out[id] = pt
	}
	return out, rows.Err()
}

// NewListJiraProjects lists the connected Jira accounts and their synced
// projects with the issue types seen in each — what create_jira_issue accepts
// for account_id, project_key and issue_type.
func NewListJiraProjects() *Tool {
	return &Tool{
		Name: "list_jira_projects",
		Description: "List the connected Jira accounts and their synced projects, with the issue types seen in " +
			"each project — what create_jira_issue accepts for account_id, project_key and issue_type.",
		InputSchema: mustSchema[listJiraProjectsArgs]("list_jira_projects"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, _ Call) (any, error) {
			accounts, err := d.ListEnabledJiraAccounts()
			if err != nil {
				return nil, fmt.Errorf("listing jira accounts: %w", err)
			}
			states, err := d.GetJiraSyncStates()
			if err != nil {
				return nil, fmt.Errorf("listing jira projects: %w", err)
			}
			typesByProject, err := jiraIssueTypesByProject(d)
			if err != nil {
				return nil, fmt.Errorf("listing issue types: %w", err)
			}
			out := make([]jiraProjectsView, 0, len(accounts))
			for _, a := range accounts {
				view := jiraProjectsView{AccountID: a.ID, Label: a.Label, SiteName: a.SiteName, SiteURL: a.SiteURL}
				for _, s := range states {
					if s.AccountID != a.ID {
						continue
					}
					pt := typesByProject[projectKeyID{a.ID, s.ProjectKey}]
					view.Projects = append(view.Projects, jiraProjectView{
						ProjectKey: s.ProjectKey, IssueTypes: pt.types, IssueCount: pt.count,
					})
				}
				out = append(out, view)
			}
			return out, nil
		},
	}
}

// NewGetJiraIssue fetches one Jira issue by key, with full fields.
func NewGetJiraIssue() *Tool {
	return &Tool{
		Name:        "get_jira_issue",
		Description: "Get a single Jira issue by key, including full fields.",
		InputSchema: mustSchema[getJiraIssueArgs]("get_jira_issue"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, call Call) (any, error) {
			var a getJiraIssueArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, &ValidationError{Msg: "invalid arguments"}
			}
			issue, err := d.GetJiraIssueByKey(a.Key)
			if err != nil {
				return nil, fmt.Errorf("getting jira issue: %w", err)
			}
			// GetJiraIssueByKey does not filter soft-deleted rows (unlike
			// GetJiraIssues); treat a tombstoned issue as not-found so the read
			// model stays consistent across the two tools.
			if issue == nil || issue.IsDeleted {
				return nil, fmt.Errorf("no jira issue with key %s", a.Key)
			}
			return issue, nil
		},
	}
}

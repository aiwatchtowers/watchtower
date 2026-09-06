package mcp

import (
	"context"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

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

func registerJira(s *mcpsdk.Server, database *db.DB) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "list_jira_issues",
		Description: "List synced Jira issues, optionally filtered by project, status, or assignee account id.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args listJiraIssuesArgs) (*mcpsdk.CallToolResult, any, error) {
		issues, err := database.GetJiraIssues(db.JiraIssueFilter{
			ProjectKey:        args.Project,
			Status:            args.Status,
			AssigneeAccountID: args.Assignee,
			Limit:             listLimit(args.Limit),
		})
		if err != nil {
			return errResult("listing jira issues: " + err.Error()), nil, nil
		}
		return jsonListResult(issues)
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "get_jira_issue",
		Description: "Get a single Jira issue by key, including full fields.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args getJiraIssueArgs) (*mcpsdk.CallToolResult, any, error) {
		issue, err := database.GetJiraIssueByKey(args.Key)
		if err != nil {
			return errResult("getting jira issue: " + err.Error()), nil, nil
		}
		// GetJiraIssueByKey does not filter soft-deleted rows (unlike
		// GetJiraIssues); treat a tombstoned issue as not-found so the read
		// model stays consistent across the two tools.
		if issue == nil || issue.IsDeleted {
			return errResult("no jira issue with key " + args.Key), nil, nil
		}
		return jsonResult(issue)
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name: "list_jira_projects",
		Description: "List the connected Jira accounts and their synced projects, with the issue types seen in " +
			"each project — what create_jira_issue accepts for account_id, project_key and issue_type.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args struct{}) (*mcpsdk.CallToolResult, any, error) {
		accounts, err := database.ListEnabledJiraAccounts()
		if err != nil {
			return errResult("listing jira accounts: " + err.Error()), nil, nil
		}
		states, err := database.GetJiraSyncStates()
		if err != nil {
			return errResult("listing jira projects: " + err.Error()), nil, nil
		}
		typesByProject, err := jiraIssueTypesByProject(database)
		if err != nil {
			return errResult("listing issue types: " + err.Error()), nil, nil
		}
		var out []jiraProjectsView
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
		return jsonListResult(out)
	})
}

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
func jiraIssueTypesByProject(database *db.DB) (map[projectKeyID]projectTypes, error) {
	rows, err := database.Query(`SELECT account_id, project_key, issue_type, COUNT(*)
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

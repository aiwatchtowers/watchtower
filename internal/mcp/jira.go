package mcp

import (
	"context"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

// registerJira mounts list_jira_projects — the last Jira read still living in
// internal/mcp. list_jira_issues/get_jira_issue moved into the registry
// (internal/tools/jira_read.go); this one is HEAVY (raw aggregation SQL + the
// jiraProjectsView assembly below) and migrates in the heavy phase.
func registerJira(s *mcpsdk.Server, database *db.DB) {
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

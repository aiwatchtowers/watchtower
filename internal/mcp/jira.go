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
	Limit    int    `json:"limit,omitempty" jsonschema:"max results, 0 = no limit"`
}

type getJiraIssueArgs struct {
	Key string `json:"key" jsonschema:"Jira issue key, e.g. ABC-123"`
}

func registerJira(s *mcpsdk.Server, database *db.DB) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "list_jira_issues",
		Description: "List synced Jira issues, optionally filtered by project, status, or assignee account id.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args listJiraIssuesArgs) (*mcpsdk.CallToolResult, any, error) {
		limit := args.Limit
		if limit == 0 {
			limit = 50
		}
		issues, err := database.GetJiraIssues(db.JiraIssueFilter{
			ProjectKey:        args.Project,
			Status:            args.Status,
			AssigneeAccountID: args.Assignee,
			Limit:             limit,
		})
		if err != nil {
			return errResult("listing jira issues: " + err.Error()), nil, nil
		}
		return jsonResult(issues)
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "get_jira_issue",
		Description: "Get a single Jira issue by key, including full fields.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args getJiraIssueArgs) (*mcpsdk.CallToolResult, any, error) {
		issue, err := database.GetJiraIssueByKey(args.Key)
		if err != nil {
			return errResult("getting jira issue: " + err.Error()), nil, nil
		}
		if issue == nil {
			return errResult("no jira issue with key " + args.Key), nil, nil
		}
		return jsonResult(issue)
	})
}

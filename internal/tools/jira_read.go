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

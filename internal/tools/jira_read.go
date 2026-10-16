package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"

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

// maxListedDescriptionBytes clips each description in list_jira_issues;
// get_jira_issue returns the whole issue.
const maxListedDescriptionBytes = 512

// jiraIssueListItem is one list_jira_issues row: the synced issue without
// RawJSON and CustomFieldsJSON (and IsDeleted, always false here) (the full API payload and the custom field
// values, often tens of KiB each — a page of them would pass the automation
// SDK's 256 KiB result cap) and with the description clipped. The keys keep
// db.JiraIssue's field names, which the chat's source chips decode.
type jiraIssueListItem struct {
	AccountID               int64    `json:"AccountID"`
	Key                     string   `json:"Key"`
	ID                      string   `json:"ID"`
	ProjectKey              string   `json:"ProjectKey"`
	BoardID                 int      `json:"BoardID,omitempty"`
	Summary                 string   `json:"Summary"`
	DescriptionText         string   `json:"DescriptionText,omitempty"`
	DescriptionTruncated    bool     `json:"DescriptionTruncated,omitempty"`
	IssueType               string   `json:"IssueType"`
	IsBug                   bool     `json:"IsBug,omitempty"`
	Status                  string   `json:"Status"`
	StatusCategory          string   `json:"StatusCategory"`
	StatusCategoryChangedAt string   `json:"StatusCategoryChangedAt,omitempty"`
	AssigneeAccountID       string   `json:"AssigneeAccountID,omitempty"`
	AssigneeEmail           string   `json:"AssigneeEmail,omitempty"`
	AssigneeDisplayName     string   `json:"AssigneeDisplayName,omitempty"`
	AssigneeSlackID         string   `json:"AssigneeSlackID,omitempty"`
	ReporterAccountID       string   `json:"ReporterAccountID,omitempty"`
	ReporterEmail           string   `json:"ReporterEmail,omitempty"`
	ReporterDisplayName     string   `json:"ReporterDisplayName,omitempty"`
	ReporterSlackID         string   `json:"ReporterSlackID,omitempty"`
	Priority                string   `json:"Priority,omitempty"`
	StoryPoints             *float64 `json:"StoryPoints,omitempty"`
	DueDate                 string   `json:"DueDate,omitempty"`
	SprintID                int      `json:"SprintID,omitempty"`
	SprintName              string   `json:"SprintName,omitempty"`
	EpicKey                 string   `json:"EpicKey,omitempty"`
	Labels                  string   `json:"Labels,omitempty"`
	Components              string   `json:"Components,omitempty"`
	FixVersions             string   `json:"FixVersions,omitempty"`
	CreatedAt               string   `json:"CreatedAt"`
	UpdatedAt               string   `json:"UpdatedAt"`
	ResolvedAt              string   `json:"ResolvedAt,omitempty"`
	SyncedAt                string   `json:"SyncedAt"`
}

func listedJiraIssue(j db.JiraIssue) jiraIssueListItem {
	desc, truncated := ClipUTF8Bytes(j.DescriptionText, maxListedDescriptionBytes)
	return jiraIssueListItem{
		AccountID: j.AccountID, Key: j.Key, ID: j.ID, ProjectKey: j.ProjectKey, BoardID: j.BoardID, Summary: j.Summary,
		DescriptionText: desc, DescriptionTruncated: truncated, IssueType: j.IssueType, IsBug: j.IsBug,
		Status: j.Status, StatusCategory: j.StatusCategory, StatusCategoryChangedAt: j.StatusCategoryChangedAt,
		AssigneeAccountID: j.AssigneeAccountID, AssigneeEmail: j.AssigneeEmail, AssigneeDisplayName: j.AssigneeDisplayName, AssigneeSlackID: j.AssigneeSlackID,
		ReporterAccountID: j.ReporterAccountID, ReporterEmail: j.ReporterEmail, ReporterDisplayName: j.ReporterDisplayName,
		ReporterSlackID: j.ReporterSlackID, Priority: j.Priority,
		StoryPoints: j.StoryPoints, DueDate: j.DueDate, SprintID: j.SprintID, SprintName: j.SprintName, EpicKey: j.EpicKey,
		Labels: j.Labels, Components: j.Components, FixVersions: j.FixVersions,
		CreatedAt: j.CreatedAt, UpdatedAt: j.UpdatedAt, ResolvedAt: j.ResolvedAt, SyncedAt: j.SyncedAt,
	}
}

// NewListJiraIssues lists synced Jira issues, optionally filtered by project,
// status, or assignee account id, as lean rows (jiraIssueListItem).
func NewListJiraIssues() *Tool {
	return &Tool{
		Name: "list_jira_issues",
		Description: "List synced Jira issues, optionally filtered by project, status, or assignee account id. " +
			"Each row has the issue's main fields, without custom fields, and its description clipped at 512 bytes; " +
			"get_jira_issue returns one issue in full.",
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
			out := make([]jiraIssueListItem, 0, len(issues))
			for _, j := range issues {
				out = append(out, listedJiraIssue(j))
			}
			return out, nil
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

// syncedJiraProjects returns every (account, project) Watchtower syncs: one
// with a full-sync watermark or one of a selected board. SyncBoard pulls a
// just-selected board's active issues at once but deliberately writes no
// watermark, so watermarks alone hide its project until the next daemon Jira
// phase. Synced issues alone do not count: an issue-key write mirrors a row
// for any project it touches, watched or not.
func syncedJiraProjects(d *db.DB) (map[projectKeyID]bool, error) {
	states, err := d.GetJiraSyncStates()
	if err != nil {
		return nil, err
	}
	boards, err := d.ListSelectedJiraBoards()
	if err != nil {
		return nil, err
	}
	keys := map[projectKeyID]bool{}
	for _, s := range states {
		keys[projectKeyID{s.AccountID, s.ProjectKey}] = true
	}
	for _, b := range boards {
		if b.ProjectKey != "" {
			keys[projectKeyID{b.AccountID, b.ProjectKey}] = true
		}
	}
	return keys, nil
}

// NewListJiraProjects lists the connected Jira accounts and their synced
// projects (a full-sync watermark or a selected board) with
// the issue types seen in each — the account_id, project_key and issue_type
// values create_jira_issue takes.
func NewListJiraProjects() *Tool {
	return &Tool{
		Name: "list_jira_projects",
		Description: "List the connected Jira accounts and their synced projects (including projects of boards " +
			"selected in the app), with the issue types seen in each project — the account_id, project_key and " +
			"issue_type values create_jira_issue takes.",
		InputSchema: mustSchema[listJiraProjectsArgs]("list_jira_projects"),
		Access:      AccessRead,
		Execute: func(_ context.Context, d *db.DB, _ Call) (any, error) {
			accounts, err := d.ListEnabledJiraAccounts()
			if err != nil {
				return nil, fmt.Errorf("listing jira accounts: %w", err)
			}
			keys, err := syncedJiraProjects(d)
			if err != nil {
				return nil, fmt.Errorf("listing jira projects: %w", err)
			}
			typesByProject, err := jiraIssueTypesByProject(d)
			if err != nil {
				return nil, fmt.Errorf("listing issue types: %w", err)
			}
			byAccount := map[int64][]string{}
			for k := range keys {
				byAccount[k.accountID] = append(byAccount[k.accountID], k.projectKey)
			}
			out := make([]jiraProjectsView, 0, len(accounts))
			for _, a := range accounts {
				view := jiraProjectsView{AccountID: a.ID, Label: a.Label, SiteName: a.SiteName, SiteURL: a.SiteURL}
				projectKeys := byAccount[a.ID]
				sort.Strings(projectKeys)
				for _, key := range projectKeys {
					pt := typesByProject[projectKeyID{a.ID, key}]
					if pt.types == nil {
						pt.types = []string{} // a board whose issues have not landed yet
					}
					view.Projects = append(view.Projects, jiraProjectView{
						ProjectKey: key, IssueTypes: pt.types, IssueCount: pt.count,
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

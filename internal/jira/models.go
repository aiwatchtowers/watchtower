// Package jira provides Jira Cloud integration for Watchtower.
package jira

import (
	"encoding/json"
	"strings"
)

// Board represents a Jira agile board.
type Board struct {
	ID       int    `json:"id"`
	Name     string `json:"name"`
	Type     string `json:"type"`
	Location struct {
		ProjectKey  string `json:"projectKey"`
		ProjectName string `json:"projectName"`
	} `json:"location"`
}

// BoardList is a paginated response from the Jira agile boards API.
type BoardList struct {
	MaxResults int     `json:"maxResults"`
	StartAt    int     `json:"startAt"`
	Total      int     `json:"total"`
	IsLast     bool    `json:"isLast"`
	Values     []Board `json:"values"`
}

// Issue represents a Jira issue.
type Issue struct {
	ID     string      `json:"id"`
	Key    string      `json:"key"`
	Fields IssueFields `json:"fields"`

	// CustomFields holds the issue's customfield_* values as the API returned
	// them (IssueFields decodes only the standard fields). Filled by
	// UnmarshalJSON; never re-encoded.
	CustomFields map[string]json.RawMessage `json:"-"`
}

// UnmarshalJSON decodes the standard fields and keeps every customfield_*
// value in CustomFields, so the sync can read a board's mapped custom fields.
func (i *Issue) UnmarshalJSON(data []byte) error {
	type plain Issue
	var p plain
	if err := json.Unmarshal(data, &p); err != nil {
		return err
	}
	var raw struct {
		Fields map[string]json.RawMessage `json:"fields"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	for k, v := range raw.Fields {
		if !strings.HasPrefix(k, "customfield_") {
			continue
		}
		if p.CustomFields == nil {
			p.CustomFields = make(map[string]json.RawMessage)
		}
		p.CustomFields[k] = v
	}
	*i = Issue(p)
	return nil
}

// IssueFields holds the fields of a Jira issue.
type IssueFields struct {
	Summary     string       `json:"summary"`
	Description interface{}  `json:"description"`
	IssueType   IssueType    `json:"issuetype"`
	Status      Status       `json:"status"`
	Assignee    *User        `json:"assignee"`
	Reporter    *User        `json:"reporter"`
	Priority    *Priority    `json:"priority"`
	Created     string       `json:"created"`
	Updated     string       `json:"updated"`
	DueDate     *string      `json:"duedate"`
	Labels      []string     `json:"labels"`
	Components  []Component  `json:"components"`
	IssueLinks  []IssueLink  `json:"issuelinks"`
	Sprint      *Sprint      `json:"sprint"`
	Epic        *EpicRef     `json:"epic"`
	Parent      *ParentRef   `json:"parent"`
	Resolved    *string      `json:"resolutiondate"`
	FixVersions []FixVersion `json:"fixVersions"`
	// StatusCategoryChanged is when the issue last moved between status
	// categories (To Do / In Progress / Done), not between statuses.
	StatusCategoryChanged *string `json:"statuscategorychangedate"`
}

// IssueType represents the type of a Jira issue.
type IssueType struct {
	Name           string `json:"name"`
	Subtask        bool   `json:"subtask"`
	HierarchyLevel int    `json:"hierarchyLevel"`
}

// Status represents a Jira issue status.
type Status struct {
	Name           string         `json:"name"`
	StatusCategory StatusCategory `json:"statusCategory"`
}

// StatusCategory represents a Jira status category.
type StatusCategory struct {
	Key  string `json:"key"`
	Name string `json:"name"`
}

// User represents a Jira user.
type User struct {
	AccountID    string `json:"accountId"`
	EmailAddress string `json:"emailAddress"`
	DisplayName  string `json:"displayName"`
	Active       bool   `json:"active"`
	// AccountType is "atlassian" for a person, "app"/"customer" otherwise;
	// only user search reads it (an issue's assignee is always a person).
	AccountType string `json:"accountType"`
}

// Priority represents a Jira issue priority.
type Priority struct {
	Name string `json:"name"`
}

// Component represents a Jira project component.
type Component struct {
	Name string `json:"name"`
}

// IssueLink represents a link between two Jira issues.
type IssueLink struct {
	ID           string        `json:"id"`
	Type         IssueLinkType `json:"type"`
	InwardIssue  *IssueRef     `json:"inwardIssue"`
	OutwardIssue *IssueRef     `json:"outwardIssue"`
}

// IssueLinkType describes the type of relationship between linked issues.
type IssueLinkType struct {
	Name    string `json:"name"`
	Inward  string `json:"inward"`
	Outward string `json:"outward"`
}

// IssueRef is a lightweight reference to a Jira issue (key only).
type IssueRef struct {
	Key string `json:"key"`
}

// Myself is the connecting person's own Atlassian identity, as returned by
// GET /rest/api/3/myself.
type Myself struct {
	AccountID    string `json:"accountId"`
	EmailAddress string `json:"emailAddress"`
	DisplayName  string `json:"displayName"`
}

// FixVersion represents a Jira fix version (release).
type FixVersion struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
	ReleaseDate string `json:"releaseDate"`
	Released    bool   `json:"released"`
	Archived    bool   `json:"archived"`
}

// Sprint represents a Jira sprint.
type Sprint struct {
	ID           int    `json:"id"`
	Name         string `json:"name"`
	State        string `json:"state"`
	Goal         string `json:"goal"`
	StartDate    string `json:"startDate"`
	EndDate      string `json:"endDate"`
	CompleteDate string `json:"completeDate"`
}

// EpicRef is a lightweight reference to a Jira epic.
type EpicRef struct {
	Key  string `json:"key"`
	Name string `json:"name"`
}

// ParentRef is a lightweight reference to a parent issue.
type ParentRef struct {
	Key string `json:"key"`
}

// SearchResult is a paginated response from the Jira search API.
// The new /rest/api/3/search/jql endpoint returns `isLast` and `nextPageToken` instead of `total`.
type SearchResult struct {
	StartAt       int     `json:"startAt"`
	MaxResults    int     `json:"maxResults"`
	Total         int     `json:"total"`
	IsLast        bool    `json:"isLast"`
	NextPageToken string  `json:"nextPageToken"`
	Issues        []Issue `json:"issues"`
}

// SprintList is a paginated response from the Jira sprints API.
type SprintList struct {
	MaxResults int      `json:"maxResults"`
	StartAt    int      `json:"startAt"`
	IsLast     bool     `json:"isLast"`
	Values     []Sprint `json:"values"`
}

// IssueComment is a single comment on a Jira issue. Body is left as
// interface{} (string or ADF, same shape as IssueFields.Description) —
// callers flatten it with extractDescriptionText.
type IssueComment struct {
	ID     string `json:"id"`
	Author struct {
		DisplayName string `json:"displayName"`
		AccountID   string `json:"accountId"`
	} `json:"author"`
	Body    interface{} `json:"body"`
	Created string      `json:"created"`
	Updated string      `json:"updated"`
}

// CommentList is a paginated response from the Jira issue comments API.
type CommentList struct {
	StartAt    int            `json:"startAt"`
	MaxResults int            `json:"maxResults"`
	Total      int            `json:"total"`
	Comments   []IssueComment `json:"comments"`
}

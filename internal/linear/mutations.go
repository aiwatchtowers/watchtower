package linear

import (
	"context"
	"errors"
	"fmt"
)

// Live fetches (names to ids for the write tools) and GraphQL mutations on
// Client. Nothing here touches the local mirror.

// WorkflowState is one state of a team's workflow.
type WorkflowState struct {
	ID       string
	Name     string
	Type     string
	Position float64
}

// Label is an issue label; TeamID is empty for a workspace label.
type Label struct {
	ID     string
	Name   string
	TeamID string
}

// User is a workspace member.
type User struct {
	ID          string
	Name        string
	DisplayName string
	Email       string
}

// IssueRef points at a created issue.
type IssueRef struct {
	ID         string
	Identifier string
	URL        string
}

// IssueCreateInput is what issueCreate takes; empty strings and nil pointers
// are not sent. ID is a client-chosen UUID: Linear creates the issue under it,
// so a retry can look the issue up instead of creating it twice.
type IssueCreateInput struct {
	ID          string
	TeamID      string
	Title       string
	Description string
	StateID     string
	AssigneeID  string
	Priority    *int
	LabelIDs    []string
}

// IssueUpdateInput carries only the fields to change (nil = leave alone).
// AssigneeID pointing at "" unassigns the issue.
type IssueUpdateInput struct {
	Title           *string
	StateID         *string
	DueDate         *string
	AssigneeID      *string
	Priority        *int
	Estimate        *float64
	AddedLabelIDs   []string
	RemovedLabelIDs []string
}

const queryTeamStates = `query LinearTeamStates($team: String!) { team(id: $team) {
  states(first: 100) { nodes { id name type position } } } }`

type teamStatesData struct {
	Team struct {
		States struct {
			Nodes []struct {
				ID       string  `json:"id"`
				Name     string  `json:"name"`
				Type     string  `json:"type"`
				Position float64 `json:"position"`
			} `json:"nodes"`
		} `json:"states"`
	} `json:"team"`
}

// FetchTeamStates lists the workflow states of one team.
func (c *Client) FetchTeamStates(ctx context.Context, teamID string) ([]WorkflowState, error) {
	var out teamStatesData
	if err := c.Do(ctx, queryTeamStates, map[string]any{"team": teamID}, &out); err != nil {
		return nil, fmt.Errorf("fetching linear states of team %s: %w", teamID, err)
	}
	states := make([]WorkflowState, 0, len(out.Team.States.Nodes))
	for _, n := range out.Team.States.Nodes {
		states = append(states, WorkflowState{ID: n.ID, Name: n.Name, Type: n.Type, Position: n.Position})
	}
	return states, nil
}

const queryLabels = `query LinearLabels($filter: IssueLabelFilter!, $after: String) {
  issueLabels(filter: $filter, first: 100, after: $after) {
    nodes { id name team { id } }
    pageInfo { hasNextPage endCursor } } }`

type labelsData struct {
	IssueLabels struct {
		Nodes []struct {
			ID   string  `json:"id"`
			Name string  `json:"name"`
			Team *idName `json:"team"`
		} `json:"nodes"`
		PageInfo pageInfo `json:"pageInfo"`
	} `json:"issueLabels"`
}

// FetchLabels lists the team's labels plus the workspace labels.
func (c *Client) FetchLabels(ctx context.Context, teamID string) ([]Label, error) {
	filter := map[string]any{"or": []any{
		map[string]any{"team": map[string]any{"id": map[string]any{"eq": teamID}}},
		map[string]any{"team": map[string]any{"null": true}},
	}}
	labels, err := c.fetchLabels(ctx, filter)
	if err != nil {
		return nil, fmt.Errorf("fetching linear labels of team %s: %w", teamID, err)
	}
	return labels, nil
}

// fetchTeamLabels lists the team's own labels, without the workspace ones.
func (c *Client) fetchTeamLabels(ctx context.Context, teamID string) ([]Label, error) {
	labels, err := c.fetchLabels(ctx, map[string]any{"team": map[string]any{"id": map[string]any{"eq": teamID}}})
	if err != nil {
		return nil, fmt.Errorf("fetching linear labels of team %s: %w", teamID, err)
	}
	return labels, nil
}

// fetchWorkspaceLabels lists the workspace labels (no team).
func (c *Client) fetchWorkspaceLabels(ctx context.Context) ([]Label, error) {
	labels, err := c.fetchLabels(ctx, map[string]any{"team": map[string]any{"null": true}})
	if err != nil {
		return nil, fmt.Errorf("fetching linear workspace labels: %w", err)
	}
	return labels, nil
}

func (c *Client) fetchLabels(ctx context.Context, filter map[string]any) ([]Label, error) {
	var labels []Label
	err := paginate(ctx, func(ctx context.Context, after *string) (pageInfo, error) {
		var out labelsData
		if err := c.Do(ctx, queryLabels, map[string]any{"filter": filter, "after": after}, &out); err != nil {
			return pageInfo{}, err
		}
		for _, n := range out.IssueLabels.Nodes {
			labels = append(labels, Label{ID: n.ID, Name: n.Name, TeamID: idOf(n.Team)})
		}
		return out.IssueLabels.PageInfo, nil
	})
	return labels, err
}

// FetchUsers lists the workspace members.
func (c *Client) FetchUsers(ctx context.Context) ([]User, error) {
	var users []User
	err := paginate(ctx, func(ctx context.Context, after *string) (pageInfo, error) {
		var out usersData
		if err := c.Do(ctx, queryUsers, map[string]any{"after": after}, &out); err != nil {
			return pageInfo{}, err
		}
		for _, n := range out.Users.Nodes {
			users = append(users, User(n))
		}
		return out.Users.PageInfo, nil
	})
	if err != nil {
		return nil, fmt.Errorf("fetching linear users: %w", err)
	}
	return users, nil
}

const (
	mutationIssueCreate = `mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier url } } }`
	mutationIssueUpdate = `mutation($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success } }`
	mutationCommentNew  = `mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success comment { id } } }`
)

// errMutationRejected is a payload with success: false.
var errMutationRejected = errors.New("linear rejected the mutation")

// CreateIssue creates an issue and returns its id, key and URL.
func (c *Client) CreateIssue(ctx context.Context, in IssueCreateInput) (IssueRef, error) {
	input := map[string]any{"teamId": in.TeamID, "title": in.Title}
	if in.ID != "" {
		input["id"] = in.ID
	}
	if in.Description != "" {
		input["description"] = in.Description
	}
	if in.StateID != "" {
		input["stateId"] = in.StateID
	}
	if in.AssigneeID != "" {
		input["assigneeId"] = in.AssigneeID
	}
	if in.Priority != nil {
		input["priority"] = *in.Priority
	}
	if len(in.LabelIDs) > 0 {
		input["labelIds"] = in.LabelIDs
	}
	var out struct {
		IssueCreate struct {
			Success bool `json:"success"`
			Issue   *struct {
				ID         string `json:"id"`
				Identifier string `json:"identifier"`
				URL        string `json:"url"`
			} `json:"issue"`
		} `json:"issueCreate"`
	}
	if err := c.Do(ctx, mutationIssueCreate, map[string]any{"input": input}, &out); err != nil {
		return IssueRef{}, fmt.Errorf("creating linear issue: %w", err)
	}
	if !out.IssueCreate.Success || out.IssueCreate.Issue == nil {
		return IssueRef{}, fmt.Errorf("creating linear issue: %w", errMutationRejected)
	}
	i := out.IssueCreate.Issue
	return IssueRef{ID: i.ID, Identifier: i.Identifier, URL: i.URL}, nil
}

const queryIssueRef = `query LinearIssueRef($id: String!) { issue(id: $id) { id identifier url } }`

// FetchIssueRef looks an issue up by id. found is false when Linear has no
// such issue (its "Entity not found" error or a null issue); any other
// failure is an error.
func (c *Client) FetchIssueRef(ctx context.Context, id string) (IssueRef, bool, error) {
	var out struct {
		Issue *struct {
			ID         string `json:"id"`
			Identifier string `json:"identifier"`
			URL        string `json:"url"`
		} `json:"issue"`
	}
	err := c.Do(ctx, queryIssueRef, map[string]any{"id": id}, &out)
	switch {
	case errors.Is(err, ErrNotFound):
		return IssueRef{}, false, nil
	case err != nil:
		return IssueRef{}, false, fmt.Errorf("looking up linear issue %s: %w", id, err)
	case out.Issue == nil:
		return IssueRef{}, false, nil
	}
	return IssueRef{ID: out.Issue.ID, Identifier: out.Issue.Identifier, URL: out.Issue.URL}, true, nil
}

// UpdateIssue changes the set fields of one issue.
func (c *Client) UpdateIssue(ctx context.Context, issueID string, in IssueUpdateInput) error {
	input := map[string]any{}
	if in.Title != nil {
		input["title"] = *in.Title
	}
	if in.StateID != nil {
		input["stateId"] = *in.StateID
	}
	if in.DueDate != nil {
		input["dueDate"] = *in.DueDate
	}
	if in.AssigneeID != nil {
		if *in.AssigneeID == "" {
			input["assigneeId"] = nil // unassign
		} else {
			input["assigneeId"] = *in.AssigneeID
		}
	}
	if in.Priority != nil {
		input["priority"] = *in.Priority
	}
	if in.Estimate != nil {
		input["estimate"] = *in.Estimate
	}
	if len(in.AddedLabelIDs) > 0 {
		input["addedLabelIds"] = in.AddedLabelIDs
	}
	if len(in.RemovedLabelIDs) > 0 {
		input["removedLabelIds"] = in.RemovedLabelIDs
	}
	var out struct {
		IssueUpdate struct {
			Success bool `json:"success"`
		} `json:"issueUpdate"`
	}
	if err := c.Do(ctx, mutationIssueUpdate, map[string]any{"id": issueID, "input": input}, &out); err != nil {
		return fmt.Errorf("updating linear issue %s: %w", issueID, err)
	}
	if !out.IssueUpdate.Success {
		return fmt.Errorf("updating linear issue %s: %w", issueID, errMutationRejected)
	}
	return nil
}

// CreateComment adds a comment to an issue and returns the comment id.
func (c *Client) CreateComment(ctx context.Context, issueID, body string) (string, error) {
	var out struct {
		CommentCreate struct {
			Success bool `json:"success"`
			Comment *struct {
				ID string `json:"id"`
			} `json:"comment"`
		} `json:"commentCreate"`
	}
	input := map[string]any{"issueId": issueID, "body": body}
	if err := c.Do(ctx, mutationCommentNew, map[string]any{"input": input}, &out); err != nil {
		return "", fmt.Errorf("commenting on linear issue %s: %w", issueID, err)
	}
	if !out.CommentCreate.Success || out.CommentCreate.Comment == nil {
		return "", fmt.Errorf("commenting on linear issue %s: %w", issueID, errMutationRejected)
	}
	return out.CommentCreate.Comment.ID, nil
}

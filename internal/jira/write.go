package jira

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strings"
)

// IssueUpdate is an edit of an existing issue. A nil pointer / empty slice
// leaves that field unchanged; labels are edited as add/remove operations so
// labels someone else added in the meantime survive.
type IssueUpdate struct {
	Summary      *string
	Priority     *string // priority NAME, e.g. "High"
	LabelsAdd    []string
	LabelsRemove []string
	DueDate      *string // YYYY-MM-DD
}

// Empty reports whether the update would change nothing.
func (u IssueUpdate) Empty() bool {
	return u.Summary == nil && u.Priority == nil && u.DueDate == nil &&
		len(u.LabelsAdd) == 0 && len(u.LabelsRemove) == 0
}

// Transition is one workflow move available on an issue right now.
type Transition struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	To   Status `json:"to"`
}

// send JSON-encodes payload (nil = no body), runs it through do, and maps any
// status outside want to an *APIError carrying Jira's own messages.
func (c *Client) send(ctx context.Context, method, path string, payload any, want ...int) ([]byte, error) {
	var body []byte
	if payload != nil {
		b, err := json.Marshal(payload)
		if err != nil {
			return nil, fmt.Errorf("encoding %s %s: %w", method, path, err)
		}
		body = b
	}
	resp, err := c.do(ctx, method, path, body)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if !slices.Contains(want, resp.StatusCode) {
		return nil, &APIError{Status: resp.StatusCode, Message: jiraErrorMessage(respBody)}
	}
	return respBody, nil
}

func issuePath(key string, suffix string) string {
	return "/rest/api/3/issue/" + url.PathEscape(key) + suffix
}

// AddComment posts a plain-text comment (converted to ADF paragraphs) and
// returns the new comment's id.
func (c *Client) AddComment(ctx context.Context, key, body string) (string, error) {
	if strings.TrimSpace(body) == "" {
		return "", errors.New("jira: comment body is empty")
	}
	resp, err := c.send(ctx, http.MethodPost, issuePath(key, "/comment"),
		map[string]any{"body": ADFDocument(body)}, http.StatusCreated, http.StatusOK)
	if err != nil {
		return "", err
	}
	var created struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(resp, &created); err != nil {
		return "", fmt.Errorf("decoding add comment response: %w", err)
	}
	return created.ID, nil
}

// GetTransitions lists the workflow moves available on the issue now.
func (c *Client) GetTransitions(ctx context.Context, key string) ([]Transition, error) {
	var out struct {
		Transitions []Transition `json:"transitions"`
	}
	if err := c.get(ctx, issuePath(key, "/transitions"), &out); err != nil {
		return nil, err
	}
	return out.Transitions, nil
}

// TransitionIssue performs one transition by id.
func (c *Client) TransitionIssue(ctx context.Context, key, transitionID string) error {
	_, err := c.send(ctx, http.MethodPost, issuePath(key, "/transitions"),
		map[string]any{"transition": map[string]any{"id": transitionID}}, http.StatusNoContent, http.StatusOK)
	return err
}

// AssignIssue sets the assignee by Atlassian account id.
func (c *Client) AssignIssue(ctx context.Context, key, accountID string) error {
	_, err := c.send(ctx, http.MethodPut, issuePath(key, "/assignee"),
		map[string]any{"accountId": accountID}, http.StatusNoContent, http.StatusOK)
	return err
}

// UpdateIssue edits summary/priority/due date (fields) and labels (update
// operations) in one PUT.
func (c *Client) UpdateIssue(ctx context.Context, key string, f IssueUpdate) error {
	if f.Empty() {
		return errors.New("jira: issue update changes nothing")
	}
	payload := map[string]any{}
	fields := map[string]any{}
	if f.Summary != nil {
		fields["summary"] = *f.Summary
	}
	if f.Priority != nil {
		fields["priority"] = map[string]any{"name": *f.Priority}
	}
	if f.DueDate != nil {
		fields["duedate"] = *f.DueDate
	}
	if len(fields) > 0 {
		payload["fields"] = fields
	}
	var ops []map[string]any
	for _, l := range f.LabelsAdd {
		ops = append(ops, map[string]any{"add": l})
	}
	for _, l := range f.LabelsRemove {
		ops = append(ops, map[string]any{"remove": l})
	}
	if len(ops) > 0 {
		payload["update"] = map[string]any{"labels": ops}
	}
	_, err := c.send(ctx, http.MethodPut, issuePath(key, ""), payload, http.StatusNoContent, http.StatusOK)
	return err
}

// SearchUsers runs Jira's user search (display name / email prefix match).
func (c *Client) SearchUsers(ctx context.Context, query string) ([]User, error) {
	var users []User
	params := url.Values{"query": {query}, "maxResults": {"20"}}
	if err := c.getWithQuery(ctx, "/rest/api/3/user/search", params, &users); err != nil {
		return nil, err
	}
	return users, nil
}

// MatchTransition picks the transition the owner named: first by the status
// it leads to ("Done"), then by the transition's own name ("Close"), both
// case-insensitive.
func MatchTransition(ts []Transition, status string) (Transition, bool) {
	want := strings.TrimSpace(status)
	for _, t := range ts {
		if strings.EqualFold(t.To.Name, want) {
			return t, true
		}
	}
	for _, t := range ts {
		if strings.EqualFold(t.Name, want) {
			return t, true
		}
	}
	return Transition{}, false
}

// TransitionTargets lists the distinct statuses the transitions lead to, in
// order — what an error message offers the model instead.
func TransitionTargets(ts []Transition) []string {
	var out []string
	for _, t := range ts {
		if t.To.Name != "" && !slices.Contains(out, t.To.Name) {
			out = append(out, t.To.Name)
		}
	}
	return out
}

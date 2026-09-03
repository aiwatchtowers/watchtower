package jira

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
)

// CreateIssueRequest is the input of CreateIssue. Description is plain text;
// it is converted to an ADF document of paragraphs.
type CreateIssueRequest struct {
	ProjectKey  string
	IssueType   string
	Summary     string
	Description string
	Labels      []string
	Priority    string
}

// CreatedIssue is Jira's POST /rest/api/3/issue response.
type CreatedIssue struct {
	ID   string `json:"id"`
	Key  string `json:"key"`
	Self string `json:"self"`
}

// APIError is a non-2xx Jira response with the messages Jira returned,
// e.g. "issuetype: The issue type selected is invalid." A 401 that survives
// a token refresh is NOT an APIError — Client.do maps it to ErrAuthRevoked.
type APIError struct {
	Status  int
	Message string
}

func (e *APIError) Error() string { return fmt.Sprintf("jira: %d: %s", e.Status, e.Message) }

// jiraErrorMessage flattens Jira's {"errorMessages":[...],"errors":{field:msg}}
// body into one line, falling back to the raw body.
func jiraErrorMessage(body []byte) string {
	var parsed struct {
		ErrorMessages []string          `json:"errorMessages"`
		Errors        map[string]string `json:"errors"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return strings.TrimSpace(string(body))
	}
	parts := append([]string{}, parsed.ErrorMessages...)
	keys := make([]string, 0, len(parsed.Errors))
	for k := range parsed.Errors {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		parts = append(parts, k+": "+parsed.Errors[k])
	}
	if len(parts) == 0 {
		return strings.TrimSpace(string(body))
	}
	return strings.Join(parts, "; ")
}

// ADFDocument renders plain text as an Atlassian Document Format doc: blank
// lines separate paragraphs, single newlines stay inside a paragraph.
func ADFDocument(text string) map[string]any {
	var paragraphs []map[string]any
	for _, block := range strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n\n") {
		block = strings.TrimSpace(block)
		if block == "" {
			continue
		}
		paragraphs = append(paragraphs, map[string]any{
			"type":    "paragraph",
			"content": []map[string]any{{"type": "text", "text": block}},
		})
	}
	if paragraphs == nil {
		paragraphs = []map[string]any{}
	}
	return map[string]any{"type": "doc", "version": 1, "content": paragraphs}
}

// DescriptionText is the exported face of extractDescriptionText (sync.go)
// so callers outside the syncer can flatten an ADF description.
func DescriptionText(desc interface{}) string { return extractDescriptionText(desc) }

// CreateIssue creates an issue via POST /rest/api/3/issue.
func (c *Client) CreateIssue(ctx context.Context, req CreateIssueRequest) (CreatedIssue, error) {
	fields := map[string]any{
		"project":   map[string]any{"key": req.ProjectKey},
		"issuetype": map[string]any{"name": req.IssueType},
		"summary":   req.Summary,
	}
	if strings.TrimSpace(req.Description) != "" {
		fields["description"] = ADFDocument(req.Description)
	}
	if len(req.Labels) > 0 {
		fields["labels"] = req.Labels
	}
	if req.Priority != "" {
		fields["priority"] = map[string]any{"name": req.Priority}
	}
	body, err := json.Marshal(map[string]any{"fields": fields})
	if err != nil {
		return CreatedIssue{}, fmt.Errorf("encoding create issue request: %w", err)
	}
	resp, err := c.do(ctx, http.MethodPost, "/rest/api/3/issue", bytes.NewReader(body))
	if err != nil {
		return CreatedIssue{}, err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusOK {
		return CreatedIssue{}, &APIError{Status: resp.StatusCode, Message: jiraErrorMessage(respBody)}
	}
	var created CreatedIssue
	if err := json.Unmarshal(respBody, &created); err != nil {
		return CreatedIssue{}, fmt.Errorf("decoding create issue response: %w", err)
	}
	return created, nil
}

// GetIssue fetches one issue with the same field set the search sync uses.
func (c *Client) GetIssue(ctx context.Context, key string) (Issue, error) {
	params := url.Values{"fields": {strings.Join(searchFields, ",")}}
	var issue Issue
	if err := c.getWithQuery(ctx, "/rest/api/3/issue/"+url.PathEscape(key), params, &issue); err != nil {
		return Issue{}, err
	}
	return issue, nil
}

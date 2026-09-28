# Chat Redesign — Phase 2: Actions (Tasks 17–19)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the main and target chats four new Jira write tools (comment, transition, assign, update), widen three local tools (`create_idea`, `create_track`, `remind_me`) to the main chat, and make every surface that describes or renders actions (Go/Swift actions contract, the proposal card, the step catalog) know about them.

**Architecture:** Jira HTTP writes live in `internal/jira/write.go` over the existing `Client.do` (401-refresh / 429-backoff / `ErrAuthRevoked`). The four registry tools live in `internal/tools/jira_write.go`; like `create_jira_issue` they are `External` (never execute-trusted, AGENT-03), go through `Propose`/`Apply` (AGENT-01/05), and refresh the local `jira_issues` mirror best-effort after the write (the `mirrorCreatedIssue` precedent, but *merging* into the stored row so syncer-owned columns survive). The actions contract becomes a byte-identical Go/Swift dual path pinned by shared fixture files.

**Tech Stack:** Go 1.25, `net/http/httptest`, testify, `github.com/google/jsonschema-go`; SwiftUI, XCTest, ViewInspector.

**Spec:** `docs/superpowers/specs/2026-09-26-chat-redesign-design.md` §8 (and §4.1 item 4 for the contract dual path). Read `docs/inventory/agent-actions.md` (AGENT-01..06) and `docs/inventory/reaction-commands.md` (REACT-02, REMIND-01/02) before starting — none of those contracts may weaken.

**Global rules for this phase:**
- Go inner loop: `go test ./internal/<pkg> -run <Name>` (no `-count=1`). Swift inner loop: `make test-swift FILTER=<TestClass>`. Lint: `make lint-diff`.
- Everything in English. One commit per task, ending with the attribution line `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Never `git add -A`; stage the files the task lists.

---

## Task 17: Jira write client

**Files:**
- Create: `internal/jira/write.go`
- Create: `internal/jira/write_test.go`
- Modify: `internal/jira/models.go` (add `AccountType` to `User`)

**Interfaces:**
- Consumes: `(*Client).do`, `ADFDocument`, `APIError`, `jiraErrorMessage` (all in `internal/jira`); test helper `makeTestClient(t, baseURL)` (`internal/jira/client_more_test.go`).
- Produces (binding for Task 18):
  - `type IssueUpdate struct{ Summary *string; Priority *string; LabelsAdd, LabelsRemove []string; DueDate *string }` + `func (u IssueUpdate) Empty() bool`
  - `type Transition struct{ ID, Name string; To Status }` (JSON `id`, `name`, `to`)
  - `func (c *Client) AddComment(ctx context.Context, key, body string) (commentID string, err error)`
  - `func (c *Client) GetTransitions(ctx context.Context, key string) ([]Transition, error)`
  - `func (c *Client) TransitionIssue(ctx context.Context, key, transitionID string) error`
  - `func (c *Client) AssignIssue(ctx context.Context, key, accountID string) error`
  - `func (c *Client) UpdateIssue(ctx context.Context, key string, f IssueUpdate) error`
  - `func (c *Client) SearchUsers(ctx context.Context, query string) ([]User, error)` (additive to the skeleton: Task 18's assignee fallback needs it)
  - `func MatchTransition(ts []Transition, status string) (Transition, bool)` — case-insensitive match on `to.name` first, then the transition's own `name`
  - `func TransitionTargets(ts []Transition) []string` — distinct `to.name` values in order, for error messages
  - `User` gains `AccountType string \`json:"accountType"\``

- [ ] **Step 1: Write the failing tests**

Create `internal/jira/write_test.go`:

```go
package jira

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// recordingServer answers every request with status/body and records the
// last method, path, raw query and decoded JSON body.
type recorded struct {
	method, path, query string
	body                map[string]any
}

func recordingServer(t *testing.T, status int, respBody string, rec *recorded) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec.method, rec.path, rec.query = r.Method, r.URL.Path, r.URL.RawQuery
		raw, _ := io.ReadAll(r.Body)
		rec.body = nil
		if len(raw) > 0 {
			require.NoError(t, json.Unmarshal(raw, &rec.body))
		}
		w.WriteHeader(status)
		_, _ = w.Write([]byte(respBody))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestAddComment_PostsADFBodyAndReturnsID(t *testing.T) {
	var rec recorded
	srv := recordingServer(t, http.StatusCreated, `{"id":"10042"}`, &rec)
	id, err := makeTestClient(t, srv.URL).AddComment(context.Background(), "ABC-7", "First.\n\nSecond.")
	require.NoError(t, err)
	assert.Equal(t, "10042", id)
	assert.Equal(t, http.MethodPost, rec.method)
	assert.Equal(t, "/rest/api/3/issue/ABC-7/comment", rec.path)
	body := rec.body["body"].(map[string]any)
	assert.Equal(t, "doc", body["type"])
	assert.Len(t, body["content"].([]any), 2, "blank line splits paragraphs")
}

func TestAddComment_EmptyBodyNeverCallsJira(t *testing.T) {
	var rec recorded
	srv := recordingServer(t, http.StatusCreated, `{"id":"1"}`, &rec)
	_, err := makeTestClient(t, srv.URL).AddComment(context.Background(), "ABC-7", "  \n ")
	require.Error(t, err)
	assert.Empty(t, rec.method, "no request for an empty comment")
}

func TestGetTransitions_Decodes(t *testing.T) {
	var rec recorded
	srv := recordingServer(t, http.StatusOK,
		`{"transitions":[{"id":"21","name":"Start","to":{"name":"In Progress","statusCategory":{"key":"indeterminate"}}},{"id":"31","name":"Finish","to":{"name":"Done","statusCategory":{"key":"done"}}}]}`, &rec)
	ts, err := makeTestClient(t, srv.URL).GetTransitions(context.Background(), "ABC-7")
	require.NoError(t, err)
	assert.Equal(t, "/rest/api/3/issue/ABC-7/transitions", rec.path)
	require.Len(t, ts, 2)
	assert.Equal(t, "21", ts[0].ID)
	assert.Equal(t, "In Progress", ts[0].To.Name)
	assert.Equal(t, "done", ts[1].To.StatusCategory.Key)
}

func TestTransitionIssue_PostsTransitionID(t *testing.T) {
	var rec recorded
	srv := recordingServer(t, http.StatusNoContent, ``, &rec)
	require.NoError(t, makeTestClient(t, srv.URL).TransitionIssue(context.Background(), "ABC-7", "31"))
	assert.Equal(t, http.MethodPost, rec.method)
	assert.Equal(t, "/rest/api/3/issue/ABC-7/transitions", rec.path)
	assert.Equal(t, "31", rec.body["transition"].(map[string]any)["id"])
}

func TestAssignIssue_PutsAccountID(t *testing.T) {
	var rec recorded
	srv := recordingServer(t, http.StatusNoContent, ``, &rec)
	require.NoError(t, makeTestClient(t, srv.URL).AssignIssue(context.Background(), "ABC-7", "acc-1"))
	assert.Equal(t, http.MethodPut, rec.method)
	assert.Equal(t, "/rest/api/3/issue/ABC-7/assignee", rec.path)
	assert.Equal(t, "acc-1", rec.body["accountId"])
}

func TestUpdateIssue_SendsFieldsAndLabelOps(t *testing.T) {
	var rec recorded
	srv := recordingServer(t, http.StatusNoContent, ``, &rec)
	summary, prio, due := "New title", "High", "2026-10-01"
	err := makeTestClient(t, srv.URL).UpdateIssue(context.Background(), "ABC-7", IssueUpdate{
		Summary: &summary, Priority: &prio, DueDate: &due,
		LabelsAdd: []string{"backend"}, LabelsRemove: []string{"stale"},
	})
	require.NoError(t, err)
	assert.Equal(t, http.MethodPut, rec.method)
	assert.Equal(t, "/rest/api/3/issue/ABC-7", rec.path)
	fields := rec.body["fields"].(map[string]any)
	assert.Equal(t, "New title", fields["summary"])
	assert.Equal(t, "High", fields["priority"].(map[string]any)["name"])
	assert.Equal(t, "2026-10-01", fields["duedate"])
	labels := rec.body["update"].(map[string]any)["labels"].([]any)
	assert.Equal(t, []any{map[string]any{"add": "backend"}, map[string]any{"remove": "stale"}}, labels)
}

func TestUpdateIssue_LabelsOnlyOmitsFields(t *testing.T) {
	var rec recorded
	srv := recordingServer(t, http.StatusNoContent, ``, &rec)
	require.NoError(t, makeTestClient(t, srv.URL).UpdateIssue(context.Background(), "ABC-7",
		IssueUpdate{LabelsAdd: []string{"x"}}))
	_, hasFields := rec.body["fields"]
	assert.False(t, hasFields)
}

func TestUpdateIssue_EmptyUpdateNeverCallsJira(t *testing.T) {
	var rec recorded
	srv := recordingServer(t, http.StatusNoContent, ``, &rec)
	require.Error(t, makeTestClient(t, srv.URL).UpdateIssue(context.Background(), "ABC-7", IssueUpdate{}))
	assert.Empty(t, rec.method)
}

func TestSearchUsers_QueriesAndDecodes(t *testing.T) {
	var rec recorded
	srv := recordingServer(t, http.StatusOK,
		`[{"accountId":"acc-1","displayName":"Jane Doe","emailAddress":"jane@example.com","active":true,"accountType":"atlassian"}]`, &rec)
	users, err := makeTestClient(t, srv.URL).SearchUsers(context.Background(), "jane")
	require.NoError(t, err)
	assert.Equal(t, "/rest/api/3/user/search", rec.path)
	assert.Contains(t, rec.query, "query=jane")
	require.Len(t, users, 1)
	assert.Equal(t, "atlassian", users[0].AccountType)
}

func TestWrites_MapJiraErrors(t *testing.T) {
	var rec recorded
	srv := recordingServer(t, http.StatusBadRequest, `{"errorMessages":[],"errors":{"priority":"Priority name 'Urgent' is not valid"}}`, &rec)
	prio := "Urgent"
	err := makeTestClient(t, srv.URL).UpdateIssue(context.Background(), "ABC-7", IssueUpdate{Priority: &prio})
	var apiErr *APIError
	require.ErrorAs(t, err, &apiErr)
	assert.Equal(t, 400, apiErr.Status)
	assert.Contains(t, apiErr.Message, "priority: Priority name 'Urgent' is not valid")
}

func TestMatchTransition_ByTargetStatusThenName(t *testing.T) {
	ts := []Transition{
		{ID: "21", Name: "Start work", To: Status{Name: "In Progress"}},
		{ID: "31", Name: "Close", To: Status{Name: "Done"}},
	}
	got, ok := MatchTransition(ts, " done ")
	require.True(t, ok)
	assert.Equal(t, "31", got.ID)
	got, ok = MatchTransition(ts, "start WORK")
	require.True(t, ok)
	assert.Equal(t, "21", got.ID)
	_, ok = MatchTransition(ts, "Review")
	assert.False(t, ok)
	assert.Equal(t, []string{"In Progress", "Done"}, TransitionTargets(append(ts, Transition{ID: "41", To: Status{Name: "Done"}})))
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./internal/jira -run 'TestAddComment|TestGetTransitions|TestTransitionIssue|TestAssignIssue|TestUpdateIssue|TestSearchUsers|TestWrites_|TestMatchTransition'`
Expected: build failure — `undefined: IssueUpdate`, `c.AddComment undefined`, etc.

- [ ] **Step 3: Add `AccountType` to `User`**

In `internal/jira/models.go`, change the `User` struct to:

```go
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
```

- [ ] **Step 4: Implement `internal/jira/write.go`**

```go
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
```

Note: `get` treats only `200` as success — correct for `GET …/transitions` and `GET /user/search`.

- [ ] **Step 5: Run the tests**

Run: `go test ./internal/jira -run 'TestAddComment|TestGetTransitions|TestTransitionIssue|TestAssignIssue|TestUpdateIssue|TestSearchUsers|TestWrites_|TestMatchTransition'`
Expected: PASS. Then `go test ./internal/jira` — PASS (the `AccountType` addition is additive).

- [ ] **Step 6: Lint + commit**

Run: `make lint-diff` — expect no new issues.

```bash
git add internal/jira/write.go internal/jira/write_test.go internal/jira/models.go
git commit -m "feat(jira): comment, transition, assign, update and user-search client calls

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

## Task 18: Jira write tools

**Files:**
- Create: `internal/db/jira_issue_lookup.go`, `internal/db/jira_issue_lookup_test.go`
- Create: `internal/tools/jira_write.go`, `internal/tools/jira_write_test.go`
- Modify: `cmd/actions_registry.go` (shared per-account client builder + write factory + registration)
- Modify: `cmd/actions_registry_test.go` (pin the four tools)

**Interfaces:**
- Consumes: Task 17's client methods; `tools.ResolveJiraAccount`, `issueRow`, `recordRevokedGrant`, `decodeStrict`, `ValidationError`; `db.GetJiraUserMaps`, `db.GetJiraUserMapByAccountID`, `db.ResolveOwner`, `db.UpsertJiraIssue`; test helpers `openDB(t)` (`registry_test.go`) and `seedJira(t, d)` (`jira_test.go`, creates account "https://acme.atlassian.net" with project ABC synced).
- Produces:
  - `func (db *DB) GetJiraIssue(accountID int64, key string) (*JiraIssue, error)` — nil, nil when absent
  - `func (db *DB) JiraAccountIDsForIssueKey(key string) ([]int64, error)` — enabled, non-removed accounts whose mirror holds a non-deleted row for `key`, ascending
  - `type JiraWriteClient interface{ GetIssue; AddComment; GetTransitions; TransitionIssue; AssignIssue; UpdateIssue; SearchUsers }` (signatures exactly as Task 17 / `*jira.Client`)
  - `type JiraWriteClientFactory func(account db.JiraAccount) (JiraWriteClient, error)`
  - `func NewAddJiraComment(f JiraWriteClientFactory) *Tool`, `NewTransitionJiraIssue`, `NewAssignJiraIssue`, `NewUpdateJiraIssue`, and `func JiraWriteTools(f JiraWriteClientFactory) []*Tool` (those four, in that order)
  - Tool args (JSON): all take `account_id` (optional int), `key` (required), `reason` (required); plus `add_jira_comment`: `body`; `transition_jira_issue`: `status`; `assign_jira_issue`: `assignee`; `update_jira_issue`: `summary`, `priority`, `labels_add`, `labels_remove`, `due_date` (all optional, at least one required)
  - Result JSON on apply: always `{"key","url","label"}` (+ `"warning"` when the mirror refresh failed). Labels: `Comment on ABC-7` / `ABC-7 → Done` / `ABC-7 → Jane Doe` / `ABC-7 updated`. Comment url: `<site>/browse/ABC-7?focusedCommentId=<id>`; others `<site>/browse/ABC-7`.
  - `cmd`: `func jiraAccountClient(cfg *config.Config, account db.JiraAccount) (*jira.Client, error)`, `func jiraWriteClientFactory(cfg *config.Config) tools.JiraWriteClientFactory`

Design rules (load-bearing — reviewers check these):
1. **Validate never writes** (AGENT-01): `transition_jira_issue` and `assign_jira_issue` may make *read* calls to Jira in Validate (GET transitions, user search), but a failure there returns a plain error — the revoked-account marking (`recordRevokedGrant`) happens only in Execute.
2. **Execute re-resolves** everything Validate resolved (transition id, assignee account id): the proposal may be approved hours later. A status no longer reachable at apply time fails the action with a message naming the reachable statuses.
3. **Which site:** explicit `account_id` wins; otherwise the site whose mirror holds the key; a key mirrored on two sites is a `ValidationError` asking for `account_id`; a key mirrored nowhere falls back to "the single enabled account" (`ResolveJiraAccount(d, 0)`).
4. **Mirror refresh merges**: the stored row keeps the syncer-owned columns (board, sprint, epic, story points, custom fields, reporter, components, fix versions); only what these writes can change (summary, description, status, priority, labels, due date, assignee, updated_at, raw_json, synced_at) is overlaid. `issueRow` alone would blank them.
5. `assignee` resolution order: `"me"` → the account's recorded `owner_account_id` → `db.ResolveOwner().JiraAccountID` (Atlassian ids are global across sites) → `ValidationError`; otherwise `jira_user_map` exact email (when the value contains `@`) or exact display name, case-insensitive (several hits → `ValidationError` listing them); otherwise Jira user search, keeping active `atlassian` users: exactly one exact email/display-name match wins, else exactly one result wins, else `ValidationError` (none, or up to 5 candidates listed).

- [ ] **Step 1: Write the failing DB tests**

Create `internal/db/jira_issue_lookup_test.go`:

```go
package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func seedLookupIssue(t *testing.T, d *DB, accountID int64, key string) {
	t.Helper()
	require.NoError(t, d.UpsertJiraIssue(JiraIssue{AccountID: accountID, Key: key, ID: key, ProjectKey: "ABC",
		Summary: "s", Labels: "[]", Components: "[]", FixVersions: "[]", BoardID: 7}))
}

func TestGetJiraIssue_ByCompositeKey(t *testing.T) {
	d := openTestDB(t)
	a1, err := d.CreateJiraAccount(JiraAccount{CloudID: "c1", SiteURL: "https://one"})
	require.NoError(t, err)
	a2, err := d.CreateJiraAccount(JiraAccount{CloudID: "c2", SiteURL: "https://two"})
	require.NoError(t, err)
	seedLookupIssue(t, d, a1, "ABC-1")

	got, err := d.GetJiraIssue(a1, "ABC-1")
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, 7, got.BoardID)

	missing, err := d.GetJiraIssue(a2, "ABC-1")
	require.NoError(t, err)
	assert.Nil(t, missing, "the same key on another site is a different row")
}

func TestJiraAccountIDsForIssueKey_OnlyEnabledLiveSites(t *testing.T) {
	d := openTestDB(t)
	a1, _ := d.CreateJiraAccount(JiraAccount{CloudID: "c1", SiteURL: "https://one"})
	a2, _ := d.CreateJiraAccount(JiraAccount{CloudID: "c2", SiteURL: "https://two"})
	a3, _ := d.CreateJiraAccount(JiraAccount{CloudID: "c3", SiteURL: "https://three"})
	for _, a := range []int64{a1, a2, a3} {
		seedLookupIssue(t, d, a, "ABC-1")
	}
	require.NoError(t, d.SetJiraAccountEnabled(a2, false))
	require.NoError(t, d.SetJiraAccountRemoved(a3))

	ids, err := d.JiraAccountIDsForIssueKey("ABC-1")
	require.NoError(t, err)
	assert.Equal(t, []int64{a1}, ids)

	none, err := d.JiraAccountIDsForIssueKey("ZZZ-9")
	require.NoError(t, err)
	assert.Empty(t, none)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./internal/db -run 'TestGetJiraIssue_ByCompositeKey|TestJiraAccountIDsForIssueKey'`
Expected: build failure — `d.GetJiraIssue undefined`.

- [ ] **Step 3: Implement `internal/db/jira_issue_lookup.go`**

```go
package db

import (
	"database/sql"
	"fmt"
)

// GetJiraIssue returns one mirrored issue by its composite key, nil when the
// account's mirror has no such row. Unlike GetJiraIssueByKey it never picks
// an arbitrary site for a key two sites share.
func (db *DB) GetJiraIssue(accountID int64, key string) (*JiraIssue, error) {
	row := db.QueryRow(`SELECT `+jiraIssueColumns+` FROM jira_issues WHERE account_id = ? AND key = ?`, accountID, key)
	issue, err := scanJiraIssue(row)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("scanning jira issue %d/%s: %w", accountID, key, err)
	}
	return &issue, nil
}

// JiraAccountIDsForIssueKey lists the enabled, non-removed accounts whose
// mirror holds a live row for key — the site a write to that key targets.
func (db *DB) JiraAccountIDsForIssueKey(key string) ([]int64, error) {
	rows, err := db.Query(`SELECT ji.account_id FROM jira_issues ji
		JOIN jira_accounts ja ON ja.id = ji.account_id
		WHERE ji.key = ? AND ji.is_deleted = 0 AND ja.enabled = 1 AND ja.status != 'removed'
		ORDER BY ji.account_id`, key)
	if err != nil {
		return nil, fmt.Errorf("querying accounts for jira issue %s: %w", key, err)
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning account id for jira issue %s: %w", key, err)
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}
```

Run: `go test ./internal/db -run 'TestGetJiraIssue_ByCompositeKey|TestJiraAccountIDsForIssueKey'` — Expected: PASS.

- [ ] **Step 4: Write the failing tool tests**

Create `internal/tools/jira_write_test.go`:

```go
package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/jira"
)

// fakeJiraWriter records every write; GetIssue returns the issue the last
// write left behind (status/assignee), so the mirror refresh can be asserted.
type fakeJiraWriter struct {
	transitions []jira.Transition
	users       []jira.User
	writeErr    error
	getErr      error
	status      string
	assigneeID  string
	assignee    string
	comments    []string
	moved       []string
	assigned    []string
	updates     []jira.IssueUpdate
	searches    []string
	// onWrite runs inside every write call, before it returns — the seam a
	// test needs to break a table the executor touches after the write.
	onWrite func()
}

func (f *fakeJiraWriter) wrote() error {
	if f.onWrite != nil {
		f.onWrite()
	}
	return f.writeErr
}

func (f *fakeJiraWriter) GetIssue(_ context.Context, key string) (jira.Issue, error) {
	if f.getErr != nil {
		return jira.Issue{}, f.getErr
	}
	status := f.status
	if status == "" {
		status = "To Do"
	}
	assignee := `null`
	if f.assigneeID != "" {
		assignee = `{"accountId":"` + f.assigneeID + `","displayName":"` + f.assignee + `"}`
	}
	var issue jira.Issue
	err := json.Unmarshal([]byte(`{"id":"1","key":"`+key+`","fields":{"summary":"Fix login","issuetype":{"name":"Task"},`+
		`"status":{"name":"`+status+`","statusCategory":{"key":"indeterminate"}},"priority":{"name":"High"},`+
		`"labels":["backend"],"duedate":"2026-10-01","assignee":`+assignee+`,`+
		`"created":"2026-09-04T10:00:00.000+0000","updated":"2026-09-26T10:00:00.000+0000"}}`), &issue)
	return issue, err
}

func (f *fakeJiraWriter) AddComment(_ context.Context, _, body string) (string, error) {
	f.comments = append(f.comments, body)
	if err := f.wrote(); err != nil {
		return "", err
	}
	return "10042", nil
}

func (f *fakeJiraWriter) GetTransitions(context.Context, string) ([]jira.Transition, error) {
	return f.transitions, f.getErr
}

func (f *fakeJiraWriter) TransitionIssue(_ context.Context, _, id string) error {
	f.moved = append(f.moved, id)
	for _, t := range f.transitions {
		if t.ID == id {
			f.status = t.To.Name
		}
	}
	return f.wrote()
}

func (f *fakeJiraWriter) AssignIssue(_ context.Context, _, accountID string) error {
	f.assigned = append(f.assigned, accountID)
	f.assigneeID, f.assignee = accountID, "Assigned Person"
	return f.wrote()
}

func (f *fakeJiraWriter) UpdateIssue(_ context.Context, _ string, u jira.IssueUpdate) error {
	f.updates = append(f.updates, u)
	return f.wrote()
}

func (f *fakeJiraWriter) SearchUsers(_ context.Context, q string) ([]jira.User, error) {
	f.searches = append(f.searches, q)
	return f.users, nil
}

func writeFactory(f *fakeJiraWriter) JiraWriteClientFactory {
	return func(db.JiraAccount) (JiraWriteClient, error) { return f, nil }
}

func seedIssueRow(t *testing.T, d *db.DB, accountID int64, key string) {
	t.Helper()
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{AccountID: accountID, Key: key, ID: "1", ProjectKey: "ABC",
		Summary: "Old", Status: "To Do", Labels: "[]", Components: "[]", FixVersions: "[]",
		BoardID: 7, SprintName: "Sprint 12", EpicKey: "ABC-1", ReporterDisplayName: "Rita"}))
}

func twoTransitions() []jira.Transition {
	return []jira.Transition{
		{ID: "21", Name: "Start work", To: jira.Status{Name: "In Progress"}},
		{ID: "31", Name: "Close", To: jira.Status{Name: "Done"}},
	}
}

func verr(t *testing.T, err error) string {
	t.Helper()
	var ve *ValidationError
	require.ErrorAs(t, err, &ve)
	return ve.Msg
}

func TestJiraWriteTools_ExternalOnMainAndTargetWithReason(t *testing.T) {
	reg := New(openDB(t))
	names := []string{"add_jira_comment", "transition_jira_issue", "assign_jira_issue", "update_jira_issue"}
	tools := JiraWriteTools(writeFactory(&fakeJiraWriter{}))
	require.Len(t, tools, len(names))
	for i, tool := range tools {
		assert.Equal(t, names[i], tool.Name)
		assert.Equal(t, AccessWrite, tool.Access)
		assert.True(t, tool.External, "%s leaves the machine", tool.Name)
		assert.ElementsMatch(t, []string{"main", "target"}, tool.Surfaces)
		assert.Contains(t, tool.InputSchema.Required, "reason")
		assert.Contains(t, tool.InputSchema.Required, "key")
		require.NoError(t, reg.Register(tool))
		// AGENT-03: an external write can never be trusted to execute.
		assert.ErrorIs(t, reg.SetTrust(tool.Name, TrustExecute), ErrExternalExecute)
	}
}

func TestAddJiraComment_ValidateRejectsBadInput(t *testing.T) {
	d := openDB(t)
	tool := NewAddJiraComment(writeFactory(&fakeJiraWriter{}))
	ctx := context.Background()
	assert.Contains(t, verr(t, tool.Validate(ctx, d, json.RawMessage(`{"key":"ABC-7","body":"hi","reason":"r"}`))), "no Jira site")

	seedJira(t, d)
	require.NoError(t, tool.Validate(ctx, d, json.RawMessage(`{"key":"abc-7","body":"hi","reason":"r"}`)), "lower-case key is normalized")
	for name, raw := range map[string]string{
		"bad key":       `{"key":"ABC7","body":"hi","reason":"r"}`,
		"empty body":    `{"key":"ABC-7","body":"  ","reason":"r"}`,
		"unknown field": `{"key":"ABC-7","body":"hi","reason":"r","visibility":"x"}`,
	} {
		t.Run(name, func(t *testing.T) { verr(t, tool.Validate(ctx, d, json.RawMessage(raw))) })
	}
}

func TestAddJiraComment_ExecutePostsAndRefreshesMirror(t *testing.T) {
	d := openDB(t)
	accountID := seedJira(t, d)
	seedIssueRow(t, d, accountID, "ABC-7")
	fake := &fakeJiraWriter{}
	out, err := NewAddJiraComment(writeFactory(fake)).Execute(context.Background(), d,
		Call{Args: json.RawMessage(`{"key":"ABC-7","body":"Looks good.\n\nShip it.","reason":"r"}`)})
	require.NoError(t, err)
	assert.Equal(t, []string{"Looks good.\n\nShip it."}, fake.comments)
	res := out.(map[string]any)
	assert.Equal(t, "ABC-7", res["key"])
	assert.Equal(t, "https://acme.atlassian.net/browse/ABC-7?focusedCommentId=10042", res["url"])
	assert.Equal(t, "Comment on ABC-7", res["label"])
	assert.NotContains(t, res, "warning")
}

func TestTransitionJiraIssue_ValidateListsReachableStatuses(t *testing.T) {
	d := openDB(t)
	seedJira(t, d)
	tool := NewTransitionJiraIssue(writeFactory(&fakeJiraWriter{transitions: twoTransitions()}))
	msg := verr(t, tool.Validate(context.Background(), d, json.RawMessage(`{"key":"ABC-7","status":"Review","reason":"r"}`)))
	assert.Contains(t, msg, `"Review"`)
	assert.Contains(t, msg, "In Progress, Done")
	require.NoError(t, tool.Validate(context.Background(), d, json.RawMessage(`{"key":"ABC-7","status":"done","reason":"r"}`)))
}

// A read failure in Validate is not the model's mistake and must not be
// reported as one — nor may Validate mark the account (AGENT-01: validation
// writes nothing).
func TestTransitionJiraIssue_ValidateReadFailureIsPlainErrorAndWritesNothing(t *testing.T) {
	d := openDB(t)
	accountID := seedJira(t, d)
	tool := NewTransitionJiraIssue(writeFactory(&fakeJiraWriter{getErr: jira.ErrAuthRevoked}))
	err := tool.Validate(context.Background(), d, json.RawMessage(`{"key":"ABC-7","status":"Done","reason":"r"}`))
	require.Error(t, err)
	var ve *ValidationError
	assert.False(t, errors.As(err, &ve))
	acct, _ := d.GetJiraAccount(accountID)
	assert.NotEqual(t, "revoked", acct.Status)
}

func TestTransitionJiraIssue_ExecuteMovesByStatusOrTransitionName(t *testing.T) {
	d := openDB(t)
	accountID := seedJira(t, d)
	seedIssueRow(t, d, accountID, "ABC-7")
	fake := &fakeJiraWriter{transitions: twoTransitions()}
	tool := NewTransitionJiraIssue(writeFactory(fake))

	out, err := tool.Execute(context.Background(), d, Call{Args: json.RawMessage(`{"key":"ABC-7","status":"DONE","reason":"r"}`)})
	require.NoError(t, err)
	assert.Equal(t, "ABC-7 → Done", out.(map[string]any)["label"])
	_, err = tool.Execute(context.Background(), d, Call{Args: json.RawMessage(`{"key":"ABC-7","status":"start work","reason":"r"}`)})
	require.NoError(t, err)
	assert.Equal(t, []string{"31", "21"}, fake.moved)

	row, err := d.GetJiraIssue(accountID, "ABC-7")
	require.NoError(t, err)
	assert.Equal(t, "In Progress", row.Status, "mirror refreshed from the fetched issue")
}

func TestTransitionJiraIssue_ExecuteFailsWhenStatusNoLongerReachable(t *testing.T) {
	d := openDB(t)
	seedJira(t, d)
	fake := &fakeJiraWriter{transitions: twoTransitions()[:1]}
	_, err := NewTransitionJiraIssue(writeFactory(fake)).Execute(context.Background(), d,
		Call{Args: json.RawMessage(`{"key":"ABC-7","status":"Done","reason":"r"}`)})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "In Progress")
	assert.Empty(t, fake.moved)
}

func TestAssignJiraIssue_MeUsesTheSiteOwnerThenTheOwnerIdentity(t *testing.T) {
	d := openDB(t)
	accountID := seedJira(t, d)
	tool := NewAssignJiraIssue(writeFactory(&fakeJiraWriter{}))
	ctx := context.Background()
	args := json.RawMessage(`{"key":"ABC-7","assignee":"Me","reason":"r"}`)

	assert.Contains(t, verr(t, tool.Validate(ctx, d, args)), "jira login --account")

	// Another site recorded the owner's Atlassian id (global across sites).
	other, err := d.CreateJiraAccount(db.JiraAccount{CloudID: "c2", SiteURL: "https://two.atlassian.net"})
	require.NoError(t, err)
	require.NoError(t, d.SetJiraAccountOwner(other, "acc-owner", "me@example.com", "Owner"))
	seedIssueRow(t, d, accountID, "ABC-7") // pins the key to the first site
	fake := &fakeJiraWriter{}
	_, err = NewAssignJiraIssue(writeFactory(fake)).Execute(ctx, d, Call{Args: args})
	require.NoError(t, err)
	assert.Equal(t, []string{"acc-owner"}, fake.assigned)

	require.NoError(t, d.SetJiraAccountOwner(accountID, "acc-site-owner", "me@example.com", "Owner"))
	_, err = NewAssignJiraIssue(writeFactory(fake)).Execute(ctx, d, Call{Args: args})
	require.NoError(t, err)
	assert.Equal(t, "acc-site-owner", fake.assigned[1], "the site's own recorded owner wins")
}

func TestAssignJiraIssue_ResolvesFromUserMapThenSearch(t *testing.T) {
	d := openDB(t)
	accountID := seedJira(t, d)
	seedIssueRow(t, d, accountID, "ABC-7")
	require.NoError(t, d.UpsertJiraUserMap(db.JiraUserMap{JiraAccountID: "acc-jane", Email: "jane@example.com", DisplayName: "Jane Doe"}))
	fake := &fakeJiraWriter{users: []jira.User{
		{AccountID: "acc-bot", DisplayName: "Bob Bot", Active: true, AccountType: "app"},
		{AccountID: "acc-bob", DisplayName: "Bob Stone", Active: true, AccountType: "atlassian"},
	}}
	tool := NewAssignJiraIssue(writeFactory(fake))
	ctx := context.Background()

	for _, who := range []string{"JANE@example.com", "jane doe"} {
		out, err := tool.Execute(ctx, d, Call{Args: json.RawMessage(`{"key":"ABC-7","assignee":"` + who + `","reason":"r"}`)})
		require.NoError(t, err)
		assert.Equal(t, "acc-jane", fake.assigned[len(fake.assigned)-1])
		assert.Equal(t, "ABC-7 → Jane Doe", out.(map[string]any)["label"])
	}
	assert.Empty(t, fake.searches, "a local hit never calls Jira")

	_, err := tool.Execute(ctx, d, Call{Args: json.RawMessage(`{"key":"ABC-7","assignee":"bob","reason":"r"}`)})
	require.NoError(t, err)
	assert.Equal(t, "acc-bob", fake.assigned[len(fake.assigned)-1], "the app account is ignored; one person left")
	assert.Equal(t, []string{"bob"}, fake.searches)
}

func TestAssignJiraIssue_AmbiguousOrUnknownIsValidationError(t *testing.T) {
	d := openDB(t)
	seedJira(t, d)
	require.NoError(t, d.UpsertJiraUserMap(db.JiraUserMap{JiraAccountID: "a1", Email: "a1@x.io", DisplayName: "Alex"}))
	require.NoError(t, d.UpsertJiraUserMap(db.JiraUserMap{JiraAccountID: "a2", Email: "a2@x.io", DisplayName: "alex"}))
	ctx := context.Background()

	msg := verr(t, NewAssignJiraIssue(writeFactory(&fakeJiraWriter{})).Validate(ctx, d,
		json.RawMessage(`{"key":"ABC-7","assignee":"Alex","reason":"r"}`)))
	assert.Contains(t, msg, "several Jira users")
	assert.Contains(t, msg, "a2@x.io")

	msg = verr(t, NewAssignJiraIssue(writeFactory(&fakeJiraWriter{})).Validate(ctx, d,
		json.RawMessage(`{"key":"ABC-7","assignee":"Nobody Here","reason":"r"}`)))
	assert.Contains(t, msg, "no active Jira user")

	two := &fakeJiraWriter{users: []jira.User{
		{AccountID: "s1", DisplayName: "Sam One", Active: true, AccountType: "atlassian"},
		{AccountID: "s2", DisplayName: "Sam Two", Active: true, AccountType: "atlassian"},
	}}
	msg = verr(t, NewAssignJiraIssue(writeFactory(two)).Validate(ctx, d,
		json.RawMessage(`{"key":"ABC-7","assignee":"sam","reason":"r"}`)))
	assert.Contains(t, msg, "Sam One")
	assert.Contains(t, msg, "Sam Two")
}

func TestUpdateJiraIssue_ValidateNeedsAFieldAndWellFormedValues(t *testing.T) {
	d := openDB(t)
	seedJira(t, d)
	tool := NewUpdateJiraIssue(writeFactory(&fakeJiraWriter{}))
	ctx := context.Background()
	assert.Contains(t, verr(t, tool.Validate(ctx, d, json.RawMessage(`{"key":"ABC-7","reason":"r"}`))), "at least one")
	assert.Contains(t, verr(t, tool.Validate(ctx, d, json.RawMessage(`{"key":"ABC-7","due_date":"next friday","reason":"r"}`))), "YYYY-MM-DD")
	assert.Contains(t, verr(t, tool.Validate(ctx, d, json.RawMessage(`{"key":"ABC-7","labels_add":["two words"],"reason":"r"}`))), "spaces")
	require.NoError(t, tool.Validate(ctx, d, json.RawMessage(`{"key":"ABC-7","priority":"High","reason":"r"}`)))
}

func TestUpdateJiraIssue_ExecuteSendsOnlyTheGivenFields(t *testing.T) {
	d := openDB(t)
	seedJira(t, d)
	fake := &fakeJiraWriter{}
	out, err := NewUpdateJiraIssue(writeFactory(fake)).Execute(context.Background(), d, Call{Args: json.RawMessage(
		`{"key":"ABC-7","summary":" New title ","labels_add":["backend"],"labels_remove":["stale"],"due_date":"2026-10-01","reason":"r"}`)})
	require.NoError(t, err)
	require.Len(t, fake.updates, 1)
	u := fake.updates[0]
	require.NotNil(t, u.Summary)
	assert.Equal(t, "New title", *u.Summary)
	assert.Nil(t, u.Priority)
	assert.Equal(t, "2026-10-01", *u.DueDate)
	assert.Equal(t, []string{"backend"}, u.LabelsAdd)
	assert.Equal(t, []string{"stale"}, u.LabelsRemove)
	assert.Equal(t, "ABC-7 updated", out.(map[string]any)["label"])
}

func TestJiraIssueWrite_KeyOnTwoSitesNeedsAccountID(t *testing.T) {
	d := openDB(t)
	a1 := seedJira(t, d)
	a2, err := d.CreateJiraAccount(db.JiraAccount{CloudID: "c2", SiteURL: "https://two.atlassian.net"})
	require.NoError(t, err)
	seedIssueRow(t, d, a1, "ABC-7")
	seedIssueRow(t, d, a2, "ABC-7")
	tool := NewAddJiraComment(writeFactory(&fakeJiraWriter{}))
	assert.Contains(t, verr(t, tool.Validate(context.Background(), d,
		json.RawMessage(`{"key":"ABC-7","body":"x","reason":"r"}`))), "account_id")
	require.NoError(t, tool.Validate(context.Background(), d,
		json.RawMessage(fmt.Sprintf(`{"account_id":%d,"key":"ABC-7","body":"x","reason":"r"}`, a2))))
}

// The refresh overlays what the write changed onto the stored row: the
// syncer-owned columns (board, sprint, epic, reporter) survive until the
// next sync instead of being blanked by a partial row.
func TestJiraIssueWrite_MirrorRefreshKeepsSyncerColumns(t *testing.T) {
	d := openDB(t)
	accountID := seedJira(t, d)
	seedIssueRow(t, d, accountID, "ABC-7")
	require.NoError(t, d.UpsertJiraUserMap(db.JiraUserMap{JiraAccountID: "acc-jane", SlackUserID: "1:UJANE", DisplayName: "Jane Doe"}))
	fake := &fakeJiraWriter{}
	_, err := NewAssignJiraIssue(writeFactory(fake)).Execute(context.Background(), d,
		Call{Args: json.RawMessage(`{"key":"ABC-7","assignee":"Jane Doe","reason":"r"}`)})
	require.NoError(t, err)

	row, err := d.GetJiraIssue(accountID, "ABC-7")
	require.NoError(t, err)
	assert.Equal(t, "acc-jane", row.AssigneeAccountID)
	assert.Equal(t, "1:UJANE", row.AssigneeSlackID)
	assert.Equal(t, "Fix login", row.Summary)
	assert.Equal(t, "2026-10-01", row.DueDate)
	assert.Equal(t, 7, row.BoardID)
	assert.Equal(t, "Sprint 12", row.SprintName)
	assert.Equal(t, "ABC-1", row.EpicKey)
	assert.Equal(t, "Rita", row.ReporterDisplayName)
}

func TestJiraIssueWrite_MirrorFailureWarnsOnASuccessfulResult(t *testing.T) {
	d := openDB(t)
	seedJira(t, d)
	fake := &fakeJiraWriter{}
	fake.onWrite = func() {
		_, derr := d.Exec(`DROP TABLE jira_issues`)
		require.NoError(t, derr)
	}
	out, err := NewAddJiraComment(writeFactory(fake)).Execute(context.Background(), d,
		Call{Args: json.RawMessage(`{"key":"ABC-7","body":"x","reason":"r"}`)})
	require.NoError(t, err, "the comment exists in Jira; a stale mirror never fails the action")
	res := out.(map[string]any)
	assert.Equal(t, "Comment on ABC-7", res["label"])
	assert.Contains(t, res["warning"], "the local mirror was not updated")
}

func TestJiraIssueWrite_AuthRevokedMarksAccount(t *testing.T) {
	d := openDB(t)
	accountID := seedJira(t, d)
	fake := &fakeJiraWriter{writeErr: jira.ErrAuthRevoked}
	_, err := NewUpdateJiraIssue(writeFactory(fake)).Execute(context.Background(), d,
		Call{Args: json.RawMessage(`{"key":"ABC-7","priority":"High","reason":"r"}`)})
	assert.ErrorIs(t, err, jira.ErrAuthRevoked)
	acct, _ := d.GetJiraAccount(accountID)
	assert.Equal(t, "revoked", acct.Status)
}
```

- [ ] **Step 5: Run to verify they fail**

Run: `go test ./internal/tools -run 'TestJiraWriteTools|TestAddJiraComment|TestTransitionJiraIssue|TestAssignJiraIssue|TestUpdateJiraIssue|TestJiraIssueWrite'`
Expected: build failure — `undefined: JiraWriteTools`, `undefined: NewAddJiraComment`, …

- [ ] **Step 6: Implement `internal/tools/jira_write.go`**

```go
package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/db"
	"watchtower/internal/jira"
)

// JiraWriteClient is the slice of *jira.Client the four issue-write tools
// need — the JiraIssueClient seam's sibling, so tests inject a fake.
type JiraWriteClient interface {
	GetIssue(ctx context.Context, key string) (jira.Issue, error)
	AddComment(ctx context.Context, key, body string) (string, error)
	GetTransitions(ctx context.Context, key string) ([]jira.Transition, error)
	TransitionIssue(ctx context.Context, key, transitionID string) error
	AssignIssue(ctx context.Context, key, accountID string) error
	UpdateIssue(ctx context.Context, key string, f jira.IssueUpdate) error
	SearchUsers(ctx context.Context, query string) ([]jira.User, error)
}

// JiraWriteClientFactory builds a write client for one connected account.
type JiraWriteClientFactory func(account db.JiraAccount) (JiraWriteClient, error)

// JiraWriteTools returns the four existing-issue write tools, in their
// registration order. All are External (AGENT-03): each leaves the machine.
func JiraWriteTools(f JiraWriteClientFactory) []*Tool {
	return []*Tool{NewAddJiraComment(f), NewTransitionJiraIssue(f), NewAssignJiraIssue(f), NewUpdateJiraIssue(f)}
}

var issueKeyRE = regexp.MustCompile(`^[A-Z][A-Z0-9_]+-\d+$`)

// resolveIssueTarget normalizes the key and picks the site it lives on:
// explicit account_id → the one site whose mirror holds the key → the single
// enabled account. A key mirrored on several sites needs account_id.
func resolveIssueTarget(d *db.DB, accountID int64, rawKey string) (db.JiraAccount, string, error) {
	key := strings.ToUpper(strings.TrimSpace(rawKey))
	if !issueKeyRE.MatchString(key) {
		return db.JiraAccount{}, "", &ValidationError{Msg: fmt.Sprintf("key %q is not a Jira issue key (e.g. ABC-123)", rawKey)}
	}
	if accountID > 0 {
		a, err := ResolveJiraAccount(d, accountID)
		return a, key, err
	}
	ids, err := d.JiraAccountIDsForIssueKey(key)
	if err != nil {
		return db.JiraAccount{}, "", err
	}
	switch len(ids) {
	case 0:
		a, err := ResolveJiraAccount(d, 0)
		return a, key, err
	case 1:
		a, err := ResolveJiraAccount(d, ids[0])
		return a, key, err
	default:
		return db.JiraAccount{}, "", &ValidationError{Msg: fmt.Sprintf("%s exists on several connected Jira sites — pass account_id (see list_jira_projects)", key)}
	}
}

// openIssue resolves the target and builds its client.
func openIssue(d *db.DB, factory JiraWriteClientFactory, accountID int64, rawKey string) (db.JiraAccount, JiraWriteClient, string, error) {
	account, key, err := resolveIssueTarget(d, accountID, rawKey)
	if err != nil {
		return db.JiraAccount{}, nil, "", err
	}
	client, err := factory(account)
	if err != nil {
		return db.JiraAccount{}, nil, "", err
	}
	return account, client, key, nil
}

// jiraWriteFailed marks the account revoked on ErrAuthRevoked (Execute only —
// Validate never writes) and folds a failed marking into the error, the
// create_jira_issue shape.
func jiraWriteFailed(d *db.DB, accountID int64, err error) error {
	if dbErr := recordRevokedGrant(d, accountID, err); dbErr != nil {
		return fmt.Errorf("%w (and recording the revoked state failed: %v)", err, dbErr)
	}
	return err
}

func browseURL(account db.JiraAccount, key string) string {
	return strings.TrimRight(account.SiteURL, "/") + "/browse/" + key
}

// issueResult is the one result shape every issue-write tool returns; the
// Desktop card renders url+label generically.
func issueResult(ctx context.Context, d *db.DB, client JiraWriteClient, accountID int64, key, url, label string) map[string]any {
	result := map[string]any{"key": key, "url": url, "label": label}
	if warning := refreshIssueMirror(ctx, d, client, accountID, key); warning != "" {
		result["warning"] = warning
	}
	return result
}

// refreshIssueMirror re-reads the issue after a write and stores it. The
// write already happened in Jira, so nothing here fails the action; the
// owner is told the mirror is stale and the next sync repairs it.
func refreshIssueMirror(ctx context.Context, d *db.DB, client JiraWriteClient, accountID int64, key string) string {
	const prefix = "applied, but the local mirror was not updated: "
	issue, err := client.GetIssue(ctx, key)
	if err != nil {
		return prefix + err.Error()
	}
	row, err := refreshedIssueRow(d, accountID, issue)
	if err != nil {
		return prefix + err.Error()
	}
	if err := d.UpsertJiraIssue(row); err != nil {
		return prefix + err.Error()
	}
	return ""
}

// refreshedIssueRow overlays what these writes can change onto the stored
// row, so board/sprint/epic/reporter/custom-field columns the syncer owns
// survive (issueRow alone would blank them). A key not mirrored yet gets
// issueRow's shape.
func refreshedIssueRow(d *db.DB, accountID int64, issue jira.Issue) (db.JiraIssue, error) {
	fresh := issueRow(accountID, issue)
	existing, err := d.GetJiraIssue(accountID, issue.Key)
	if err != nil {
		return db.JiraIssue{}, err
	}
	row := fresh
	if existing != nil {
		row = *existing
		row.Summary, row.DescriptionText = fresh.Summary, fresh.DescriptionText
		row.Status, row.StatusCategory = fresh.Status, fresh.StatusCategory
		row.Priority, row.Labels = fresh.Priority, fresh.Labels
		row.UpdatedAt, row.RawJSON, row.SyncedAt = fresh.UpdatedAt, fresh.RawJSON, fresh.SyncedAt
	}
	f := issue.Fields
	row.DueDate = ""
	if f.DueDate != nil {
		row.DueDate = *f.DueDate
	}
	row.AssigneeAccountID, row.AssigneeEmail, row.AssigneeDisplayName, row.AssigneeSlackID = "", "", "", ""
	if f.Assignee != nil {
		row.AssigneeAccountID = f.Assignee.AccountID
		row.AssigneeEmail = f.Assignee.EmailAddress
		row.AssigneeDisplayName = f.Assignee.DisplayName
		m, err := d.GetJiraUserMapByAccountID(f.Assignee.AccountID)
		if err != nil {
			return db.JiraIssue{}, err
		}
		if m != nil {
			row.AssigneeSlackID = m.SlackUserID
		}
	}
	return row, nil
}

func mustWriteSchema[T any](name string) *jsonschema.Schema {
	schema, err := jsonschema.For[T](nil)
	if err != nil {
		panic(name + " schema: " + err.Error())
	}
	return schema
}

// ---- add_jira_comment -------------------------------------------------------

type addJiraCommentArgs struct {
	AccountID int64  `json:"account_id,omitempty" jsonschema:"connected Jira account id; needed only when the key exists on several sites (see list_jira_projects)"`
	Key       string `json:"key" jsonschema:"issue key, e.g. ABC-123"`
	Body      string `json:"body" jsonschema:"plain-text comment; blank lines separate paragraphs"`
	Reason    string `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
}

// NewAddJiraComment builds the add_jira_comment write tool.
func NewAddJiraComment(factory JiraWriteClientFactory) *Tool {
	return &Tool{
		Name: "add_jira_comment",
		Description: "Propose a comment on an existing Jira issue. The owner approves it in the chat before " +
			"anything is sent to Jira.",
		InputSchema: mustWriteSchema[addJiraCommentArgs]("add_jira_comment"),
		Access:      AccessWrite,
		External:    true,
		Surfaces:    []string{"main", "target"},
		Validate: func(_ context.Context, d *db.DB, raw json.RawMessage) error {
			var a addJiraCommentArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			switch body := strings.TrimSpace(a.Body); {
			case body == "":
				return &ValidationError{Msg: "body is required"}
			case len([]rune(body)) > 32000:
				return &ValidationError{Msg: "body must be at most 32000 characters"}
			}
			_, _, err := resolveIssueTarget(d, a.AccountID, a.Key)
			return err
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a addJiraCommentArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding add_jira_comment args: %w", err)
			}
			account, client, key, err := openIssue(d, factory, a.AccountID, a.Key)
			if err != nil {
				return nil, err
			}
			id, err := client.AddComment(ctx, key, a.Body)
			if err != nil {
				return nil, jiraWriteFailed(d, account.ID, err)
			}
			url := browseURL(account, key) + "?focusedCommentId=" + id
			return issueResult(ctx, d, client, account.ID, key, url, "Comment on "+key), nil
		},
	}
}

// ---- transition_jira_issue --------------------------------------------------

type transitionJiraIssueArgs struct {
	AccountID int64  `json:"account_id,omitempty" jsonschema:"connected Jira account id; needed only when the key exists on several sites (see list_jira_projects)"`
	Key       string `json:"key" jsonschema:"issue key, e.g. ABC-123"`
	Status    string `json:"status" jsonschema:"the status to move the issue to, e.g. In Progress or Done (the transition's name also works)"`
	Reason    string `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
}

// reachableTransition fetches the issue's transitions and matches status.
// A miss is a ValidationError naming the reachable statuses.
func reachableTransition(ctx context.Context, client JiraWriteClient, key, status string) (jira.Transition, error) {
	ts, err := client.GetTransitions(ctx, key)
	if err != nil {
		return jira.Transition{}, fmt.Errorf("reading the transitions of %s: %w", key, err)
	}
	t, ok := jira.MatchTransition(ts, status)
	if !ok {
		return jira.Transition{}, &ValidationError{Msg: fmt.Sprintf("no transition of %s leads to %q; reachable now: %s",
			key, strings.TrimSpace(status), strings.Join(jira.TransitionTargets(ts), ", "))}
	}
	return t, nil
}

// NewTransitionJiraIssue builds the transition_jira_issue write tool.
func NewTransitionJiraIssue(factory JiraWriteClientFactory) *Tool {
	return &Tool{
		Name: "transition_jira_issue",
		Description: "Propose moving an existing Jira issue to another status. Pass the target status name; " +
			"the tool rejects a status the issue's workflow cannot reach right now and lists the reachable ones. " +
			"The owner approves it in the chat before anything is sent to Jira.",
		InputSchema: mustWriteSchema[transitionJiraIssueArgs]("transition_jira_issue"),
		Access:      AccessWrite,
		External:    true,
		Surfaces:    []string{"main", "target"},
		Validate: func(ctx context.Context, d *db.DB, raw json.RawMessage) error {
			var a transitionJiraIssueArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if strings.TrimSpace(a.Status) == "" {
				return &ValidationError{Msg: "status is required"}
			}
			_, client, key, err := openIssue(d, factory, a.AccountID, a.Key)
			if err != nil {
				return err
			}
			_, err = reachableTransition(ctx, client, key, a.Status)
			return err
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a transitionJiraIssueArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding transition_jira_issue args: %w", err)
			}
			account, client, key, err := openIssue(d, factory, a.AccountID, a.Key)
			if err != nil {
				return nil, err
			}
			// Re-resolved at apply time: the workflow may have moved since the proposal.
			t, err := reachableTransition(ctx, client, key, a.Status)
			if err != nil {
				return nil, jiraWriteFailed(d, account.ID, err)
			}
			if err := client.TransitionIssue(ctx, key, t.ID); err != nil {
				return nil, jiraWriteFailed(d, account.ID, err)
			}
			return issueResult(ctx, d, client, account.ID, key, browseURL(account, key), key+" → "+t.To.Name), nil
		},
	}
}

// ---- assign_jira_issue ------------------------------------------------------

type assignJiraIssueArgs struct {
	AccountID int64  `json:"account_id,omitempty" jsonschema:"connected Jira account id; needed only when the key exists on several sites (see list_jira_projects)"`
	Key       string `json:"key" jsonschema:"issue key, e.g. ABC-123"`
	Assignee  string `json:"assignee" jsonschema:"me (the owner), a person's email, or their exact display name"`
	Reason    string `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
}

type jiraAssignee struct{ AccountID, Name string }

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

// resolveAssignee maps "me" / an email / a display name to an Atlassian
// account id: owner identity → jira_user_map → Jira user search. client is
// lazy so "me" and a local hit never build one.
func resolveAssignee(ctx context.Context, d *db.DB, account db.JiraAccount, who string, client func() (JiraWriteClient, error)) (jiraAssignee, error) {
	who = strings.TrimSpace(who)
	if strings.EqualFold(who, "me") {
		return ownerAssignee(d, account)
	}
	if a, found, err := localAssignee(d, who); err != nil || found {
		return a, err
	}
	c, err := client()
	if err != nil {
		return jiraAssignee{}, err
	}
	return searchAssignee(ctx, c, who)
}

func ownerAssignee(d *db.DB, account db.JiraAccount) (jiraAssignee, error) {
	if account.OwnerAccountID != "" {
		return jiraAssignee{account.OwnerAccountID, firstNonEmpty(account.OwnerDisplayName, "you")}, nil
	}
	owner, err := d.ResolveOwner()
	if err != nil {
		return jiraAssignee{}, fmt.Errorf("resolving the owner: %w", err)
	}
	if owner.JiraAccountID != "" {
		return jiraAssignee{owner.JiraAccountID, firstNonEmpty(owner.DisplayName, "you")}, nil
	}
	return jiraAssignee{}, &ValidationError{Msg: fmt.Sprintf("the owner's own Jira identity is not recorded yet; "+
		"ask the owner to run 'watchtower jira login --account %d', or pass their email", account.ID)}
}

func localAssignee(d *db.DB, who string) (jiraAssignee, bool, error) {
	maps, err := d.GetJiraUserMaps()
	if err != nil {
		return jiraAssignee{}, false, err
	}
	byEmail := strings.Contains(who, "@")
	var hits []db.JiraUserMap
	for _, m := range maps {
		if (byEmail && strings.EqualFold(m.Email, who)) || (!byEmail && strings.EqualFold(m.DisplayName, who)) {
			hits = append(hits, m)
		}
	}
	switch len(hits) {
	case 0:
		return jiraAssignee{}, false, nil
	case 1:
		return jiraAssignee{hits[0].JiraAccountID, firstNonEmpty(hits[0].DisplayName, hits[0].Email)}, true, nil
	default:
		names := make([]string, 0, len(hits))
		for _, h := range hits {
			names = append(names, strings.TrimSpace(h.DisplayName+" <"+h.Email+">"))
		}
		return jiraAssignee{}, true, &ValidationError{Msg: fmt.Sprintf("%q matches several Jira users (%s); pass an email", who, strings.Join(names, ", "))}
	}
}

func searchAssignee(ctx context.Context, c JiraWriteClient, who string) (jiraAssignee, error) {
	users, err := c.SearchUsers(ctx, who)
	if err != nil {
		return jiraAssignee{}, fmt.Errorf("searching Jira users for %q: %w", who, err)
	}
	var people, exact []jira.User
	for _, u := range users {
		if !u.Active || (u.AccountType != "" && u.AccountType != "atlassian") {
			continue
		}
		people = append(people, u)
		if strings.EqualFold(u.EmailAddress, who) || strings.EqualFold(u.DisplayName, who) {
			exact = append(exact, u)
		}
	}
	pick := func(u jira.User) jiraAssignee { return jiraAssignee{u.AccountID, firstNonEmpty(u.DisplayName, u.EmailAddress)} }
	switch {
	case len(exact) == 1:
		return pick(exact[0]), nil
	case len(exact) == 0 && len(people) == 1:
		return pick(people[0]), nil
	case len(people) == 0:
		return jiraAssignee{}, &ValidationError{Msg: fmt.Sprintf("no active Jira user matches %q; ask the owner for the person's email", who)}
	}
	names := make([]string, 0, 5)
	for i, u := range people {
		if i == 5 {
			break
		}
		names = append(names, u.DisplayName)
	}
	return jiraAssignee{}, &ValidationError{Msg: fmt.Sprintf("%q matches several Jira users (%s); pass an email", who, strings.Join(names, ", "))}
}

// NewAssignJiraIssue builds the assign_jira_issue write tool.
func NewAssignJiraIssue(factory JiraWriteClientFactory) *Tool {
	return &Tool{
		Name: "assign_jira_issue",
		Description: "Propose assigning an existing Jira issue. assignee is \"me\" (the owner), a person's email, " +
			"or their exact display name; an ambiguous name is rejected with the candidates. The owner approves " +
			"it in the chat before anything is sent to Jira.",
		InputSchema: mustWriteSchema[assignJiraIssueArgs]("assign_jira_issue"),
		Access:      AccessWrite,
		External:    true,
		Surfaces:    []string{"main", "target"},
		Validate: func(ctx context.Context, d *db.DB, raw json.RawMessage) error {
			var a assignJiraIssueArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if strings.TrimSpace(a.Assignee) == "" {
				return &ValidationError{Msg: "assignee is required"}
			}
			account, _, err := resolveIssueTarget(d, a.AccountID, a.Key)
			if err != nil {
				return err
			}
			_, err = resolveAssignee(ctx, d, account, a.Assignee, func() (JiraWriteClient, error) { return factory(account) })
			return err
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a assignJiraIssueArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding assign_jira_issue args: %w", err)
			}
			account, client, key, err := openIssue(d, factory, a.AccountID, a.Key)
			if err != nil {
				return nil, err
			}
			who, err := resolveAssignee(ctx, d, account, a.Assignee, func() (JiraWriteClient, error) { return client, nil })
			if err != nil {
				return nil, jiraWriteFailed(d, account.ID, err)
			}
			if err := client.AssignIssue(ctx, key, who.AccountID); err != nil {
				return nil, jiraWriteFailed(d, account.ID, err)
			}
			return issueResult(ctx, d, client, account.ID, key, browseURL(account, key), key+" → "+who.Name), nil
		},
	}
}

// ---- update_jira_issue ------------------------------------------------------

type updateJiraIssueArgs struct {
	AccountID    int64    `json:"account_id,omitempty" jsonschema:"connected Jira account id; needed only when the key exists on several sites (see list_jira_projects)"`
	Key          string   `json:"key" jsonschema:"issue key, e.g. ABC-123"`
	Summary      string   `json:"summary,omitempty" jsonschema:"new title, at most 255 characters"`
	Priority     string   `json:"priority,omitempty" jsonschema:"Jira priority name, e.g. High"`
	LabelsAdd    []string `json:"labels_add,omitempty" jsonschema:"labels to add (no spaces)"`
	LabelsRemove []string `json:"labels_remove,omitempty" jsonschema:"labels to remove"`
	DueDate      string   `json:"due_date,omitempty" jsonschema:"new due date, YYYY-MM-DD"`
	Reason       string   `json:"reason" jsonschema:"one sentence: why you propose this, shown to the owner"`
}

func trimmedLabels(in []string) []string {
	var out []string
	for _, l := range in {
		if l = strings.TrimSpace(l); l != "" {
			out = append(out, l)
		}
	}
	return out
}

func (a updateJiraIssueArgs) update() jira.IssueUpdate {
	var u jira.IssueUpdate
	if s := strings.TrimSpace(a.Summary); s != "" {
		u.Summary = &s
	}
	if p := strings.TrimSpace(a.Priority); p != "" {
		u.Priority = &p
	}
	if due := strings.TrimSpace(a.DueDate); due != "" {
		u.DueDate = &due
	}
	u.LabelsAdd, u.LabelsRemove = trimmedLabels(a.LabelsAdd), trimmedLabels(a.LabelsRemove)
	return u
}

func validateIssueUpdate(u jira.IssueUpdate) error {
	if u.Empty() {
		return &ValidationError{Msg: "pass at least one of summary, priority, labels_add, labels_remove, due_date"}
	}
	if u.Summary != nil && len([]rune(*u.Summary)) > 255 {
		return &ValidationError{Msg: "summary must be at most 255 characters"}
	}
	if u.DueDate != nil {
		if _, err := time.Parse("2006-01-02", *u.DueDate); err != nil {
			return &ValidationError{Msg: fmt.Sprintf("due_date %q must be YYYY-MM-DD", *u.DueDate)}
		}
	}
	for _, l := range append(append([]string{}, u.LabelsAdd...), u.LabelsRemove...) {
		if strings.ContainsAny(l, " \t") {
			return &ValidationError{Msg: fmt.Sprintf("label %q: Jira labels cannot contain spaces", l)}
		}
	}
	return nil
}

// NewUpdateJiraIssue builds the update_jira_issue write tool.
func NewUpdateJiraIssue(factory JiraWriteClientFactory) *Tool {
	return &Tool{
		Name: "update_jira_issue",
		Description: "Propose editing an existing Jira issue: any of summary, priority (by name), labels to add " +
			"or remove, and due date (YYYY-MM-DD). The owner approves it in the chat before anything is sent to Jira.",
		InputSchema: mustWriteSchema[updateJiraIssueArgs]("update_jira_issue"),
		Access:      AccessWrite,
		External:    true,
		Surfaces:    []string{"main", "target"},
		Validate: func(_ context.Context, d *db.DB, raw json.RawMessage) error {
			var a updateJiraIssueArgs
			if err := decodeStrict(raw, &a); err != nil {
				return err
			}
			if err := validateIssueUpdate(a.update()); err != nil {
				return err
			}
			_, _, err := resolveIssueTarget(d, a.AccountID, a.Key)
			return err
		},
		Execute: func(ctx context.Context, d *db.DB, call Call) (any, error) {
			var a updateJiraIssueArgs
			if err := json.Unmarshal(call.Args, &a); err != nil {
				return nil, fmt.Errorf("decoding update_jira_issue args: %w", err)
			}
			account, client, key, err := openIssue(d, factory, a.AccountID, a.Key)
			if err != nil {
				return nil, err
			}
			if err := client.UpdateIssue(ctx, key, a.update()); err != nil {
				return nil, jiraWriteFailed(d, account.ID, err)
			}
			return issueResult(ctx, d, client, account.ID, key, browseURL(account, key), key+" updated"), nil
		},
	}
}
```

- [ ] **Step 7: Run the tool tests**

Run: `go test ./internal/tools -run 'TestJiraWriteTools|TestAddJiraComment|TestTransitionJiraIssue|TestAssignJiraIssue|TestUpdateJiraIssue|TestJiraIssueWrite'`
Expected: PASS. Then `go test ./internal/tools` — PASS.

- [ ] **Step 8: Wire the registry (`cmd/actions_registry.go`)**

Replace `jiraClientFactory` and `jiraConnectFactory`'s duplicated token/cloud-id checks with one builder, add the write factory, and register the four tools right after `create_jira_issue`:

```go
// jiraAccountClient builds a per-account Jira client the way the sync wiring
// does: the account's token file + the resolved OAuth client credentials.
func jiraAccountClient(cfg *config.Config, account db.JiraAccount) (*jira.Client, error) {
	store := jira.NewTokenStore(cfg.WorkspaceDir(), account.ID)
	if !store.Exists() {
		return nil, fmt.Errorf("jira account #%d has no token; run 'watchtower jira login --account %d'", account.ID, account.ID)
	}
	if account.CloudID == "" {
		return nil, fmt.Errorf("jira account #%d has no cloud id; run 'watchtower jira login --account %d'", account.ID, account.ID)
	}
	return jira.NewClient(account.CloudID, resolveJiraOAuthConfig(), store), nil
}

// jiraClientFactory serves create_jira_issue.
func jiraClientFactory(cfg *config.Config) tools.JiraClientFactory {
	return func(account db.JiraAccount) (tools.JiraIssueClient, error) {
		c, err := jiraAccountClient(cfg, account)
		if err != nil {
			return nil, err // never a typed-nil *jira.Client inside the interface
		}
		return c, nil
	}
}

// jiraWriteClientFactory serves the four existing-issue write tools.
func jiraWriteClientFactory(cfg *config.Config) tools.JiraWriteClientFactory {
	return func(account db.JiraAccount) (tools.JiraWriteClient, error) {
		c, err := jiraAccountClient(cfg, account)
		if err != nil {
			return nil, err
		}
		return c, nil
	}
}

// jiraConnectFactory builds the per-account board client + board analyzer
// connect_jira_board needs, the way runJiraBoards/runJiraBoardsAnalyze do.
func jiraConnectFactory(cfg *config.Config, database *db.DB) tools.JiraConnectFactory {
	return func(account db.JiraAccount) (tools.JiraConnect, error) {
		client, err := jiraAccountClient(cfg, account)
		if err != nil {
			return tools.JiraConnect{}, err
		}
		analyzer := jira.NewBoardAnalyzer(client, database, newAIClient(cfg, cfg.DBPath()), account.ID)
		analyzer.SetLanguage(cfg.Digest.Language)
		return tools.JiraConnect{Client: client, Profiler: analyzer}, nil
	}
}
```

In `buildToolRegistry`:

```go
	reg := tools.New(database)
	regTools := []*tools.Tool{
		tools.NewCreateTarget(),
		tools.NewCreateJiraIssue(jiraClientFactory(cfg)),
	}
	regTools = append(regTools, tools.JiraWriteTools(jiraWriteClientFactory(cfg))...)
	regTools = append(regTools,
		tools.NewConnectJiraBoard(jiraConnectFactory(cfg, database)),
		tools.NewCreateTrack(),
		tools.NewCreateIdea(),
		tools.NewRemindMe(),
		tools.NewBriefContext(),
	)
```

- [ ] **Step 9: Pin the new tools**

In `cmd/actions_registry_test.go`, add after the `reactionTools` declaration:

```go
	jiraWrites := []string{"add_jira_comment", "transition_jira_issue", "assign_jira_issue", "update_jira_issue"}
```

and extend the assertions:

```go
	main := names("main")
	for _, w := range append([]string{"create_target", "create_jira_issue", "connect_jira_board"}, jiraWrites...) {
		assert.True(t, main[w], "write tool %s missing on main", w)
	}
```

```go
	for _, w := range jiraWrites {
		assert.True(t, target[w], "%s is offered on the target surface", w)
		tool, ok := reg.Get(w)
		require.True(t, ok)
		assert.True(t, tool.External, "%s leaves the machine (AGENT-03)", w)
	}
```

```go
	for _, w := range jiraWrites {
		assert.False(t, reaction[w], "%s has no reacted message to act on", w)
	}
```

(Task 19 rewrites this test's reaction-tool expectations; keep them as they are here.)

- [ ] **Step 10: Run, lint, commit**

Run: `go test ./cmd -run TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces && go test ./internal/tools ./internal/db -run 'Jira'`
Expected: PASS.
Run: `make lint-diff` — no new issues (split a function if the complexity gate complains; do not re-baseline).

```bash
git add internal/db/jira_issue_lookup.go internal/db/jira_issue_lookup_test.go internal/tools/jira_write.go internal/tools/jira_write_test.go cmd/actions_registry.go cmd/actions_registry_test.go
git commit -m "feat(tools): add_jira_comment, transition/assign/update_jira_issue write tools

External, main+target, through Propose/Apply; the local mirror row is
refreshed after apply by merging into the stored row.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

## Task 19: Widen local tools + contracts + generic card

**Files:**
- Modify: `internal/tools/ideas.go`, `internal/tools/tracks.go`, `internal/tools/remind.go`
- Modify: `internal/tools/ideas_test.go`, `internal/tools/tracks_test.go`, `internal/tools/remind_test.go`
- Modify: `cmd/actions_registry_test.go`
- Modify (replace whole file): `internal/chat/actions_contract.go` (created by Task 5)
- Create: `internal/chat/actions_contract_pin_test.go`, `internal/chat/testdata/actions_contract_main.txt`, `internal/chat/testdata/actions_contract_target.txt`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Actions/AgentToolsContract.swift`, `WatchtowerDesktop/Tests/Core/AgentToolsContractTests.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Actions/ReactionToolCatalog.swift`, `WatchtowerDesktop/Tests/Core/ReactionToolCatalogTests.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Chat/AgentActionCardView.swift`, `WatchtowerDesktop/Tests/AgentActionCardViewTests.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatToolCatalog+Actions.swift`, `WatchtowerDesktop/Tests/Core/ChatToolCatalogActionsTests.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatToolCatalog.swift` (created by Task 13 — two call sites only)
- Modify: `docs/inventory/agent-actions.md`, `docs/inventory/reaction-commands.md` (changelog entries)

**Interfaces:**
- Consumes: Task 5 `func ActionsContract(surface string) string` (package `chat`); Task 13 `ChatToolCatalog.label(name:args:) -> String` / `.icon(name:) -> String`, where `args` is the raw JSON string of the `tool_start` event's `args` (the `AgentAction.argsJSON` shape); Task 18 tool names/args/result shape.
- Produces:
  - `create_idea`, `create_track`: `Surfaces: ["reaction", "main"]`; `remind_me`: `Surfaces: ["reaction", "main"]` + optional `message_ref` arg (`<channel_id>@<message_ts>`), used only off the reaction path.
  - `chat.ActionsContract("main"|"target")` byte-identical to Swift `AgentToolsContract.promptBlock(surface: .main|.target)`; both pinned to `internal/chat/testdata/actions_contract_{main,target}.txt` (file content = contract + one trailing `\n`); any other surface → `""`.
  - `ReactionToolCatalog` entries for the four Jira write tools (`alwaysAsks: true`, destination `Jira`); NOT added to `ReactionDictionaryTools.all`.
  - `AgentActionCardView`: an applied row with a `url` in `result_json` renders `Link(label ?? key ?? url)`; summary lines for the four Jira tools.
  - `ChatToolCatalog.actionLabel(name:args:) -> String?`, `.actionIcon(name:) -> String?` (package), consulted first by `label`/`icon`.

**Owner-visible consequence to state in the PR (do not silently decide otherwise):** migration 00065 seeded `create_idea` and `remind_me` with trust `execute` (an owner call for the reaction path). Trust is per tool, not per surface, so in the main chat those two now apply immediately (a done-chip, no Approve card) unless the owner flips them to `ask` in Settings. `create_track` stays `ask`. This reverses the 2026-09-12 "reaction-path only" decision recorded in `docs/inventory/reaction-commands.md` — the spec (§8) makes that call; the changelog entry below records it.

- [ ] **Step 1: Failing Go tests for the widened tools**

In `internal/tools/ideas_test.go` line 117, `internal/tools/tracks_test.go` line 60 and `internal/tools/remind_test.go` line 59, replace

```go
	assert.Equal(t, []string{"reaction"}, tool.Surfaces, "reaction-path only")
```

with

```go
	assert.ElementsMatch(t, []string{"reaction", "main"}, tool.Surfaces, "reaction path + main chat; never the target chat (TGT-BRIEF-01 axis 3)")
```

Append to `internal/tools/remind_test.go`:

```go
// Off the reaction path the binding's ContextID is a chat context, never a
// message ref: the reminder carries the model's explicit message_ref (or none).
func TestRemindMe_MainChatUsesExplicitMessageRefOnly(t *testing.T) {
	d := openDB(t)
	tool := NewRemindMe()
	for _, tc := range []struct {
		args, want string
	}{
		{`{"remind_at":"2999-01-01T09:00:00Z","message_ref":"1:C9@123.45","reason":"r"}`, "1:C9@123.45"},
		{`{"remind_at":"2999-01-02T09:00:00Z","reason":"r"}`, ""},
	} {
		require.NoError(t, tool.Validate(context.Background(), d, json.RawMessage(tc.args)))
		res, err := tool.Execute(context.Background(), d, Call{ActionID: 1, Args: json.RawMessage(tc.args),
			Binding: Binding{Surface: "main", ConversationID: 4, ContextType: "", ContextID: "conv-context"}})
		require.NoError(t, err)
		id := res.(map[string]any)["reminder_id"].(int64)
		due, err := d.ListDueReminders("3000-01-01T00:00:00Z")
		require.NoError(t, err)
		for _, r := range due {
			if r.ID == id {
				assert.Equal(t, tc.want, r.MessageRef)
			}
		}
	}
}

// REACT-02: on the reaction path the reacted message is the ref, whatever
// the composed arguments say.
func TestRemindMe_ReactionPathIgnoresModelMessageRef(t *testing.T) {
	d := openDB(t)
	args := json.RawMessage(`{"remind_at":"2999-01-01T09:00:00Z","message_ref":"1:CX@9.9","reason":"r"}`)
	res, err := NewRemindMe().Execute(context.Background(), d, Call{ActionID: 1, Args: args,
		Binding: Binding{Surface: "reaction", ContextType: "reaction", ContextID: "1:C9@123.45"}})
	require.NoError(t, err)
	due, err := d.ListDueReminders("3000-01-01T00:00:00Z")
	require.NoError(t, err)
	require.Len(t, due, 1)
	assert.Equal(t, res.(map[string]any)["reminder_id"], due[0].ID)
	assert.Equal(t, "1:C9@123.45", due[0].MessageRef)
}

func TestRemindMe_ValidateRejectsMalformedMessageRef(t *testing.T) {
	err := NewRemindMe().Validate(context.Background(), openDB(t),
		json.RawMessage(`{"remind_at":"2999-01-01T09:00:00Z","message_ref":"not a ref","reason":"r"}`))
	var ve *ValidationError
	require.ErrorAs(t, err, &ve)
	assert.Contains(t, ve.Msg, "message_ref")
}
```

Also in `TestRemindMe_ExecuteInsertsReminderWithRef` nothing changes (it binds `Surface: "reaction"`). In `TestRemindMe_OffsetPastInUTCIsDue` the binding has no surface — it only asserts the row count, so it keeps passing.

Run: `go test ./internal/tools -run 'TestCreateIdea|TestCreateTrack|TestRemindMe'`
Expected: FAIL — surfaces are `["reaction"]`; `message_ref` is an unknown field.

- [ ] **Step 2: Widen the tools**

`internal/tools/ideas.go` — in `NewCreateIdea` replace the `Surfaces` comment + line with:

```go
		// The reaction path (REACT-02 binds the reacted message) and the main
		// chat, where the owner asks for it directly. Never the target chat:
		// its mandate forbids creating work outside the target's vertical line
		// (TGT-BRIEF-01 axis 3).
		Surfaces: []string{"reaction", "main"},
```

`internal/tools/tracks.go` — same replacement in `NewCreateTrack`, and fix its doc comment's last sentence to: `Visible on the reaction path and in the main chat.`

`internal/tools/remind.go` — args, doc, surfaces, validation, and the ref rule:

```go
type remindMeArgs struct {
	RemindAt   string `json:"remind_at" jsonschema:"when to resurface this: RFC 3339 with a timezone offset or Z (e.g. 2026-09-07T09:00:00+02:00), or owner-local YYYY-MM-DDTHH:MM; stored as UTC"`
	Note       string `json:"note,omitempty" jsonschema:"a short note about what to follow up on"`
	MessageRef string `json:"message_ref,omitempty" jsonschema:"optional: the Slack message this is about, as <channel_id>@<message_ts> (e.g. 1:C0123@1712345678.000100)"`
	Reason     string `json:"reason" jsonschema:"one sentence for the owner"`
}

// messageRefRE is the "<channel_id>@<message_ts>" shape the reaction binding
// writes (channel ids are namespaced "<account>:<raw>").
var messageRefRE = regexp.MustCompile(`^[^@\s]+@\d+\.\d+$`)

// reminderRef picks the stored message ref. On the reaction path it is the
// reacted message from the binding and nothing else (REACT-02: no invented
// provenance); elsewhere the binding's ContextID is a chat context, so only
// the model's explicit message_ref (or none) is used.
func reminderRef(a remindMeArgs, b Binding) string {
	if b.Surface == "reaction" {
		return b.ContextID
	}
	return strings.TrimSpace(a.MessageRef)
}
```

(add `"regexp"` to the imports), in `NewRemindMe`:

```go
		Description: "Set a reminder that resurfaces in the Inbox at a chosen time, optionally about one Slack message.",
		...
		// The reaction path (REACT-02 binds the reacted message) and the main
		// chat; never the target chat (TGT-BRIEF-01 axis 3).
		Surfaces: []string{"reaction", "main"},
```

in `Validate`, after the `normalizeRemindAt` check:

```go
			if ref := strings.TrimSpace(a.MessageRef); ref != "" && !messageRefRE.MatchString(ref) {
				return &ValidationError{Msg: fmt.Sprintf("message_ref %q must look like <channel_id>@<message_ts>", ref)}
			}
```

and in `Execute`:

```go
			id, err := d.InsertReminder(db.Reminder{
				MessageRef: reminderRef(a, call.Binding),
				Note:       strings.TrimSpace(a.Note),
				RemindAt:   remindAt,
			})
```

Update the `NewRemindMe` doc comment to: `NewRemindMe builds the remind_me write tool: a reminder that resurfaces at a chosen time — about the reacted message on the reaction path (REACT-02), or an optional explicit message_ref in the main chat.`

Run: `go test ./internal/tools -run 'TestCreateIdea|TestCreateTrack|TestRemindMe' && go test ./internal/reactioncmd`
Expected: PASS (the reaction compose guide never mentions `message_ref`, and the reaction path ignores it anyway).

- [ ] **Step 3: Rewrite the registry pin's reaction-tool expectations**

In `cmd/actions_registry_test.go` replace

```go
	reactionTools := []string{"create_track", "create_idea", "remind_me", "brief_context"}
```

with

```go
	reactionTools := []string{"create_track", "create_idea", "remind_me", "brief_context"}
	// Spec 2026-09-26 §8: three reaction tools widen to the main chat; the
	// target chat still gets none (TGT-BRIEF-01 axis 3); brief_context stays
	// reaction-only (its summary needs a reacted thread).
	mainLocalTools := []string{"create_track", "create_idea", "remind_me"}
```

replace the main-surface loop

```go
	for _, w := range reactionTools {
		assert.False(t, main[w], "%s is reaction-path only; in chat it would create work with no message to bind to", w)
	}
```

with

```go
	for _, w := range mainLocalTools {
		assert.True(t, main[w], "%s is offered in the main chat", w)
	}
	assert.False(t, main["brief_context"], "brief_context is reaction-path only")
```

The target and reaction loops stay unchanged.

Run: `go test ./cmd -run TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces`
Expected: PASS.

- [ ] **Step 4: Write the shared contract fixtures**

Create `internal/chat/testdata/actions_contract_main.txt` (exactly these lines, ending with one newline):

```text
=== AGENT ACTIONS ===
You have write TOOLS. A write tool never changes anything by itself: calling it records a PROPOSAL and returns a receipt with an action id and a status. The owner sees a card in this chat and approves or rejects it; only then does the app execute it. A tool the owner has pre-approved runs at once, and its receipt already says "applied".
Write tools on this surface:
- create_target — propose a new task or reminder (a task with a due date) in the owner's task list.
- create_jira_issue — propose a Jira issue on a connected site.
- connect_jira_board — propose watching a Jira board so its issues start syncing; pass board_name when the project has several boards, and ask the owner when the project is ambiguous.
- add_jira_comment — propose a comment on an existing Jira issue.
- transition_jira_issue — propose moving a Jira issue to another status; pass the target status name.
- assign_jira_issue — propose assigning a Jira issue to "me" (the owner), an email, or a display name.
- update_jira_issue — propose changing a Jira issue's summary, priority, labels, or due date.
- create_track — propose a track that follows a topic over time.
- create_idea — capture an idea in the owner's ideas registry.
- remind_me — set a reminder that resurfaces in the Inbox at a chosen time; pass message_ref when it is about one Slack message.
Rules:
- Read the receipt. Status "pending": tell the owner what you proposed and that it awaits their approval; never claim it is done, created, or sent. Status "applied": report what was done.
- One proposal per item; never propose the same item twice in one turn.
- For a new Jira issue, call list_jira_projects FIRST to pick a synced project and a known issue type. When the project or type is ambiguous, ask the owner instead of guessing.
- For an existing Jira issue, pass its key (e.g. ABC-123); call get_jira_issue first when you are not sure of its current status, assignee, or fields.
- get_action <id> answers what happened to a proposal; an ACTIONS SINCE YOUR LAST MESSAGE block at the top of the owner's message reports outcomes since your last turn.
```

Create `internal/chat/testdata/actions_contract_target.txt`:

```text
=== AGENT ACTIONS ===
You have write TOOLS. A write tool never changes anything by itself: calling it records a PROPOSAL and returns a receipt with an action id and a status. The owner sees a card in this chat and approves or rejects it; only then does the app execute it. A tool the owner has pre-approved runs at once, and its receipt already says "applied".
Write tools on this surface:
- create_jira_issue — propose a Jira issue on a connected site.
- add_jira_comment — propose a comment on an existing Jira issue.
- transition_jira_issue — propose moving a Jira issue to another status; pass the target status name.
- assign_jira_issue — propose assigning a Jira issue to "me" (the owner), an email, or a display name.
- update_jira_issue — propose changing a Jira issue's summary, priority, labels, or due date.
Rules:
- Read the receipt. Status "pending": tell the owner what you proposed and that it awaits their approval; never claim it is done, created, or sent. Status "applied": report what was done.
- One proposal per item; never propose the same item twice in one turn.
- For a new Jira issue, call list_jira_projects FIRST to pick a synced project and a known issue type. When the project or type is ambiguous, ask the owner instead of guessing.
- For an existing Jira issue, pass its key (e.g. ABC-123); call get_jira_issue first when you are not sure of its current status, assignee, or fields.
- get_action <id> answers what happened to a proposal; an ACTIONS SINCE YOUR LAST MESSAGE block at the top of the owner's message reports outcomes since your last turn.

Changes to THIS task and its vertical line still go through `watchtower-action` blocks (TASK ACTIONS above); Jira work goes through the Jira tools. Never create other Watchtower tasks from here — report the finding in prose instead.
```

Verify each file ends with exactly one newline: `tail -c 1 internal/chat/testdata/actions_contract_main.txt | xxd` → `0a`, and `tail -c 2 … | xxd` must not be `0a0a`.

- [ ] **Step 5: Failing Go pin test**

Create `internal/chat/actions_contract_pin_test.go`:

```go
package chat

import (
	"os"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// The actions contract is a Go↔Swift dual path (spec §4.1 item 4): Go owns
// the main chat's prompt, Swift's AgentToolsContract still feeds the target
// chat. Both sides compare against the SAME fixture files, so an edit to one
// copy without the other fails on the side that drifted.
func TestActionsContract_MatchesSharedFixtures(t *testing.T) {
	for _, surface := range []string{"main", "target"} {
		raw, err := os.ReadFile("testdata/actions_contract_" + surface + ".txt")
		require.NoError(t, err)
		want := strings.TrimSuffix(string(raw), "\n")
		assert.Equal(t, want, ActionsContract(surface), surface)
	}
	assert.Empty(t, ActionsContract("meeting"), "a draft-only surface gets no actions contract (AGENT-04)")
}

func TestActionsContract_ListsEveryWriteToolOfTheSurface(t *testing.T) {
	main := ActionsContract("main")
	for _, tool := range []string{"create_target", "create_jira_issue", "connect_jira_board", "add_jira_comment",
		"transition_jira_issue", "assign_jira_issue", "update_jira_issue", "create_track", "create_idea", "remind_me"} {
		assert.Contains(t, main, "- "+tool+" — ", tool)
	}
	target := ActionsContract("target")
	for _, tool := range []string{"create_target", "connect_jira_board", "create_track", "create_idea", "remind_me"} {
		assert.NotContains(t, target, "- "+tool+" — ", "%s is not offered on the target surface", tool)
	}
	assert.Contains(t, target, "watchtower-action")
}
```

Run: `go test ./internal/chat -run TestActionsContract_`
Expected: FAIL — Task 5's text differs from the fixtures.

- [ ] **Step 6: Replace `internal/chat/actions_contract.go`**

Replace the whole file with (keep any exported identifier Task 5 added *other than* `ActionsContract` by re-adding it below unchanged — Task 5's binding interface is only `ActionsContract(surface string) string`):

```go
package chat

import "strings"

// ActionsContract is the system-prompt block that teaches an action surface
// how write tools work. The Swift twin is
// WatchtowerCore/Services/Actions/AgentToolsContract.swift — byte-identical,
// pinned on both sides by testdata/actions_contract_{main,target}.txt. Any
// surface other than main/target is draft-only (AGENT-04) and gets "".
func ActionsContract(surface string) string {
	var tools []string
	switch surface {
	case "main":
		tools = mainActionTools
	case "target":
		tools = targetActionTools
	default:
		return ""
	}
	lines := make([]string, 0, len(actionsHeader)+len(tools)+len(actionsRules))
	lines = append(lines, actionsHeader...)
	lines = append(lines, tools...)
	lines = append(lines, actionsRules...)
	text := strings.Join(lines, "\n")
	if surface == "target" {
		text += "\n\n" + targetCoexistence
	}
	return text
}

var actionsHeader = []string{
	"=== AGENT ACTIONS ===",
	`You have write TOOLS. A write tool never changes anything by itself: calling it records a PROPOSAL and returns a receipt with an action id and a status. The owner sees a card in this chat and approves or rejects it; only then does the app execute it. A tool the owner has pre-approved runs at once, and its receipt already says "applied".`,
	"Write tools on this surface:",
}

var jiraIssueWriteTools = []string{
	"- add_jira_comment — propose a comment on an existing Jira issue.",
	"- transition_jira_issue — propose moving a Jira issue to another status; pass the target status name.",
	`- assign_jira_issue — propose assigning a Jira issue to "me" (the owner), an email, or a display name.`,
	"- update_jira_issue — propose changing a Jira issue's summary, priority, labels, or due date.",
}

var mainActionTools = concat(
	[]string{
		"- create_target — propose a new task or reminder (a task with a due date) in the owner's task list.",
		"- create_jira_issue — propose a Jira issue on a connected site.",
		"- connect_jira_board — propose watching a Jira board so its issues start syncing; pass board_name when the project has several boards, and ask the owner when the project is ambiguous.",
	},
	jiraIssueWriteTools,
	[]string{
		"- create_track — propose a track that follows a topic over time.",
		"- create_idea — capture an idea in the owner's ideas registry.",
		"- remind_me — set a reminder that resurfaces in the Inbox at a chosen time; pass message_ref when it is about one Slack message.",
	},
)

var targetActionTools = concat(
	[]string{"- create_jira_issue — propose a Jira issue on a connected site."},
	jiraIssueWriteTools,
)

var actionsRules = []string{
	"Rules:",
	`- Read the receipt. Status "pending": tell the owner what you proposed and that it awaits their approval; never claim it is done, created, or sent. Status "applied": report what was done.`,
	"- One proposal per item; never propose the same item twice in one turn.",
	"- For a new Jira issue, call list_jira_projects FIRST to pick a synced project and a known issue type. When the project or type is ambiguous, ask the owner instead of guessing.",
	"- For an existing Jira issue, pass its key (e.g. ABC-123); call get_jira_issue first when you are not sure of its current status, assignee, or fields.",
	"- get_action <id> answers what happened to a proposal; an ACTIONS SINCE YOUR LAST MESSAGE block at the top of the owner's message reports outcomes since your last turn.",
}

const targetCoexistence = "Changes to THIS task and its vertical line still go through `watchtower-action` blocks (TASK ACTIONS above); " +
	"Jira work goes through the Jira tools. Never create other Watchtower tasks from here — report the finding in prose instead."

func concat(parts ...[]string) []string {
	var out []string
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}
```

Run: `go test ./internal/chat`
Expected: PASS — including Task 5's prompt golden/budget tests. If Task 5 has a prompt golden file, regenerate it with that test's documented `-update` flag and review the diff: it must change only inside the AGENT ACTIONS block.

- [ ] **Step 7: Go checkpoint**

Run: `go test ./internal/tools ./internal/chat ./internal/reactioncmd && go test ./cmd -run TestBuildToolRegistry`
Expected: PASS. (The task's single commit is Step 16.)

- [ ] **Step 8: Failing Swift contract pin**

Append to `WatchtowerDesktop/Tests/Core/AgentToolsContractTests.swift` (inside the class):

```swift
    // MARK: - Shared Go fixtures (dual path, spec §4.1 item 4)

    /// `internal/chat/testdata` — the files Go's
    /// `TestActionsContract_MatchesSharedFixtures` pins `chat.ActionsContract`
    /// to. Both sides read the SAME files, so a one-sided edit fails here or there.
    private static func goFixture(_ surface: String) throws -> String {
        let path = URL(fileURLWithPath: #filePath)   // …/WatchtowerDesktop/Tests/Core/<this file>
            .deletingLastPathComponent()              // …/Tests/Core
            .deletingLastPathComponent()              // …/Tests
            .deletingLastPathComponent()              // …/WatchtowerDesktop
            .deletingLastPathComponent()              // repo root
            .appendingPathComponent("internal/chat/testdata/actions_contract_\(surface).txt")
        let raw = try String(contentsOf: path, encoding: .utf8)
        return raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
    }

    func testPromptBlocksMatchTheGoFixturesByteForByte() throws {
        XCTAssertEqual(AgentToolsContract.promptBlock(surface: .main), try Self.goFixture("main"))
        XCTAssertEqual(AgentToolsContract.promptBlock(surface: .target), try Self.goFixture("target"))
    }

    func testTargetBlockOffersTheJiraIssueWrites() {
        let block = AgentToolsContract.promptBlock(surface: .target)
        for tool in ["add_jira_comment", "transition_jira_issue", "assign_jira_issue", "update_jira_issue"] {
            XCTAssertTrue(block.contains("- \(tool) — "), tool)
        }
        for tool in ["create_track", "create_idea", "remind_me"] {
            XCTAssertFalse(block.contains("- \(tool) — "), "\(tool) is main-chat only")
        }
    }
```

Run: `make test-swift FILTER=AgentToolsContractTests`
Expected: FAIL on the two new tests.

- [ ] **Step 9: Rewrite `AgentToolsContract.promptBlock`**

Replace `promptBlock(surface:)` in `AgentToolsContract.swift` (keep `noToolsBlock` and `actionsSinceLastTurnBlock` unchanged):

```swift
    /// Byte-identical to Go `chat.ActionsContract` (`internal/chat/actions_contract.go`),
    /// pinned on both sides by `internal/chat/testdata/actions_contract_{main,target}.txt`.
    /// Change both copies and the fixture together.
    package static func promptBlock(surface: AgentSurface) -> String {
        let tools: [String]
        switch surface {
        case .main: tools = mainTools
        case .target: tools = targetTools
        }
        var text = (header + tools + rules).joined(separator: "\n")
        if surface == .target {
            text += "\n\n" + targetCoexistence
        }
        return text
    }

    private static let header = [
        "=== AGENT ACTIONS ===",
        "You have write TOOLS. A write tool never changes anything by itself: calling it records a PROPOSAL and "
            + "returns a receipt with an action id and a status. The owner sees a card in this chat and approves or "
            + "rejects it; only then does the app execute it. A tool the owner has pre-approved runs at once, and its "
            + "receipt already says \"applied\".",
        "Write tools on this surface:"
    ]

    private static let jiraIssueWriteTools = [
        "- add_jira_comment — propose a comment on an existing Jira issue.",
        "- transition_jira_issue — propose moving a Jira issue to another status; pass the target status name.",
        "- assign_jira_issue — propose assigning a Jira issue to \"me\" (the owner), an email, or a display name.",
        "- update_jira_issue — propose changing a Jira issue's summary, priority, labels, or due date."
    ]

    private static let mainTools = [
        "- create_target — propose a new task or reminder (a task with a due date) in the owner's task list.",
        "- create_jira_issue — propose a Jira issue on a connected site.",
        "- connect_jira_board — propose watching a Jira board so its issues start syncing; pass board_name when "
            + "the project has several boards, and ask the owner when the project is ambiguous."
    ] + jiraIssueWriteTools + [
        "- create_track — propose a track that follows a topic over time.",
        "- create_idea — capture an idea in the owner's ideas registry.",
        "- remind_me — set a reminder that resurfaces in the Inbox at a chosen time; pass message_ref when it is "
            + "about one Slack message."
    ]

    private static let targetTools = ["- create_jira_issue — propose a Jira issue on a connected site."]
        + jiraIssueWriteTools

    private static let rules = [
        "Rules:",
        "- Read the receipt. Status \"pending\": tell the owner what you proposed and that it awaits their approval; "
            + "never claim it is done, created, or sent. Status \"applied\": report what was done.",
        "- One proposal per item; never propose the same item twice in one turn.",
        "- For a new Jira issue, call list_jira_projects FIRST to pick a synced project and a known issue type. "
            + "When the project or type is ambiguous, ask the owner instead of guessing.",
        "- For an existing Jira issue, pass its key (e.g. ABC-123); call get_jira_issue first when you are not sure "
            + "of its current status, assignee, or fields.",
        "- get_action <id> answers what happened to a proposal; an ACTIONS SINCE YOUR LAST MESSAGE block at the "
            + "top of the owner's message reports outcomes since your last turn."
    ]

    private static let targetCoexistence = "Changes to THIS task and its vertical line still go through "
        + "`watchtower-action` blocks (TASK ACTIONS above); Jira work goes through the Jira tools. Never create "
        + "other Watchtower tasks from here — report the finding in prose instead."
```

Update the doc comment above `enum AgentToolsContract` to say it teaches that write tools "create PROPOSALS the owner approves in the chat, unless the owner pre-approved the tool".

Run: `make test-swift FILTER=AgentToolsContractTests`
Expected: PASS (the existing `testMainBlockListsBothWriteTools` still finds `never claim` / `awaits their approval`).

- [ ] **Step 10: Failing Swift catalog + card tests**

Append to `WatchtowerDesktop/Tests/Core/ReactionToolCatalogTests.swift` (inside the class):

```swift
    /// The Jira issue writes are chat-only (never in the reaction dictionary)
    /// but render on the same agent-action card, so they need human names too.
    func testJiraIssueWriteToolsHaveHumanNamesAndAlwaysAsk() {
        let expected = [
            "add_jira_comment": "Comment on a Jira issue",
            "transition_jira_issue": "Move a Jira issue",
            "assign_jira_issue": "Assign a Jira issue",
            "update_jira_issue": "Update a Jira issue"
        ]
        for (tool, title) in expected {
            XCTAssertEqual(ReactionToolCatalog.title(for: tool), title)
            XCTAssertEqual(ReactionToolCatalog.info(for: tool)?.alwaysAsks, true, "\(tool) is External (AGENT-03)")
            XCTAssertFalse(ReactionDictionaryTools.all.contains(tool), "\(tool) is not a reaction tool")
        }
    }
```

Append to `WatchtowerDesktop/Tests/AgentActionCardViewTests.swift` (inside the class):

```swift
    func testJiraIssueWriteSummaryLines() throws {
        func lines(_ tool: String, _ args: String) throws -> [String] {
            let action = try row { db in try TestDatabase.insertAgentAction(db, tool: tool, external: true, argsJSON: args) }
            return AgentActionCardView.summaryLines(for: action)
        }
        XCTAssertEqual(try lines("add_jira_comment", #"{"key":"ABC-7","body":"Ship it","reason":"r"}"#),
                       ["Issue: ABC-7", "Ship it"])
        XCTAssertEqual(try lines("transition_jira_issue", #"{"key":"ABC-7","status":"Done","reason":"r"}"#),
                       ["Issue: ABC-7 → Done"])
        XCTAssertEqual(try lines("assign_jira_issue", #"{"key":"ABC-7","assignee":"me","reason":"r"}"#),
                       ["Issue: ABC-7 · Assignee: me"])
        XCTAssertEqual(
            try lines("update_jira_issue",
                      #"{"key":"ABC-7","summary":"New","priority":"High","labels_add":["a","b"],"labels_remove":["c"],"due_date":"2026-10-01","reason":"r"}"#),
            ["Issue: ABC-7", "Summary: New", "Priority: High", "Add labels: a, b", "Remove labels: c", "Due: 2026-10-01"])
    }

    /// Any applied row with a url renders as a link titled by `label`, then
    /// `key`, then the url itself — no per-tool code for new tools.
    func testAppliedResultWithURLRendersGenericLabelledLink() throws {
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "transition_jira_issue", external: true, status: "applied",
                                               resultJSON: #"{"key":"ABC-7","url":"https://acme.atlassian.net/browse/ABC-7","label":"ABC-7 → Done"}"#,
                                               appliedAt: "2026-09-26T10:00:00Z")
        }
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        let link = try view.inspect().find(ViewType.Link.self)
        XCTAssertEqual(try link.labelView().text().string(), "ABC-7 → Done")
        XCTAssertEqual(try link.url(), URL(string: "https://acme.atlassian.net/browse/ABC-7"))
    }

    func testAppliedJiraIssueWithoutLabelStillShowsTheKey() throws {
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "create_jira_issue", external: true, status: "applied",
                                               resultJSON: #"{"key":"ABC-8","url":"https://acme.atlassian.net/browse/ABC-8"}"#,
                                               appliedAt: "2026-09-26T10:00:00Z")
        }
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        XCTAssertEqual(try view.inspect().find(ViewType.Link.self).labelView().text().string(), "ABC-8")
    }
```

Create `WatchtowerDesktop/Tests/Core/ChatToolCatalogActionsTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

/// Step labels for the write tools a chat turn can call (spec §8): the step
/// block names what was PROPOSED, never claims it happened.
final class ChatToolCatalogActionsTests: XCTestCase {
    func testJiraWriteLabels() {
        XCTAssertEqual(ChatToolCatalog.label(name: "add_jira_comment", args: #"{"key":"ABC-7","body":"x"}"#),
                       "Proposing a comment on ABC-7")
        XCTAssertEqual(ChatToolCatalog.label(name: "transition_jira_issue", args: #"{"key":"ABC-7","status":"Done"}"#),
                       "Proposing ABC-7 → Done")
        XCTAssertEqual(ChatToolCatalog.label(name: "assign_jira_issue", args: #"{"key":"ABC-7","assignee":"me"}"#),
                       "Proposing to assign ABC-7 to me")
        XCTAssertEqual(ChatToolCatalog.label(name: "update_jira_issue", args: #"{"key":"ABC-7","priority":"High"}"#),
                       "Proposing an update to ABC-7")
    }

    func testLocalWriteLabels() {
        XCTAssertEqual(ChatToolCatalog.label(name: "create_idea", args: #"{"essence":"x"}"#), "Saving an idea")
        XCTAssertEqual(ChatToolCatalog.label(name: "create_track", args: #"{"text":"Payments migration"}"#),
                       "Proposing a track: Payments migration")
        XCTAssertEqual(ChatToolCatalog.label(name: "remind_me", args: #"{"remind_at":"2026-10-01T09:00"}"#),
                       "Setting a reminder for 2026-10-01T09:00")
    }

    func testMalformedArgsStillLabelTheTool() {
        XCTAssertEqual(ChatToolCatalog.label(name: "transition_jira_issue", args: "not json"), "Proposing an issue transition")
    }

    func testIcons() {
        XCTAssertEqual(ChatToolCatalog.icon(name: "add_jira_comment"), "text.bubble")
        XCTAssertEqual(ChatToolCatalog.icon(name: "transition_jira_issue"), "arrow.right.circle")
        XCTAssertEqual(ChatToolCatalog.icon(name: "assign_jira_issue"), "person.crop.circle.badge.plus")
        XCTAssertEqual(ChatToolCatalog.icon(name: "update_jira_issue"), "square.and.pencil")
        XCTAssertEqual(ChatToolCatalog.icon(name: "create_idea"), "lightbulb")
        XCTAssertEqual(ChatToolCatalog.icon(name: "create_track"), "binoculars")
        XCTAssertEqual(ChatToolCatalog.icon(name: "remind_me"), "alarm")
    }
}
```

Run: `make test-swift FILTER=ReactionToolCatalogTests`, `make test-swift FILTER=AgentActionCardViewTests`, `make test-swift FILTER=ChatToolCatalogActionsTests`
Expected: FAIL (build errors / wrong titles / no link label).

- [ ] **Step 11: Catalog entries**

In `ReactionToolCatalog.swift`, add to `entries` after `connect_jira_board`:

```swift
        // Chat-only Jira issue writes (spec 2026-09-26 §8) — External, so they
        // always land behind Approve; not in ReactionDictionaryTools.all.
        "add_jira_comment": ReactionToolInfo(
            title: "Comment on a Jira issue",
            summary: "Posts a comment on an existing issue",
            destination: "Jira",
            alwaysAsks: true
        ),
        "transition_jira_issue": ReactionToolInfo(
            title: "Move a Jira issue",
            summary: "Moves an existing issue to another status",
            destination: "Jira",
            alwaysAsks: true
        ),
        "assign_jira_issue": ReactionToolInfo(
            title: "Assign a Jira issue",
            summary: "Sets an existing issue's assignee",
            destination: "Jira",
            alwaysAsks: true
        ),
        "update_jira_issue": ReactionToolInfo(
            title: "Update a Jira issue",
            summary: "Edits an existing issue's summary, priority, labels or due date",
            destination: "Jira",
            alwaysAsks: true
        )
```

- [ ] **Step 12: Card rendering**

In `AgentActionCardView.swift`, change the `default:` branch of `summaryLines(for:)` to:

```swift
        default:
            return waveTwoSummaryLines(for: action) ?? jiraIssueWriteSummaryLines(for: action) ?? [action.argsJSON]
```

add:

```swift
    /// The four existing-issue Jira writes (spec 2026-09-26 §8); nil for any other tool.
    private static func jiraIssueWriteSummaryLines(for action: AgentAction) -> [String]? {
        let key = action.argString("key") ?? "?"
        switch action.tool {
        case "add_jira_comment":
            return ["Issue: \(key)", action.argString("body") ?? ""]
        case "transition_jira_issue":
            return ["Issue: \(key) → \(action.argString("status") ?? "?")"]
        case "assign_jira_issue":
            return ["Issue: \(key) · Assignee: \(action.argString("assignee") ?? "?")"]
        case "update_jira_issue":
            var lines = ["Issue: \(key)"]
            let fields: [(String, String)] = [("summary", "Summary"), ("priority", "Priority"),
                                              ("labels_add", "Add labels"), ("labels_remove", "Remove labels"),
                                              ("due_date", "Due")]
            for (arg, title) in fields {
                if let value = action.argString(arg), !value.isEmpty { lines.append("\(title): \(value)") }
            }
            return lines
        default:
            return nil
        }
    }
```

and replace the first branch of `outcome`:

```swift
        if action.status == "applied", let url = action.resultString("url"), let link = URL(string: url) {
            // Generic: any tool that returns a url (+ optional label) links it —
            // label, then key, then the url itself (spec 2026-09-26 §8).
            Link(action.resultString("label") ?? action.resultString("key") ?? url, destination: link).font(.callout)
        } else if action.status == "applied", let id = action.resultString("target_id") {
```

(the remaining `else if` branches and the warning block stay as they are).

- [ ] **Step 13: ChatToolCatalog labels**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatToolCatalog+Actions.swift`:

```swift
import Foundation

/// Step labels/icons for the chat's write tools (spec 2026-09-26 §8). A write
/// call only records a proposal (AGENT-01), so the label says "Proposing…" —
/// except for the tools the owner commonly pre-approves locally, whose card
/// shows the real outcome. `args` is the raw JSON of the `tool_start` event.
extension ChatToolCatalog {
    package static func actionLabel(name: String, args: String) -> String? {
        let object = (args.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        func arg(_ key: String) -> String? {
            guard let value = object?[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return value
        }
        switch name {
        case "add_jira_comment":
            return arg("key").map { "Proposing a comment on \($0)" } ?? "Proposing a Jira comment"
        case "transition_jira_issue":
            guard let key = arg("key"), let status = arg("status") else { return "Proposing an issue transition" }
            return "Proposing \(key) → \(status)"
        case "assign_jira_issue":
            guard let key = arg("key"), let who = arg("assignee") else { return "Proposing an issue assignment" }
            return "Proposing to assign \(key) to \(who)"
        case "update_jira_issue":
            return arg("key").map { "Proposing an update to \($0)" } ?? "Proposing a Jira issue update"
        case "create_idea":
            return "Saving an idea"
        case "create_track":
            return arg("text").map { "Proposing a track: \($0)" } ?? "Proposing a track"
        case "remind_me":
            return arg("remind_at").map { "Setting a reminder for \($0)" } ?? "Setting a reminder"
        default:
            return nil
        }
    }

    package static func actionIcon(name: String) -> String? {
        switch name {
        case "add_jira_comment": return "text.bubble"
        case "transition_jira_issue": return "arrow.right.circle"
        case "assign_jira_issue": return "person.crop.circle.badge.plus"
        case "update_jira_issue": return "square.and.pencil"
        case "create_idea": return "lightbulb"
        case "create_track": return "binoculars"
        case "remind_me": return "alarm"
        default: return nil
        }
    }
}
```

In `ChatToolCatalog.swift` (Task 13), make the first statement of `label(name:args:)`:

```swift
        if let label = actionLabel(name: name, args: args) { return label }
```

and the first statement of `icon(name:)`:

```swift
        if let icon = actionIcon(name: name) { return icon }
```

If Task 13 already maps any of these seven names, delete its case — this file is the one mapping for write tools.

- [ ] **Step 14: Run the Swift tests**

Run, one at a time (never unfiltered in the inner loop):
`make test-swift FILTER=ReactionToolCatalogTests`
`make test-swift FILTER=AgentActionCardViewTests`
`make test-swift FILTER=ChatToolCatalogActionsTests`
`make test-swift FILTER=AgentToolsContractTests`
Expected: all PASS. Check `$?` explicitly (do not pipe through `tail`); XCTest failures print above the swift-testing summary.

- [ ] **Step 15: Inventory changelog entries**

Append to the `## Changelog` of `docs/inventory/agent-actions.md`:

```markdown
- 2026-09-26 (chat redesign, spec `docs/superpowers/specs/2026-09-26-chat-redesign-design.md` §8): four new `External` write tools on the main and target surfaces — `add_jira_comment`, `transition_jira_issue`, `assign_jira_issue`, `update_jira_issue` (`internal/tools/jira_write.go`), registered in `buildToolRegistry` and pinned by `TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces`. AGENT-01..06 unchanged: all four go through `Propose`/`Apply`; `transition_jira_issue`/`assign_jira_issue` make read-only Jira calls in `Validate` (GET transitions, user search) and never write there — the revoked-account marking happens only in `Execute` (`TestTransitionJiraIssue_ValidateReadFailureIsPlainErrorAndWritesNothing`); AGENT-03 holds (`TestJiraWriteTools_ExternalOnMainAndTargetWithReason`). `Execute` re-resolves the transition id and assignee at apply time, and refreshes the local `jira_issues` row by merging into the stored row (syncer-owned columns survive; failure → `result_json.warning`, never a failed action). Results carry `{key, url, label}`; the Desktop card now renders any applied `url` generically as a link titled `label` → `key` → url. The actions contract became a byte-identical Go (`chat.ActionsContract`) ↔ Swift (`AgentToolsContract.promptBlock`) dual path pinned by `internal/chat/testdata/actions_contract_{main,target}.txt` on both sides.
```

Append to the `## Changelog` of `docs/inventory/reaction-commands.md`:

```markdown
- 2026-09-26 (chat redesign, spec §8 — reverses the 2026-09-12 "reaction-path only" surface decision for three tools): `create_track`, `create_idea` and `remind_me` are now `Surfaces: ["reaction", "main"]` — the main chat may call them; the target chat still may not (TGT-BRIEF-01 axis 3); `brief_context` stays reaction-only. `remind_me` gains an optional `message_ref` argument (`<channel_id>@<message_ts>`), used only off the reaction path: on the reaction path the stored ref is the binding's reacted message whatever the arguments say, so **REACT-02 is unchanged** (`internal/tools/remind_test.go::TestRemindMe_ReactionPathIgnoresModelMessageRef`), and off it the binding's `ContextID` is never read as a message ref (`::TestRemindMe_MainChatUsesExplicitMessageRefOnly`). REMIND-01/02 unchanged. **Trust note:** trust is per tool, not per surface, so the 00065 seeds (`create_idea`/`remind_me` = `execute`, `create_track` = `ask`) now also apply in the main chat — a main-chat idea or reminder applies immediately unless the owner sets the tool to `ask`.
```

- [ ] **Step 16: Full-package verification, lint, commit**

Run:
- `go test ./internal/tools ./internal/chat ./internal/reactioncmd ./internal/jira ./internal/db -run 'Jira|Remind|Idea|Track|ActionsContract|Reaction'`
- `go test ./cmd -run 'TestBuildToolRegistry|TestActions_'`
- `make lint-diff`

Expected: all PASS, no new lint issues.

```bash
git add internal/tools/ideas.go internal/tools/tracks.go internal/tools/remind.go \
  internal/tools/ideas_test.go internal/tools/tracks_test.go internal/tools/remind_test.go \
  cmd/actions_registry_test.go \
  internal/chat/actions_contract.go internal/chat/actions_contract_pin_test.go \
  internal/chat/testdata/actions_contract_main.txt internal/chat/testdata/actions_contract_target.txt \
  WatchtowerDesktop/Sources/WatchtowerCore/Services/Actions/AgentToolsContract.swift \
  WatchtowerDesktop/Tests/Core/AgentToolsContractTests.swift \
  WatchtowerDesktop/Sources/WatchtowerCore/Services/Actions/ReactionToolCatalog.swift \
  WatchtowerDesktop/Tests/Core/ReactionToolCatalogTests.swift \
  WatchtowerDesktop/Sources/Views/Chat/AgentActionCardView.swift \
  WatchtowerDesktop/Tests/AgentActionCardViewTests.swift \
  WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatToolCatalog+Actions.swift \
  WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatToolCatalog.swift \
  WatchtowerDesktop/Tests/Core/ChatToolCatalogActionsTests.swift \
  docs/inventory/agent-actions.md docs/inventory/reaction-commands.md
git commit -m "feat(chat): widen idea/track/reminder tools to the main chat; pin the actions contract on both sides

create_idea/create_track/remind_me gain the main surface (remind_me takes
an optional message_ref off the reaction path; REACT-02 unchanged). The
actions contract is byte-identical in Go and Swift, pinned by shared
fixtures. The proposal card renders any applied url+label generically.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

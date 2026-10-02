package jira

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/db"
)

// scriptedAI is an ai.Provider whose QuerySync returns a fixed reply (or
// error) with fixed usage, recording each user message.
type scriptedAI struct {
	reply string
	err   error
	usage *ai.Usage
	calls []string
}

func (s *scriptedAI) Query(context.Context, string, string, string) (<-chan ai.StreamChunk, <-chan error, <-chan string) {
	panic("scriptedAI.Query: field discovery uses QuerySync only")
}

func (s *scriptedAI) QuerySync(_ context.Context, _, user, _ string) (string, *ai.Usage, error) {
	s.calls = append(s.calls, user)
	return s.reply, s.usage, s.err
}

// fieldsServer serves the Jira field list and the issue sample used by
// MapFieldsForBoard; any other path is a test failure.
func fieldsServer(t *testing.T, fieldsJSON, searchJSON string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/ex/jira/cloud1/rest/api/2/field":
			_, _ = w.Write([]byte(fieldsJSON))
		case "/ex/jira/cloud1/rest/api/3/search/jql":
			_, _ = w.Write([]byte(searchJSON))
		default:
			t.Errorf("unexpected request %s", r.URL.Path)
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

// DiscoverFields stores only custom fields, skips Service Desk "sd-" fields,
// tolerates a missing schema, and scopes every row to the account.
func TestDiscoverFields_StoresCustomFieldsOnly(t *testing.T) {
	d := openTestDB(t)
	srv := fieldsServer(t, `[
		{"id":"summary","name":"Summary","custom":false,"schema":{"type":"string"}},
		{"id":"customfield_1","name":"Story Points","custom":true,"schema":{"type":"number"}},
		{"id":"customfield_2","name":"SLA","custom":true,"schema":{"type":"sd-servicelevelagreement"}},
		{"id":"customfield_3","name":"Reviewers","custom":true,"schema":{"type":"array","items":"user"}},
		{"id":"customfield_4","name":"No schema","custom":true}
	]`, `{}`)
	fd := NewFieldDiscovery(newTestClient(t, srv.URL, "", "at"), d, nil, 1)

	got, err := fd.DiscoverFields(context.Background())
	require.NoError(t, err)
	ids := make([]string, len(got))
	for i, f := range got {
		ids[i] = f.ID
	}
	assert.Equal(t, []string{"customfield_1", "customfield_3", "customfield_4"}, ids)

	stored, err := d.GetJiraCustomFields(1)
	require.NoError(t, err)
	require.Len(t, stored, 3)
	byID := map[string]db.JiraCustomField{}
	for _, f := range stored {
		byID[f.ID] = f
	}
	assert.Equal(t, "array", byID["customfield_3"].FieldType)
	assert.Equal(t, "user", byID["customfield_3"].ItemsType)
	assert.Empty(t, byID["customfield_4"].FieldType)
	assert.False(t, fd.NeedsDiscovery(), "a fresh discovery is not stale")
}

// A failing field fetch is an error, not an empty discovery.
func TestDiscoverFields_FetchErrorPropagates(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	t.Cleanup(srv.Close)
	fd := NewFieldDiscovery(newTestClient(t, srv.URL, "", "at"), openTestDB(t), nil, 1)
	_, err := fd.DiscoverFields(context.Background())
	assert.ErrorContains(t, err, "fetching fields")
}

func seedCustomField(t *testing.T, d *db.DB, id, name, fieldType string, useful bool, hint string) {
	t.Helper()
	require.NoError(t, d.UpsertJiraCustomField(db.JiraCustomField{
		AccountID: 1, ID: id, Name: name, FieldType: fieldType, SyncedAt: time.Now().UTC().Format(time.RFC3339),
	}))
	if useful {
		require.NoError(t, d.UpdateJiraCustomFieldClassification(1, id, true, hint))
	}
}

// ClassifyFields parses a fenced LLM reply, writes is_useful/usage_hint per
// field and accumulates the call's usage.
func TestClassifyFields_WritesClassificationAndUsage(t *testing.T) {
	d := openTestDB(t)
	seedCustomField(t, d, "customfield_1", "Story Points", "number", false, "")
	seedCustomField(t, d, "customfield_2", "Rank", "any", false, "")
	fields, err := d.GetJiraCustomFields(1)
	require.NoError(t, err)

	gen := &scriptedAI{
		reply: "```json\n[{\"id\":\"customfield_1\",\"useful\":true,\"hint\":\"estimation\"},{\"id\":\"customfield_2\",\"useful\":false}]\n```",
		usage: &ai.Usage{InputTokens: 3, OutputTokens: 4, TotalAPITokens: 7},
	}
	fd := NewFieldDiscovery(nil, d, gen, 1)
	require.NoError(t, fd.ClassifyFields(context.Background(), fields))

	useful, err := d.GetUsefulJiraCustomFields(1)
	require.NoError(t, err)
	require.Len(t, useful, 1)
	assert.Equal(t, "customfield_1", useful[0].ID)
	assert.Equal(t, "estimation", useful[0].UsageHint)
	in, out, total := fd.AccumulatedUsage()
	assert.Equal(t, []int{3, 4, 7}, []int{in, out, total})
}

// ClassifyFields' guard rails: nothing to classify makes no call, a missing
// provider is an error, and an LLM failure or unparseable reply surfaces
// without touching the stored classification.
func TestClassifyFields_Guards(t *testing.T) {
	d := openTestDB(t)
	seedCustomField(t, d, "customfield_1", "Story Points", "number", false, "")
	fields, err := d.GetJiraCustomFields(1)
	require.NoError(t, err)

	gen := &scriptedAI{reply: "[]"}
	require.NoError(t, NewFieldDiscovery(nil, d, gen, 1).ClassifyFields(context.Background(), nil))
	assert.Empty(t, gen.calls, "no fields, no LLM call")

	assert.ErrorContains(t, NewFieldDiscovery(nil, d, nil, 1).ClassifyFields(context.Background(), fields), "AI provider not configured")

	failing := &scriptedAI{err: errors.New("down"), usage: &ai.Usage{InputTokens: 2}}
	fd := NewFieldDiscovery(nil, d, failing, 1)
	assert.ErrorContains(t, fd.ClassifyFields(context.Background(), fields), "LLM classification")
	in, _, _ := fd.AccumulatedUsage()
	assert.Equal(t, 2, in, "a failed call's usage is still counted")

	assert.ErrorContains(t, NewFieldDiscovery(nil, d, &scriptedAI{reply: "not json"}, 1).ClassifyFields(context.Background(), fields), "parsing LLM classification")
	useful, err := d.GetUsefulJiraCustomFields(1)
	require.NoError(t, err)
	assert.Empty(t, useful)
}

// MapFieldsForBoard samples the board's issues, sends only populated useful
// fields to the LLM, and stores its roles — dropping "skip", empty roles and
// any field id the LLM invented that was not in the sample.
func TestMapFieldsForBoard_StoresSampledRoles(t *testing.T) {
	d := openTestDB(t)
	seedCustomField(t, d, "customfield_1", "Story Points", "number", true, "estimation")
	seedCustomField(t, d, "customfield_2", "Team", "option", true, "categorization")
	seedCustomField(t, d, "customfield_3", "Never set", "string", true, "tracking")
	srv := fieldsServer(t, `[]`, `{"issues":[
		{"fields":{"customfield_1":3,"customfield_2":{"value":"Core"},"customfield_3":null}},
		{"fields":{"customfield_1":5,"customfield_9":"not useful"}}
	]}`)
	gen := &scriptedAI{reply: `[
		{"id":"customfield_1","role":"story_points"},
		{"id":"customfield_2","role":"skip"},
		{"id":"customfield_3","role":""},
		{"id":"customfield_777","role":"team"}
	]`}
	fd := NewFieldDiscovery(newTestClient(t, srv.URL, "", "at"), d, gen, 1)
	board := db.JiraBoard{AccountID: 1, ID: 42, Name: "Core board", ProjectKey: "CORE"}

	got, err := fd.MapFieldsForBoard(context.Background(), board)
	require.NoError(t, err)
	assert.Equal(t, []db.JiraBoardFieldMap{{AccountID: 1, BoardID: 42, FieldID: "customfield_1", Role: "story_points"}}, got)

	require.Len(t, gen.calls, 1)
	assert.Contains(t, gen.calls[0], "customfield_1")
	assert.Contains(t, gen.calls[0], "customfield_2")
	assert.NotContains(t, gen.calls[0], "customfield_3", "a field null on every sampled issue is not sent")
	assert.NotContains(t, gen.calls[0], "customfield_9", "a field not classified useful is not sent")

	stored, err := d.GetJiraBoardFieldMap(1, 42)
	require.NoError(t, err)
	require.Len(t, stored, 1)
	assert.Equal(t, "customfield_1", stored[0].FieldID)
}

// MapFieldsForBoard's early exits: no useful fields, a project key that would
// inject JQL, and a board with no issues all return before any LLM call.
func TestMapFieldsForBoard_EarlyExits(t *testing.T) {
	d := openTestDB(t)
	srv := fieldsServer(t, `[]`, `{"issues":[]}`)
	gen := &scriptedAI{reply: "[]"}
	fd := NewFieldDiscovery(newTestClient(t, srv.URL, "", "at"), d, gen, 1)

	_, err := fd.MapFieldsForBoard(context.Background(), db.JiraBoard{ID: 1, ProjectKey: "CORE"})
	assert.ErrorContains(t, err, "no useful fields")

	seedCustomField(t, d, "customfield_1", "Story Points", "number", true, "estimation")
	_, err = fd.MapFieldsForBoard(context.Background(), db.JiraBoard{ID: 1, ProjectKey: "CORE OR 1=1"})
	assert.ErrorContains(t, err, "invalid project key")

	got, err := fd.MapFieldsForBoard(context.Background(), db.JiraBoard{ID: 1, ProjectKey: "CORE"})
	require.NoError(t, err)
	assert.Nil(t, got)
	assert.Empty(t, gen.calls)
}

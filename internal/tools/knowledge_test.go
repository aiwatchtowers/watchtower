package tools

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/kb"
)

func knowledgeRegistry(t *testing.T, d *db.DB) *Registry {
	t.Helper()
	reg := New(d)
	require.NoError(t, reg.Register(NewSearchKnowledge()))
	require.NoError(t, reg.Register(NewGetKnowledgeDocument()))
	return reg
}

// seedKnowledgeFixture indexes one Jira issue whose description carries the
// Russian word стейдж (stage/staging), so a query for its stem finds it.
func seedKnowledgeFixture(t *testing.T, d *db.DB) {
	t.Helper()
	accountID := db.SeedTestJiraAccount(t, d)
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
		AccountID: accountID, Key: "PROJ-123", ID: "PROJ-123", ProjectKey: "PROJ",
		Summary: "Stage environment", DescriptionText: "Нужен второй стейдж",
		Status: "In Progress", StatusCategory: "indeterminate",
		CreatedAt: "2026-04-01T09:00:00Z", UpdatedAt: "2026-04-20T09:37:38Z", SyncedAt: "2026-04-20T11:00:01Z",
	}))
	_, err := kb.Run(context.Background(), d, kb.Options{})
	require.NoError(t, err)
}

func TestSearchKnowledge_FindsIndexedJiraIssue(t *testing.T) {
	d := openDB(t)
	seedKnowledgeFixture(t, d)
	got := callReadString(t, knowledgeRegistry(t, d), "search_knowledge", `{"queries":["стейдж*"]}`)
	assert.Contains(t, got, `"ref":"jira:1:PROJ-123"`)
	assert.Contains(t, got, `"anchor"`)
}

func TestSearchKnowledge_EmptyQueriesIsValidationError(t *testing.T) {
	reg := knowledgeRegistry(t, openDB(t))
	_, err := reg.CallRead(context.Background(), "search_knowledge", json.RawMessage(`{"queries":[]}`))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr, "the model must see a message, not a bare error")
	assert.NotEmpty(t, verr.Msg)
}

func TestSearchKnowledge_BadFromDateIsValidationError(t *testing.T) {
	reg := knowledgeRegistry(t, openDB(t))
	_, err := reg.CallRead(context.Background(), "search_knowledge", json.RawMessage(`{"queries":["x"],"from":"26-09-2026"}`))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "from")
}

func TestGetKnowledgeDocument_ReturnsTextForAHit(t *testing.T) {
	d := openDB(t)
	seedKnowledgeFixture(t, d)
	got := callReadString(t, knowledgeRegistry(t, d), "get_knowledge_document", `{"ref":"jira:1:PROJ-123"}`)
	assert.Contains(t, got, `"text"`)
	assert.Contains(t, got, "стейдж")
}

func TestGetKnowledgeDocument_UnknownRefIsValidationError(t *testing.T) {
	reg := knowledgeRegistry(t, openDB(t))
	_, err := reg.CallRead(context.Background(), "get_knowledge_document", json.RawMessage(`{"ref":"nope"}`))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "no document")
}

func TestSearchKnowledge_FromAfterToIsValidationError(t *testing.T) {
	reg := knowledgeRegistry(t, openDB(t))
	_, err := reg.CallRead(context.Background(), "search_knowledge",
		json.RawMessage(`{"queries":["x"],"from":"2026-09-26","to":"2026-09-20"}`))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "before")
}

func TestSearchKnowledge_HitNamesItsChunk(t *testing.T) {
	d := openDB(t)
	seedKnowledgeFixture(t, d)
	got := callReadString(t, knowledgeRegistry(t, d), "search_knowledge", `{"queries":["стейдж*"]}`)
	assert.Contains(t, got, `"chunk":0`)
}

func TestGetKnowledgeDocument_FromChunk(t *testing.T) {
	d := openDB(t)
	seedKnowledgeFixture(t, d)
	reg := knowledgeRegistry(t, d)
	got := callReadString(t, reg, "get_knowledge_document", `{"ref":"jira:1:PROJ-123","from_chunk":0}`)
	assert.Contains(t, got, `"from_chunk":0`)
	assert.Contains(t, got, `"chunk_count":1`)
	_, err := reg.CallRead(context.Background(), "get_knowledge_document", json.RawMessage(`{"ref":"jira:1:PROJ-123","from_chunk":5}`))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr, "an out-of-range chunk is the model's mistake, not a tool failure")
	assert.Contains(t, verr.Msg, "from_chunk")
}

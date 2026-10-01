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

func addSource(t *testing.T, d *db.DB, projectID int64, kind, ref string) {
	t.Helper()
	_, err := d.AddProjectSource(db.ProjectSource{ProjectID: projectID, Kind: kind, Ref: ref})
	require.NoError(t, err)
}

func TestProjectKnowledgeScope_ResolvesRefs(t *testing.T) {
	d := openDB(t)
	_, err := d.Exec(`INSERT INTO channels (id, name, type) VALUES
		('1:C1', 'general', 'public'), ('2:C9', 'General', 'public'), ('1:C5', 'eng', 'private'), ('1:C7', 'random', 'public')`)
	require.NoError(t, err)
	p := seedProject(t, d, "alpha")
	for _, s := range []struct{ kind, ref string }{
		{"slack_channel", "#general"}, // a name in two accounts
		{"slack_channel", "C5"},       // a raw id
		{"slack_channel", "https://acme.slack.com/archives/C5/p1700000000"}, // the same channel again
		{"slack_channel", "1:C7"},                          // a namespaced id
		{"slack_channel", "nope"},                          // nothing synced by that name
		{"slack_channel", "slack://channel?team=T1&id=C7"}, // a Desktop deep link
		{"jira_project", "proj"},
		{"jira_project", "https://acme.atlassian.net/browse/OPS-12"},
		{"jira_project", "WEB-7"},
		{"jira_project", "not a key"},
		{"jira_project", "my-team"}, // a hyphenated name, not an issue key
		{"confluence_space", "ENG"},
		{"confluence_space", "https://acme.atlassian.net/wiki/spaces/DOC/pages/1/Title"},
		{"confluence_space", "two words"},
		{"confluence_space", "https://acme.atlassian.net/wiki/display/OLD/Page"},
		{"person", "anna@example.com"},
		{"link", "https://example.com"},
	} {
		addSource(t, d, p, s.kind, s.ref)
	}
	scope, unresolved, err := ProjectKnowledgeScope(context.Background(), d, p)
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{"1:C1", "2:C9", "1:C5", "1:C7"}, scope.SlackChannels)
	assert.ElementsMatch(t, []string{"PROJ", "OPS", "WEB"}, scope.JiraProjects)
	assert.ElementsMatch(t, []string{"ENG", "DOC", "OLD"}, scope.ConfluenceSpaces)
	assert.Equal(t, []string{"confluence_space two words", "jira_project not a key", "jira_project my-team", "slack_channel nope"}, unresolved,
		"person and link sources are never reported; sources come by kind, then id")

	empty, unresolved, err := ProjectKnowledgeScope(context.Background(), d, seedProject(t, d, "beta"))
	require.NoError(t, err)
	assert.True(t, empty.Empty())
	assert.Empty(t, unresolved)
}

// seedScopedKnowledge indexes two Jira issues sharing a word, one in project
// PROJ and a newer one in OTHER, and returns a project whose source is PROJ.
func seedScopedKnowledge(t *testing.T, d *db.DB) int64 {
	t.Helper()
	accountID := db.SeedTestJiraAccount(t, d)
	for _, is := range []db.JiraIssue{
		{AccountID: accountID, Key: "PROJ-1", ID: "PROJ-1", ProjectKey: "PROJ", Summary: "Stage", DescriptionText: "Нужен стейдж",
			Status: "Open", StatusCategory: "new", CreatedAt: "2026-04-01T09:00:00Z", UpdatedAt: "2026-04-01T09:00:00Z", SyncedAt: "2026-04-20T11:00:01Z"},
		{AccountID: accountID, Key: "OTHER-1", ID: "OTHER-1", ProjectKey: "OTHER", Summary: "Stage", DescriptionText: "Нужен стейдж",
			Status: "Open", StatusCategory: "new", CreatedAt: "2026-04-20T09:00:00Z", UpdatedAt: "2026-04-20T09:00:00Z", SyncedAt: "2026-04-20T11:00:01Z"},
	} {
		require.NoError(t, d.UpsertJiraIssue(is))
	}
	_, err := kb.Run(context.Background(), d, kb.Options{})
	require.NoError(t, err)
	p := seedProject(t, d, "alpha")
	addSource(t, d, p, "jira_project", "PROJ")
	return p
}

func searchIn(t *testing.T, reg *Registry, projectID int64, args string) (kb.Result, error) {
	t.Helper()
	out, err := reg.CallRead(context.Background(), "search_knowledge", json.RawMessage(args), Binding{ProjectID: projectID})
	if err != nil {
		return kb.Result{}, err
	}
	res, ok := out.(kb.Result)
	require.True(t, ok, "result %T", out)
	return res, nil
}

func TestSearchKnowledge_ProjectSessionPrefersProjectSources(t *testing.T) {
	d := openDB(t)
	p := seedScopedKnowledge(t, d)
	reg := knowledgeRegistry(t, d)

	res, err := searchIn(t, reg, 0, `{"queries":["стейдж"]}`)
	require.NoError(t, err)
	require.Len(t, res.Hits, 2)
	assert.Equal(t, "OTHER-1", res.Hits[0].Anchor["key"], "outside a project session the newer issue leads")

	res, err = searchIn(t, reg, p, `{"queries":["стейдж"]}`)
	require.NoError(t, err)
	require.Len(t, res.Hits, 2, "the boost drops nothing")
	assert.Equal(t, "PROJ-1", res.Hits[0].Anchor["key"])
	assert.True(t, res.Hits[0].InScope)
	assert.False(t, res.Hits[1].InScope)

	res, err = searchIn(t, reg, p, `{"queries":["стейдж"],"project_scope":"only"}`)
	require.NoError(t, err)
	require.Len(t, res.Hits, 1)
	assert.Equal(t, "PROJ-1", res.Hits[0].Anchor["key"])
	assert.Empty(t, res.ScopeNote)

	// An explicit sources filter applies on top of the boost: out-of-scope
	// hits of that source stay, after the in-scope one.
	res, err = searchIn(t, reg, p, `{"queries":["стейдж"],"sources":["jira"]}`)
	require.NoError(t, err)
	require.Len(t, res.Hits, 2)
	assert.Equal(t, "PROJ-1", res.Hits[0].Anchor["key"])

	res, err = searchIn(t, reg, p, `{"queries":["стейдж"],"project_scope":"off"}`)
	require.NoError(t, err)
	require.Len(t, res.Hits, 2)
	assert.Equal(t, "OTHER-1", res.Hits[0].Anchor["key"])
	assert.False(t, res.Hits[0].InScope || res.Hits[1].InScope)

	// An explicit sources filter still wins: no jira, no project hit.
	res, err = searchIn(t, reg, p, `{"queries":["стейдж"],"sources":["calendar"]}`)
	require.NoError(t, err)
	assert.Empty(t, res.Hits)
}

func TestSearchKnowledge_ProjectScopeErrors(t *testing.T) {
	d := openDB(t)
	p := seedScopedKnowledge(t, d)
	reg := knowledgeRegistry(t, d)
	var ve *ValidationError

	_, err := searchIn(t, reg, 0, `{"queries":["стейдж"],"project_scope":"only"}`)
	require.ErrorAs(t, err, &ve)
	assert.Contains(t, ve.Msg, "only in a project session")

	_, err = searchIn(t, reg, p, `{"queries":["стейдж"],"project_scope":"all"}`)
	require.ErrorAs(t, err, &ve)
	assert.Contains(t, ve.Msg, "project_scope")

	bare := seedProject(t, d, "bare")
	_, err = searchIn(t, reg, bare, `{"queries":["стейдж"],"project_scope":"only"}`)
	require.ErrorAs(t, err, &ve)
	assert.Contains(t, ve.Msg, "add_project_source")

	_, err = searchIn(t, reg, p, `{"queries":["стейдж"],"project_scope":"only","sources":["gmail"]}`)
	require.ErrorAs(t, err, &ve)
	assert.Contains(t, ve.Msg, "only covers slack, jira and confluence")

	// Without sources the default boost is a plain search.
	res, err := searchIn(t, reg, bare, `{"queries":["стейдж"]}`)
	require.NoError(t, err)
	assert.Len(t, res.Hits, 2)

	// A source that resolves to nothing is named, not an error.
	addSource(t, d, p, "slack_channel", "#no-such-channel")
	res, err = searchIn(t, reg, p, `{"queries":["стейдж"]}`)
	require.NoError(t, err)
	assert.Equal(t, "PROJ-1", res.Hits[0].Anchor["key"])
	assert.Contains(t, res.ScopeNote, "slack_channel #no-such-channel")
}

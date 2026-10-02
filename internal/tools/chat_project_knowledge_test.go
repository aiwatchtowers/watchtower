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

// seedChatProject creates a chat project pinning sources (kind, ref pairs),
// the way the Desktop writes them (Go only reads chat projects).
func seedChatProject(t *testing.T, d *db.DB, name string, sources ...[2]string) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO chat_projects (name, created_at, updated_at) VALUES (?, 1, 1)`, name)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	for _, s := range sources {
		_, err := d.Exec(`INSERT INTO chat_project_sources (project_id, kind, ref) VALUES (?, ?, ?)`, id, s[0], s[1])
		require.NoError(t, err)
	}
	return id
}

func searchInChatProject(t *testing.T, reg *Registry, chatProjectID int64, args string) (kb.Result, error) {
	t.Helper()
	out, err := reg.CallRead(context.Background(), "search_knowledge", json.RawMessage(args),
		Binding{Surface: "main", ConversationID: 1, ChatProjectID: chatProjectID})
	if err != nil {
		return kb.Result{}, err
	}
	res, ok := out.(kb.Result)
	require.True(t, ok, "result %T", out)
	return res, nil
}

// A chat project's slack_channel, jira_project and confluence_space pins
// resolve like a workbench's; target, track and person pins stay prompt-only
// and are never reported as unresolved.
func TestChatProjectKnowledgeScope_ResolvesSearchKinds(t *testing.T) {
	d := openDB(t)
	_, err := d.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C1', 'general', 'public')`)
	require.NoError(t, err)
	p := seedChatProject(t, d, "alpha",
		[2]string{"slack_channel", "1:C1"}, // the picker stores the namespaced id
		[2]string{"jira_project", "PAY"},
		[2]string{"confluence_space", "ENG"},
		[2]string{"slack_channel", "1:C404"}, // no longer synced
		[2]string{"target", "12"}, [2]string{"track", "3"}, [2]string{"person", "1:U1"},
	)
	scope, unresolved, err := ChatProjectKnowledgeScope(context.Background(), d, p)
	require.NoError(t, err)
	assert.Equal(t, kb.Scope{SlackChannels: []string{"1:C1"}, JiraProjects: []string{"PAY"}, ConfluenceSpaces: []string{"ENG"}}, scope)
	assert.Equal(t, []string{"slack_channel 1:C404"}, unresolved)

	for _, id := range []int64{seedChatProject(t, d, "bare", [2]string{"person", "1:U1"}), 404} {
		empty, unresolved, err := ChatProjectKnowledgeScope(context.Background(), d, id)
		require.NoError(t, err)
		assert.True(t, empty.Empty(), "project %d", id)
		assert.Empty(t, unresolved)
	}
}

// Board #209: in a chat project's chat, search_knowledge boosts (or with
// workbench_scope: only, restricts to) the project's pinned sources, exactly
// as a workbench session does with its own.
func TestSearchKnowledge_ChatProjectChatPrefersPinnedSources(t *testing.T) {
	d := openDB(t)
	seedScopedKnowledge(t, d) // PROJ-1 and the newer OTHER-1, both matching стейдж
	p := seedChatProject(t, d, "payments", [2]string{"jira_project", "PROJ"})
	reg := knowledgeRegistry(t, d)

	res, err := searchInChatProject(t, reg, 0, `{"queries":["стейдж"]}`)
	require.NoError(t, err)
	require.Len(t, res.Hits, 2)
	assert.Equal(t, "OTHER-1", res.Hits[0].Anchor["key"], "a chat outside any project is unchanged")
	assert.False(t, res.Hits[0].InScope || res.Hits[1].InScope)

	res, err = searchInChatProject(t, reg, p, `{"queries":["стейдж"]}`)
	require.NoError(t, err)
	require.Len(t, res.Hits, 2, "the boost drops nothing")
	assert.Equal(t, "PROJ-1", res.Hits[0].Anchor["key"])
	assert.True(t, res.Hits[0].InScope)
	assert.False(t, res.Hits[1].InScope)

	res, err = searchInChatProject(t, reg, p, `{"queries":["стейдж"],"workbench_scope":"only"}`)
	require.NoError(t, err)
	require.Len(t, res.Hits, 1)
	assert.Equal(t, "PROJ-1", res.Hits[0].Anchor["key"])

	res, err = searchInChatProject(t, reg, p, `{"queries":["стейдж"],"workbench_scope":"off"}`)
	require.NoError(t, err)
	require.Len(t, res.Hits, 2)
	assert.Equal(t, "OTHER-1", res.Hits[0].Anchor["key"])

	// A pin that resolves to nothing is named, not an error.
	_, err = d.Exec(`INSERT INTO chat_project_sources (project_id, kind, ref) VALUES (?, 'slack_channel', '#gone')`, p)
	require.NoError(t, err)
	res, err = searchInChatProject(t, reg, p, `{"queries":["стейдж"]}`)
	require.NoError(t, err)
	assert.Equal(t, "PROJ-1", res.Hits[0].Anchor["key"])
	assert.Equal(t, "left out of the chat project scope (no synced Slack channel by that ref, or not a Jira project or Confluence space key): slack_channel #gone", res.ScopeNote)
}

// Each chat project steers search toward its own pins only, and a project
// without search-kind pins searches like a plain chat.
func TestSearchKnowledge_ChatProjectsAreIsolated(t *testing.T) {
	d := openDB(t)
	seedScopedKnowledge(t, d)
	a := seedChatProject(t, d, "a", [2]string{"jira_project", "PROJ"})
	b := seedChatProject(t, d, "b", [2]string{"jira_project", "OTHER"})
	bare := seedChatProject(t, d, "bare", [2]string{"target", "1"})
	reg := knowledgeRegistry(t, d)

	for id, want := range map[int64]string{a: "PROJ-1", b: "OTHER-1"} {
		res, err := searchInChatProject(t, reg, id, `{"queries":["стейдж"],"workbench_scope":"only"}`)
		require.NoError(t, err)
		require.Len(t, res.Hits, 1, "project %d", id)
		assert.Equal(t, want, res.Hits[0].Anchor["key"], "project %d", id)
	}

	res, err := searchInChatProject(t, reg, bare, `{"queries":["стейдж"]}`)
	require.NoError(t, err)
	require.Len(t, res.Hits, 2)
	assert.Equal(t, "OTHER-1", res.Hits[0].Anchor["key"])
	assert.False(t, res.Hits[0].InScope || res.Hits[1].InScope)
	assert.Empty(t, res.ScopeNote)

	var ve *ValidationError
	_, err = searchInChatProject(t, reg, bare, `{"queries":["стейдж"],"workbench_scope":"only"}`)
	require.ErrorAs(t, err, &ve)
	assert.Equal(t, "this chat project has no usable Slack channel, Jira project or Confluence space source — the owner pins one in the project's settings, or search without workbench_scope", ve.Msg)

	// A chat project grants no workbench's attached documents (PROJ-08).
	_, err = searchInChatProject(t, reg, a, `{"queries":["x"],"sources":["project_doc"]}`)
	require.ErrorAs(t, err, &ve)
	assert.Contains(t, ve.Msg, "only from that workbench's own session")
}

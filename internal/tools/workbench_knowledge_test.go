package tools

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/kb"
)

func addSource(t *testing.T, d *db.DB, workbenchID int64, kind, ref string) {
	t.Helper()
	_, err := d.AddWorkbenchSource(db.WorkbenchSource{WorkbenchID: workbenchID, Kind: kind, Ref: ref})
	require.NoError(t, err)
}

func TestProjectKnowledgeScope_ResolvesRefs(t *testing.T) {
	d := openDB(t)
	_, err := d.Exec(`INSERT INTO channels (id, name, type) VALUES
		('1:C1', 'general', 'public'), ('2:C9', 'General', 'public'), ('1:C5', 'eng', 'private'), ('1:C7', 'random', 'public')`)
	require.NoError(t, err)
	p := seedWorkbench(t, d, "alpha")
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
	scope, unresolved, err := WorkbenchKnowledgeScope(context.Background(), d, p)
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{"1:C1", "2:C9", "1:C5", "1:C7"}, scope.SlackChannels)
	assert.ElementsMatch(t, []string{"PROJ", "OPS", "WEB"}, scope.JiraProjects)
	assert.ElementsMatch(t, []string{"ENG", "DOC", "OLD"}, scope.ConfluenceSpaces)
	assert.Equal(t, []string{"confluence_space two words", "jira_project not a key", "jira_project my-team", "slack_channel nope"}, unresolved,
		"person and link sources are never reported; sources come by kind, then id")

	empty, unresolved, err := WorkbenchKnowledgeScope(context.Background(), d, seedWorkbench(t, d, "beta"))
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
	p := seedWorkbench(t, d, "alpha")
	addSource(t, d, p, "jira_project", "PROJ")
	return p
}

func searchIn(t *testing.T, reg *Registry, workbenchID int64, args string) (kb.Result, error) {
	t.Helper()
	out, err := reg.CallRead(context.Background(), "search_knowledge", json.RawMessage(args), Binding{WorkbenchID: workbenchID})
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

	res, err = searchIn(t, reg, p, `{"queries":["стейдж"],"workbench_scope":"only"}`)
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

	res, err = searchIn(t, reg, p, `{"queries":["стейдж"],"workbench_scope":"off"}`)
	require.NoError(t, err)
	require.Len(t, res.Hits, 2)
	assert.Equal(t, "OTHER-1", res.Hits[0].Anchor["key"])
	assert.False(t, res.Hits[0].InScope || res.Hits[1].InScope)

	// An explicit sources filter still wins: no jira, no project hit.
	res, err = searchIn(t, reg, p, `{"queries":["стейдж"],"sources":["calendar"]}`)
	require.NoError(t, err)
	assert.Empty(t, res.Hits)
}

func TestSearchKnowledge_WorkbenchScopeErrors(t *testing.T) {
	d := openDB(t)
	p := seedScopedKnowledge(t, d)
	reg := knowledgeRegistry(t, d)
	var ve *ValidationError

	// Only workbench_scope is offered; the pre-rename project_scope is gone.
	tool, ok := reg.Get("search_knowledge")
	require.True(t, ok)
	require.NotNil(t, tool.InputSchema)
	assert.Contains(t, tool.InputSchema.Properties, "workbench_scope")
	assert.NotContains(t, tool.InputSchema.Properties, "project_scope")

	_, err := searchIn(t, reg, 0, `{"queries":["стейдж"],"workbench_scope":"only"}`)
	require.ErrorAs(t, err, &ve)
	assert.Equal(t, "workbench_scope works only in a workbench session (watchtower mcp --workbench N) or a chat project's chat", ve.Msg)

	_, err = searchIn(t, reg, p, `{"queries":["стейдж"],"workbench_scope":"all"}`)
	require.ErrorAs(t, err, &ve)
	assert.Contains(t, ve.Msg, "workbench_scope")

	bare := seedWorkbench(t, d, "bare")
	_, err = searchIn(t, reg, bare, `{"queries":["стейдж"],"workbench_scope":"only"}`)
	require.ErrorAs(t, err, &ve)
	assert.Contains(t, ve.Msg, "add_workbench_source")

	_, err = searchIn(t, reg, p, `{"queries":["стейдж"],"workbench_scope":"only","sources":["gmail"]}`)
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

// putFolderOnBench adds a live folder named name to workbench wb and
// returns the folder's path and row id.
func putFolderOnBench(t *testing.T, d *db.DB, wb int64, name string, position int) (string, int64) {
	t.Helper()
	path, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	res, err := d.Exec(`INSERT INTO workbench_folders (workbench_id, folder_path, position, added_by, name)
		VALUES (?, ?, ?, 'owner', ?)`, wb, path, position, name)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return path, id
}

// PROJ-08 at the tool layer (was ...ShowProjectDocsOnlyToTheirProject;
// amended 2026-10-03, and for multi-folder workbenches 2026-11-18):
// search_knowledge and get_knowledge_document show the files of every folder
// of a workbench — none attached — only in that workbench's session; the
// main and Discuss chats (no WorkbenchID) and another workbench see nothing.
func TestProj08_KnowledgeToolsShowFolderFilesOnlyToTheirWorkbench(t *testing.T) {
	ctx := context.Background()
	d := openDB(t)
	p := seedWorkbench(t, d, "alpha")
	home, err := d.HomeFolder(ctx, p)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(home.FolderPath, "plan.md"), []byte("# Plan\nКанареечный выкат\n"), 0o600))
	hub, _ := putFolderOnBench(t, d, p, "hub", 1)
	require.NoError(t, os.WriteFile(filepath.Join(hub, "hub.md"), []byte("# Hub\nКанареечный хаб\n"), 0o600))
	other := seedWorkbench(t, d, "beta")
	_, err = kb.Run(ctx, d, kb.Options{})
	require.NoError(t, err)
	reg := knowledgeRegistry(t, d)

	own, err := searchIn(t, reg, p, `{"queries":["канареечн*"]}`)
	require.NoError(t, err)
	require.Len(t, own.Hits, 2, "both folders' files")
	var refs []string
	for _, h := range own.Hits {
		assert.Equal(t, "project_doc", h.Source)
		refs = append(refs, h.Ref)
		_, err = reg.CallRead(ctx, "get_knowledge_document", json.RawMessage(`{"ref":"`+h.Ref+`"}`), Binding{WorkbenchID: p})
		require.NoError(t, err)
	}

	for _, b := range []Binding{{}, {Surface: "main", ConversationID: 3}, {ContextType: "target", ContextID: "9"}, {WorkbenchID: other}} {
		out, err := reg.CallRead(ctx, "search_knowledge", json.RawMessage(`{"queries":["канареечн*"]}`), b)
		require.NoError(t, err)
		assert.Empty(t, out.(kb.Result).Hits, "binding %+v", b)
		for _, ref := range refs {
			_, err = reg.CallRead(ctx, "get_knowledge_document", json.RawMessage(`{"ref":"`+ref+`"}`), b)
			var ve *ValidationError
			require.ErrorAs(t, err, &ve, "binding %+v", b)
			assert.Contains(t, ve.Msg, "no document with that ref", "indistinguishable from a missing one")
		}
	}
}

// TestDocDisplayPathOnlyWithSeveralFolders (spec §6.11, F17): a workbench
// document is shown as <folder>/<rel> — the folder's stored name — in search
// and open only while the bench has more than one folder, else as <rel>.
func TestDocDisplayPathOnlyWithSeveralFolders(t *testing.T) {
	ctx := context.Background()
	d := openDB(t)
	p := seedWorkbench(t, d, "alpha")
	home, err := d.HomeFolder(ctx, p)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(home.FolderPath, "plan.md"), []byte("# Plan\nquokka\n"), 0o600))
	_, _, err = kb.IndexWorkbenchDocs(ctx, d, p)
	require.NoError(t, err)
	reg := knowledgeRegistry(t, d)
	titles := func() (string, string) {
		t.Helper()
		res, err := searchIn(t, reg, p, `{"queries":["quokka"]}`)
		require.NoError(t, err)
		require.Len(t, res.Hits, 1)
		out, err := reg.CallRead(ctx, "get_knowledge_document", json.RawMessage(`{"ref":"`+res.Hits[0].Ref+`"}`), Binding{WorkbenchID: p})
		require.NoError(t, err)
		return res.Hits[0].Title, out.(kb.DocView).Title
	}

	hit, opened := titles()
	assert.Equal(t, "plan.md", hit, "one folder: <rel>")
	assert.Equal(t, "plan.md", opened)

	_, hubID := putFolderOnBench(t, d, p, "hub", 1)
	hit, opened = titles()
	assert.Equal(t, home.Name+"/plan.md", hit, "two folders: <folder>/<rel>")
	assert.Equal(t, home.Name+"/plan.md", opened)

	_, err = d.Exec(`UPDATE workbench_folders SET removed_at = '2026-11-18T00:00:00Z' WHERE id = ?`, hubID)
	require.NoError(t, err)
	hit, _ = titles()
	assert.Equal(t, "plan.md", hit, "back to one live folder")
}

func TestSearchKnowledge_ProjectDocSourceOutsideAProjectSessionIsRefused(t *testing.T) {
	d := openDB(t)
	reg := knowledgeRegistry(t, d)
	_, err := reg.CallRead(context.Background(), "search_knowledge", json.RawMessage(`{"queries":["x"],"sources":["project_doc"]}`), Binding{})
	var ve *ValidationError
	require.ErrorAs(t, err, &ve)
	assert.Contains(t, ve.Msg, "only from that workbench's own session")
}

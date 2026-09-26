package tools

import (
	"context"
	"fmt"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/kb"
)

const confluenceSite = "https://test.atlassian.net/wiki/spaces/ENG/pages/"

// seedConfluenceTask seeds PROJ-7 and one selected space, returning the
// source id. Pages are added with addTaskPage.
func seedConfluenceTask(t *testing.T, d *db.DB) int64 {
	t.Helper()
	accountID := db.SeedTestJiraAccount(t, d)
	now := time.Now().UTC().Format(time.RFC3339)
	require.NoError(t, d.UpsertJiraIssue(db.JiraIssue{
		AccountID: accountID, Key: "PROJ-7", ID: "10007", ProjectKey: "PROJ", Summary: "Ship the payments API",
		Status: "To Do", StatusCategory: "To Do", CreatedAt: now, UpdatedAt: now, SyncedAt: now,
	}))
	src, err := d.CreateExtSource("confluence", accountID, "ENG", "100", "Engineering")
	require.NoError(t, err)
	return src
}

func addTaskPage(t *testing.T, d *db.DB, src int64, id, title, text string, linked bool) string {
	t.Helper()
	_, err := d.Exec(`INSERT INTO ext_documents (source_id, ext_id, kind, title, url, sections_json, modified_at)
		VALUES (?, ?, 'page', ?, ?, json_array(json_object('heading', '', 'anchor', '', 'text', ?)), '2026-09-20T10:00:00Z')`,
		src, id, title, confluenceSite+id, text)
	require.NoError(t, err)
	ref := "confluence:" + strconv.FormatInt(src, 10) + ":" + id
	if linked {
		_, err = d.Exec(`INSERT INTO doc_links (from_kind, from_ref, to_kind, to_ref) VALUES ('confluence', ?, 'jira_issue', 'PROJ-7')`, ref)
		require.NoError(t, err)
	}
	return ref
}

func indexConfluence(t *testing.T, d *db.DB) {
	t.Helper()
	// The KB lists only markers from seconds that are over.
	_, err := kb.Run(context.Background(), d, kb.Options{Sources: []string{"confluence"}, Now: time.Now().Add(2 * time.Second)})
	require.NoError(t, err)
}

// The section lists the pages that link the key first (evidence: a doc
// link), then pages search finds for it, each once, with title, link,
// space and a snippet.
func TestGetTaskContext_ConfluenceSection(t *testing.T) {
	d := openDB(t)
	src := seedConfluenceTask(t, d)
	linkedRef := addTaskPage(t, d, src, "1001", "Payments API design",
		"Background first. The API for PROJ-7 exposes three endpoints.", true)
	searchRef := addTaskPage(t, d, src, "1002", "Rollout notes", "Rollout order for PROJ-7: canary first.", false)
	addTaskPage(t, d, src, "1003", "Unrelated", "Nothing about that ticket.", false)
	indexConfluence(t, d)

	got := taskContextDossier(t, d, "PROJ-7")
	require.Len(t, got.Confluence, 2, "the linked page is also a search hit: listed once")
	assert.Equal(t, taskConfluencePage{
		Title: "Payments API design", Link: confluenceSite + "1001", Space: "ENG",
		Snippet: "Background first. The API for PROJ-7 exposes three endpoints.", Ref: linkedRef, Via: "link",
	}, got.Confluence[0])
	second := got.Confluence[1]
	assert.Equal(t, searchRef, second.Ref)
	assert.Equal(t, "search", second.Via)
	assert.Equal(t, "Rollout notes", second.Title)
	assert.Equal(t, confluenceSite+"1002", second.Link)
	assert.Equal(t, "ENG", second.Space)
	assert.Contains(t, second.Snippet, "canary")
}

// Linked pages alone fill the section up to its cap; a link whose page is no
// longer stored is skipped, not rendered empty.
func TestGetTaskContext_ConfluenceCapAndStaleLink(t *testing.T) {
	d := openDB(t)
	src := seedConfluenceTask(t, d)
	_, err := d.Exec(`INSERT INTO doc_links (from_kind, from_ref, to_kind, to_ref, detected_at)
		VALUES ('confluence', ?, 'jira_issue', 'PROJ-7', '2030-01-01T00:00:00Z')`, fmt.Sprintf("confluence:%d:gone", src))
	require.NoError(t, err)
	for i := range 7 {
		addTaskPage(t, d, src, fmt.Sprintf("20%d", i), fmt.Sprintf("Page %d", i), "mentions PROJ-7", true)
	}
	got := taskContextDossier(t, d, "PROJ-7")
	require.Len(t, got.Confluence, taskContextMaxConfluence)
	for _, p := range got.Confluence {
		assert.NotEmpty(t, p.Title)
		assert.Equal(t, "link", p.Via)
	}
}

// A long page is excerpted around the key.
func TestConfluenceSnippet(t *testing.T) {
	long := string(make([]rune, 0))
	for range 50 {
		long += "filler words here. "
	}
	text := long + "The PROJ-7 decision." + long
	s := confluenceSnippet(text, "PROJ-7")
	assert.Contains(t, s, "PROJ-7")
	assert.LessOrEqual(t, len([]rune(s)), 2*confluenceSnippetRadius+len("PROJ-7")+2)
	assert.Equal(t, "short text", confluenceSnippet("short text", "PROJ-7"), "no key: the start of the text")
}

// No link and no search hit: the section is omitted, not an empty array.
func TestGetTaskContext_ConfluenceOmittedWhenEmpty(t *testing.T) {
	d := openDB(t)
	src := seedConfluenceTask(t, d)
	addTaskPage(t, d, src, "1003", "Unrelated", "Nothing about that ticket.", false)
	indexConfluence(t, d)
	got := callReadString(t, taskContextRegistry(t, d), "get_task_context", `{"key":"PROJ-7"}`)
	assert.NotContains(t, got, `"confluence"`)
}

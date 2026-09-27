package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestExtSourceCRUDAndCascade(t *testing.T) {
	d := openTestDB(t)
	acct, err := d.CreateJiraAccount(JiraAccount{CloudID: "c1", SiteURL: "https://x.atlassian.net", Enabled: true, Status: "ok"})
	require.NoError(t, err)

	id, err := d.CreateExtSource("confluence", acct, "ENG", "123", "Engineering")
	require.NoError(t, err)
	again, err := d.CreateExtSource("confluence", acct, "ENG", "123", "Engineering")
	require.NoError(t, err)
	assert.Equal(t, id, again, "idempotent")

	_, err = d.Exec(`INSERT INTO ext_documents (source_id, ext_id, kind) VALUES (?, 'p1', 'page')`, id)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO ext_comments (source_id, ext_id, page_ext_id, kind) VALUES (?, 'c1', 'p1', 'footer')`, id)
	require.NoError(t, err)

	require.NoError(t, d.DeleteExtSource(id))
	var n int
	require.NoError(t, d.QueryRow(`SELECT (SELECT COUNT(*) FROM ext_documents) + (SELECT COUNT(*) FROM ext_comments)`).Scan(&n))
	assert.Zero(t, n)
}

func TestExtSourceOwnerCheck(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO ext_sources (provider, container_key) VALUES ('confluence', 'X')`)
	assert.Error(t, err, "neither owner set must violate the CHECK")
}

func TestExtSourceCascadesFromJiraAccount(t *testing.T) {
	d := openTestDB(t)
	acct, _ := d.CreateJiraAccount(JiraAccount{CloudID: "c1", Enabled: true, Status: "ok"})
	_, err := d.CreateExtSource("confluence", acct, "ENG", "1", "E")
	require.NoError(t, err)
	_, err = d.Exec(`DELETE FROM jira_accounts WHERE id = ?`, acct)
	require.NoError(t, err)
	srcs, err := d.ListExtSources("confluence")
	require.NoError(t, err)
	assert.Empty(t, srcs)
}

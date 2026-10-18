package targets

import (
	"context"
	"testing"

	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestExtract_LinearURLs(t *testing.T) {
	got := Extract("see https://linear.app/acme/issue/ENG-12/fix-login and https://linear.app/acme/issue/ENG-12/fix-login again, " +
		"plus https://linear.app/acme/team/ENG/active")
	require.Len(t, got, 1)
	assert.Equal(t, URLMatch{Source: "linear", RawURL: "https://linear.app/acme/issue/ENG-12", Key: "ENG-12"}, got[0])
	assert.Equal(t, "linear:ENG-12", refForMatch(got[0]))
	assert.True(t, IsValidExternalRef("linear:ENG-12"))
}

func TestLinearResolver_ResolvesFromTrackerIssues(t *testing.T) {
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	acme, err := d.CreateLinearAccount("acme")
	require.NoError(t, err)
	other, err := d.CreateLinearAccount("other")
	require.NoError(t, err)
	require.NoError(t, d.UpsertLinearIssue(db.LinearIssue{AccountID: acme, ID: "a-1", Key: "ENG-12", Title: "Fix login",
		StateName: "In Progress", StatusCategory: "in_progress", Priority: 2,
		URL: "https://linear.app/acme/issue/ENG-12/fix-login", UpdatedAt: "2026-10-03T00:00:00.000Z"}))
	require.NoError(t, d.UpsertLinearIssue(db.LinearIssue{AccountID: other, ID: "o-1", Key: "ENG-12", Title: "Other workspace",
		StatusCategory: "todo", URL: "https://linear.app/other/issue/ENG-12/x", UpdatedAt: "2026-10-03T00:00:00.000Z"}))

	r := NewResolver(d, nil, 0)
	got := r.Resolve(context.Background(), Extract("https://linear.app/acme/issue/ENG-12/fix-login"))
	require.Len(t, got, 1)
	assert.Equal(t, "linear:ENG-12", got[0].Ref)
	assert.Equal(t, "[ENG-12] Fix login", got[0].Title, "the URL's workspace picks between two ENG-12s")
	assert.Equal(t, "- [ENG-12 status=In Progress priority=High] Fix login", got[0].Body)
	assert.Equal(t, "local", got[0].Source)

	got = r.Resolve(context.Background(), Extract("https://linear.app/acme/issue/ENG-99"))
	require.Len(t, got, 1)
	assert.Equal(t, "[linear issue not in local DB]", got[0].Body)
	assert.Empty(t, got[0].Error)
}

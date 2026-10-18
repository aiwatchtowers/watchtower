package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestResolveLinearUsersByEmail(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO users (id, name, email) VALUES ('1:U1','ann','Ann@Example.com'), ('2:U9','ann2','ann@example.com'), ('1:U2','bot','bot@example.com')`)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE users SET is_bot = 1 WHERE id = '1:U2'`)
	require.NoError(t, err)
	require.NoError(t, d.UpsertLinearUsers([]LinearUser{{ID: "u-1", Email: "ann@example.com"}, {ID: "u-2", Email: "bot@example.com"}, {ID: "u-3", Email: "x@example.com"}}))
	_, err = d.Exec(`INSERT INTO linear_user_map (linear_user_id, email, slack_user_id, match_method) VALUES ('u-4','ann@example.com','1:U7','manual')`)
	require.NoError(t, err)

	n, err := d.ResolveLinearUsersByEmail("2026-10-10T00:00:00Z")
	require.NoError(t, err)
	assert.Equal(t, int64(1), n)
	var slack, method string
	require.NoError(t, d.QueryRow(`SELECT slack_user_id, match_method FROM linear_user_map WHERE linear_user_id='u-1'`).Scan(&slack, &method))
	assert.Equal(t, "1:U1", slack)
	assert.Equal(t, "email", method)
	require.NoError(t, d.QueryRow(`SELECT slack_user_id FROM linear_user_map WHERE linear_user_id='u-4'`).Scan(&slack))
	assert.Equal(t, "1:U7", slack) // manual mapping kept
}

func TestFindLinearUsers_ByEmailOrDisplayName(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertLinearUsers([]LinearUser{
		{ID: "u-1", Email: "ann@example.com", DisplayName: "ann"},
		{ID: "u-2", Email: "sam1@example.com", DisplayName: "Sam"},
		{ID: "u-3", Email: "sam2@example.com", DisplayName: "sam"},
		{ID: "u-4"},
	}))
	got, err := d.FindLinearUsers("ANN@example.com")
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, "u-1", got[0].ID)
	got, err = d.FindLinearUsers("sam")
	require.NoError(t, err)
	assert.Len(t, got, 2)
	got, err = d.FindLinearUsers("ann@")
	require.NoError(t, err)
	assert.Empty(t, got)
}

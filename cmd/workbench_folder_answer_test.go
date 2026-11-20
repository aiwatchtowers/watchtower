package cmd

import (
	"context"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Not Now on a folder suggestion: the session's row for the root is quiet,
// so the hook never nudges about it again; the answer is {ok}.
func TestFolderQuiet(t *testing.T) {
	f := newFolderFixture(t)
	res, err := f.database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 's', ?, ?)`, f.pid, f.app, briefLaunchID)
	require.NoError(t, err)
	row, err := res.LastInsertId()
	require.NoError(t, err)
	lib := repoDir(t, "lib")

	out, errOut, err := runFolder(t, "quiet", "--session", strconv.FormatInt(row, 10), "--root", lib, "--json")
	require.NoError(t, err, errOut)
	assert.JSONEq(t, `{"ok":true,"error_code":"","error":""}`, out)
	_, _, quiet, err := f.database.CountOutsideTouch(context.Background(), row, lib)
	require.NoError(t, err)
	assert.True(t, quiet)

	out, _, err = runFolder(t, "quiet", "--session", "999999", "--root", lib, "--json")
	require.NoError(t, err, "a refusal is a result")
	res2 := decodeFolderResult(t, out)
	assert.False(t, res2.OK)
	assert.Equal(t, "not_found", res2.ErrorCode)
	assert.Equal(t, "not_found: there is no terminal session 999999.", res2.Error)

	out, _, err = runFolder(t, "quiet", "--session", strconv.FormatInt(row, 10), "--root", "lib", "--json")
	require.NoError(t, err)
	assert.Equal(t, "bad_args", decodeFolderResult(t, out).ErrorCode)

	t.Setenv("WATCHTOWER_TERMINAL_SESSION_ID", "5")
	_, _, err = runFolder(t, "quiet", "--session", strconv.FormatInt(row, 10), "--root", lib, "--json")
	assert.ErrorContains(t, err, "only the owner and the Desktop", "an agent never answers for the owner")
}

// Never for This Folder: a decline row for the bench, read NOCASE; a second
// decline is no error.
func TestFolderDecline(t *testing.T) {
	f := newFolderFixture(t)
	lib := repoDir(t, "lib")
	for range 2 {
		out, errOut, err := runFolder(t, "decline", "--workbench", f.id(), "--folder", lib, "--json")
		require.NoError(t, err, errOut)
		assert.JSONEq(t, `{"ok":true,"error_code":"","error":""}`, out)
	}
	declined, err := f.database.FolderDeclined(context.Background(), f.database, f.pid, lib)
	require.NoError(t, err)
	assert.True(t, declined)

	out, _, err := runFolder(t, "decline", "--workbench", f.id(), "--folder", "lib", "--json")
	require.NoError(t, err)
	assert.Equal(t, "bad_args", decodeFolderResult(t, out).ErrorCode)

	t.Setenv("WATCHTOWER_TERMINAL_SESSION_ID", "5")
	_, _, err = runFolder(t, "decline", "--workbench", f.id(), "--folder", lib, "--json")
	assert.ErrorContains(t, err, "only the owner and the Desktop")
}

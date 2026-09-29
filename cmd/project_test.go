package cmd

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// runProject executes the real "project" command tree via rootCmd (the
// runActions precedent) with stdout and stderr captured separately.
func runProject(t *testing.T, args ...string) (stdout, stderr string, err error) {
	t.Helper()
	var out, errOut bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errOut)
	rootCmd.SetArgs(append([]string{"project"}, args...))
	err = rootCmd.Execute()
	rootCmd.SetArgs(nil)
	projectFlagJSON = false
	projectCreateFlagFolder = ""
	projectCreateFlagName = ""
	projectBriefFlagProject = ""
	return out.String(), errOut.String(), err
}

func TestProject_CreateStoresTheResolvedFolderAndDefaultsTheName(t *testing.T) {
	writeActionsConfig(t)
	base := t.TempDir()
	realDir := filepath.Join(base, "my проект")
	require.NoError(t, os.Mkdir(realDir, 0o755))
	link := filepath.Join(base, "link with spaces")
	require.NoError(t, os.Symlink(realDir, link))
	want, err := filepath.EvalSymlinks(realDir)
	require.NoError(t, err)

	out, _, err := runProject(t, "create", "--folder", link, "--json")
	require.NoError(t, err)
	var got projectJSON
	require.NoError(t, json.Unmarshal([]byte(out), &got))
	assert.Positive(t, got.ID)
	assert.Equal(t, want, got.Folder, "the symlink-resolved absolute path is stored")
	assert.Equal(t, "my проект", got.Name, "the name defaults to the folder's base name")

	out, _, err = runProject(t, "create", "--folder", realDir, "--name", "Acme", "--json")
	assert.ErrorIs(t, err, db.ErrProjectFolderTaken, "the real path of an already-bound symlink is taken: %s", out)
}

func TestProject_CreateRefusesMissingAndAlreadyBoundFolders(t *testing.T) {
	writeActionsConfig(t)
	_, _, err := runProject(t, "create", "--folder", filepath.Join(t.TempDir(), "gone"))
	assert.Error(t, err, "a missing directory is refused")
	_, _, err = runProject(t, "create")
	assert.ErrorContains(t, err, "--folder is required")

	folder := t.TempDir()
	_, _, err = runProject(t, "create", "--folder", folder)
	require.NoError(t, err)
	_, _, err = runProject(t, "create", "--folder", folder)
	assert.ErrorIs(t, err, db.ErrProjectFolderTaken)
}

func TestProject_ListShowAndBoardJSON(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateProject("acme", t.TempDir())
	require.NoError(t, err)
	_, err = database.CreateProject("other", t.TempDir())
	require.NoError(t, err)
	var ids []int64
	require.NoError(t, database.WithTx(func(tx *sql.Tx) error {
		var err error
		ids, err = database.CreateProjectTargetsTx(tx, pid, []db.ProjectTargetInput{
			{Title: "feature"}, {Title: "task 1", BatchParent: 1},
		})
		return err
	}))
	require.NoError(t, database.UpdateTargetStatus(int(ids[1]), "in_progress"))
	_, err = database.AddProjectSource(db.ProjectSource{ProjectID: pid, Kind: "link", Ref: "https://example.com", Label: "site"})
	require.NoError(t, err)
	_, err = database.AddProjectComment(db.ProjectComment{ProjectID: pid, TargetID: sql.NullInt64{Int64: ids[0], Valid: true},
		Author: "owner", Body: "go"})
	require.NoError(t, err)

	out, _, err := runProject(t, "list", "--json")
	require.NoError(t, err)
	var list []projectJSON
	require.NoError(t, json.Unmarshal([]byte(out), &list))
	assert.Len(t, list, 2)

	out, _, err = runProject(t, "show", strconv.FormatInt(pid, 10), "--json")
	require.NoError(t, err)
	var view projectViewJSON
	require.NoError(t, json.Unmarshal([]byte(out), &view))
	assert.Equal(t, "acme", view.Name)
	require.Len(t, view.Sources, 1)
	assert.Equal(t, "https://example.com", view.Sources[0].Ref)
	assert.Equal(t, 1, view.Counts["todo"])
	assert.Equal(t, 1, view.Counts["in_progress"])

	out, _, err = runProject(t, "board", strconv.FormatInt(pid, 10), "--json")
	require.NoError(t, err)
	var board []boardNodeJSON
	require.NoError(t, json.Unmarshal([]byte(out), &board))
	require.Len(t, board, 1)
	assert.Equal(t, "feature", board[0].Title)
	assert.Equal(t, 1, board[0].NewForAgent)
	require.Len(t, board[0].Children, 1)
	assert.Equal(t, "in_progress", board[0].Children[0].Status)

	_, _, err = runProject(t, "show", "999")
	assert.ErrorIs(t, err, db.ErrProjectNotFound)
	_, _, err = runProject(t, "board", "abc")
	assert.Error(t, err)
}

// TestProject_DeleteStillDeletesWhenInstallRemovalFails: the folder cleanup
// runs first; its failure is reported and the delete still happens (spec §4.4).
func TestProject_DeleteStillDeletesWhenInstallRemovalFails(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateProject("acme", t.TempDir())
	require.NoError(t, err)
	_, err = database.CreateProjectTarget(pid, sql.NullInt64{}, "board item", "")
	require.NoError(t, err)

	var removed *db.Project
	orig := projectRemoveInstall
	projectRemoveInstall = func(_ context.Context, _ *config.Config, p *db.Project) error {
		removed = p
		return errors.New("folder is read-only")
	}
	t.Cleanup(func() { projectRemoveInstall = orig })

	out, errOut, err := runProject(t, "delete", strconv.FormatInt(pid, 10))
	require.NoError(t, err)
	require.NotNil(t, removed, "the folder cleanup ran")
	assert.Equal(t, pid, removed.ID)
	assert.Contains(t, errOut, "folder is read-only")
	assert.Contains(t, out, "Deleted project")

	_, err = database.GetProject(pid)
	assert.ErrorIs(t, err, db.ErrProjectNotFound)
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM targets WHERE project_id = ?`, pid).Scan(&n))
	assert.Zero(t, n)

	_, _, err = runProject(t, "delete", strconv.FormatInt(pid, 10))
	assert.ErrorIs(t, err, db.ErrProjectNotFound)
}

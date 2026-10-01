package cmd

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/projectfiles"
)

// attachTestImage stores a fake PNG (a PNG signature is all the sniff needs)
// in projectID's image directory and attaches it to targetID.
func attachTestImage(t *testing.T, database *db.DB, store projectfiles.Store, projectID, targetID int64, payload string) string {
	t.Helper()
	src := filepath.Join(t.TempDir(), "shot.png")
	require.NoError(t, os.WriteFile(src, []byte("\x89PNG\r\n\x1a\n"+payload), 0o600))
	img, err := store.Ingest(projectID, src)
	require.NoError(t, err)
	require.NoError(t, database.WithTx(func(tx *sql.Tx) error {
		_, err := db.AddProjectTargetImageTx(tx, db.ProjectTargetImage{ProjectID: projectID, TargetID: targetID,
			FileName: img.FileName, MIME: img.MIME, Size: img.Size, SHA256: img.SHA256, Path: img.Path})
		return err
	}))
	return img.Path
}

func testImageStore(t *testing.T) projectfiles.Store {
	t.Helper()
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	return projectfiles.New(cfg.WorkspaceDir())
}

// TestProj02_ProjectDeleteRemovesStoredTargetImages: `project delete` leaves
// no stored image copy of the project behind, and touches no other
// project's.
func TestProj02_ProjectDeleteRemovesStoredTargetImages(t *testing.T) {
	database := writeActionsConfig(t)
	orig := projectRemoveInstall
	projectRemoveInstall = func(context.Context, *config.Config, *db.Project) error { return nil }
	t.Cleanup(func() { projectRemoveInstall = orig })
	store := testImageStore(t)

	pid, err := database.CreateProject("acme", t.TempDir())
	require.NoError(t, err)
	other, err := database.CreateProject("other", t.TempDir())
	require.NoError(t, err)
	target := db.SeedTestProjectTarget(t, database, pid, sql.NullInt64{}, "with a screenshot")
	otherTarget := db.SeedTestProjectTarget(t, database, other, sql.NullInt64{}, "other board")
	stored := attachTestImage(t, database, store, pid, target, "a")
	kept := attachTestImage(t, database, store, other, otherTarget, "a")

	_, _, err = runProject(t, "delete", strconv.FormatInt(pid, 10))
	require.NoError(t, err)

	_, err = os.Stat(stored)
	assert.True(t, os.IsNotExist(err), "PROJ-02: the stored image survived project delete (err=%v)", err)
	_, err = os.Stat(store.Dir(pid))
	assert.True(t, os.IsNotExist(err), "PROJ-02: the project's image directory survived (err=%v)", err)
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM project_target_images WHERE project_id = ?`, pid).Scan(&n))
	assert.Zero(t, n)
	_, err = os.Stat(kept)
	assert.NoError(t, err, "another project's stored image is untouched")
}

// TestProj02_TargetDeleteDiscardsItsUnsharedImages: `targets delete` of a
// project target removes the stored copies no other target of the project
// names and keeps a shared one.
func TestProj02_TargetDeleteDiscardsItsUnsharedImages(t *testing.T) {
	database := writeActionsConfig(t)
	store := testImageStore(t)
	pid, err := database.CreateProject("acme", t.TempDir())
	require.NoError(t, err)
	doomed := db.SeedTestProjectTarget(t, database, pid, sql.NullInt64{}, "doomed")
	sibling := db.SeedTestProjectTarget(t, database, pid, sql.NullInt64{}, "sibling")
	own := attachTestImage(t, database, store, pid, doomed, "own")
	shared := attachTestImage(t, database, store, pid, doomed, "shared")
	require.Equal(t, shared, attachTestImage(t, database, store, pid, sibling, "shared"), "one copy per content")

	rootCmd.SetArgs([]string{"targets", "delete", strconv.FormatInt(doomed, 10)})
	err = rootCmd.Execute()
	rootCmd.SetArgs(nil)
	require.NoError(t, err)

	_, err = os.Stat(own)
	assert.True(t, os.IsNotExist(err), "PROJ-02: the deleted target's own image survived (err=%v)", err)
	_, err = os.Stat(shared)
	assert.NoError(t, err, "an image another target still carries stays")
}

// TestProject_DeleteJSONReportsAFailedImageCleanup: a failed removal of the
// stored copies is reported in files_ok/files_error and never undoes the
// delete.
func TestProject_DeleteJSONReportsAFailedImageCleanup(t *testing.T) {
	database := writeActionsConfig(t)
	orig := projectRemoveInstall
	projectRemoveInstall = func(context.Context, *config.Config, *db.Project) error { return nil }
	t.Cleanup(func() { projectRemoveInstall = orig })
	store := testImageStore(t)
	pid, err := database.CreateProject("acme", t.TempDir())
	require.NoError(t, err)
	target := db.SeedTestProjectTarget(t, database, pid, sql.NullInt64{}, "with a screenshot")
	attachTestImage(t, database, store, pid, target, "a")
	// A read-only project directory makes removing its file fail.
	require.NoError(t, os.Chmod(store.Dir(pid), 0o500))
	t.Cleanup(func() { _ = os.Chmod(store.Dir(pid), 0o700) })

	out, errOut, err := runProject(t, "delete", strconv.FormatInt(pid, 10), "--json")
	require.NoError(t, err)
	var got map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &got), "stdout is one JSON object: %q", out)
	assert.Equal(t, true, got["deleted"])
	assert.Equal(t, false, got["files_ok"])
	assert.NotEmpty(t, got["files_error"])
	assert.Contains(t, errOut, "stored images failed")
	_, err = database.GetProject(pid)
	assert.ErrorIs(t, err, db.ErrProjectNotFound, "the delete stands")
}

package db

import (
	"database/sql"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func attachImage(d *DB, projectID, targetID int64, sha string) (int64, error) {
	var id int64
	err := d.WithTx(func(tx *sql.Tx) error {
		var err error
		id, err = AddProjectTargetImageTx(tx, ProjectTargetImage{ProjectID: projectID, TargetID: targetID,
			FileName: "shot.png", MIME: "image/png", Size: 3, SHA256: sha, Path: "/store/" + sha + ".png"})
		return err
	})
	return id, err
}

func TestProjectTargetImages_AttachDedupesPerTargetAndCaps(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	a := insertProjectTargetRow(t, d, pid, "a")
	b := insertProjectTargetRow(t, d, pid, "b")

	first, err := attachImage(d, pid, a, "s1")
	require.NoError(t, err)
	again, err := attachImage(d, pid, a, "s1")
	require.NoError(t, err)
	assert.Equal(t, first, again, "the same content on the same target is one row")
	_, err = attachImage(d, pid, b, "s1")
	require.NoError(t, err, "the same content may sit on another target")

	for i := 2; i <= MaxTargetImages; i++ {
		_, err := attachImage(d, pid, a, fmt.Sprintf("s%d", i))
		require.NoError(t, err)
	}
	_, err = attachImage(d, pid, a, "one-too-many")
	assert.ErrorIs(t, err, ErrTooManyImages)
	_, err = attachImage(d, pid, a, "s1")
	assert.NoError(t, err, "re-attaching carried content is never refused by the cap")

	got, err := d.ListProjectTargetImages(a)
	require.NoError(t, err)
	assert.Len(t, got, MaxTargetImages)
	keep, err := d.ProjectImagePaths(pid)
	require.NoError(t, err)
	assert.Len(t, keep, MaxTargetImages, "paths are distinct across targets")
}

func TestProjectTargetImages_ScopedToTheProjectAndTarget(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	other := newTestProject(t, d)
	mine := insertProjectTargetRow(t, d, pid, "mine")
	theirs := insertProjectTargetRow(t, d, other, "theirs")

	_, err := attachImage(d, pid, theirs, "x")
	assert.ErrorIs(t, err, ErrNotInProject, "a target of another project is refused")

	id, err := attachImage(d, pid, mine, "x")
	require.NoError(t, err)
	err = d.WithTx(func(tx *sql.Tx) error {
		_, err := RemoveProjectTargetImageTx(tx, other, mine, id)
		return err
	})
	assert.ErrorIs(t, err, ErrNotInProject)
	var path string
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		var err error
		path, err = RemoveProjectTargetImageTx(tx, pid, mine, id)
		return err
	}))
	assert.Equal(t, "/store/x.png", path)
	got, err := d.ListProjectTargetImages(mine)
	require.NoError(t, err)
	assert.Empty(t, got)
}

func TestProjectTargetImages_GoWithTheirTarget(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	tid := insertProjectTargetRow(t, d, pid, "doomed")
	_, err := attachImage(d, pid, tid, "x")
	require.NoError(t, err)
	require.NoError(t, d.DeleteTarget(int(tid)))
	keep, err := d.ProjectImagePaths(pid)
	require.NoError(t, err)
	assert.Empty(t, keep)
}

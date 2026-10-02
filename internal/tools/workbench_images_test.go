package tools

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/projectfiles"
)

// imageRegistry is projectRegistry with a store the test can look into.
func imageRegistry(t *testing.T, d *db.DB) (*Registry, projectfiles.Store) {
	t.Helper()
	store := projectfiles.New(t.TempDir())
	reg := New(d)
	for _, tool := range append(ProjectTools(store, false), NewGetTarget()) {
		require.NoError(t, reg.Register(tool))
	}
	return reg, store
}

// fakeImage writes a file whose content sniffs as PNG.
func fakeImage(t *testing.T, name, payload string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	require.NoError(t, os.WriteFile(p, []byte("\x89PNG\r\n\x1a\n"+payload), 0o600))
	return p
}

func storedFiles(t *testing.T, store projectfiles.Store, projectID int64) []string {
	t.Helper()
	entries, err := os.ReadDir(store.Dir(projectID))
	if os.IsNotExist(err) {
		return nil
	}
	require.NoError(t, err)
	var out []string
	for _, e := range entries {
		out = append(out, e.Name())
	}
	return out
}

func createdTargetIDs(out map[string]any) []int64 {
	var ids []int64
	for _, c := range out["created"].([]any) {
		ids = append(ids, int64(c.(map[string]any)["target_id"].(float64)))
	}
	return ids
}

type targetImagesView struct {
	Images []db.ProjectTargetImage `json:"images"`
}

func targetImages(t *testing.T, reg *Registry, projectID, targetID int64) []db.ProjectTargetImage {
	t.Helper()
	var v targetImagesView
	require.NoError(t, json.Unmarshal([]byte(callReadIn(t, reg, projectID, "get_target", fmt.Sprintf(`{"id":%d}`, targetID))), &v))
	return v.Images
}

func TestCreateTargets_AttachesImagesAndGetTargetListsThem(t *testing.T) {
	fx := newProjectFixture(t)
	reg, store := imageRegistry(t, fx.d)
	shot := fakeImage(t, "Screenshot.png", "a")

	out := mustApply(t, reg, fx.a, "create_targets", fmt.Sprintf(
		`{"items":[{"key":"f","text":"Fix the header","images":[%q,%q]},{"text":"Plain","parent_key":"f"}],"reason":"r"}`,
		shot, shot))
	created := createdTargetIDs(out)

	images := targetImages(t, reg, fx.a, created[0])
	require.Len(t, images, 1, "one path named twice is one image")
	img := images[0]
	assert.Equal(t, "Screenshot.png", img.FileName)
	assert.Equal(t, "image/png", img.MIME)
	assert.Equal(t, filepath.Join(store.Dir(fx.a), img.SHA256+".png"), img.Path, "get_target names the stored copy")
	data, err := os.ReadFile(img.Path)
	require.NoError(t, err)
	assert.Equal(t, "\x89PNG\r\n\x1a\na", string(data))
	assert.Empty(t, targetImages(t, reg, fx.a, created[1]))
}

// A file Validate refuses fails the call before anything is copied in.
func TestCreateTargets_ARefusedImageFailsTheWholeCallBeforeAnyCopy(t *testing.T) {
	fx := newProjectFixture(t)
	reg, store := imageRegistry(t, fx.d)
	good := fakeImage(t, "good.png", "g")
	bad := filepath.Join(t.TempDir(), "notes.png")
	require.NoError(t, os.WriteFile(bad, []byte("not an image"), 0o600))

	_, err := proposeIn(t, reg, fx.a, "create_targets", fmt.Sprintf(
		`{"items":[{"text":"A","images":[%q]},{"text":"B","images":[%q]}],"reason":"r"}`, good, bad))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "not a PNG, JPEG, GIF or WebP image")
	assert.Equal(t, 1, countProjectTargets(t, fx.d, fx.a), "no target was created")
	assert.Empty(t, storedFiles(t, store, fx.a), "Validate refused the call before any copy was made")

	_, err = proposeIn(t, reg, fx.a, "create_targets", `{"items":[{"text":"A","images":["relative.png"]}],"reason":"r"}`)
	require.ErrorAs(t, err, &verr, "a relative path is refused before any file is read")

	var eleven []string
	for i := 0; i <= maxImagesPerCall; i++ {
		eleven = append(eleven, fmt.Sprintf("%q", good))
	}
	_, err = proposeIn(t, reg, fx.a, "create_targets",
		fmt.Sprintf(`{"items":[{"text":"A","images":[%s]}],"reason":"r"}`, strings.Join(eleven, ",")))
	require.ErrorAs(t, err, &verr, "more than maxImagesPerCall paths are refused")
	_, err = proposeIn(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"add_images":[%s],"reason":"r"}`,
		fx.aTarget, strings.Join(eleven, ",")))
	require.ErrorAs(t, err, &verr, "more than maxImagesPerCall add_images are refused")
	assert.Empty(t, storedFiles(t, store, fx.a))
}

// A write that fails after the images were copied in removes the copies it
// created, and never a copy it reused that another target still carries.
func TestCreateTargets_AFailedWriteRemovesOnlyTheCopiesItCreated(t *testing.T) {
	fx := newProjectFixture(t)
	reg, store := imageRegistry(t, fx.d)
	shared := fakeImage(t, "shared.png", "s")
	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"add_images":[%q],"reason":"r"}`, fx.aTarget, shared))
	sharedCopy := targetImages(t, reg, fx.a, fx.aTarget)[0].Path
	fresh := fakeImage(t, "fresh.png", "f")
	_, err := fx.d.Exec(`CREATE TRIGGER fail_image BEFORE INSERT ON project_target_images
		WHEN NEW.file_name = 'fresh.png' BEGIN SELECT RAISE(ABORT, 'boom'); END`)
	require.NoError(t, err)

	rc, err := proposeIn(t, reg, fx.a, "create_targets", fmt.Sprintf(
		`{"items":[{"text":"New","images":[%q,%q]}],"reason":"r"}`, shared, fresh))
	require.NoError(t, err)
	assert.Equal(t, "failed", rc.Status)
	assert.Contains(t, rc.Error, "boom")
	assert.Equal(t, 1, countProjectTargets(t, fx.d, fx.a), "the target rolled back")
	assert.Equal(t, []string{filepath.Base(sharedCopy)}, storedFiles(t, store, fx.a),
		"the fresh copy is gone, the shared one another target carries stays")

	// A copy the call merely reused — here one no row names yet, as when
	// another session stored it and has not committed — is never discarded.
	pending, err := store.Ingest(fx.a, fakeImage(t, "pending.png", "p"))
	require.NoError(t, err)
	_, err = fx.d.Exec(`DROP TRIGGER fail_image; CREATE TRIGGER fail_image BEFORE INSERT ON project_target_images
		BEGIN SELECT RAISE(ABORT, 'boom'); END`)
	require.NoError(t, err)
	rc, err = proposeIn(t, reg, fx.a, "create_targets", fmt.Sprintf(
		`{"items":[{"text":"New","images":[%q]}],"reason":"r"}`, fakeImage(t, "same.png", "p")))
	require.NoError(t, err)
	assert.Equal(t, "failed", rc.Status)
	_, err = os.Stat(pending.Path)
	assert.NoError(t, err, "a reused copy is not the failed call's to remove")
}

// A cleanup that fails after a failed write is reported in the error, which
// keeps its kind — a leftover copy is never silent.
func TestIngestedImagesUndo_ReportsAFailedCleanupKeepingTheErrorKind(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root ignores the read-only directory this test relies on")
	}
	fx := newProjectFixture(t)
	store := projectfiles.New(t.TempDir())
	in, err := ingestImages(fx.d, store, fx.a, []string{fakeImage(t, "x.png", "x")})
	require.NoError(t, err)
	require.NoError(t, os.Chmod(store.Dir(fx.a), 0o500))
	t.Cleanup(func() { _ = os.Chmod(store.Dir(fx.a), 0o700) })

	err = in.undo(fx.d, fx.a, &ValidationError{Msg: "too many", Err: db.ErrTooManyImages})
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.ErrorIs(t, err, db.ErrTooManyImages)
	assert.Contains(t, verr.Msg, "too many; also, copied image files could not all be removed")

	err = in.undo(fx.d, fx.a, fmt.Errorf("boom"))
	assert.False(t, errors.As(err, &verr))
	assert.Contains(t, err.Error(), "boom; also, copied image files could not all be removed")
}

func TestUpdateTarget_AddsAndRemovesImagesKeepingSharedCopies(t *testing.T) {
	fx := newProjectFixture(t)
	reg, store := imageRegistry(t, fx.d)
	shared := fakeImage(t, "shared.png", "s")
	own := fakeImage(t, "own.png", "o")
	out := mustApply(t, reg, fx.a, "create_targets", fmt.Sprintf(`{"items":[{"text":"Sibling","images":[%q]}],"reason":"r"}`, shared))
	sibling := createdTargetIDs(out)[0]

	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"add_images":[%q,%q],"reason":"r"}`, fx.aTarget, shared, own))
	images := targetImages(t, reg, fx.a, fx.aTarget)
	require.Len(t, images, 2)
	assert.Len(t, storedFiles(t, store, fx.a), 2, "the shared image is stored once")

	ids := []string{}
	for _, img := range images {
		ids = append(ids, fmt.Sprint(img.ID))
	}
	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"remove_image_ids":[%s],"reason":"r"}`,
		fx.aTarget, strings.Join(ids, ",")))
	assert.Empty(t, targetImages(t, reg, fx.a, fx.aTarget))
	files := storedFiles(t, store, fx.a)
	require.Len(t, files, 1, "the unshared copy is removed, the shared one stays")
	assert.Equal(t, filepath.Base(targetImages(t, reg, fx.a, sibling)[0].Path), files[0])

	_, err := proposeIn(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"remove_image_ids":[%s],"reason":"r"}`, fx.aTarget, ids[0]))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr, "an image the target no longer carries is refused")
}

func TestUpdateTarget_ImageCapFailsTheWholeUpdate(t *testing.T) {
	fx := newProjectFixture(t)
	reg, store := imageRegistry(t, fx.d)
	for batch := 0; batch < 2; batch++ {
		var paths []string
		for i := 0; i < maxImagesPerCall; i++ {
			paths = append(paths, fmt.Sprintf("%q", fakeImage(t, "x.png", fmt.Sprintf("%d-%d", batch, i))))
		}
		mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"add_images":[%s],"reason":"r"}`,
			fx.aTarget, strings.Join(paths, ",")))
	}
	require.Len(t, targetImages(t, reg, fx.a, fx.aTarget), db.MaxTargetImages)

	rc, err := proposeIn(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"text":"Renamed","add_images":[%q],"reason":"r"}`,
		fx.aTarget, fakeImage(t, "extra.png", "extra")))
	require.NoError(t, err)
	assert.Equal(t, "failed", rc.Status)
	assert.Contains(t, rc.Error, "at most 20 images")
	got, gerr := fx.d.GetTargetByID(int(fx.aTarget))
	require.NoError(t, gerr)
	assert.Equal(t, "Alpha feature", got.Text, "the rename rolled back with the refused attach")
	assert.Len(t, storedFiles(t, store, fx.a), db.MaxTargetImages, "the refused image's copy was removed")
}

package tools

import (
	"encoding/json"
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
	for _, tool := range append(ProjectTools(store), NewGetTarget()) {
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

func TestCreateTargets_ARefusedImageFailsTheWholeCallAndLeavesNoFile(t *testing.T) {
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
	assert.Empty(t, storedFiles(t, store, fx.a), "the good image's copy was removed again")

	_, err = proposeIn(t, reg, fx.a, "create_targets", `{"items":[{"text":"A","images":["relative.png"]}],"reason":"r"}`)
	require.ErrorAs(t, err, &verr, "a relative path is refused before any file is read")
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
	if err == nil {
		assert.Equal(t, "failed", rc.Status)
	}
	got, gerr := fx.d.GetTargetByID(int(fx.aTarget))
	require.NoError(t, gerr)
	assert.Equal(t, "Alpha feature", got.Text, "the rename rolled back with the refused attach")
	assert.Len(t, storedFiles(t, store, fx.a), db.MaxTargetImages, "the refused image's copy was removed")
}

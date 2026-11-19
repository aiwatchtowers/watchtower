package kb

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/workbenchdocs"
)

// hubFolderID is the second folder the multi-folder fixtures put on
// workbench 1.
const hubFolderID = 5

// seedTwoFolderBench creates workbench 1 (home folder, row 1) with a second
// folder, hub (row hubFolderID), each holding one plan, and workbench 2.
func seedTwoFolderBench(t *testing.T, d *db.DB) (home, hub string) {
	t.Helper()
	home, hub, other := t.TempDir(), t.TempDir(), t.TempDir()
	writeWorkbenchFile(t, home, "plan.md", "# App\nроадмап приложения\n")
	writeWorkbenchFile(t, hub, "plan.md", "# Hub\nроадмап хаба\n")
	writeWorkbenchFile(t, other, "plan.md", "# Other\nроадмап другого\n")
	seedBench(t, d, 1, "acme", home)
	seedFolder(t, d, 1, hubFolderID, "hub", hub, 1)
	seedBench(t, d, 2, "beta", other)
	return home, hub
}

// TestProj08_EveryFolderIsIndexedUnderItsWorkbench (spec §4 item 7, §8
// PROJ-08 amended): the documents of every folder of a workbench are indexed
// under wbdoc:<workbench>:<folder>:<rel>, searchable and openable only from
// that workbench's session; a later pass matches the keys it wrote (the
// shape 00208 rekeyed the older rows to), writing and dropping nothing.
func TestProj08_EveryFolderIsIndexedUnderItsWorkbench(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedTwoFolderBench(t, d)
	runWorkbenchDocs(t, d)
	assert.Equal(t, []string{"wbdoc:1:1:plan.md", "wbdoc:1:5:plan.md", "wbdoc:2:2:plan.md"}, indexedIDs(t, d))

	search := func(workbenchID int64) []string {
		res, err := Search(ctx, d, Request{Queries: []string{"роадмап"}, WorkbenchID: workbenchID, Limit: MaxLimit, Now: testNow()})
		require.NoError(t, err)
		return hitRefs(res)
	}
	assert.ElementsMatch(t, []string{"wbdoc:1:1:plan.md", "wbdoc:1:5:plan.md"}, search(1), "both folders, one workbench")
	assert.Equal(t, []string{"wbdoc:2:2:plan.md"}, search(2))
	assert.Empty(t, search(0))
	for _, wb := range []int64{0, 2} {
		_, err := GetDocument(ctx, d, "wbdoc:1:5:plan.md", DocOptions{WorkbenchID: wb})
		assert.ErrorIs(t, err, ErrNotFound, "from workbench %d", wb)
	}
	doc, err := GetDocument(ctx, d, "wbdoc:1:5:plan.md", DocOptions{WorkbenchID: 1})
	require.NoError(t, err)
	assert.Equal(t, "hub/plan.md", doc.Title, "two folders: shown as <folder>/<rel>")

	st := runWorkbenchDocs(t, d)
	assert.Zero(t, st.Written, "the keys match: nothing re-written")
	assert.Zero(t, st.Deleted, "the keys match: nothing dropped")

	// The explicit trigger covers every folder too.
	writeWorkbenchFile(t, mustFolder(t, d, hubFolderID), "new.md", "# New\nсвежий\n")
	_, _, err = IndexWorkbenchDocs(ctx, d, 1)
	require.NoError(t, err)
	assert.Contains(t, indexedIDs(t, d), "wbdoc:1:5:new.md")
}

func mustFolder(t *testing.T, d *db.DB, id int64) string {
	t.Helper()
	var path string
	require.NoError(t, d.QueryRow(`SELECT folder_path FROM workbench_folders WHERE id = ?`, id).Scan(&path))
	return path
}

// TestProj08_CapIsPerFolder: the 2 000-document cap counts each folder on
// its own — a full app folder never keeps the hub's documents out.
func TestProj08_CapIsPerFolder(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	_, _ = seedTwoFolderBench(t, d)
	app := mustFolder(t, d, 1)
	base := time.Now().Add(-time.Hour)
	for i := range workbenchdocs.MaxTextFiles {
		rel := fmt.Sprintf("n%04d.md", i)
		writeWorkbenchFile(t, app, rel, "x")
		at := base.Add(time.Duration(i) * time.Second)
		require.NoError(t, os.Chtimes(filepath.Join(app, rel), at, at))
	}

	documents, _, err := IndexWorkbenchDocs(ctx, d, 1)
	require.NoError(t, err)
	assert.Equal(t, workbenchdocs.MaxTextFiles+1, documents, "the app's newest 2000, and the hub's own")
	assert.Contains(t, indexedIDs(t, d), "wbdoc:1:5:plan.md", "the hub is indexed past the app's cap")
	assert.NotContains(t, indexedIDs(t, d), "wbdoc:1:1:n0000.md", "the app's oldest file is cut at its own cap")
}

// TestRemovedFolderDocsAreDropped (spec §6.3): a folder that leaves its
// workbench loses its index entries — at the daemon's reconcile, at the
// explicit trigger, and at once through DropWorkbenchFolderDocs — and the
// other folders keep theirs.
func TestRemovedFolderDocsAreDropped(t *testing.T) {
	ctx := context.Background()
	remove := func(d *db.DB) {
		t.Helper()
		exec(t, d, `UPDATE workbench_folders SET removed_at = '2026-11-18T00:00:00Z' WHERE id = ?`, hubFolderID)
	}
	kept := []string{"wbdoc:1:1:plan.md", "wbdoc:2:2:plan.md"}

	t.Run("daemon reconcile", func(t *testing.T) {
		d := db.OpenTestDB(t)
		seedTwoFolderBench(t, d)
		runWorkbenchDocs(t, d)
		remove(d)
		runWorkbenchDocs(t, d)
		assert.Equal(t, kept, indexedIDs(t, d))
	})
	t.Run("explicit trigger", func(t *testing.T) {
		d := db.OpenTestDB(t)
		seedTwoFolderBench(t, d)
		_, _, err := IndexWorkbenchDocs(ctx, d, 1)
		require.NoError(t, err)
		_, _, err = IndexWorkbenchDocs(ctx, d, 2)
		require.NoError(t, err)
		remove(d)
		_, _, err = IndexWorkbenchDocs(ctx, d, 1)
		require.NoError(t, err)
		assert.Equal(t, kept, indexedIDs(t, d))
	})
	t.Run("drop at once", func(t *testing.T) {
		d := db.OpenTestDB(t)
		seedTwoFolderBench(t, d)
		runWorkbenchDocs(t, d)
		remove(d)
		n, err := DropWorkbenchFolderDocs(ctx, d, 1, hubFolderID)
		require.NoError(t, err)
		assert.Equal(t, 1, n)
		assert.Equal(t, kept, indexedIDs(t, d))
	})
}

package kb

import (
	"context"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// IndexFileSet indexes the files it is given and touches no other entry of
// the container: one file indexed alone (the agent's ask_owner) leaves the
// rest of the workbench's entries in place.
func TestIndexFileSet_IndexesOnlyTheGivenFiles(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	folder := seedWorkbenchDocs(t, d)
	runWorkbenchDocs(t, d)

	writeWorkbenchFile(t, folder, "docs/new.md", "# New\nсвежий документ\n")
	set := FileSet{Source: WorkbenchDocSource, Container: fixtureWorkbenchID, Root: folder, Files: []string{"docs/new.md"}}
	docs, changed, err := IndexFileSet(ctx, d, set)
	require.NoError(t, err)
	assert.Equal(t, 1, docs)
	assert.Equal(t, 1, changed)
	assert.Equal(t, []string{fixtureReadmeRef, "wbdoc:1:docs/new.md", fixturePlanRef}, indexedIDs(t, d))
	assert.Contains(t, indexedText(t, d, "wbdoc:1:docs/new.md"), "свежий")

	_, changed, err = IndexFileSet(ctx, d, set)
	require.NoError(t, err)
	assert.Zero(t, changed, "unchanged: nothing written")

	// An edit whose mtime did not move (made in the second of the last index).
	at := time.Now().Add(-time.Hour)
	require.NoError(t, os.Chtimes(filepath.Join(folder, "docs/new.md"), at, at))
	_, _, err = IndexFileSet(ctx, d, set)
	require.NoError(t, err)
	writeWorkbenchFile(t, folder, "docs/new.md", "# New\nвторая правка\n")
	require.NoError(t, os.Chtimes(filepath.Join(folder, "docs/new.md"), at, at))
	_, changed, err = IndexFileSet(ctx, d, set)
	require.NoError(t, err)
	assert.Equal(t, 1, changed, "an explicit trigger re-reads a file whose mtime did not move")
	assert.Contains(t, indexedText(t, d, "wbdoc:1:docs/new.md"), "вторая")
}

// An edit with an older mtime is re-indexed, and a file gone from disk
// loses its entry.
func TestIndexFileSet_OlderMtimeAndGoneFile(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	folder := seedWorkbenchDocs(t, d)
	readme := filepath.Join(folder, "README.md")
	set := FileSet{Source: WorkbenchDocSource, Container: fixtureWorkbenchID, Root: folder, Files: []string{"README.md"}}
	_, _, err := IndexFileSet(ctx, d, set)
	require.NoError(t, err)

	writeWorkbenchFile(t, folder, "README.md", "восстановлено из бэкапа\n")
	older := time.Now().Add(-72 * time.Hour)
	require.NoError(t, os.Chtimes(readme, older, older))
	_, changed, err := IndexFileSet(ctx, d, set)
	require.NoError(t, err)
	assert.Equal(t, 1, changed)
	assert.Contains(t, indexedText(t, d, fixtureReadmeRef), "бэкапа")

	require.NoError(t, os.Remove(readme))
	_, changed, err = IndexFileSet(ctx, d, set)
	require.NoError(t, err)
	assert.Equal(t, 1, changed)
	assert.Empty(t, indexedIDs(t, d))
}

// A named pipe is indexed as unreadable, and the indexer never blocks on it.
func TestIndexFileSet_NamedPipeIsUnreadableNeverBlocking(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	folder := seedWorkbenchDocs(t, d)
	require.NoError(t, syscall.Mkfifo(filepath.Join(folder, "pipe.md"), 0o600))
	done := make(chan error, 1)
	go func() {
		_, _, err := IndexFileSet(ctx, d, FileSet{Source: WorkbenchDocSource, Container: fixtureWorkbenchID, Root: folder, Files: []string{"pipe.md"}})
		done <- err
	}()
	select {
	case err := <-done:
		require.NoError(t, err)
	case <-time.After(5 * time.Second):
		t.Fatal("indexing a named pipe blocked")
	}
	var anchor string
	require.NoError(t, d.QueryRow(`SELECT json_extract(anchor_json, '$.unreadable') FROM kb_documents WHERE id = 'wbdoc:1:pipe.md'`).Scan(&anchor))
	assert.Equal(t, "not a regular file", anchor)
}

// A path that is not inside the root, or a source that keeps no file set,
// is refused before anything is written.
func TestIndexFileSet_RefusesBadInput(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	folder := seedWorkbenchDocs(t, d)
	for _, rel := range []string{"../x.md", "/etc/hosts", "", "."} {
		_, _, err := IndexFileSet(ctx, d, FileSet{Source: WorkbenchDocSource, Container: fixtureWorkbenchID, Root: folder, Files: []string{"README.md", rel}})
		assert.Error(t, err, rel)
	}
	_, _, err := IndexFileSet(ctx, d, FileSet{Source: "jira", Container: 1, Root: folder, Files: []string{"README.md"}})
	assert.Error(t, err)
	assert.Empty(t, indexedIDs(t, d))
}

package workbenchdocs

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func writeFile(t *testing.T, folder, rel string, age time.Duration) {
	t.Helper()
	p := filepath.Join(folder, filepath.FromSlash(rel))
	require.NoError(t, os.MkdirAll(filepath.Dir(p), 0o755))
	require.NoError(t, os.WriteFile(p, []byte("# "+rel+"\n"), 0o644))
	at := time.Now().Add(-age)
	require.NoError(t, os.Chtimes(p, at, at))
}

func newWorkbench(t *testing.T) (*db.DB, *db.Workbench) {
	t.Helper()
	d := db.OpenTestDB(t)
	folder, err := db.ResolveWorkbenchFolder(t.TempDir(), nil)
	require.NoError(t, err)
	id, err := d.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	p, err := d.GetWorkbench(id)
	require.NoError(t, err)
	return d, p
}

func relPaths(cs []Candidate) []string {
	out := make([]string, 0, len(cs))
	for _, c := range cs {
		out = append(out, c.RelPath)
	}
	return out
}

// The scan finds the root README and .md/.txt files directly inside a specs or
// plans directory anywhere under docs/, README first, then newest first, and
// nothing else.
func TestScan_FindsReadmeSpecsAndPlansNewestFirst(t *testing.T) {
	_, p := newWorkbench(t)
	f := p.FolderPath
	writeFile(t, f, "README.md", 10*time.Hour)
	writeFile(t, f, "docs/superpowers/specs/old-spec.md", 5*time.Hour)
	writeFile(t, f, "docs/plans/new-plan.txt", time.Hour)
	writeFile(t, f, "docs/specs/diagram.pdf", 0)              // wrong extension
	writeFile(t, f, "docs/notes/idea.md", 0)                  // not a specs/plans dir
	writeFile(t, f, "docs/specs/deeper/nested.md", 0)         // not directly inside specs
	writeFile(t, f, "docs/.cache/specs/hidden.md", 0)         // hidden dir
	writeFile(t, f, "docs/node_modules/specs/vendored.md", 0) // node_modules
	writeFile(t, f, "specs/outside-docs.md", 0)               // not under docs/

	got, _, err := Scan(f)
	require.NoError(t, err)
	assert.Equal(t, []string{"README.md", "docs/plans/new-plan.txt", "docs/superpowers/specs/old-spec.md"}, relPaths(got))
	assert.Equal(t, "doc", got[0].Kind)
	assert.Equal(t, "plan", got[1].Kind)
	assert.Equal(t, "spec", got[2].Kind)
	assert.Equal(t, "old-spec", got[2].Title)
}

// Symlinks are never followed or listed: a linked file, a linked directory and
// a docs/ that is itself a link all stay out, so no rel_path leaves the folder.
func TestScan_IgnoresSymlinks(t *testing.T) {
	_, p := newWorkbench(t)
	outside := t.TempDir()
	writeFile(t, outside, "specs/secret.md", 0)
	writeFile(t, outside, "note.md", 0)
	writeFile(t, p.FolderPath, "docs/specs/real.md", 0)
	require.NoError(t, os.Symlink(filepath.Join(outside, "note.md"), filepath.Join(p.FolderPath, "docs/specs/link.md")))
	require.NoError(t, os.Symlink(outside, filepath.Join(p.FolderPath, "docs/ext")))

	got, _, err := Scan(p.FolderPath)
	require.NoError(t, err)
	assert.Equal(t, []string{"docs/specs/real.md"}, relPaths(got))

	linked := t.TempDir()
	require.NoError(t, os.Symlink(outside, filepath.Join(linked, "docs")))
	got, _, err = Scan(linked)
	require.NoError(t, err)
	assert.Empty(t, got, "a docs/ that is a symlink is not walked")
}

// Import is additive and idempotent: an attached document is never touched,
// a second run imports nothing, and imported rows carry origin 'import'.
func TestImport_AdditiveIdempotentAndMarkedImport(t *testing.T) {
	d, p := newWorkbench(t)
	writeFile(t, p.FolderPath, "README.md", 0)
	writeFile(t, p.FolderPath, "docs/specs/a.md", 0)
	agentID, _, err := d.UpsertWorkbenchDocument(db.WorkbenchDocument{WorkbenchID: p.ID, RelPath: "docs/specs/A.md", Kind: "spec", Title: "Agent title"})
	require.NoError(t, err)
	before, err := d.GetWorkbenchDocument(agentID)
	require.NoError(t, err)

	rep, err := Import(d, p, false)
	require.NoError(t, err)
	assert.Equal(t, []string{"README.md"}, rep.Imported)
	assert.Equal(t, []string{"docs/specs/a.md"}, rep.AlreadyAttached, "another spelling of an attached path is the same file")

	after, err := d.GetWorkbenchDocument(agentID)
	require.NoError(t, err)
	assert.Equal(t, before, after, "an attached document is never touched")
	assert.Equal(t, "agent", after.Origin)

	docs, err := d.ListWorkbenchDocuments(p.ID)
	require.NoError(t, err)
	require.Len(t, docs, 2)
	assert.Equal(t, "import", docs[1].Origin)
	assert.Equal(t, "doc", docs[1].Kind)

	again, err := Import(d, p, false)
	require.NoError(t, err)
	assert.Empty(t, again.Imported)
	assert.Len(t, again.AlreadyAttached, 2)
}

func TestImport_DryRunWritesNothing(t *testing.T) {
	d, p := newWorkbench(t)
	writeFile(t, p.FolderPath, "docs/plans/p.md", 0)
	rep, err := Import(d, p, true)
	require.NoError(t, err)
	assert.True(t, rep.DryRun)
	assert.Equal(t, []string{"docs/plans/p.md"}, rep.Imported)
	docs, err := d.ListWorkbenchDocuments(p.ID)
	require.NoError(t, err)
	assert.Empty(t, docs)
}

// The cap counts only new documents: past it the rest is reported, and the
// next run picks it up.
func TestImport_CapReportsTheRestAndTheNextRunTakesIt(t *testing.T) {
	d, p := newWorkbench(t)
	for i := range MaxImport + 5 {
		writeFile(t, p.FolderPath, fmt.Sprintf("docs/specs/s%02d.md", i), time.Duration(i)*time.Minute)
	}
	rep, err := Import(d, p, false)
	require.NoError(t, err)
	assert.Len(t, rep.Imported, MaxImport)
	assert.Equal(t, []string{"docs/specs/s50.md", "docs/specs/s51.md", "docs/specs/s52.md", "docs/specs/s53.md", "docs/specs/s54.md"},
		rep.SkippedOverCap, "the oldest are left out")

	next, err := Import(d, p, false)
	require.NoError(t, err)
	assert.Len(t, next.Imported, 5)
	assert.Empty(t, next.SkippedOverCap)
}

// An agent re-attach of an imported document makes it the agent's.
func TestUpsertProjectDocument_ReattachOfImportBecomesAgent(t *testing.T) {
	d, p := newWorkbench(t)
	writeFile(t, p.FolderPath, "docs/plans/p.md", 0)
	_, err := Import(d, p, false)
	require.NoError(t, err)
	id, created, err := d.UpsertWorkbenchDocument(db.WorkbenchDocument{WorkbenchID: p.ID, RelPath: "docs/plans/p.md", Kind: "plan"})
	require.NoError(t, err)
	assert.False(t, created)
	doc, err := d.GetWorkbenchDocument(id)
	require.NoError(t, err)
	assert.Equal(t, "agent", doc.Origin)
}

// A path below docs/ that cannot be read is skipped and reported; the rest,
// README included, is imported. Only an unreadable docs/ fails the import.
func TestImport_UnreadablePathIsSkippedAndReported(t *testing.T) {
	d, p := newWorkbench(t)
	writeFile(t, p.FolderPath, "README.md", 0)
	writeFile(t, p.FolderPath, "docs/plans/p.md", 0)
	writeFile(t, p.FolderPath, "docs/private/specs/s.md", 0)
	locked := filepath.Join(p.FolderPath, "docs", "private")
	require.NoError(t, os.Chmod(locked, 0))
	t.Cleanup(func() { _ = os.Chmod(locked, 0o755) })

	rep, err := Import(d, p, false)
	require.NoError(t, err)
	assert.Equal(t, []string{"README.md", "docs/plans/p.md"}, rep.Imported)
	assert.Equal(t, []string{"docs/private: permission denied"}, rep.Unreadable)

	docs := filepath.Join(p.FolderPath, "docs")
	require.NoError(t, os.Chmod(docs, 0))
	t.Cleanup(func() { _ = os.Chmod(docs, 0o755) })
	_, err = Import(d, p, false)
	assert.Error(t, err, "an unreadable docs/ is not skipped")
}
